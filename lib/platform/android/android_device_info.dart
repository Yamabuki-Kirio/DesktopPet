import 'package:device_info_plus/device_info_plus.dart';

import '../../core/logger.dart';
import '../device_info_provider.dart';

/// Android 设备信息补全（Phase 4A 第 10 项）。
///
/// `dart:io` 只能给出 `Android <version> (API <n>)` 这类文本，
/// 拿不到**设备型号**。型号要读 `android.os.Build.MODEL`，
/// 因此这里用 `device_info_plus`。
///
/// 只读取型号 / 系统版本 / 品牌等级别的"设备标识"，不读取任何账号、
/// 通讯录、已安装应用列表等敏感信息。
class AndroidDeviceInfoProvider {
  const AndroidDeviceInfoProvider();

  Future<DeviceEnvironment> detect() async {
    final DeviceEnvironment base = DeviceEnvironment.detect();
    try {
      final AndroidDeviceInfo info =
          await DeviceInfoPlugin().androidInfo;

      final String model = info.model.trim().isEmpty ? info.device : info.model.trim();
      final String version = 'Android ${info.version.release} (API ${info.version.sdkInt})';

      return base.copyWith(
        platform: 'android',
        deviceName: _displayName(model, base.deviceName),
        modelName: _clip(model, 128),
        osVersion: _clip(version, 128),
      );
    } catch (e, st) {
      // 读不到型号时仍要能登录 / 同步：只上报基础信息。
      Loggers.app.warning('读取 Android 设备信息失败（将使用基础信息）', e, st);
      return base.copyWith(platform: 'android');
    }
  }

  /// 设备显示名优先用用户可读的机型（例如 `Pixel 7`），
  /// 而不是 `dart:io` 的主机名（通常是 `localhost`）。
  static String _displayName(String model, String fallback) {
    final String candidate = model.trim();
    if (candidate.isEmpty || candidate.toLowerCase() == 'unknown') {
      return fallback;
    }
    return _clip(candidate, 128);
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}
