/// 阶段 1：应用分类与活动段结束原因。
library;

/// 应用分类（第一版固化 8 类）。
///
/// 分类只影响桌宠状态映射与统计展示，不参与任何隐私相关的判断。
enum AppCategory {
  development('development', '开发'),
  productivity('productivity', '生产力'),
  gaming('gaming', '游戏'),
  social('social', '社交'),
  entertainment('entertainment', '娱乐'),
  browser('browser', '浏览器'),
  system('system', '系统'),
  other('other', '其他');

  const AppCategory(this.wireName, this.labelZh);

  /// 持久化 / 规则表里使用的稳定名称。
  final String wireName;

  /// 界面展示名。
  final String labelZh;

  bool get isUserAdjustable => true;

  static AppCategory fromWire(String? value) {
    for (final AppCategory c in AppCategory.values) {
      if (c.wireName == value) return c;
    }
    return AppCategory.other;
  }
}

/// 活动段的结束原因。
///
/// 每一个都对应需求里明确的一类中断，用于事后诊断「这段时间为什么没被记录」。
enum SegmentEndReason {
  /// 前台应用发生变化。
  foregroundChanged('foreground_changed', '前台应用变化'),

  /// 用户进入空闲（超过阈值）。
  userIdle('user_idle', '用户空闲'),

  /// Windows 锁屏。
  sessionLocked('session_locked', '锁屏'),

  /// 系统休眠 / 恢复。
  systemSuspend('system_suspend', '系统休眠'),

  /// 用户暂停记录。
  trackingPaused('tracking_paused', '暂停记录'),

  /// 应用被排除（含 PetLife 自身）。
  appExcluded('app_excluded', '应用被排除'),

  /// PetLife 正常退出。
  clientShutdown('client_shutdown', '正常退出'),

  /// 无法取得有效进程信息 / 前台窗口消失。
  processUnavailable('process_unavailable', '进程不可用'),

  /// 上次异常退出，启动时用检查点补齐关闭。
  crashRecovery('crash_recovery', '异常退出恢复'),

  /// 检测到系统时间大幅变化。
  clockChanged('clock_changed', '系统时间变化');

  const SegmentEndReason(this.wireName, this.labelZh);

  final String wireName;
  final String labelZh;

  /// 是否属于「非正常结束」（用于统计与诊断提示）。
  bool get isAbnormal =>
      this == SegmentEndReason.crashRecovery ||
      this == SegmentEndReason.processUnavailable ||
      this == SegmentEndReason.clockChanged;

  static SegmentEndReason? fromWire(String? value) {
    if (value == null) return null;
    for (final SegmentEndReason r in SegmentEndReason.values) {
      if (r.wireName == value) return r;
    }
    return null;
  }
}

/// 采集器对外暴露的运行状态（诊断页 / 统计页展示）。
enum TrackingStatus {
  /// 正常采集中。
  running('采集中'),

  /// 用户暂停。
  paused('已暂停'),

  /// 锁屏中（不计时）。
  locked('已锁屏'),

  /// 用户空闲超过阈值（不计时）。
  idle('空闲中'),

  /// 采集器不可用（非 Windows 或 Win32 加载失败）。
  unavailable('不可用');

  const TrackingStatus(this.labelZh);

  final String labelZh;
}
