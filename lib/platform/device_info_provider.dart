/// 设备环境信息（需求「Phase 4A 第 10 项」）。
///
/// 与服务端 `devices` 表的上报字段一一对应：
///
/// | 服务端字段 | 来源 |
/// |---|---|
/// | `platform` | `windows` / `android` |
/// | `architecture` | x64 / arm64-v8a / armeabi-v7a / x86_64 |
/// | `device_name` | 用户可读设备名（主机名或机型） |
/// | `model_name` | Android 设备型号 / Windows 主机型号（可空） |
/// | `os_version` | 精简后的系统版本 |
/// | `app_version` | PetLife 版本 |
///
/// 这个类本身**只承载数据**，不 import 任何平台库；探测逻辑在
/// `platform/windows` 与 `platform/android` 各自的实现里。
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import '../core/constants.dart';

class DeviceEnvironment {
  const DeviceEnvironment({
    required this.platform,
    required this.architecture,
    required this.deviceName,
    required this.osVersion,
    this.modelName,
  });

  final String platform;
  final String architecture;
  final String deviceName;
  final String osVersion;
  final String? modelName;

  String get appVersion => AppConstants.appVersion;

  /// `dart:io` 能给出的**同步**默认值（不含 Android 机型，那需要平台插件）。
  ///
  /// Windows 上这就是完整信息；Android 上 `prepareForStartup()` 会用
  /// `device_info_plus` 补齐 `model_name` 与 `os_version`。
  factory DeviceEnvironment.detect() {
    final String platform = Platform.isWindows
        ? 'windows'
        : (Platform.isAndroid ? 'android' : Platform.operatingSystem);

    return DeviceEnvironment(
      platform: platform,
      architecture: _detectArchitecture(),
      deviceName: _detectDeviceName(),
      osVersion: _condenseOsVersion(Platform.operatingSystemVersion),
    );
  }

  static String _detectArchitecture() {
    // `Abi.current()` 是**编译期确定**的 ABI，比解析 Platform.version 可靠得多。
    final Abi abi = Abi.current();
    if (abi == Abi.androidArm64) return 'arm64-v8a';
    if (abi == Abi.androidArm) return 'armeabi-v7a';
    if (abi == Abi.androidX64) return 'x86_64';
    if (abi == Abi.androidIA32) return 'x86';
    if (abi == Abi.windowsX64) return 'x64';
    if (abi == Abi.windowsIA32) return 'x86';
    if (abi == Abi.windowsArm64) return 'arm64';
    if (abi == Abi.macosArm64 || abi == Abi.iosArm64) return 'arm64';
    if (abi == Abi.macosX64 || abi == Abi.iosX64) return 'x64';
    if (abi == Abi.linuxX64) return 'x64';
    if (abi == Abi.linuxArm64) return 'arm64';
    if (abi == Abi.linuxArm) return 'arm';
    return '$abi';
  }

  static String _detectDeviceName() {
    try {
      final String host = Platform.localHostname.trim();
      if (host.isNotEmpty) {
        return host.length <= 128 ? host : host.substring(0, 128);
      }
    } catch (_) {
      // 取不到主机名时退回固定文案
    }
    return Platform.isWindows ? 'Windows 设备' : 'Android 设备';
  }

  /// 压到 128 字符（服务端该列上限 128）并去掉换行。
  static String _condenseOsVersion(String raw) {
    final String cleaned = raw.replaceAll('\n', ' ').trim();
    if (cleaned.isEmpty) return Platform.operatingSystem;
    return cleaned.length <= 128 ? cleaned : cleaned.substring(0, 128);
  }

  DeviceEnvironment copyWith({
    String? platform,
    String? architecture,
    String? deviceName,
    String? osVersion,
    String? modelName,
  }) =>
      DeviceEnvironment(
        platform: platform ?? this.platform,
        architecture: architecture ?? this.architecture,
        deviceName: deviceName ?? this.deviceName,
        osVersion: osVersion ?? this.osVersion,
        modelName: modelName ?? this.modelName,
      );

  @override
  String toString() =>
      'DeviceEnvironment($platform/$architecture, name=$deviceName, '
      'model=${modelName ?? '-'}, os=$osVersion)';
}
