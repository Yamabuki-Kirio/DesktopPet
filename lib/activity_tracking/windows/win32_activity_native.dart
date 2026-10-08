import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../core/logger.dart';
import '../models/activity_sample.dart';

/// Win32 活动采集原生绑定（Dart FFI 直连）。
///
/// 为什么用 FFI 而不是 C++ 插件：阶段 0 的进程 CPU / 内存采样已经用同一条路径
/// 稳定跑过（`lib/diagnostics/win32_process_stats.dart`），沿用它可以不新增 CMake
/// 目标与插件注册，风险最低；需求也明确允许「C++ 插件或 Dart FFI」。
///
/// 本类**只做原生调用**，不含任何业务规则（分类、合并、落库都在上层），
/// 且所有方法失败时返回 null / 保守值，绝不抛出（需求「十五、异常处理」）。
class Win32ActivityNative {
  Win32ActivityNative._(this._user32, this._kernel32);

  final DynamicLibrary _user32;
  final DynamicLibrary _kernel32;

  // Keep the mutex handle alive for the lifetime of the process. The first
  // instance owns this mutex and intentionally never releases it; Windows
  // releases it automatically when the process exits.
  int? _singleInstanceMutexHandle;

  static Win32ActivityNative? _instance;
  static bool _initialized = false;

  /// 平台不支持或 DLL 加载失败时返回 null。
  static Win32ActivityNative? get instance {
    if (!_initialized) {
      _initialized = true;
      _instance = _tryCreate();
    }
    return _instance;
  }

  static bool get isAvailable => instance != null;

  static Win32ActivityNative? _tryCreate() {
    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      return Win32ActivityNative._(user32, kernel32);
    } catch (e) {
      // 非 Windows（测试环境）或系统异常时静默降级。
      Loggers.activity.warning('Win32 活动采集不可用，将不记录使用统计', e);
      return null;
    }
  }

  late final _GetForegroundWindowDart _getForegroundWindow = _user32
      .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
        'GetForegroundWindow',
      );

  late final _GetWindowThreadProcessIdDart _getWindowThreadProcessId = _user32
      .lookupFunction<
        _GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart
      >('GetWindowThreadProcessId');

  late final _GetLastInputInfoDart _getLastInputInfo = _user32
      .lookupFunction<_GetLastInputInfoNative, _GetLastInputInfoDart>(
        'GetLastInputInfo',
      );

  late final _OpenInputDesktopDart _openInputDesktop = _user32
      .lookupFunction<_OpenInputDesktopNative, _OpenInputDesktopDart>(
        'OpenInputDesktop',
      );

  late final _CloseDesktopDart _closeDesktop = _user32
      .lookupFunction<_CloseDesktopNative, _CloseDesktopDart>('CloseDesktop');

  late final _OpenProcessDart _openProcess = _kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');

  late final _CloseHandleDart _closeHandle = _kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  late final _QueryFullProcessImageNameDart _queryFullProcessImageName =
      _kernel32.lookupFunction<
        _QueryFullProcessImageNameNative,
        _QueryFullProcessImageNameDart
      >('QueryFullProcessImageNameW');

  late final _CreateToolhelp32SnapshotDart _createToolhelp32Snapshot = _kernel32
      .lookupFunction<
        _CreateToolhelp32SnapshotNative,
        _CreateToolhelp32SnapshotDart
      >('CreateToolhelp32Snapshot');

  late final _Process32FirstDart _process32First = _kernel32
      .lookupFunction<_Process32FirstNative, _Process32FirstDart>(
        'Process32FirstW',
      );

  late final _Process32NextDart _process32Next = _kernel32
      .lookupFunction<_Process32NextNative, _Process32NextDart>(
        'Process32NextW',
      );

  late final _GetTickCountDart _getTickCount = _kernel32
      .lookupFunction<_GetTickCountNative, _GetTickCountDart>('GetTickCount');

  // ---------------------------------------------------------------------------
  // 对外能力
  // ---------------------------------------------------------------------------

  /// 读取当前前台应用。无前台窗口或无法获取任何标识时返回 null。
  ///
  /// **绝不使用窗口标题**作为应用标识（需求「六、应用标识」隐私要求）。
  ForegroundAppInfo? foregroundApp() {
    try {
      final int hwnd = _getForegroundWindow();
      if (hwnd == 0) return null;

      final Pointer<Uint32> pidPtr = calloc<Uint32>();
      try {
        _getWindowThreadProcessId(hwnd, pidPtr);
        final int pid = pidPtr.value;
        if (pid == 0) return null;

        final String? path = _processImagePath(pid);
        final String? processName = path != null
            ? null
            : _processNameByPid(pid);
        if (path == null && processName == null) {
          // 进程信息完全不可用：不记虚假应用名，交给上层按 process_unavailable 处理。
          return null;
        }
        return ForegroundAppInfo(
          windowHandle: hwnd,
          processId: pid,
          processName: processName ?? _basename(path!),
          executablePath: path,
        );
      } finally {
        calloc.free(pidPtr);
      }
    } catch (e, st) {
      Loggers.activity.fine('读取前台应用失败', e, st);
      return null;
    }
  }

  /// 距最后一次键鼠输入的时长。
  ///
  /// 使用 GetLastInputInfo + GetTickCount 的 32 位差值（按 DWORD 回绕处理）。
  Duration idleTime() {
    try {
      final Pointer<_LastInputInfo> info = calloc<_LastInputInfo>();
      try {
        info.ref.cbSize = sizeOf<_LastInputInfo>();
        final int ok = _getLastInputInfo(info);
        if (ok == 0) return Duration.zero;
        final int now = _getTickCount() & 0xFFFFFFFF;
        final int delta = (now - info.ref.dwTime) & 0xFFFFFFFF;
        return Duration(milliseconds: delta);
      } finally {
        calloc.free(info);
      }
    } catch (e, st) {
      Loggers.activity.fine('读取空闲时长失败', e, st);
      return Duration.zero;
    }
  }

  /// Windows 是否处于锁屏 / 安全桌面。
  ///
  /// 做法：尝试打开「输入桌面」。锁屏时输入桌面切到 Winlogon，
  /// 普通进程 `OpenInputDesktop` 会失败 → 判定为锁屏。
  bool isSessionLocked() {
    try {
      const int desktopSwitchDesktop = 0x0100;
      final int handle = _openInputDesktop(0, 0, desktopSwitchDesktop);
      if (handle == 0) return true;
      _closeDesktop(handle);
      return false;
    } catch (e, st) {
      // 判断不了时保守认为「未锁屏」，避免把正常使用误判成离开。
      Loggers.activity.fine('会话锁定探测失败', e, st);
      return false;
    }
  }

  /// 32 位系统启动以来的毫秒数（用于空闲时长换算）。
  int tickCount() => _getTickCount() & 0xFFFFFFFF;

  /// 创建单实例互斥体。返回 true 表示本进程是唯一实例。
  ///
  /// 返回 null 表示无法判断（此时调用方应放行，不要因互斥体失败而拒绝启动）。
  bool? tryAcquireSingleInstance(String name) {
    if (_singleInstanceMutexHandle != null) return true;
    try {
      final Pointer<Utf16> namePtr = name.toNativeUtf16();
      try {
        // Ask Windows to grant initial ownership. If this is a new mutex the
        // zero-time wait succeeds (recursive acquisition by the same thread).
        // If another PetLife process owns it, the wait times out. This avoids
        // relying on GetLastError across two Dart FFI calls.
        final int handle = _createMutex(nullptr, 1, namePtr);
        if (handle == 0) return null;
        final int waitResult = _waitForSingleObject(handle, 0);
        if (waitResult == _waitObject0) {
          _singleInstanceMutexHandle = handle;
          return true;
        }
        _closeHandle(handle);
        if (waitResult == _waitTimeout) return false;
        return null;
      } finally {
        calloc.free(namePtr);
      }
    } catch (e, st) {
      Loggers.activity.warning('单实例互斥体创建失败', e, st);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 用 `QueryFullProcessImageNameW` 取完整路径（需要 PROCESS_QUERY_LIMITED_INFORMATION）。
  String? _processImagePath(int pid) {
    const int processQueryLimitedInformation = 0x1000;
    final int handle = _openProcess(processQueryLimitedInformation, 0, pid);
    if (handle == 0) return null;
    try {
      final Pointer<Utf16> buffer = calloc<Uint16>(_kMaxPath).cast<Utf16>();
      final Pointer<Uint32> size = calloc<Uint32>();
      try {
        size.value = _kMaxPath;
        final int ok = _queryFullProcessImageName(handle, 0, buffer, size);
        if (ok == 0) return null;
        final String value = buffer.toDartString();
        return value.isEmpty ? null : value;
      } finally {
        calloc.free(buffer);
        calloc.free(size);
      }
    } finally {
      _closeHandle(handle);
    }
  }

  /// 权限不足时的兜底：用 Toolhelp 快照按 PID 找进程可执行文件名。
  ///
  /// 这一步保证「读不到完整路径时仍保留进程名」，而不是整条记录丢掉。
  String? _processNameByPid(int pid) {
    const int th32csSnapProcess = 0x00000002;
    final int snapshot = _createToolhelp32Snapshot(th32csSnapProcess, 0);
    if (snapshot == 0 || snapshot == -1) return null;
    try {
      final Pointer<_ProcessEntry32W> entry = calloc<_ProcessEntry32W>();
      try {
        entry.ref.dwSize = sizeOf<_ProcessEntry32W>();
        int ok = _process32First(snapshot, entry);
        while (ok != 0) {
          if (entry.ref.th32ProcessID == pid) {
            final String name = _readWideString(entry.ref.szExeFile);
            return name.isEmpty ? null : name;
          }
          ok = _process32Next(snapshot, entry);
        }
        return null;
      } finally {
        calloc.free(entry);
      }
    } finally {
      _closeHandle(snapshot);
    }
  }

  static String _readWideString(Array<Uint16> chars) {
    final StringBuffer sb = StringBuffer();
    // 不依赖 Array.length（不同 SDK 版本可用性不同），直接按 MAX_PATH 上限读，
    // 遇到 NUL 终止符即停止。
    for (int i = 0; i < _kMaxPath; i++) {
      final int code = chars[i];
      if (code == 0) break;
      sb.writeCharCode(code);
    }
    return sb.toString();
  }

  static String _basename(String path) {
    final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
    return sep >= 0 ? path.substring(sep + 1) : path;
  }

  late final _CreateMutexDart _createMutex = _kernel32
      .lookupFunction<_CreateMutexNative, _CreateMutexDart>('CreateMutexW');

  late final _WaitForSingleObjectDart _waitForSingleObject = _kernel32
      .lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObjectDart>(
        'WaitForSingleObject',
      );
}

// -----------------------------------------------------------------------------
// FFI 绑定
// -----------------------------------------------------------------------------

/// `MAX_PATH`（宽字符数），用于路径缓冲区与 `PROCESSENTRY32W.szExeFile`。
const int _kMaxPath = 260;
const int _waitObject0 = 0x00000000;
const int _waitTimeout = 0x00000102;

/// `LASTINPUTINFO`。
final class _LastInputInfo extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwTime;
}

/// `PROCESSENTRY32W`（x64 布局，szExeFile 偏移 44）。
final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;

  @Uint32()
  external int cntUsage;

  @Uint32()
  external int th32ProcessID;

  @UintPtr()
  external int th32DefaultHeapID;

  @Uint32()
  external int th32ModuleID;

  @Uint32()
  external int cntThreads;

  @Uint32()
  external int th32ParentProcessID;

  @Int32()
  external int pcPriClassBase;

  @Uint32()
  external int dwFlags;

  @Array(260)
  external Array<Uint16> szExeFile;
}

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _GetWindowThreadProcessIdNative =
    Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(int, Pointer<Uint32>);

typedef _GetLastInputInfoNative = Int32 Function(Pointer<_LastInputInfo>);
typedef _GetLastInputInfoDart = int Function(Pointer<_LastInputInfo>);

typedef _OpenInputDesktopNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenInputDesktopDart = int Function(int, int, int);

typedef _CloseDesktopNative = Int32 Function(IntPtr);
typedef _CloseDesktopDart = int Function(int);

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

typedef _QueryFullProcessImageNameNative =
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>);
typedef _QueryFullProcessImageNameDart =
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>);

typedef _CreateToolhelp32SnapshotNative = IntPtr Function(Uint32, Uint32);
typedef _CreateToolhelp32SnapshotDart = int Function(int, int);

typedef _Process32FirstNative =
    Int32 Function(IntPtr, Pointer<_ProcessEntry32W>);
typedef _Process32FirstDart = int Function(int, Pointer<_ProcessEntry32W>);

typedef _Process32NextNative =
    Int32 Function(IntPtr, Pointer<_ProcessEntry32W>);
typedef _Process32NextDart = int Function(int, Pointer<_ProcessEntry32W>);

typedef _GetTickCountNative = Uint32 Function();
typedef _GetTickCountDart = int Function();

typedef _CreateMutexNative =
    IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>);
typedef _CreateMutexDart = int Function(Pointer<Void>, int, Pointer<Utf16>);

typedef _WaitForSingleObjectNative = Uint32 Function(IntPtr, Uint32);
typedef _WaitForSingleObjectDart = int Function(int, int);
