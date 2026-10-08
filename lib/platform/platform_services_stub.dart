/// 无 IO 平台（Web）的占位实现。
///
/// PetLife 只支持 Windows 与 Android，不会真的运行到这里；保留它是为了让
/// 条件导入在非 IO 平台上仍有可编译的分支（Dart 要求默认分支必须存在）。
library;

import 'platform_services_contract.dart';

PlatformServices createPlatformServices() =>
    throw UnsupportedError('PetLife 不支持当前平台（仅支持 Windows 与 Android）');
