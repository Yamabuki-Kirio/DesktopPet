import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/logger.dart';
// 本文件既要使用这些类型（import），也要把它们转出去给原来的调用方（export）。
import '../../diagnostics/process_metrics.dart';

export '../../diagnostics/process_metrics.dart';
/// Windows 进程资源读取。
///
/// 走 **Dart FFI 直连 Win32 API**（`GetProcessTimes` / `GetProcessMemoryInfo` /
/// `GetProcessHandleCount`），因为 Dart 标准库不暴露进程 CPU 时间。
/// 这正是需求「Windows 原生能力使用 C++ 插件或 Dart FFI」所允许的路径，
/// 而且比启动外部进程（tasklist / wmic）采样准确得多、也几乎零开销。
///
/// 在非 Windows 平台上退化为只用 [ProcessInfo.currentRss]。
class Win32ProcessStats {
  Win32ProcessStats._();

  static final DynamicLibrary? _kernel32 =
      Platform.isWindows ? _tryOpen('kernel32.dll') : null;
  static final DynamicLibrary? _psapi =
      Platform.isWindows ? _tryOpen('psapi.dll') : null;

  static DynamicLibrary? _tryOpen(String name) {
    try {
      return DynamicLibrary.open(name);
    } catch (e) {
      Loggers.app.warning('无法加载 $name，CPU/句柄采样将降级', e);
      return null;
    }
  }

  static bool get isAvailable => _kernel32 != null && _psapi != null;

  /// 采样一次。失败时返回 null（绝不抛出）。
  static ProcessSample? sample() {
    try {
      if (!Platform.isWindows || !isAvailable) {
        final int rss = ProcessInfo.currentRss;
        return ProcessSample(
          at: DateTime.now(),
          workingSetBytes: rss,
          peakWorkingSetBytes: rss,
          cpuTotalMs: 0,
          handleCount: 0,
          threadCount: 0,
        );
      }
      return _sampleWindows();
    } catch (e, st) {
      Loggers.app.warning('进程资源采样失败', e, st);
      return null;
    }
  }

  static ProcessSample _sampleWindows() {
    final _Win32Fns fns = _Win32Fns.instance;
    final int handle = fns.getCurrentProcess();
    final DateTime now = DateTime.now();

    // --- CPU：内核态 + 用户态累计时间 ---
    final Pointer<Int64> creation = calloc<Int64>();
    final Pointer<Int64> exitTime = calloc<Int64>();
    final Pointer<Int64> kernel = calloc<Int64>();
    final Pointer<Int64> user = calloc<Int64>();
    int cpuMs = 0;
    try {
      final int ok = fns.getProcessTimes(handle, creation, exitTime, kernel, user);
      if (ok != 0) {
        // FILETIME 单位是 100ns。
        cpuMs = (kernel.value + user.value) ~/ 10000;
      }
    } finally {
      calloc.free(creation);
      calloc.free(exitTime);
      calloc.free(kernel);
      calloc.free(user);
    }

    // --- 内存：工作集 / 峰值工作集 ---
    final Pointer<_MemoryCounters> counters = calloc<_MemoryCounters>();
    int workingSet = 0;
    int peak = 0;
    try {
      counters.ref.cb = sizeOf<_MemoryCounters>();
      final int ok = fns.getProcessMemoryInfo(handle, counters, sizeOf<_MemoryCounters>());
      if (ok != 0) {
        workingSet = counters.ref.workingSetSize;
        peak = counters.ref.peakWorkingSetSize;
      }
    } finally {
      calloc.free(counters);
    }

    // --- 句柄数：长时运行若持续增长即为资源泄漏信号（验收第 21 项）---
    final Pointer<Uint32> handles = calloc<Uint32>();
    int handleCount = 0;
    try {
      final int ok = fns.getProcessHandleCount(handle, handles);
      if (ok != 0) handleCount = handles.value;
    } finally {
      calloc.free(handles);
    }

    if (workingSet == 0) {
      // psapi 不可用时退回 Dart 自带值，保证诊断页仍然有数据。
      workingSet = ProcessInfo.currentRss;
      peak = workingSet;
    }

    return ProcessSample(
      at: now,
      workingSetBytes: workingSet,
      peakWorkingSetBytes: peak,
      cpuTotalMs: cpuMs,
      handleCount: handleCount,
      threadCount: 0, // 线程数需要 Toolhelp 快照，阶段 0 不采集。
    );
  }

  /// 计算两个采样点之间的 CPU 占用率。
  static CpuUsage? usageBetween(ProcessSample a, ProcessSample b, int logicalCores) {
    final int deltaCpuMs = b.cpuTotalMs - a.cpuTotalMs;
    final int deltaWallMs = b.at.difference(a.at).inMilliseconds;
    if (deltaCpuMs < 0 || deltaWallMs <= 0) return null;
    final double oneCore = deltaCpuMs / deltaWallMs * 100;
    final int cores = logicalCores <= 0 ? 1 : logicalCores;
    return CpuUsage(
      percentOfOneCore: oneCore,
      percentOfMachine: oneCore / cores,
      elapsed: Duration(milliseconds: deltaWallMs),
    );
  }

  /// 机器逻辑核心数（供 CPU 百分比换算）。
  static int get logicalCores => Platform.numberOfProcessors;
}

// -----------------------------------------------------------------------------
// FFI 绑定
// -----------------------------------------------------------------------------

/// `PROCESS_MEMORY_COUNTERS` 结构体（x64 布局）。
final class _MemoryCounters extends Struct {
  @Uint32()
  external int cb;

  @Uint32()
  external int pageFaultCount;

  @UintPtr()
  external int peakWorkingSetSize;

  @UintPtr()
  external int workingSetSize;

  @UintPtr()
  external int quotaPeakPagedPoolUsage;

  @UintPtr()
  external int quotaPagedPoolUsage;

  @UintPtr()
  external int quotaPeakNonPagedPoolUsage;

  @UintPtr()
  external int quotaNonPagedPoolUsage;

  @UintPtr()
  external int pagefileUsage;

  @UintPtr()
  external int peakPagefileUsage;
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _GetProcessTimesNative = Int32 Function(
    IntPtr, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);
typedef _GetProcessTimesDart = int Function(
    int, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);

typedef _GetProcessMemoryInfoNative = Int32 Function(
    IntPtr, Pointer<_MemoryCounters>, Uint32);
typedef _GetProcessMemoryInfoDart = int Function(
    int, Pointer<_MemoryCounters>, int);

typedef _GetProcessHandleCountNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetProcessHandleCountDart = int Function(int, Pointer<Uint32>);

class _Win32Fns {
  _Win32Fns._();

  static final _Win32Fns instance = _Win32Fns._();

  final DynamicLibrary _k = Win32ProcessStats._kernel32!;
  final DynamicLibrary _p = Win32ProcessStats._psapi!;

  late final _GetCurrentProcessDart getCurrentProcess =
      _k.lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
    'GetCurrentProcess',
  );

  late final _GetProcessTimesDart getProcessTimes =
      _k.lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
    'GetProcessTimes',
  );

  late final _GetProcessHandleCountDart getProcessHandleCount =
      _k.lookupFunction<_GetProcessHandleCountNative, _GetProcessHandleCountDart>(
    'GetProcessHandleCount',
  );

  late final _GetProcessMemoryInfoDart getProcessMemoryInfo =
      _p.lookupFunction<_GetProcessMemoryInfoNative, _GetProcessMemoryInfoDart>(
    'GetProcessMemoryInfo',
  );
}

/// [ProcessDiagnostics] 的 Windows 实现。
///
/// 只是把上面那套静态 FFI 调用包成接口实例，好处是上层（诊断页 / 性能采样器）
/// 只依赖 `ProcessDiagnostics`，Android 编译单元因此不必 import 本文件。
class Win32ProcessDiagnostics implements ProcessDiagnostics {
  const Win32ProcessDiagnostics();

  @override
  bool get isAvailable => Win32ProcessStats.isAvailable;

  @override
  ProcessSample? sample() => Win32ProcessStats.sample();

  @override
  CpuUsage? usageBetween(
    ProcessSample previous,
    ProcessSample current,
    int logicalCores,
  ) =>
      Win32ProcessStats.usageBetween(previous, current, logicalCores);

  @override
  int get logicalCores => Win32ProcessStats.logicalCores;
}