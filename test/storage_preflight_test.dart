import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:petlife/core/constants.dart';
import 'package:petlife/database/storage_preflight.dart';

import 'support/sqlite_test_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  Future<void> clearReadOnly(FileSystemEntity entity) async {
    final String path = entity.path;
    if (Platform.isWindows) {
      await Process.run('attrib', <String>['-R', path]);
    } else {
      await Process.run('chmod', <String>['u+w', path]);
    }
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('petlife_preflight_');
  });

  tearDown(() async {
    // 只读属性会阻止 tearDown 删除：先清属性再删。
    for (final FileSystemEntity entity in tempRoot.listSync(recursive: true)) {
      if (entity is File) {
        await clearReadOnly(entity);
      }
    }
    await clearReadOnly(Directory(p.join(tempRoot.path, 'blocked')));
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('StoragePreflight.ensureWritable（规格§四：数据库启动前检查）', () {
    test('可写目录顺利通过且不残留探针文件', () async {
      final Directory dir = Directory(p.join(tempRoot.path, 'PetLife'));
      final File db = File(p.join(dir.path, AppConstants.databaseFileName));

      await StoragePreflight.ensureWritable(dataDir: dir, dbFile: db);

      expect(dir.existsSync(), isTrue);
      expect(
        dir
            .listSync()
            .whereType<File>()
            .where((File f) =>
                p.basename(f.path).startsWith('.petlife-write-probe-'))
            .isEmpty,
        isTrue,
        reason: '探针文件必须创建后删除（含 PID 后缀的探针不残留）',
      );
    });

    test('数据目录被同名文件占用 → directoryUnavailable + 中文文案', () async {
      // 把“目录路径”用一个文件占住：create(recursive) 必然失败。
      final String blockedPath = p.join(tempRoot.path, 'blocked');
      await File(blockedPath).writeAsString('occupied');

      final StoragePreflightFailure failure = await _capture(() {
        return StoragePreflight.ensureWritable(
          dataDir: Directory(p.join(blockedPath, 'PetLife')),
          dbFile: File(p.join(blockedPath, 'PetLife', 'petlife.db')),
        );
      });

      expect(failure.issue, StoragePreflightIssue.directoryUnavailable);
      expect(failure.userMessage, 'PetLife 无法写入本地数据目录');
      expect(failure.dataDirPath, contains('blocked'));
    });

    test('探针候选全部被同名目录占用 → probeWriteFailed', () async {
      final Directory dir = Directory(p.join(tempRoot.path, 'PetLife'));
      await dir.create(recursive: true);
      // 探针会依次尝试三个候选文件名（瞬时拦截重试设计）；
      // 全部以同名目录占住，writeAsString 必然失败。
      for (final String name in <String>[
        '.petlife-write-probe-$pid.tmp',
        '.petlife-write-probe-$pid.tmp.a',
        '.petlife-write-probe-$pid.tmp1',
      ]) {
        await Directory(p.join(dir.path, name)).create();
      }

      final StoragePreflightFailure failure = await _capture(() {
        return StoragePreflight.ensureWritable(
          dataDir: dir,
          dbFile: File(p.join(dir.path, AppConstants.databaseFileName)),
        );
      });

      expect(failure.issue, StoragePreflightIssue.probeWriteFailed);
      expect(failure.userMessage, 'PetLife 无法写入本地数据目录');
      expect(failure.diagnosticText, contains('probeWriteFailed'));
    });
  });

  group('只读数据库文件校验', () {
    test('petlife.db 带只读属性 → readOnlyDatabaseFiles（真实 attrib +R）',
        () async {
      final Directory dir = Directory(p.join(tempRoot.path, 'PetLife'));
      await dir.create(recursive: true);
      final File db = File(p.join(dir.path, AppConstants.databaseFileName));
      await db.writeAsString('fake sqlite');
      final ProcessResult result =
          await Process.run('attrib', <String>['+R', db.path]);
      expect(result.exitCode, 0, reason: '测试环境必须能设置只读属性');

      final StoragePreflightFailure failure = await _capture(() {
        return StoragePreflight.ensureWritable(dataDir: dir, dbFile: db);
      });

      expect(failure.issue, StoragePreflightIssue.readOnlyDatabaseFiles);
      expect(failure.userDetail, contains(AppConstants.databaseFileName));
      expect(failure.diagnosticText, isNot(contains('SqliteException')),
          reason: '诊断文本不得暴露原始 SQLite 堆栈');
    }, testOn: 'windows');

    test('只读属性作用在 -wal 上同样失败', () async {
      final Directory dir = Directory(p.join(tempRoot.path, 'PetLife'));
      await dir.create(recursive: true);
      final File db = File(p.join(dir.path, AppConstants.databaseFileName));
      await db.writeAsString('db');
      final File wal = File('${db.path}-wal');
      await wal.writeAsString('wal');
      await Process.run('attrib', <String>['+R', wal.path]);

      final StoragePreflightFailure failure = await _capture(() {
        return StoragePreflight.ensureWritable(dataDir: dir, dbFile: db);
      });

      expect(failure.issue, StoragePreflightIssue.readOnlyDatabaseFiles);
    }, testOn: 'windows');
  });

  group('StoragePreflight.verifyDatabaseWriteTx（轻量写事务）', () {
    test('真实 SQLite：写 PRAGMA user_version 事务通过且库仍可用', () async {
      SqliteTestBootstrap.ensureLoaded();
      final String dbPath = p.join(tempRoot.path, 'tx.db');
      final Database db = await databaseFactoryFfi.openDatabase(dbPath);

      await StoragePreflight.verifyDatabaseWriteTx(db);
      final List<Map<String, Object?>> rows =
          await db.rawQuery('PRAGMA user_version');
      expect((rows.first['user_version'] as int?) ?? 0,
          AppConstants.databaseSchemaVersion);

      await db.close();
    });

    test('写失败 → openOrWriteFailed（映射为中文诊断）', () async {
      SqliteTestBootstrap.ensureLoaded();
      final String dbPath = p.join(tempRoot.path, 'tx_ro.db');
      final Database db = await databaseFactoryFfi.openDatabase(dbPath);
      await db.close();
      // 关库后的连接再执行事务必然报错 → 必须映射为 StoragePreflightFailure。
      final StoragePreflightFailure failure = await _capture(() {
        return StoragePreflight.verifyDatabaseWriteTx(db);
      });

      expect(failure.issue, StoragePreflightIssue.openOrWriteFailed);
      expect(failure.userMessage, 'PetLife 无法打开或写入本地数据库');
    });

    test(':memory: 数据库跳过写事务（测试路径无落盘语义）', () async {
      SqliteTestBootstrap.ensureLoaded();
      final Database db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await StoragePreflight.verifyDatabaseWriteTx(db);
      await db.close();
    });
  });
}

/// 捕获 StoragePreflightFailure 并断言确实抛出（而不是静默通过）。
Future<StoragePreflightFailure> _capture(Future<void> Function() action) async {
  try {
    await action();
  } on StoragePreflightFailure catch (failure) {
    return failure;
  }
  fail('预检应当抛出 StoragePreflightFailure，但没有');
}
