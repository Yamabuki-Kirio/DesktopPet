import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import '../core/paths.dart';
import 'process_metrics.dart';

/// 一次采样记录。
class PerfSample {
  const PerfSample({
    required this.elapsed,
    required this.workingSetMb,
    required this.cpuPercentOfOneCore,
    required this.cpuPercentOfMachine,
    required this.handleCount,
    required this.frameCount,
  });

  /// 从开始采样到现在经过的时间。
  final Duration elapsed;

  final double workingSetMb;
  final double cpuPercentOfOneCore;
  final double cpuPercentOfMachine;
  final int handleCount;

  /// 采样时的累计着色帧数（用于计算平均 FPS）。
  final int frameCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'elapsed_s': elapsed.inSeconds,
        'working_set_mb': double.parse(workingSetMb.toStringAsFixed(2)),
        'cpu_percent_one_core': double.parse(cpuPercentOfOneCore.toStringAsFixed(3)),
        'cpu_percent_machine': double.parse(cpuPercentOfMachine.toStringAsFixed(3)),
        'handle_count': handleCount,
        'frame_count': frameCount,
      };
}

/// 稳定性测试期间的汇总。
class PerfReport {
  const PerfReport({
    required this.samples,
    required this.duration,
    required this.avgWorkingSetMb,
    required this.firstWorkingSetMb,
    required this.lastWorkingSetMb,
    required this.peakWorkingSetMb,
    required this.avgCpuOneCore,
    required this.peakCpuOneCore,
    required this.handleGrowth,
    required this.avgFps,
  });

  final List<PerfSample> samples;
  final Duration duration;
  final double avgWorkingSetMb;
  final double firstWorkingSetMb;
  final double lastWorkingSetMb;
  final double peakWorkingSetMb;
  final double avgCpuOneCore;
  final double peakCpuOneCore;

  /// 句柄数净增长（正数表示可能泄漏）。
  final int handleGrowth;

  final double avgFps;

  /// 内存是否仍在持续增长（简单判定：后 1/3 均值比前 1/3 均值高 20% 且增量 > 20MB）。
  bool get memoryKeepsGrowing {
    if (samples.length < 9) return false;
    final List<PerfSample> head = samples.sublist(0, samples.length ~/ 3);
    final List<PerfSample> tail = samples.sublist(samples.length * 2 ~/ 3);
    final double headAvg =
        head.map((PerfSample s) => s.workingSetMb).reduce((double a, double b) => a + b) / head.length;
    final double tailAvg =
        tail.map((PerfSample s) => s.workingSetMb).reduce((double a, double b) => a + b) / tail.length;
    return tailAvg > headAvg * 1.2 && (tailAvg - headAvg) > 20;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'duration_s': duration.inSeconds,
        'samples': samples.length,
        'working_set_mb': <String, Object?>{
          'first': double.parse(firstWorkingSetMb.toStringAsFixed(2)),
          'last': double.parse(lastWorkingSetMb.toStringAsFixed(2)),
          'avg': double.parse(avgWorkingSetMb.toStringAsFixed(2)),
          'peak': double.parse(peakWorkingSetMb.toStringAsFixed(2)),
        },
        'cpu_percent_one_core': <String, Object?>{
          'avg': double.parse(avgCpuOneCore.toStringAsFixed(3)),
          'peak': double.parse(peakCpuOneCore.toStringAsFixed(3)),
        },
        'handle_count_growth': handleGrowth,
        'avg_fps': double.parse(avgFps.toStringAsFixed(2)),
        'memory_keeps_growing': memoryKeepsGrowing,
      };

  /// CSV 导出（便于把原始数据贴进交付文档）。
  String toCsv() {
    final StringBuffer b = StringBuffer()
      ..writeln('elapsed_s,working_set_mb,cpu_percent_one_core,cpu_percent_machine,handle_count,frame_count');
    for (final PerfSample s in samples) {
      b.writeln('${s.elapsed.inSeconds},'
          '${s.workingSetMb.toStringAsFixed(2)},'
          '${s.cpuPercentOfOneCore.toStringAsFixed(3)},'
          '${s.cpuPercentOfMachine.toStringAsFixed(3)},'
          '${s.handleCount},'
          '${s.frameCount}');
    }
    return b.toString();
  }
}

/// 长时运行性能采样器。
///
/// 每 [interval] 采样一次进程 CPU / 内存 / 句柄数。
/// 用于验收第 21、22 项（连续运行的内存增长与 CPU/内存实测）。
/// 采样本身的开销极小（两次 FFI 调用），因此不会干扰被测对象。
class PerfSampler extends ChangeNotifier {
  PerfSampler({
    this.interval = const Duration(seconds: 30),
    this.sessionId = 'soak',
    ProcessDiagnostics diagnostics = const UnavailableProcessDiagnostics(),
  }) : _diagnostics = diagnostics;

  final Duration interval;
  final String sessionId;

  /// 平台进程指标实现（Windows 注入 FFI 实现；Android 注入不可用实现）。
  final ProcessDiagnostics _diagnostics;

  final List<PerfSample> _samples = <PerfSample>[];
  ProcessSample? _previous;
  DateTime? _startedAt;
  Timer? _timer;

  /// 由外部注入的帧计数读取器（拿到 SchedulerBinding.instance.framesEnabled 等）。
  int Function()? frameCounter;

  List<PerfSample> get samples => List<PerfSample>.unmodifiable(_samples);

  bool get isRunning => _timer != null;

  Duration get elapsedSinceStart =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  ProcessSample? get latest {
    final ProcessSample? s = _diagnostics.sample();
    return s;
  }

  /// 进程指标是否可用（诊断页据此隐藏 CPU / 句柄列）。
  bool get diagnosticsAvailable => _diagnostics.isAvailable;

  void start() {
    if (_timer != null) return;
    _startedAt = DateTime.now();
    _samples.clear();
    _previous = _diagnostics.sample();
    Loggers.app.info(
      '性能采样开始（间隔 ${interval.inSeconds}s，平台采样可用=${_diagnostics.isAvailable}）',
    );
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    Loggers.app.info('性能采样停止，共 ${_samples.length} 个采样点');
  }

  void reset() {
    stop();
    _samples.clear();
    _previous = null;
    _startedAt = null;
    notifyListeners();
  }

  void _tick() {
    final ProcessSample? current = _diagnostics.sample();
    if (current == null) return;
    final ProcessSample? prev = _previous;
    double cpuOne = 0;
    double cpuMachine = 0;
    if (prev != null) {
      final CpuUsage? usage = _diagnostics.usageBetween(
        prev,
        current,
        _diagnostics.logicalCores,
      );
      if (usage != null) {
        cpuOne = usage.percentOfOneCore;
        cpuMachine = usage.percentOfMachine;
      }
    }
    _previous = current;

    _samples.add(PerfSample(
      elapsed: elapsedSinceStart,
      workingSetMb: current.workingSetMb,
      cpuPercentOfOneCore: cpuOne,
      cpuPercentOfMachine: cpuMachine,
      handleCount: current.handleCount,
      frameCount: frameCounter?.call() ?? 0,
    ));
    notifyListeners();
  }

  /// 汇总报告；不可用时返回 null。
  PerfReport? buildReport() {
    if (_samples.isEmpty) return null;

    final List<double> ws = _samples.map((PerfSample s) => s.workingSetMb).toList();
    final double avgWs = ws.reduce((double a, double b) => a + b) / ws.length;
    final double peakWs = ws.reduce((double a, double b) => a > b ? a : b);

    final List<double> cpu = _samples.map((PerfSample s) => s.cpuPercentOfOneCore).toList();
    // 第一个采样点没有前一帧，CPU 计为 0，汇总时排除。
    final List<double> cpuValid = cpu.length > 1 ? cpu.sublist(1) : cpu;
    final double avgCpu =
        cpuValid.isEmpty ? 0 : cpuValid.reduce((double a, double b) => a + b) / cpuValid.length;
    final double peakCpu =
        cpuValid.isEmpty ? 0 : cpuValid.reduce((double a, double b) => a > b ? a : b);

    final double avgFps = _samples.length < 2
        ? 0
        : (_samples.last.frameCount - _samples.first.frameCount) /
            (duration.inMilliseconds / 1000).clamp(1, double.infinity);

    return PerfReport(
      samples: List<PerfSample>.unmodifiable(_samples),
      duration: duration,
      avgWorkingSetMb: avgWs,
      firstWorkingSetMb: ws.first,
      lastWorkingSetMb: ws.last,
      peakWorkingSetMb: peakWs,
      avgCpuOneCore: avgCpu,
      peakCpuOneCore: peakCpu,
      handleGrowth: _samples.last.handleCount - _samples.first.handleCount,
      avgFps: avgFps,
    );
  }

  Duration get duration => elapsedSinceStart;

  /// 把采样原始数据与汇总写到应用数据目录，便于交付。
  Future<String?> exportReports() async {
    final PerfReport? report = buildReport();
    if (report == null) return null;
    try {
      final Directory dir = AppPaths.instance.indexDir;
      await dir.create(recursive: true);
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final File csv = File('${dir.path}/perf_${sessionId}_$stamp.csv');
      await csv.writeAsString(report.toCsv(), flush: true);
      final File summary = File('${dir.path}/perf_${sessionId}_$stamp.summary.json');
      await summary.writeAsString(
        const JsonEncoderPretty().convert(report.toJson()),
        flush: true,
      );
      Loggers.app.info('性能数据已导出: ${csv.path}');
      return csv.path;
    } catch (e, st) {
      Loggers.app.warning('导出性能数据失败', e, st);
      return null;
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// 简单的 JSON 美化编码器，避免为 fmt 再引一个依赖。
class JsonEncoderPretty {
  const JsonEncoderPretty();

  String convert(Object? value) {
    final StringBuffer buffer = StringBuffer();
    _write(value, buffer, 0);
    return buffer.toString();
  }

  void _write(Object? value, StringBuffer b, int indent) {
    final String pad = '  ' * indent;
    final String padInner = '  ' * (indent + 1);
    if (value is Map) {
      if (value.isEmpty) {
        b.write('{}');
        return;
      }
      b.writeln('{');
      final List<MapEntry> entries = value.entries.cast<MapEntry>().toList();
      for (int i = 0; i < entries.length; i++) {
        b.write('$padInner"${entries[i].key}": ');
        _write(entries[i].value, b, indent + 1);
        b.write(i == entries.length - 1 ? '\n' : ',\n');
      }
      b.write('$pad}');
      return;
    }
    if (value is List) {
      if (value.isEmpty) {
        b.write('[]');
        return;
      }
      b.writeln('[');
      for (int i = 0; i < value.length; i++) {
        b.write(padInner);
        _write(value[i], b, indent + 1);
        b.write(i == value.length - 1 ? '\n' : ',\n');
      }
      b.write('$pad]');
      return;
    }
    if (value is String) {
      b.write('"${value.replaceAll('"', r'\"')}"');
      return;
    }
    b.write('${value ?? 'null'}');
  }
}
