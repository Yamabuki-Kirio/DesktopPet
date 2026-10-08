import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';

import '../platform_database.dart';

/// Android 平台 SQLite 后端：`sqflite`（底层是系统 `android.database.sqlite`）。
///
/// 为什么不用 FFI：
/// * 移动端已有系统 SQLite，`sqflite` 是官方推荐的移动实现；
/// * 避免把桌面侧的 `sqlite3.dll` 动态库假设带到 Android 上。
///
/// **Schema / 迁移 / DAO / 统计口径完全共用上层代码**，这里只负责"用哪个原生库打开"。
class AndroidSqfliteDatabase implements PlatformDatabase {
  const AndroidSqfliteDatabase();

  @override
  String get backendName => 'sqflite（android.database.sqlite）';

  @override
  Future<void> configure() async {
    // sqflite 的 Android 实现由插件在进程启动时注册，这里无需额外初始化；
    // 打开时直接使用 `databaseFactorySqflitePlugin`，不依赖全局 factory 的时序。
  }

  @override
  Future<Database> open(String path, {required OpenDatabaseOptions options}) =>
      sqflite.databaseFactorySqflitePlugin.openDatabase(path, options: options);
}
