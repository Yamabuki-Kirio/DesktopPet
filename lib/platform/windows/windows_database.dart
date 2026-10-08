import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../platform_database.dart';

/// Windows 平台 SQLite 后端：`sqflite_common_ffi` + `sqlite3_flutter_libs`。
///
/// 与阶段 1 的做法完全一致（`sqfliteFfiInit()` + 设置全局 `databaseFactory`），
/// 因此**现有 Windows 数据库与迁移行为零变化**。
class WindowsFfiDatabase implements PlatformDatabase {
  const WindowsFfiDatabase();

  @override
  String get backendName => 'sqflite_common_ffi（sqlite3_flutter_libs）';

  @override
  Future<void> configure() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  @override
  Future<Database> open(String path, {required OpenDatabaseOptions options}) =>
      databaseFactoryFfi.openDatabase(path, options: options);
}
