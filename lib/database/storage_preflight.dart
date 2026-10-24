import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../core/constants.dart';
import '../core/logger.dart';

/// 存储预检失败类型（规格§四）。
enum StoragePreflightIssue {
  /// 数据目录不存在且无法创建（权限 / 路径被占用）。
  directoryUnavailable,

  /// 临时探针文件无法创建 / 写入 / 删除 → 目录不可写。
  probeWriteFailed,

  /// `petlife.db` / `-wal` / `-shm` 存在但无法以写方式打开（只读属性）。
  readOnlyDatabaseFiles,

  /// 数据库能探到但打开或轻量写事务失败（锁 / 损坏 / 权限）。
  openOrWriteFailed,
}

/// 存储预检失败：携带**面向用户的中文结果**与**面向日志/剪贴板的诊断**。
///
/// [userMessage] / [userDetail] 供诊断页展示，**绝不包含原始 SQLite 堆栈**；
/// [diagnosticText] 含异常首行摘要，供「复制诊断信息」与日志使用。
class StoragePreflightFailure implements Exception {
  const StoragePreflightFailure({
    required this.issue,
    required this.dataDirPath,
    required this.userMessage,
    required this.userDetail,
    required this.diagnosticText,
  });

  final StoragePreflightIssue issue;
  final String dataDirPath;
  final String userMessage;
  final String userDetail;
  final String diagnosticText;

  @override
  String toString() => '$userMessage（$issue）';
}

/// 数据库启动前检查（规格§四：只有主实例可以走到这里）。
///
/// 依次检查：
/// 1. 数据目录存在；不存在则创建；
/// 2. 在数据目录创建并删除一个临时探针文件；
/// 3. 验证 `petlife.db`、`-wal`、`-shm` 没有只读属性（真实以写方式打开）；
/// 4. `verifyDatabaseWriteTx`：打开数据库后执行轻量写事务。
///
/// 任何一步失败都抛 [StoragePreflightFailure]，调用方展示中文诊断页，
/// **不得**进入主界面，**不得**自动删除、重建或移动用户数据库。
class StoragePreflight {
  StoragePreflight._();

  /// 探针文件名前缀。后缀带当前 PID：
  /// * 同机多个实例几乎同时预检时不会争抢同一个文件（Windows 打开已存在
  ///   且被占用而无共享写标志的文件会报 errno=5）；
  /// * 上一次运行被强杀留下的探针残留不会影响下一次预检。
  static String _probeFileName() => '.petlife-write-probe-$pid.tmp';

  /// 主动清理本进程可能残留的探针文件（幂等；只动探针，绝不动数据库）。
  static void _cleanStaleProbe(Directory dataDir) {
    try {
      for (final FileSystemEntity entity in dataDir.listSync()) {
        final String name = p.basename(entity.path);
        if (name.startsWith('.petlife-write-probe-') && name.endsWith('.tmp')) {
          (entity as File).deleteSync();
        }
      }
    } catch (_) {
      // 清理失败不影响预检结论。
    }
  }

  /// 步骤 1-3（目录 / 探针 / 只读校验）。
  ///
  /// 抛出的 [StoragePreflightFailure.dataDirPath] 供诊断页展示。
  static Future<void> ensureWritable({
    required Directory dataDir,
    required File dbFile,
  }) async {
    final String dirPath = dataDir.path;

    // 1. 数据目录存在；不存在则创建。
    try {
      if (!await dataDir.exists()) {
        await dataDir.create(recursive: true);
      }
    } catch (e, st) {
      Loggers.db.severe('存储预检：数据目录不可用：$dirPath', e, st);
      throw _failure(
        issue: StoragePreflightIssue.directoryUnavailable,
        dataDirPath: dirPath,
        error: e,
      );
    }

    // 先清掉历史运行残留的探针文件（只动探针，绝不动数据库）。
    _cleanStaleProbe(dataDir);

    // 2. 临时探针：创建 → 写入 → 删除（文件名带 PID，跨进程唯一）。
    //
    //    部分安全软件/终端防护会对「新进程在既有目录创建 .tmp」瞬时拒访
    //    （errno=5），同目录的日志追加却正常。因此这里按顺序尝试三种
    //    打开方式并做短重试，任何一种成功即证明目录可写；全部失败才
    //    判定 probeWriteFailed（避免把瞬时拦截误报成目录不可写）。
    final String probeName = _probeFileName();
    final File probe = File(p.join(dirPath, probeName));
    Object? lastError;
    bool probed = false;
    for (final String attemptName in <String>[
      probeName,
      '$probeName.a',
      '${probeName}1',
    ]) {
      final File candidate = File(p.join(dirPath, attemptName));
      for (int retry = 0; retry < 2 && !probed; retry++) {
        try {
          await candidate.writeAsString('probe', flush: true);
          if (await candidate.exists()) {
            await candidate.delete();
          }
          probed = true;
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      if (probed) break;
      // 备选方案：RandomAccessFile 直接以写模式打开（不同 CreateFile 路径）。
      try {
        final RandomAccessFile handle =
            await candidate.open(mode: FileMode.write);
        await handle.writeString('probe');
        await handle.flush();
        await handle.close();
        await candidate.delete();
        probed = true;
      } catch (e) {
        lastError = e;
      }
      if (probed) break;
    }
    if (!probed) {
      Loggers.db.severe('存储预检：探针文件写入失败：${probe.path}', lastError);
      throw _failure(
        issue: StoragePreflightIssue.probeWriteFailed,
        dataDirPath: dirPath,
        error: lastError ?? '未知错误',
      );
    }

    // 3. 数据库三件套没有只读属性：以追加写方式真实打开（不改内容）。
    final List<String> lockedFiles = <String>[];
    for (final String suffix in <String>['', '-wal', '-shm']) {
      final File file = File('${dbFile.path}$suffix');
      if (!await file.exists()) continue;
      try {
        final RandomAccessFile handle = await file.open(mode: FileMode.append);
        await handle.close();
      } catch (e, st) {
        Loggers.db.severe('存储预检：数据库文件不可写：${file.path}', e, st);
        lockedFiles.add(p.basename(file.path));
      }
    }
    if (lockedFiles.isNotEmpty) {
      throw StoragePreflightFailure(
        issue: StoragePreflightIssue.readOnlyDatabaseFiles,
        dataDirPath: dirPath,
        userMessage: 'PetLife 数据库文件为只读，无法写入',
        userDetail: '以下文件不可写：\n${lockedFiles.join('、')}',
        diagnosticText:
            'issue=readOnlyDatabaseFiles dir=$dirPath files=${lockedFiles.join(",")}',
      );
    }
  }

  /// 步骤 4：轻量写事务——把 schema 版本写回 `PRAGMA user_version`
  ///（值不变，只动数据库头页与 WAL），既证明写路径可用，又零逻辑副作用。
  ///
  /// PRAGMA 一律走 rawQuery（项目规则，见 database_pragma_test.dart：
  /// Android 的 execute() 拒绝任何返回结果行的语句）。
  /// `:memory:` 数据库（测试）没有落盘语义，跳过。
  static Future<void> verifyDatabaseWriteTx(Database db) async {
    if (db.path == ':memory:') return;
    try {
      await db.transaction((Transaction txn) async {
        await txn.rawQuery(
          'PRAGMA user_version = ${AppConstants.databaseSchemaVersion}',
        );
      });
      Loggers.db.info('存储预检：轻量写事务通过（数据库可写）');
    } catch (e, st) {
      Loggers.db.severe('存储预检：轻量写事务失败', e, st);
      throw _failure(
        issue: StoragePreflightIssue.openOrWriteFailed,
        dataDirPath: p.dirname(db.path),
        error: e,
      );
    }
  }

  static StoragePreflightFailure _failure({
    required StoragePreflightIssue issue,
    required String dataDirPath,
    required Object error,
  }) {
    final String firstLine = error.toString().split('\n').first;
    final String message = switch (issue) {
      StoragePreflightIssue.directoryUnavailable ||
      StoragePreflightIssue.probeWriteFailed =>
        'PetLife 无法写入本地数据目录',
      StoragePreflightIssue.readOnlyDatabaseFiles =>
        'PetLife 数据库文件为只读，无法写入',
      StoragePreflightIssue.openOrWriteFailed =>
        'PetLife 无法打开或写入本地数据库',
    };
    return StoragePreflightFailure(
      issue: issue,
      dataDirPath: dataDirPath,
      userMessage: message,
      userDetail: firstLine.length > 160 ? firstLine.substring(0, 160) : firstLine,
      diagnosticText: 'issue=$issue dir=$dataDirPath error=$firstLine',
    );
  }
}
