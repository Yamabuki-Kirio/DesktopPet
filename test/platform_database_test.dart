import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/platform/android/android_database.dart';
import 'package:petlife/platform/platform_database.dart';
import 'package:petlife/platform/windows/windows_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4A：数据库平台适配。
///
/// 关键结论有两条：
/// 1. **Schema / 迁移 / 业务层完全共用**：平台只决定"用哪个原生库打开"；
/// 2. `AppDatabase` 可以从外部注入 [PlatformDatabase]，
///    因此上层的打开流程（版本号、建表、迁移、WAL）在两端走的是同一段代码。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_platform_db');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  tearDown(() async {
    await AppDatabase.close();
  });

  test('Android 后端是 sqflite（不是桌面 FFI），且 configure 是安全的 no-op', () async {
    const AndroidSqfliteDatabase android = AndroidSqfliteDatabase();
    expect(android.backendName, contains('sqflite'));
    expect(android.backendName, contains('android.database.sqlite'));
    expect(android.backendName, isNot(contains('ffi')));

    // 不依赖任何插件即可调用（真正打开数据库才会用到 Android 插件）。
    await android.configure();
  });

  test('两端的后端名不同，证明没有共用同一条实现', () {
    expect(const WindowsFfiDatabase().backendName, contains('ffi'));
    expect(
      const WindowsFfiDatabase().backendName,
      isNot(const AndroidSqfliteDatabase().backendName),
    );
  });

  test('AppDatabase 走注入的平台后端打开，Schema 与迁移逻辑完全复用', () async {
    final _RecordingBackend backend = _RecordingBackend();
    final String path = p.join(tmp.path, 'injected.db');

    final AppDatabase db = await AppDatabase.open(path: path, platform: backend);

    expect(backend.configureCalls, 1, reason: '必须调用平台后端的 configure');
    expect(backend.openCalls, 1);
    expect(db.backendName, backend.backendName);

    // 共享 Schema 已经生效：核心表都在。
    final List<Map<String, Object?>> tables = await db.raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final Set<String> names =
        tables.map((Map<String, Object?> r) => r['name']! as String).toSet();
    for (final String expected in <String>[
      'activity_segments',
      'applications',
      'activity_checkpoints',
      'daily_usage',
      'tracking_settings',
      'sync_outbox',
      'sync_state',
      'account_session_state',
      'character_packs',
      'character_models',
      'emotion_assets',
      'state_mappings',
      'local_settings',
    ]) {
      expect(names, contains(expected), reason: '共享 Schema 应包含 $expected');
    }

    // 版本号来自共享常量（两端一致）。
    expect(await db.raw.getVersion(), AppConstants.databaseSchemaVersion);
  });

  test('AppDatabase 默认使用当前平台的后端（测试宿主是 Windows）', () async {
    final AppDatabase db = await AppDatabase.open(
      path: p.join(tmp.path, 'default.db'),
    );
    expect(db.backendName, contains('ffi'));
  });
}

/// 记录调用次数的注入后端：内部用 FFI 打开（测试宿主是 Windows），
/// 但对外表现成一个独立后端，用来证明"切换点"真的生效。
class _RecordingBackend implements PlatformDatabase {
  int configureCalls = 0;
  int openCalls = 0;

  @override
  String get backendName => 'injected-test-backend';

  @override
  Future<void> configure() async {
    configureCalls++;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  @override
  Future<Database> open(String path, {required OpenDatabaseOptions options}) {
    openCalls++;
    return databaseFactoryFfi.openDatabase(path, options: options);
  }
}
