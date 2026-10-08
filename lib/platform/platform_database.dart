/// 平台 SQLite 后端（需求「Phase 4A 第 7 项」）。
///
/// 关键约束
/// --------
/// * **Schema / 迁移 / DAO / 业务层完全共用**：这个接口只负责"用哪个原生库打开"，
///   不参与任何表结构定义（那是 `database/schema.dart` 的唯一职责）；
/// * Windows 继续走 `sqflite_common_ffi` + `sqlite3_flutter_libs`（行为与阶段 1 完全一致）；
/// * Android 走移动端实现（`sqflite`，底层是系统 `android.database.sqlite`）；
/// * **Windows 现有数据库不受影响**：路径、版本号、迁移语句都由上层共享代码给出。
library;

import 'package:sqflite_common/sqlite_api.dart';

abstract interface class PlatformDatabase {
  /// 后端名称（诊断展示）。
  String get backendName;

  /// 打开数据库前的准备（初始化 FFI 库 / 设置全局 factory）。
  Future<void> configure();

  /// 打开（或创建）数据库。
  Future<Database> open(String path, {required OpenDatabaseOptions options});
}
