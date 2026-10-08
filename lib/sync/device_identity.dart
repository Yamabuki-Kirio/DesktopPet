import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../database/app_database.dart';
import '../database/schema.dart';
import '../platform/device_info_provider.dart';

/// 设备身份与设备元数据（需求「二、稳定设备身份」）。
///
/// `device_local_id` 规则：
/// * 首次运行生成一个 UUID（v4），写入 `local_settings`；
/// * 之后每次启动都读回同一个值 → **重启不变**；
/// * **不使用** MAC、硬盘序列号等硬件指纹——客户端自己生成的随机标识，
///   用户可以随时在服务端撤销设备，撤销后原 ID 立即失效。
///
/// 平台元数据（`platform` / `architecture` / `model_name` / `os_version`）
/// 来自 [DeviceEnvironment]：启动时由 `PlatformServices.prepareForStartup()`
/// 写入（Android 会用 `device_info_plus` 补齐机型），默认值由 `dart:io` 推导。
/// **Windows 与 Android 因此必然注册成不同设备。**
class DeviceIdentity {
  DeviceIdentity(this._db);

  final AppDatabase _db;

  /// `local_settings` 里的键名。
  static const String _key = 'sync.deviceLocalId';

  static const Uuid _uuid = Uuid();

  static DeviceEnvironment _environment = DeviceEnvironment.detect();

  /// 当前进程使用的设备环境。
  static DeviceEnvironment get environment => _environment;

  /// 启动装配时调用（平台层已解析好机型 / 系统版本）。
  static void configureEnvironment(DeviceEnvironment environment) {
    _environment = environment;
  }

  /// 测试用：恢复为 `dart:io` 推导出的默认值。
  static void resetEnvironmentForTest() {
    _environment = DeviceEnvironment.detect();
  }

  /// 读取或生成稳定的 `device_local_id`。
  Future<String> ensureDeviceLocalId({String ownerId = AppConstants.localOwnerId}) async {
    final List<Map<String, Object?>> rows = await _db.raw.query(
      DbSchema.tableSettings,
      columns: <String>['value'],
      where: 'owner_id = ? AND key = ?',
      whereArgs: <Object?>[ownerId, _key],
      limit: 1,
    );

    final String? existing = rows.isEmpty ? null : rows.first['value'] as String?;
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }

    final String generated = _uuid.v4();
    await _db.raw.insert(
      DbSchema.tableSettings,
      <String, Object?>{
        'owner_id': ownerId,
        'key': _key,
        'value': generated,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    Loggers.sync.info('已生成新的 device_local_id（本机稳定标识）');
    return generated;
  }

  /// 设备显示名：Windows 用主机名；Android 用机型（用户更认得）。
  static String defaultDeviceName() => _environment.deviceName;

  /// 平台标识：`windows` / `android`。
  static String platform() => _environment.platform;

  /// 架构标识：`x64` / `arm64-v8a` / `armeabi-v7a` / `x86_64`。
  static String architecture() => _environment.architecture;

  /// 精简后的操作系统版本，例如 `Windows 11 (10.0.22631)` / `Android 14 (API 34)`。
  static String osVersion() => _environment.osVersion;

  /// 设备型号（Android 机型；Windows 上通常为空）。
  static String? modelName() => _environment.modelName;

  /// 客户端版本（上报给服务端，便于排查版本相关问题）。
  static String appVersion() => AppConstants.appVersion;
}
