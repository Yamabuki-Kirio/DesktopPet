/// Windows（Win32 FFI）平台实现的活动采集提供者。
///
/// 为什么单独一个文件：这三个实现是**Windows 专属**的，Android 编译单元
/// 不允许 import 它们（见 `docs/25`「平台隔离」）。共享的接口与
/// 「不可用」实现留在上一层的 `activity_tracking/` 里，平台实现只出现在这里，
/// 并由 `platform/windows/windows_platform_services.dart` 装配。
library;

import '../foreground_app_provider.dart';
import '../idle_detector.dart';
import '../models/activity_sample.dart';
import '../session_state_provider.dart';
import 'win32_activity_native.dart';

/// 前台应用（`GetForegroundWindow` + `GetWindowThreadProcessId`）。
class Win32ForegroundAppProvider implements ForegroundAppProvider {
  const Win32ForegroundAppProvider();

  @override
  ForegroundAppInfo? current() => Win32ActivityNative.instance?.foregroundApp();

  @override
  bool get isAvailable => Win32ActivityNative.isAvailable;
}

/// 空闲检测（`GetLastInputInfo`）。
///
/// 只读取「最后一次输入的时刻」，不记录任何按键内容、鼠标位置或坐标轨迹。
class Win32IdleDetector implements IdleDetector {
  const Win32IdleDetector();

  @override
  Duration idleTime() => Win32ActivityNative.instance?.idleTime() ?? Duration.zero;

  @override
  bool get isAvailable => Win32ActivityNative.isAvailable;
}

/// 会话状态（`OpenInputDesktop` 探测锁屏 / 安全桌面）。
class Win32SessionStateProvider implements SessionStateProvider {
  const Win32SessionStateProvider();

  @override
  bool isLocked() => Win32ActivityNative.instance?.isSessionLocked() ?? false;

  @override
  bool get isAvailable => Win32ActivityNative.isAvailable;
}

/// Win32 活动采集原生库是否可用。
bool get win32ActivityNativeAvailable => Win32ActivityNative.isAvailable;
