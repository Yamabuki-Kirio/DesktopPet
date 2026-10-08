/// 桌面/移动平台装配点（Windows 与 Android 共用本文件）。
///
/// 这是**唯一**同时 import 两个平台实现的文件。判断只发生一次（`Platform.isWindows`），
/// 之后所有代码都通过 `PlatformServices` 接口访问平台能力，
/// 不存在散落的 `Platform.isWindows` 分支。
library;

import 'dart:io';

import 'android/android_platform_services.dart';
import 'platform_services_contract.dart';
import 'windows/windows_platform_services.dart';

PlatformServices createPlatformServices() {
  if (Platform.isWindows) return WindowsPlatformServices();
  if (Platform.isAndroid) return AndroidPlatformServices();
  throw UnsupportedError(
    'PetLife 仅支持 Windows 与 Android，当前平台：${Platform.operatingSystem}',
  );
}
