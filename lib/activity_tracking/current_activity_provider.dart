import 'dart:async';

import 'package:flutter/foundation.dart';

/// 「当前前台应用」的跨平台统一模型（Phase 4C-5.1A）。
///
/// 为什么要有这一层：使用统计页原先直接读 `ActivityTracker.currentAppDisplayName`
/// （**Windows 专用**链路），而 Android 的前台识别在原生侧 —— 于是出现
/// "设置页能显示当前应用、统计页显示空"（真机缺陷 D）。
/// 现在两个页面都只依赖本接口提供的结果。
@immutable
class CurrentActivity {
  const CurrentActivity({
    required this.available,
    this.packageName,
    this.displayName,
    this.category,
    this.detectionSource = 'unavailable',
    this.detectionReason,
    this.failureReason,
    this.eventTime,
    this.detectedAt,
    this.usageAccessAvailable = false,
    this.collectorRunning = false,
  });

  /// 是否识别到一个可用的前台应用。
  final bool available;

  /// 应用标识：Android 为包名，Windows 为 `app_key`（可执行文件名规范化）。
  final String? packageName;

  /// 显示名（Android 取应用标签，Windows 取进程名）。
  final String? displayName;

  /// 分类（`AppCategory.wireName`）。
  final String? category;

  /// 检测来源：`activity-events` / `usage-stats-fallback` / `cache` /
  /// `win32-foreground` / `unavailable`。
  final String detectionSource;

  /// 原生给出的检测原因（例如 `last-event-is-self`）。
  final String? detectionReason;

  /// **单一**的失败原因（界面不要自己拼状态）：
  /// `usage_access_missing` / `collector_not_running` / `collector_paused_or_stopped` /
  /// `foreground_unavailable` / `unsupported-platform-provider` / `no-foreground-window`。
  final String? failureReason;

  /// 判定依据的事件时间（Android：`UsageEvents` 时间戳）。
  final DateTime? eventTime;

  /// 本次检测时刻。
  final DateTime? detectedAt;

  /// Android：使用情况访问是否可用；Windows：恒为 true（不需要该权限）。
  final bool usageAccessAvailable;

  /// 采集器（Android：悬浮服务里的唯一轮询任务；Windows：Dart 采集器）是否在运行。
  final bool collectorRunning;

  /// 应用显示名（拿不到时退回标识）。
  String? get label => displayName ?? packageName;

  /// 界面用的主文案（**绝不返回空字符串**，也不会长期停在"—"）。
  ///
  /// 优先按**失败原因**给结论，`collectorRunning` 只作为兜底判据 ——
  /// 否则"读取失败"会被误显示成"未采集"。
  String get displayLabelZh {
    if (available) return label ?? '未知应用';
    return switch (failureReason) {
      'usage_access_missing' => '不可用',
      'collector_not_running' => '未采集',
      'collector_paused_or_stopped' => '未采集',
      'unsupported-platform-provider' => '不支持',
      'read_failed' => '暂时无法识别',
      'foreground_unavailable' => '暂时无法识别',
      'no-foreground-window' => '暂时无法识别',
      _ => collectorRunning ? '暂时无法识别' : '未采集',
    };
  }

  /// 失败 / 降级的中文说明（正常识别时为 null）。
  String? get hintZh => switch (failureReason) {
        null => null,
        'usage_access_missing' => '未授予使用情况访问权限，无法识别当前应用',
        'collector_not_running' =>
          '未开启悬浮桌宠：Android 前台识别依附于悬浮服务，开启后即可统计',
        'collector_paused_or_stopped' => '采集已暂停（锁屏或用户暂停），恢复后继续',
        'foreground_unavailable' => '暂时无法确定当前应用（窗口内没有有效的前台事件）',
        'no-foreground-window' => '当前没有可识别的前台窗口',
        'read_failed' => '读取当前前台应用失败（原生通道不可用）',
        'unsupported-platform-provider' => '当前平台不支持前台应用识别',
        _ => null,
      };

  /// 检测来源的中文说明。
  String get sourceLabelZh => switch (detectionSource) {
        'activity-events' => '前台事件',
        'usage-stats-fallback' => '使用统计兜底',
        'cache' => '最近有效应用',
        'win32-foreground' => 'Windows 前台窗口',
        _ => '不可用',
      };

  /// 从原生通道返回的 Map 解析（字段缺失一律按"不可用"处理，绝不猜）。
  static CurrentActivity fromMap(Map<String, Object?> map) {
    final int detectedAt = _int(map['detectedAt']);
    final int eventTime = _int(map['eventTime']);
    return CurrentActivity(
      available: map['available'] == true,
      packageName: map['packageName'] as String?,
      displayName: map['appLabel'] as String?,
      category: map['category'] as String?,
      detectionSource: (map['detectionSource'] as String?) ?? 'unavailable',
      detectionReason: map['detectionReason'] as String?,
      failureReason: map['failureReason'] as String?,
      detectedAt:
          detectedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(detectedAt) : null,
      eventTime:
          eventTime > 0 ? DateTime.fromMillisecondsSinceEpoch(eventTime) : null,
      usageAccessAvailable: map['usageAccessAvailable'] == true,
      collectorRunning: map['collectorRunning'] == true,
    );
  }

  /// 读不到任何信息时的安全默认。
  static const CurrentActivity unavailable = CurrentActivity(
    available: false,
    failureReason: 'foreground_unavailable',
  );

  /// 读取本身失败（通道不可用等）—— 与"识别不到应用"区分开，便于排查。
  static const CurrentActivity readFailed = CurrentActivity(
    available: false,
    failureReason: 'read_failed',
  );

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// 当前前台应用提供者（**跨平台接口**）。
///
/// 统计页与任何需要"当前应用"的界面只依赖它，不再自己判断平台、也不自己拼第二套逻辑
/// （需求 §3.4 / §3.5）。
abstract interface class CurrentActivityProvider {
  /// 当前平台是否支持前台应用识别。
  bool get isSupported;

  /// 持续监听（实现内部自行决定轮询节奏；订阅取消后必须停止轮询）。
  Stream<CurrentActivity> watch();

  /// 读取一次。
  Future<CurrentActivity> current();
}

/// 非 Windows / 非 Android（测试、桩）实现。
class UnsupportedCurrentActivityProvider implements CurrentActivityProvider {
  const UnsupportedCurrentActivityProvider();

  @override
  bool get isSupported => false;

  @override
  Future<CurrentActivity> current() async => const CurrentActivity(
        available: false,
        failureReason: 'unsupported-platform-provider',
      );

  @override
  Stream<CurrentActivity> watch() => const Stream<CurrentActivity>.empty();
}

/// 轮询式监听的通用实现：**订阅取消即停止定时器**（避免页面销毁后仍在轮询）。
Stream<CurrentActivity> pollCurrentActivity(
  Future<CurrentActivity> Function() read, {
  required Duration interval,
}) {
  late StreamController<CurrentActivity> controller;
  Timer? timer;
  bool busy = false;
  bool emitted = false;

  Future<void> emit() async {
    if (busy || controller.isClosed) return;
    busy = true;
    try {
      final CurrentActivity activity = await read();
      if (!controller.isClosed) {
        controller.add(activity);
        emitted = true;
      }
    } catch (_) {
      // 单次失败不打断流（界面保留上一条结果）；但**一次都没成功**时
      // 必须给出明确状态，否则界面会长期停在"读取中…"。
      if (!emitted && !controller.isClosed) {
        controller.add(CurrentActivity.readFailed);
      }
    } finally {
      busy = false;
    }
  }

  controller = StreamController<CurrentActivity>(
    onListen: () {
      unawaited(emit());
      timer = Timer.periodic(interval, (Timer _) => unawaited(emit()));
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );
  return controller.stream;
}
