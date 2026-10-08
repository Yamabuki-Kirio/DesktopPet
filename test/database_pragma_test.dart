import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// 回归保护：**不许把"有结果集"的 PRAGMA 交给 `execute()`**。
///
/// ## 背景（真机上真实发生过）
///
/// Android 的 `SQLiteDatabase.execSQL()`（sqflite 的 `execute()`）底层是
/// `SQLiteConnection.nativeExecuteForChangedRowCount`，它只接受"不返回数据"的语句：
/// 只要 `sqlite3_step()` 返回 `SQLITE_ROW` 就抛
///
/// ```
/// SQLException: Queries can be performed using SQLiteDatabase query or
/// rawQuery methods only.
/// ```
///
/// `PRAGMA journal_mode = WAL` 恰好**会返回一行**（生效后的模式），
/// 于是 Android 端在打开数据库时直接崩：
///
/// ```
/// DatabaseException: Queries can be performed using SQLiteDatabase query or
/// rawQuery methods only.  SQL: PRAGMA journal_mode = WAL
/// ```
///
/// Windows 的 FFI 后端对此宽容，所以这是个**只在 Android 上炸**的缺陷。
/// 这组测试用"真实 SQLite 的结果行数"来判定一条 PRAGMA 能不能走 `execute()`，
/// 因此**不需要真机**也能拦住同类回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_pragma');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 打开一个**文件**数据库（`:memory:` 切不到 WAL，必须用文件）。
  Future<Database> openProbe(String name) => databaseFactory.openDatabase(
        p.join(tmp.path, name),
        options: OpenDatabaseOptions(singleInstance: false),
      );

  // ---------------------------------------------------------------------------
  // 1. 用真实 SQLite 判定每类 PRAGMA 的结果集特性
  //    （同时也是需求 4 要求的"验证 synchronous 能否继续用 execute"）
  // ---------------------------------------------------------------------------
  group('PRAGMA 的结果集特性（决定能否用 execute）', () {
    test('journal_mode 赋值**会返回一行** —— 所以必须用 rawQuery', () async {
      final Database db = await openProbe('journal_mode.db');
      addTearDown(db.close);

      final List<Map<String, Object?>> rows =
          await db.rawQuery('PRAGMA journal_mode = WAL');

      expect(rows, hasLength(1), reason: '这一行正是 Android 上 execute() 会炸的原因');
      expect(rows.first['journal_mode'], 'wal');
    });

    test('synchronous 赋值**不返回任何行** —— execute() 在 Android 上同样合法', () async {
      final Database db = await openProbe('synchronous.db');
      addTearDown(db.close);

      expect(
        await db.rawQuery('PRAGMA synchronous = NORMAL'),
        isEmpty,
        reason: '只写语句，sqlite3_step() 直接返回 SQLITE_DONE',
      );
    });

    test('foreign_keys 赋值**不返回任何行** —— onConfigure 里的 execute() 是合法的', () async {
      final Database db = await openProbe('foreign_keys.db');
      addTearDown(db.close);

      expect(
        await db.rawQuery('PRAGMA foreign_keys = ON'),
        isEmpty,
        reason: '真机上这条没报错、WAL 报错，正说明 Android 的判定标准是"有没有结果行"',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. 模拟 Android 的严格 execute：确认修复真的过得了那一关
  // ---------------------------------------------------------------------------
  group('Android 式严格 execute（复现真机约束）', () {
    test('反向验证：替身确实会拒绝旧写法（证明它不是空跑）', () async {
      final Database db = await openProbe('strict_control.db');
      addTearDown(db.close);
      final _AndroidStrictExecutor strict = _AndroidStrictExecutor(db);

      await expectLater(
        strict.execute('PRAGMA journal_mode = WAL'),
        throwsA(isA<_AndroidSqliteRejection>()),
      );
      expect(strict.rejected, <String>['PRAGMA journal_mode = WAL']);
    });

    test('applyPerformancePragmas 在严格 execute 下成功，且确实切到 WAL', () async {
      final Database db = await openProbe('strict_ok.db');
      addTearDown(db.close);
      final _AndroidStrictExecutor strict = _AndroidStrictExecutor(db);

      await AppDatabase.applyPerformancePragmas(strict);

      expect(strict.rejected, isEmpty, reason: '不应有任何语句被严格 execute 拒绝');
      // synchronous 走的是 execute()：严格替身放行说明它确实没有结果集。
      expect(strict.executed, contains('PRAGMA synchronous = NORMAL'));
      final List<Map<String, Object?>> mode = await db.rawQuery('PRAGMA journal_mode');
      expect(mode.first['journal_mode'], 'wal');
    });

    test('设备切不到 WAL 时只记日志、不抛异常（例如 :memory: 数据库）', () async {
      final Database db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);
      final _AndroidStrictExecutor strict = _AndroidStrictExecutor(db);

      // 内存库的 journal_mode 恒为 memory，本来就不是 wal。
      await AppDatabase.applyPerformancePragmas(strict);

      expect(strict.rejected, isEmpty);
      final List<Map<String, Object?>> mode = await db.rawQuery('PRAGMA journal_mode');
      expect(mode.first['journal_mode'], isNot('wal'));
    });
  });

  // ---------------------------------------------------------------------------
  // 3. 静态保护：扫描 lib/，任何"有结果集"的 PRAGMA 都不许出现在 execute() 里
  // ---------------------------------------------------------------------------
  test('lib/ 下没有把"有结果集"的 PRAGMA 交给 execute() 的调用点', () async {
    final Database db = await openProbe('scan.db');
    addTearDown(db.close);

    // 允许跨行写法：execute(\n  'PRAGMA ...')。
    final RegExp call = RegExp(r'''execute\(\s*(?:'|")(PRAGMA[^'"]*)''');
    final Directory lib = Directory(p.join(Directory.current.path, 'lib'));
    final List<String> violations = <String>[];
    int scanned = 0;

    for (final File file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final String source = file.readAsStringSync();
      for (final Match m in call.allMatches(source)) {
        final String sql = m.group(1)!.trim();
        scanned++;
        final List<Map<String, Object?>> rows = await db.rawQuery(sql);
        if (rows.isNotEmpty) {
          final int line =
              '\n'.allMatches(source.substring(0, m.start)).length + 1;
          violations.add('${p.relative(file.path).replaceAll('\\', '/')}:$line → $sql');
        }
      }
    }

    expect(scanned, greaterThan(0), reason: '扫描没命中任何调用点，说明正则失效了');
    expect(
      violations,
      isEmpty,
      reason: '这些 PRAGMA 会返回结果行，在 Android 上经 execute() 会抛\n'
          '「Queries can be performed using SQLiteDatabase query or rawQuery '
          'methods only.」\n请改用 rawQuery()：\n${violations.join('\n')}',
    );
  });
}

/// 模拟 Android `SQLiteDatabase.execSQL()` 的严格性。
///
/// 规则与真机一致：**语句只要会返回结果行就拒绝**（错误文案照抄真机）。
/// 这样即使没有真机，"用 execute 跑有结果集的 PRAGMA"也会在测试里当场失败。
class _AndroidStrictExecutor implements DatabaseExecutor {
  _AndroidStrictExecutor(this._inner);

  final DatabaseExecutor _inner;

  /// 被拒绝的语句（应始终为空）。
  final List<String> rejected = <String>[];

  /// 成功通过 execute() 的语句。
  final List<String> executed = <String>[];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    final List<Map<String, Object?>> rows = await _inner.rawQuery(sql, arguments);
    if (rows.isNotEmpty) {
      rejected.add(sql);
      throw _AndroidSqliteRejection(sql);
    }
    executed.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) =>
      _inner.rawQuery(sql, arguments);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未实现 ${invocation.memberName}');
}

/// 与真机一致的拒绝异常（文案照抄 Android `SQLiteConnection`）。
class _AndroidSqliteRejection implements Exception {
  _AndroidSqliteRejection(this.sql);

  final String sql;

  @override
  String toString() =>
      'DatabaseException: Queries can be performed using SQLiteDatabase query '
      'or rawQuery methods only. SQL: $sql';
}
