/// 进程资源采样的**平台中立**数据模型与接口。
///
/// 之所以单独一个文件：Windows 用 FFI 直连 Win32 读取，Android 读不到同等的
/// 句柄/线程信息。把"数据"与"能力"放在中立层、把实现放在平台层，
/// 上层（诊断页、性能采样器）就不必 import 任何 Win32 代码。
library;

/// 一次进程资源采样。
class ProcessSample {
  const ProcessSample({
    required this.at,
    required this.workingSetBytes,
    required this.peakWorkingSetBytes,
    required this.cpuTotalMs,
    required this.handleCount,
    required this.threadCount,
  });

  final DateTime at;

  /// 当前工作集（任务管理器里的「内存(专用工作集)」近似值）。
  final int workingSetBytes;

  /// 峰值工作集。
  final int peakWorkingSetBytes;

  /// 内核态 + 用户态 CPU 累计时间。
  final int cpuTotalMs;

  final int handleCount;
  final int threadCount;

  double get workingSetMb => workingSetBytes / 1024 / 1024;

  double get peakWorkingSetMb => peakWorkingSetBytes / 1024 / 1024;

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'working_set_mb': double.parse(workingSetMb.toStringAsFixed(2)),
        'peak_working_set_mb': double.parse(peakWorkingSetMb.toStringAsFixed(2)),
        'cpu_total_ms': cpuTotalMs,
        'handle_count': handleCount,
        'thread_count': threadCount,
      };
}

/// 两个采样点之间的 CPU 占用。
class CpuUsage {
  const CpuUsage({
    required this.percentOfOneCore,
    required this.percentOfMachine,
    required this.elapsed,
  });

  final double percentOfOneCore;
  final double percentOfMachine;
  final Duration elapsed;

  @override
  String toString() => '${percentOfOneCore.toStringAsFixed(2)}% (单核) / '
      '${percentOfMachine.toStringAsFixed(2)}% (整机)';
}

/// 进程资源读取能力（需求「三、架构改造重点」中的 `ProcessDiagnostics`）。
abstract interface class ProcessDiagnostics {
  /// 该平台是否真的能读到进程资源。
  bool get isAvailable;

  /// 采样一次；不可用或失败时返回 null。
  ProcessSample? sample();

  /// 两个采样点之间的 CPU 占用；无法计算时返回 null。
  CpuUsage? usageBetween(ProcessSample previous, ProcessSample current, int logicalCores);

  /// 逻辑核心数（用于换算"占整机百分比"）。
  int get logicalCores;
}

/// 不可用实现：任何采样都返回 null。
///
/// 语义是"这个平台读不到"，而不是"占用为 0"——
/// 上层据此隐藏相应指标，而不是展示假的 0%。
class UnavailableProcessDiagnostics implements ProcessDiagnostics {
  const UnavailableProcessDiagnostics();

  @override
  bool get isAvailable => false;

  @override
  ProcessSample? sample() => null;

  @override
  CpuUsage? usageBetween(ProcessSample previous, ProcessSample current, int logicalCores) => null;

  @override
  int get logicalCores => 1;
}

