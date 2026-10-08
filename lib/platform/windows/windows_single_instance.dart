/// 单实例保护（Windows 实现）。
///
/// 需求「十五、异常处理」要求「多个 PetLife 实例」时建议增加单实例限制，
/// 否则两个进程会同时写 `activity_segments` 与 `daily_usage`，
/// 造成同一段时间被记录两次。
///
/// 实现：Win32 命名互斥体（`CreateMutexW`）。互斥体随进程退出自动释放，
/// 不需要额外的清理逻辑，也不会留下需要人工删除的锁文件。
///
/// Android 侧**不需要**这个保护：系统按包名保证单实例（后启动的实例会复用
/// 同一进程），因此 `AndroidPlatformServices.tryAcquireSingleInstance()` 直接返回 null。
library;

import '../../activity_tracking/windows/win32_activity_native.dart';
import '../../core/constants.dart';
import '../../core/logger.dart';

class WindowsSingleInstanceGuard {
  WindowsSingleInstanceGuard._();

  /// 尝试取得单实例所有权。
  ///
  /// - `true`：本进程是唯一实例，可以继续启动；
  /// - `false`：已有实例在运行，调用方应退出；
  /// - `null`：无法判断（原生库不可用），调用方应放行启动。
  static bool? tryAcquire([String name = ActivityTracking.singleInstanceMutexName]) {
    final Win32ActivityNative? native = Win32ActivityNative.instance;
    if (native == null) return null;
    return native.tryAcquireSingleInstance(name);
  }

  /// 启动期检查并记录日志。返回值语义同 [tryAcquire]。
  static bool? checkAtStartup() {
    final bool? acquired = tryAcquire();
    if (acquired == false) {
      Loggers.app.warning(
        '检测到已有 PetLife 实例在运行，本次启动将退出'
        '（避免两个实例重复记录使用时长）',
      );
    }
    return acquired;
  }
}
