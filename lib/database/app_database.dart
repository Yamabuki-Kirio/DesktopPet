import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../platform/platform_database.dart';
import '../platform/platform_services.dart';
import 'schema.dart';

/// SQLite 连接管理。
///
/// **平台无关**：具体用哪个原生库由 [PlatformDatabase] 决定
/// （Windows = `sqflite_common_ffi`，Android = `sqflite`）。
/// Schema 版本、建表语句、迁移语句全部来自共享的 [DbSchema]，
/// 因此两端的数据结构与统计口径必然一致。
class AppDatabase {
  AppDatabase._(this._db, this.backendName);

  final Database _db;

  /// 实际使用的后端名（诊断展示）。
  final String backendName;

  Database get raw => _db;

  static AppDatabase? _instance;

  static AppDatabase get instance {
    final AppDatabase? i = _instance;
    if (i == null) {
      throw StateError('AppDatabase 未初始化，请先 await AppDatabase.open()');
    }
    return i;
  }

  /// 打开（或创建）数据库。
  ///
  /// [path] 为 `:memory:` 时用于测试。
  /// [platform] 留空时使用当前平台后端（测试可直接沿用默认值）。
  static Future<AppDatabase> open({
    required String path,
    PlatformDatabase? platform,
  }) async {
    if (_instance != null) return _instance!;

    final PlatformDatabase backend = platform ?? platformServices.database;
    await backend.configure();

    try {
      final Database db = await backend.open(
        path,
        options: OpenDatabaseOptions(
          version: AppConstants.databaseSchemaVersion,
          onConfigure: (Database db) async {
            // 外键约束：素材随角色、角色随作品包级联删除。
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (Database db, int version) async {
            final Batch batch = db.batch();
            for (final String stmt in DbSchema.createStatements) {
              batch.execute(stmt);
            }
            await batch.commit(noResult: true);
            Loggers.db.info('数据库创建完成，schema version=$version，'
                '表数量=${DbSchema.createStatements.where((String s) => s.contains('CREATE TABLE')).length}');
          },
          onUpgrade: (Database db, int from, int to) async {
            Loggers.db.info('数据库迁移 $from -> $to');
            for (int v = from + 1; v <= to; v++) {
              final List<String>? stmts = DbSchema.migrations[v];
              if (stmts == null) continue;
              final Batch batch = db.batch();
              for (final String stmt in stmts) {
                batch.execute(stmt);
              }
              await batch.commit(noResult: true);
              Loggers.db.info('已应用迁移 v$v（${stmts.length} 条语句）');
            }
          },
          onOpen: (Database db) async {
            await applyPerformancePragmas(db);
          },
        ),
      );
      _instance = AppDatabase._(db, backend.backendName);
      Loggers.db.info('数据库已打开: $path（后端=${backend.backendName}）');
      return _instance!;
    } catch (e, st) {
      Loggers.db.severe('数据库打开失败: $path', e, st);
      rethrow;
    }
  }

  /// 打开后应用与日志模式 / 同步级别相关的 PRAGMA。
  ///
  /// ## 为什么 `journal_mode` 必须用 `rawQuery`（Android 真机踩过的坑）
  ///
  /// `PRAGMA journal_mode = WAL` 是**有结果集**的语句：SQLite 会把生效后的
  /// journal_mode 作为**一行**返回（用来告诉你它到底切成功了没有）。
  ///
  /// Android 的 `SQLiteDatabase.execSQL()`（也就是 sqflite 的 `execute()`）
  /// 底层是 `SQLiteConnection.nativeExecuteForChangedRowCount`，它只接受
  /// "不返回数据"的语句：
  ///
  /// ```cpp
  /// int err = sqlite3_step(statement);
  /// if (err == SQLITE_ROW) {
  ///     throw_sqlite3_exception(env, db,
  ///         "Queries can be performed using SQLiteDatabase query or rawQuery methods only.");
  /// }
  /// ```
  ///
  /// 于是真机上直接抛：
  ///
  /// ```
  /// DatabaseException: Queries can be performed using SQLiteDatabase query or
  /// rawQuery methods only.  SQL: PRAGMA journal_mode = WAL
  /// ```
  ///
  /// Windows 的 FFI 后端对"execute 却拿到结果行"是宽容的（不检查 step 返回值），
  /// 所以这个缺陷**只**在 Android 上炸，Windows 上分析器与测试全绿 —— 见 docs/31。
  ///
  /// ## `synchronous` 为什么可以继续用 `execute`
  ///
  /// 判断标准是"这条语句会不会返回行"，而不是"是不是 PRAGMA"：
  /// `PRAGMA synchronous = NORMAL` 是**只写**语句，`sqlite3_step()` 直接返回
  /// `SQLITE_DONE`，没有任何结果行，因此在两种后端上 `execute()` 都合法。
  /// 真机证据也支持这一点：`onConfigure` 里的 `PRAGMA foreign_keys = ON`
  /// （同样是无结果行的赋值形式）在同一个设备上**没有**报错，报错的是 WAL。
  /// `test/database_pragma_test.dart` 用真实 SQLite 实测并把这条性质固化下来。
  ///
  /// ## 失败时的取舍
  ///
  /// WAL 与同步级别都是**性能**选项，不是正确性前提。因此这里任何一步失败
  /// 都只记录明确日志并继续：既不允许"没切成 WAL 就让应用起不来"，
  /// 也不允许静默 —— 日志里能直接看到实际生效的 journal_mode。
  @visibleForTesting
  static Future<void> applyPerformancePragmas(DatabaseExecutor db) async {
    // 1) journal_mode：有结果集 → 必须 rawQuery。
    try {
      final List<Map<String, Object?>> rows =
          await db.rawQuery('PRAGMA journal_mode = WAL');
      final Object? raw = rows.isEmpty ? null : rows.first['journal_mode'];
      final String? mode = raw?.toString().toLowerCase();
      if (mode == 'wal') {
        Loggers.db.info('journal_mode = wal（WAL 已启用）');
      } else {
        // 常见于 :memory: 数据库（恒为 memory）与不支持 WAL 的文件系统。
        Loggers.db.warning(
          '本设备的 SQLite 未能切到 WAL：PRAGMA journal_mode 返回 '
          '${mode ?? '<无结果行>'}。功能不受影响，仅并发读写性能下降。',
        );
      }
    } catch (e, st) {
      Loggers.db.warning(
        '设置 journal_mode = WAL 失败（继续使用默认日志模式，功能不受影响）',
        e,
        st,
      );
    }

    // 2) synchronous：只写、无结果集 → execute 在两种后端都合法。
    try {
      await db.execute('PRAGMA synchronous = NORMAL');
    } catch (e, st) {
      Loggers.db.warning(
        '设置 synchronous = NORMAL 失败（继续使用默认同步级别，功能不受影响）',
        e,
        st,
      );
    }
  }

  /// 关闭连接（正常退出时调用）。
  static Future<void> close() async {
    final AppDatabase? i = _instance;
    if (i == null) return;
    try {
      await i._db.close();
      Loggers.db.info('数据库已关闭');
    } catch (e, st) {
      Loggers.db.warning('数据库关闭异常', e, st);
    }
    _instance = null;
  }

  static bool get isOpen => _instance != null;

  /// 简单健康检查，用于诊断面板。
  Future<bool> ping() async {
    try {
      await _db.rawQuery('SELECT 1');
      return true;
    } catch (e, st) {
      Loggers.db.warning('数据库 ping 失败', e, st);
      return false;
    }
  }

  /// 便于测试与维护：清空某个用户的数据（不删表）。
  Future<void> purgeOwner(String ownerId) async {
    await _db.transaction((Transaction txn) async {
      await txn.delete(DbSchema.tablePacks, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      await txn.delete(DbSchema.tableCharacters, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      await txn.delete(DbSchema.tableStateMappings,
          where: 'character_id IN (SELECT id FROM ${DbSchema.tableCharacters} WHERE owner_id = ?)',
          whereArgs: <Object?>[ownerId]);
      await txn.delete(DbSchema.tableSettings, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      // v2：活动采集
      await txn.delete(DbSchema.tableActivitySegments, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      await txn.delete(DbSchema.tableDailyUsage, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      await txn.delete(DbSchema.tableTrackingSettings, where: 'owner_id = ?', whereArgs: <Object?>[ownerId]);
      // v3：账户与同步（按代码 owner 隔离，这里是整体清空，测试用）
      await txn.delete(DbSchema.tableSyncOutbox);
      await txn.delete(DbSchema.tableSyncState);
      await txn.delete(DbSchema.tableAccountSession);
    });
    // applications / activity_checkpoints 没有 owner 列（当前单一本地用户），单独清。
    await _db.delete(DbSchema.tableApplications);
    await _db.delete(DbSchema.tableActivityCheckpoints);
  }

  /// 文件是否已存在（避免 Windows 下对不存在的路径做 File 操作）。
  static bool fileExists(String path) => File(path).existsSync();
}
