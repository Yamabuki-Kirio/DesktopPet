import 'dart:async';

import 'package:flutter/material.dart';

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/android_usage_import_service.dart';
import '../../activity_tracking/android_usage_session.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../../activity_tracking/models/activity_enums.dart';
import '../../activity_tracking/models/usage_stats.dart';
import '../../activity_tracking/usage_analytics_service.dart';
import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../app/app_scope.dart';
import '../../platform/overlay_pet.dart';
import '../../settings/app_settings.dart';
import '../../state_engine/system_state.dart';
import '../dialogs/text_input_dialog.dart';
import '../overlay_pet_controller.dart';
import 'cloud_statistics_page.dart';

/// 使用统计页面（需求「十三、统计界面」）。
///
/// 口径说明集中在 [UsageAnalyticsService] 与 `docs/12-使用统计口径.md`：
/// **屏幕会话时间 / 活跃使用时间 / 空闲时间 / 应用使用时间**是四个不同指标，
/// 本页面把它们分开显示，绝不笼统地叫「屏幕时间」。
///
/// Phase 4B 之后，本页顶部增加「本机 | 云端」切换：
/// * **本机**：原有采集数据（采集、暂停/恢复、应用管理全部保留、行为不变）；
/// * **云端**：其他设备上传到服务器的使用统计（只读，见 [CloudStatisticsPage]）。
class UsageStatsPage extends StatefulWidget {
  const UsageStatsPage({
    super.key,
    required this.services,
    this.onOpenAccount,
    this.overlay,
  });

  final AppServices services;

  /// 云端页未登录时「去登录」的入口（切到「账户与同步」页）。
  final VoidCallback? onOpenAccount;

  /// Android 悬浮桌宠协调器（Phase 4C-6A）。
  ///
  /// 「当前桌宠状态」必须读**原生**真值：Android 的状态切换发生在悬浮服务里，
  /// Flutter 状态引擎在 Android 上不会收到前台事件（其采集器是"不可用"实现），
  /// 因此读状态引擎会让这一行**永远停在 default**。
  final OverlayPetController? overlay;

  @override
  State<UsageStatsPage> createState() => UsageStatsPageState();
}

/// 本页状态。**公开**类型是为了让外壳（轮盘菜单动作）能通过 `GlobalKey`
/// 请求切到云端子页 —— 复用本页既有的 [_selectTab]（含持久化），
/// 而不是在外面再造一套子页切换逻辑。
class UsageStatsPageState extends State<UsageStatsPage> with WidgetsBindingObserver {
  UsageRange _range = UsageRange.today;
  UsageSummary? _summary;
  bool _loading = true;
  String? _error;

  /// 与 [_summary] **同一个窗口**的时间段列表（需求 §8.3）。
  List<UsageSegmentRow> _timeline = const <UsageSegmentRow>[];

  /// 当前子页：false = 本机统计（原有），true = 云端统计（Phase 4B）。
  bool _showCloud = false;
  bool _tabRestored = false;

  /// Phase 4C-5.1A：「当前前台应用」来自**跨平台**提供者。
  ///
  /// 原先直接读 `ActivityTracker.currentAppDisplayName`（Windows 专用链路），
  /// 因此在 Android 上永远是空 —— 这也正是"设置页能显示、统计页显示空"的根因。
  CurrentActivity? _activity;
  StreamSubscription<CurrentActivity>? _activitySub;

  /// Phase 4C-5.1B：Android 原生采集器状态（非 Android 时为 null）。
  UsageCollectorState? _collector;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _restoreTab();
    _subscribeCurrentActivity();
  }

  /// 从后台回到前台：先把原生暂存会话导入，再刷新（需求 §7 的触发点之一）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      unawaited(_reload());
    }
  }

  /// 订阅"当前前台应用"。订阅取消时提供者会自己停掉轮询。
  void _subscribeCurrentActivity() {
    _activitySub = widget.services.currentActivity.watch().listen(
      (CurrentActivity activity) {
        if (!mounted) return;
        setState(() => _activity = activity);
      },
      onError: (Object e, StackTrace st) {
        Loggers.activity.warning('读取当前前台应用失败', e, st);
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_activitySub?.cancel());
    _activitySub = null;
    super.dispose();
  }

  /// 恢复用户上次停留的子页（需求：默认保持用户上次选择）。
  ///
  /// 用 post-frame 的原因：读设置是异步的，而 build 期间不该触发 I/O 或 setState。
  void _restoreTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabRestored) return;
      _tabRestored = true;
      final String tab = widget.services.settings.settings.usageStatsTab;
      final bool cloud = tab == AppSettings.usageStatsTabCloud;
      if (cloud != _showCloud) setState(() => _showCloud = cloud);
    });
  }

  void _selectTab(bool cloud) {
    if (cloud == _showCloud) return;
    setState(() => _showCloud = cloud);
    widget.services.settings
        .setUsageStatsTab(
          cloud ? AppSettings.usageStatsTabCloud : AppSettings.usageStatsTabLocal,
        )
        .catchError((Object e, StackTrace st) {
      Loggers.app.warning('保存统计子页选择失败', e, st);
    });
  }

  /// 切到「云端」子页（轮盘菜单 `records_cloud` 用）。
  ///
  /// 刻意复用 [_selectTab]：切换动作、持久化与顶部 SegmentedButton 完全同源，
  /// 不存在"从菜单进来是一套、手点又是另一套"的分叉。
  void showCloudTab() => _selectTab(true);

  Future<void> _reload() async {
    // 触发点可能是异步的（例如对话框返回后）：页面可能已被销毁。
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 先把内存中的活动段落盘，保证查询到的是最新数据。
      await widget.services.activityTracker.flushNow();
      // Phase 4C-5.1B：再把原生暂存的使用会话幂等导入本机库（Android）。
      // 顺序很重要：不先导入，统计页会"看不到刚用完的应用"。
      await widget.services.importAndroidUsageSessions();
      // 累计统计与时间段列表用**同一个窗口**（需求 §8.3）。
      final UsageWindow window = UsageAnalyticsService.windowFor(_range);
      final UsageSummary summary =
          await widget.services.usageAnalytics.summarize(window);
      final List<UsageSegmentRow> timeline =
          await widget.services.usageAnalytics.timeline(window);
      final UsageCollectorState? collector = await _readCollectorState();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _timeline = timeline;
        _collector = collector ?? _collector;
        _loading = false;
      });
    } catch (e, st) {
      Loggers.activity.warning('加载使用统计失败', e, st);
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 读取采集器状态（非 Android 返回 null，界面据此隐藏相关区块）。
  Future<UsageCollectorState?> _readCollectorState() async {
    final AndroidUsageImportService? importer = widget.services.androidUsageImport;
    if (importer == null) return null;
    return importer.collectorState();
  }

  @override
  Widget build(BuildContext context) {
    final AppServices s = widget.services;
    final ActivityTracker tracker = s.activityTracker;

    return Column(
      children: <Widget>[
        _sourceSelector(),
        const Divider(height: 1),
        // 用 IndexedStack 而不是条件构建：切回本机页时滚动位置与展开状态都保留，
        // 云端页也不会因为切走而被销毁（返回时不会重新请求）。
        Expanded(
          child: IndexedStack(
            index: _showCloud ? 1 : 0,
            children: <Widget>[
              _localStatsView(s, tracker),
              CloudStatisticsPage(
                controller: s.cloudStatistics,
                isSignedIn: () => s.authenticatedApi.isSignedIn,
                syncEngine: s.syncEngine,
                onOpenAccount: widget.onOpenAccount,
                active: _showCloud,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 「本机 | 云端」切换。原有本机统计完全保留。
  Widget _sourceSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text('本机'),
                  icon: Icon(Icons.computer, size: 18),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('云端'),
                  icon: Icon(Icons.cloud_outlined, size: 18),
                ),
              ],
              selected: <bool>{_showCloud},
              onSelectionChanged: (Set<bool> selection) =>
                  _selectTab(selection.first),
            ),
          ),
        ],
      ),
    );
  }

  /// 本机统计视图（Phase 4B 之前的内容，逻辑未改动）。
  Widget _localStatsView(AppServices s, ActivityTracker tracker) {
    return Column(
      children: <Widget>[
        _toolbar(tracker),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _liveCard(s, tracker),
                const SizedBox(height: 16),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('正在统计…')),
                  )
                else if (_error != null)
                  _errorCard()
                else ...<Widget>[
                  _overviewCard(),
                  const SizedBox(height: 16),
                  _timelineCard(),
                  const SizedBox(height: 16),
                  _appRankingCard(),
                  const SizedBox(height: 16),
                  _categoryCard(),
                ],
                const SizedBox(height: 16),
                _managementCard(s, tracker),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 顶部工具条
  // ---------------------------------------------------------------------------

  Widget _toolbar(ActivityTracker tracker) {
    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            const Text('统计范围：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            SegmentedButton<UsageRange>(
              segments: <ButtonSegment<UsageRange>>[
                for (final UsageRange r in UsageRange.values)
                  ButtonSegment<UsageRange>(value: r, label: Text(r.label)),
              ],
              selected: <UsageRange>{_range},
              onSelectionChanged: (Set<UsageRange> next) {
                setState(() => _range = next.first);
                _reload();
              },
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _loading ? null : _reload,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('读取使用统计时出错', style: TextStyle(color: Colors.red)),
              const SizedBox(height: 6),
              SelectableText(_error ?? '', style: const TextStyle(fontSize: 11)),
              const SizedBox(height: 8),
              const Text(
                '桌宠动画不受影响；可稍后重试或查看诊断页的「最近日志」。',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
        ),
      );

  // ---------------------------------------------------------------------------
  // 实时状态
  // ---------------------------------------------------------------------------

  Widget _liveCard(AppServices s, ActivityTracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ListenableBuilder(
          // 状态诊断由悬浮控制器每 2 秒推送一次（只读），这里跟着一起重建，
          // 因此"当前桌宠状态"与设置页显示的是**同一份原生真值**。
          listenable: widget.overlay == null
              ? tracker
              : Listenable.merge(<Listenable>[tracker, widget.overlay!]),
          builder: (BuildContext context, Widget? _) {
            final TrackingStatus status = tracker.status;
            final CurrentActivity? activity = _activity;
            final AppCategory? category = _categoryOf(activity?.category);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Text('当前应用：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Expanded(
                      child: Text(
                        '${activity?.displayLabelZh ?? '读取中…'}'
                        '${category == null ? '' : '（${category.labelZh}）'}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    _statusChip(status, tracker.isPaused),
                  ],
                ),
                if (activity != null && activity.packageName != null)
                  Text(
                    '检测来源：${activity.sourceLabelZh}'
                    '${activity.detectionReason == null ? '' : '（${activity.detectionReason}）'}',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                const SizedBox(height: 6),
                Text(
                  '当前桌宠状态：${_petStateLabel(s)}'
                  ' · 本段已持续 ${formatDurationZh(_sessionSeconds(tracker))}'
                  ' · 连续活跃 ${formatDurationZh(tracker.continuousActiveSeconds)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                // Android：把"状态提交链路"的关键值一并显示，方便按应用逐条记录诊断。
                if (_nativeStateTrace() != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _nativeStateTrace()!,
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ),
                // Phase 4C-5.1B：Android 采集器状态 + 最近一次导入时间。
                if (_collector != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '使用记录采集：${_collector!.labelZh}'
                      '${_collector!.pendingCount > 0 ? ' · 待导入 ${_collector!.pendingCount} 条' : ''}'
                      '${_lastImportLabel()}',
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ),
                if (activity?.hintZh != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '⚠ ${activity!.hintZh}',
                      style: const TextStyle(fontSize: 11, color: Colors.orange),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 「当前桌宠状态」：Android 读**原生**诊断，其它平台读状态引擎。
  ///
  /// 显示层根因修正：Android 的自动状态切换发生在原生悬浮服务里，
  /// Flutter 状态引擎在该平台不会被前台事件驱动 —— 读它会让这一行永远停在
  /// `default`，与桌宠实际状态完全无关（这正是真机"始终 default"的来源之一）。
  String _petStateLabel(AppServices s) {
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;
    if (d != null && d.stateId.isNotEmpty) {
      return '${d.stateLabel}（${d.stateId}）';
    }
    final SystemState state = s.stateEngineSnapshot.value.state;
    return '${state.wireName}（${state.descriptionZh}）';
  }

  /// 状态提交链路的一行摘要（仅 Android；与设置页诊断区同源）。
  String? _nativeStateTrace() {
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;
    if (d == null) return null;
    final String category = d.category ?? '—';
    final String target = d.resolvedTargetState ?? '—';
    final String rule = d.matchedRule ?? '—';
    final String result = d.lastTransitionResult ?? '—';
    return '状态链路：分类 $category → 目标 $target'
        ' · 规则 $rule · 提交 $result'
        '${d.candidateState == null ? '' : ' · 候选 ${d.candidateState}（${d.candidateElapsedMs}ms）'}';
  }

  /// 分类：直接用提供者回报的 `AppCategory.wireName`
  /// （Windows 来自 Dart 采集器、Android 来自原生分类，两边同一套 8 类命名）。
  AppCategory? _categoryOf(String? wireName) {
    if (wireName == null) return null;
    for (final AppCategory c in AppCategory.values) {
      if (c.wireName == wireName) return c;
    }
    return null;
  }

  /// 当前会话已持续秒数。
  ///
  /// Android 的会话在**原生**侧（Dart 采集器不参与），因此优先用原生回报的值；
  /// Windows 没有原生采集器，继续用 Dart 采集器的当前段秒数。
  int _sessionSeconds(ActivityTracker tracker) {
    final int native = _collector?.currentSessionSeconds ?? 0;
    return native > 0 ? native : tracker.currentSegmentSeconds;
  }

  /// 「· 最近更新 HH:mm:ss」（没有导入过则返回空串）。
  String _lastImportLabel() {
    final DateTime? at = widget.services.androidUsageImport?.lastImportAt;
    if (at == null) return '';
    final DateTime local = at.toLocal();
    final String hh = local.hour.toString().padLeft(2, '0');
    final String mm = local.minute.toString().padLeft(2, '0');
    final String ss = local.second.toString().padLeft(2, '0');
    return ' · 最近更新 $hh:$mm:$ss';
  }

  Widget _statusChip(TrackingStatus status, bool paused) {
    final Color color = switch (status) {
      TrackingStatus.running => const Color(0xFF2E7D32),
      TrackingStatus.paused => const Color(0xFFB26A00),
      TrackingStatus.locked => const Color(0xFF5C6BC0),
      TrackingStatus.idle => const Color(0xFF00838F),
      TrackingStatus.unavailable => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          Text(status.labelZh, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 今日 / 区间概览
  // ---------------------------------------------------------------------------

  Widget _overviewCard() {
    final UsageSummary summary = _summary!;
    final UsageOverview o = summary.overview;
    // Android 的原生采集只产出应用会话，没有设备级「屏幕会话 / 空闲」来源：
    // 这一项为 false 时**如实用应用时长表达总时长**，而不是摆三个 0 让人误判。
    final bool deviceMetrics = o.deviceMetricsAvailable;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title('${_range.label}概览 · ${summary.window.label}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 28,
              runSpacing: 12,
              children: <Widget>[
                if (deviceMetrics) ...<Widget>[
                  _stat('活跃使用时间', formatDurationZh(o.activeSeconds),
                      '屏幕会话中用户未超过空闲阈值的时间'),
                  _stat('屏幕会话时间', formatDurationZh(o.sessionSeconds),
                      '设备解锁且未休眠的时间'),
                  _stat('空闲时间', formatDurationZh(o.idleSeconds),
                      '解锁但用户超过空闲阈值的时间'),
                  _stat('应用使用时间', formatDurationZh(o.appActiveSeconds),
                      '活跃时间中归属到有效前台应用的部分'),
                ] else
                  _stat('今日总使用时长', formatDurationZh(o.appActiveSeconds),
                      '本设备只采集「应用使用时长」（由前台应用会话累计）'),
                _stat('最长连续使用', formatDurationZh(o.longestContinuousSeconds), '同一段连续活跃的峰值'),
                _stat('首次活跃', _fmtClock(o.firstActiveAt), '当日第一次进入活跃'),
                _stat('最后活跃', _fmtClock(o.lastActiveAt), '当日最后一次活跃'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              deviceMetrics
                  ? '四个时间口径互不相同：活跃 ≠ 屏幕会话（可能锁屏/休眠），'
                      '应用使用 ≤ 活跃使用（可能存在无有效前台应用的时间）。'
                  : '本设备（Android）只统计「应用使用时长」：'
                      '没有可靠来源区分屏幕会话与空闲时间，因此不作展示，也不填 0 充数。',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 使用时间段（Phase 4C-5.1B，需求 §8.2）
  // ---------------------------------------------------------------------------

  /// 今天（或所选范围）的应用使用时间段，按开始时间倒序。
  Widget _timelineCard() {
    final List<UsageSegmentRow> rows = _timeline;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _title('使用时间段（${_range.label}）'),
                const Spacer(),
                Text(
                  '${rows.length} 条',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (rows.isEmpty)
              const Text(
                '该时间段内还没有使用记录。开启桌宠后，切换应用即会开始记录；'
                '若刚刚用完应用，点「刷新」即可看到。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              )
            else
              Table(
                columnWidths: const <int, TableColumnWidth>{
                  0: FlexColumnWidth(2.4),
                  1: FlexColumnWidth(1.2),
                  2: FlexColumnWidth(1.2),
                  3: FlexColumnWidth(1),
                  4: FlexColumnWidth(1.6),
                },
                children: <TableRow>[
                  _headerRow(<String>['应用', '开始', '结束', '时长', '结束原因']),
                  for (final UsageSegmentRow row in rows.take(100)) _timelineRow(row),
                ],
              ),
            const SizedBox(height: 8),
            const Text(
              '时间按设备本地时区显示；跨小时 / 跨午夜的时间段保留真实起止时刻。'
              '进行中的会话只标「使用中」，不会提前写成已结束记录。',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  TableRow _timelineRow(UsageSegmentRow row) {
    return TableRow(
      children: <Widget>[
        _cell(row.displayName, bold: true),
        _cell(_fmtClock(row.startedAtUtc)),
        _cell(row.running ? '使用中' : _fmtClock(row.endedAtUtc)),
        _cell(formatDurationZh(row.activeSeconds)),
        _cell(row.endReasonLabelZh),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 应用排行
  // ---------------------------------------------------------------------------

  Widget _appRankingCard() {
    final List<AppUsageRow> apps = _summary!.apps;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title('应用排行（${_range.label}）'),
            const SizedBox(height: 6),
            if (apps.isEmpty)
              const Text('该时间段内没有记录到应用使用。',
                  style: TextStyle(fontSize: 12, color: Colors.black54))
            else
              Table(
                columnWidths: const <int, TableColumnWidth>{
                  0: FlexColumnWidth(3),
                  1: FlexColumnWidth(1.4),
                  2: FlexColumnWidth(1.4),
                  3: FlexColumnWidth(1),
                  4: FlexColumnWidth(1.2),
                  5: FlexColumnWidth(1.2),
                },
                children: <TableRow>[
                  _headerRow(<String>['应用', '分类', '时长', '段次数', '占比', '操作']),
                  for (final AppUsageRow row in apps.take(50)) _appRow(row),
                ],
              ),
          ],
        ),
      ),
    );
  }

  TableRow _appRow(AppUsageRow row) {
    return TableRow(
      children: <Widget>[
        _cell(row.displayName, bold: true),
        _cell(row.category.labelZh),
        _cell(formatDurationZh(row.activeSeconds)),
        _cell('${row.segmentCount}'),
        _cell('${(row.ratioOfAppTime * 100).toStringAsFixed(1)}%'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: PopupMenuButton<String>(
            tooltip: '修改分类 / 显示名 / 排除记录',
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (String value) => _onAppAction(value, row),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'rename', child: Text('修改显示名称')),
              const PopupMenuItem<String>(value: 'category', child: Text('修改分类')),
              PopupMenuItem<String>(
                value: 'exclude',
                child: Text(
                  widget.services.applications.find(row.appKey)?.excluded ?? false
                      ? '恢复记录'
                      : '排除记录',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _onAppAction(String action, AppUsageRow row) async {
    final AppServices s = widget.services;
    switch (action) {
      case 'rename':
        final String? name = await _promptText(
          title: '修改显示名称',
          initial: row.displayName,
          hint: '例如 Visual Studio Code',
        );
        if (name == null) return;
        await s.applications.setDisplayName(row.appKey, name);
      case 'category':
        final AppCategory? category = await _promptCategory(row.category);
        if (category == null) return;
        await s.applications.setCategory(row.appKey, category);
      case 'exclude':
        final bool excluded = s.applications.find(row.appKey)?.excluded ?? false;
        await s.applications.setExcluded(row.appKey, !excluded);
        // 排除后当前段应立即结束，不能等下一个采样周期。
        if (!excluded && s.activityTracker.currentAppKey == row.appKey) {
          await s.activitySegments.endCurrentSegment(SegmentEndReason.appExcluded);
        }
    }
    await _reload();
  }

  // ---------------------------------------------------------------------------
  // 分类统计
  // ---------------------------------------------------------------------------

  Widget _categoryCard() {
    final List<CategoryUsageRow> rows = _summary!.categories;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title('分类统计（${_range.label}）'),
            const SizedBox(height: 6),
            if (rows.isEmpty)
              const Text('该时间段内没有分类数据。',
                  style: TextStyle(fontSize: 12, color: Colors.black54))
            else
              for (final CategoryUsageRow row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: 76, child: Text(row.category.labelZh, style: _cellStyle())),
                      SizedBox(width: 96, child: Text(formatDurationZh(row.activeSeconds), style: _cellStyle())),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: row.ratioOfAppTime.clamp(0.0, 1.0),
                            minHeight: 10,
                            backgroundColor: const Color(0xFFE8ECF1),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 52,
                        child: Text('${(row.ratioOfAppTime * 100).toStringAsFixed(1)}%',
                            textAlign: TextAlign.right, style: _cellStyle()),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 管理
  // ---------------------------------------------------------------------------

  Widget _managementCard(AppServices s, ActivityTracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title('记录管理'),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: tracker,
              builder: (BuildContext context, Widget? _) {
                final bool paused = tracker.isPaused;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          onPressed: () => s.saveTrackingSettings(
                            tracker.settings.copyWith(paused: !paused),
                          ),
                          icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 16),
                          label: Text(paused ? '恢复记录' : '暂停记录'),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          paused ? '当前已暂停：不计时、不写库、不切换状态' : '当前正在记录',
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        const SizedBox(
                          width: 148,
                          child: Text('空闲阈值', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        ),
                        DropdownButton<int>(
                          value: tracker.settings.idleThresholdMs,
                          items: <DropdownMenuItem<int>>[
                            for (final int ms in ActivityTracking.idleThresholdOptionsMs)
                              DropdownMenuItem<int>(
                                value: ms,
                                child: Text('${ms ~/ 60000} 分钟', style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (int? value) {
                            if (value == null) return;
                            s.saveTrackingSettings(
                              tracker.settings.copyWith(idleThresholdMs: value),
                            );
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          '超过该时长视为「离开」，不计入活跃时间',
                          style: TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const SizedBox(
                          width: 148,
                          child: Text('连续使用提醒', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        ),
                        Switch(
                          value: tracker.settings.continuousReminderEnabled,
                          onChanged: (bool value) => s.saveTrackingSettings(
                            tracker.settings.copyWith(continuousReminderEnabled: value),
                          ),
                        ),
                        const Text(
                          '开启后：连续活跃 90 分钟切换为 tired（仅改变表情，不打断使用）',
                          style: TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const SizedBox(
                          width: 148,
                          child: Text('今日活跃告警阈值', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        ),
                        DropdownButton<int>(
                          value: tracker.settings.usageAlertThresholdMs,
                          items: <DropdownMenuItem<int>>[
                            const DropdownMenuItem<int>(value: 0, child: Text('关闭', style: TextStyle(fontSize: 12))),
                            for (final int hours in <int>[2, 4, 6, 8, 10])
                              DropdownMenuItem<int>(
                                value: hours * 3600 * 1000,
                                child: Text('$hours 小时', style: TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (int? value) {
                            if (value == null) return;
                            s.saveTrackingSettings(
                              tracker.settings.copyWith(usageAlertThresholdMs: value),
                            );
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          '达到后切换为 concerned',
                          style: TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const Divider(height: 24),
            _title('已登记应用（${s.applications.all.length}）'),
            const SizedBox(height: 6),
            const Text(
              '隐私说明：只记录可执行文件名、启动时段与分类，'
              '不保存窗口标题、文档名、网页标题、键盘输入、鼠标内容或截图，也不上传任何数据。',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final app in s.applications.all.take(60))
                  Chip(
                    label: Text(
                      '${app.displayName} · ${app.category.labelZh}'
                      '${app.excluded ? ' · 已排除' : ''}'
                      '${app.userOverridden ? ' · 人工' : ''}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 小工具
  // ---------------------------------------------------------------------------

  /// 询问一段单行文本（例如修改应用显示名称）。
  ///
  /// 控制器由 [TextInputDialog] 自己的 State 持有并销毁 —— 调用方**不能**
  /// 在 `await` 之后自行 dispose（那会在弹窗退场动画期间销毁仍在使用的控制器，
  /// 触发 `'_dependents.isEmpty': is not true.`，见 docs/32）。
  ///
  /// 取消或留空都返回 null，调用方据此不执行修改。
  Future<String?> _promptText({
    required String title,
    required String initial,
    String? hint,
  }) async {
    final String? result = await TextInputDialog.show(
      context,
      title: title,
      initialText: initial,
      hintText: hint,
    );
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  Future<AppCategory?> _promptCategory(AppCategory current) async {
    return showDialog<AppCategory>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('选择分类'),
        children: <Widget>[
          for (final AppCategory c in AppCategory.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Row(
                children: <Widget>[
                  Icon(
                    c == current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text('${c.labelZh}（${c.wireName}）'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  TableRow _headerRow(List<String> labels) => TableRow(
        children: <Widget>[
          for (final String l in labels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                l,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      );

  TextStyle _cellStyle() => const TextStyle(fontSize: 12);

  Widget _cell(String text, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w600 : FontWeight.normal),
        ),
      );

  Widget _title(String t) => Text(
        t,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF2F4A63)),
      );

  Widget _stat(String label, String value, String note) => SizedBox(
        width: 168,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Text(note, style: const TextStyle(fontSize: 10, color: Colors.black54)),
          ],
        ),
      );

  String _fmtClock(DateTime? t) {
    if (t == null) return '—';
    final DateTime local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
