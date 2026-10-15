import 'dart:async';

import 'package:flutter/material.dart';

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/android_usage_import_service.dart';
import '../../activity_tracking/android_usage_session.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../../activity_tracking/models/activity_enums.dart';
import '../../activity_tracking/models/usage_stats.dart';
import '../../activity_tracking/usage_analytics_service.dart';
import '../../app/app_scope.dart';
import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../platform/overlay_pet.dart';
import '../../settings/app_settings.dart';
import '../../state_engine/system_state.dart';
import '../dialogs/text_input_dialog.dart';
import '../overlay_pet_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_decor.dart';
import '../widgets/petlife/petlife_page.dart';
import 'cloud_statistics_page.dart';

/// 使用统计页面（需求「使用统计」）。
///
/// 口径说明集中在 [UsageAnalyticsService] 与 `docs/12-使用统计口径.md`：
/// **屏幕会话时间 / 活跃使用时间 / 空闲时间 / 应用使用时间**是四个不同指标，
/// 本页面把它们分开显示，绝不笼统地叫「屏幕时间」。
///
/// **本轮只改视觉**：统计口径、去重规则、查询窗口与筛选逻辑一行未动。
/// 页面结构调整为三个清晰区域：今日概览卡 → 应用排行 → 时间线。
class UsageStatsPage extends StatefulWidget {
  const UsageStatsPage({
    super.key,
    required this.services,
    this.onOpenAccount,
    this.overlay,
    this.showActivityQualifier = false,
  });

  final AppServices services;

  /// 云端页未登录时「去登录」的入口（切到「账户与同步」页）。
  final VoidCallback? onOpenAccount;

  /// Android 悬浮桌宠协调器。
  ///
  /// 「当前桌宠状态」必须读**原生**真值：Android 的状态切换发生在悬浮服务里，
  /// Flutter 状态引擎在 Android 上不会收到前台事件（其采集器是"不可用"实现），
  /// 因此读状态引擎会让这一行**永远停在 default**。
  final OverlayPetController? overlay;

  /// 采集能力未启用时，在标题上标注「本机」，避免与服务器汇总混淆。
  final bool showActivityQualifier;

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

  /// 与 [_summary] **同一个窗口**的时间段列表。
  List<UsageSegmentRow> _timeline = const <UsageSegmentRow>[];

  /// 当前子页：false = 本机统计（原有），true = 云端统计。
  bool _showCloud = false;
  bool _tabRestored = false;

  /// 「当前前台应用」来自**跨平台**提供者。
  CurrentActivity? _activity;
  StreamSubscription<CurrentActivity>? _activitySub;

  /// Android 原生采集器状态（非 Android 时为 null）。
  UsageCollectorState? _collector;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _restoreTab();
    _subscribeCurrentActivity();
  }

  /// 从后台回到前台：先把原生暂存会话导入，再刷新。
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
  /// 刻意复用 [_selectTab]：切换动作、持久化与顶部胶囊选择器完全同源，
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
      // 再把原生暂存的使用会话幂等导入本机库（Android）。
      // 顺序很重要：不先导入，统计页会"看不到刚用完的应用"。
      await widget.services.importAndroidUsageSessions();
      // 累计统计与时间段列表用**同一个窗口**。
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

    return PetLifePage(
      title: widget.showActivityQualifier ? '使用统计（本机）' : '使用统计',
      subtitle: '本机采集 + 云端汇总；统计口径与去重规则与改造前一致',
      actions: <Widget>[
        PetLifeHeaderAction(
          icon: Icons.refresh,
          tooltip: '刷新统计',
          onPressed: _loading || _showCloud ? null : _reload,
        ),
      ],
      headerTrailing: PetLifePillSelector<bool>(
        options: const <bool>[false, true],
        selected: _showCloud,
        onSelected: _selectTab,
        labelOf: (bool cloud) => cloud ? '云端' : '本机',
      ),
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
    );
  }

  /// 本机统计视图（业务逻辑未改动，仅重排视觉）。
  Widget _localStatsView(AppServices s, ActivityTracker tracker) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _rangeToolbar(),
        const SizedBox(height: PetLifeSpacing.topContent),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              _liveCard(s, tracker),
              const SizedBox(height: PetLifeSpacing.cardGap),
              if (_loading)
                const PetLifeLoading(label: '正在统计…')
              else if (_error != null)
                PetLifeErrorState(
                  title: '读取使用统计时出错',
                  detail: _error!,
                  hint: '桌宠动画不受影响；可稍后重试或查看设置页的「诊断」。',
                  onRetry: _reload,
                )
              else ...<Widget>[
                PetLifeCardEntrance(child: _overviewCard()),
                const SizedBox(height: PetLifeSpacing.cardGap),
                // 宽屏（桌面）把「应用排行」与「时间线」并排成双栏；
                // 窄屏仍然上下堆叠。**内容宽度上限由外层
                // PetLifeDesktopContentWidth 负责**，这里只负责分栏。
                _rankingAndTimeline(),
                const SizedBox(height: PetLifeSpacing.cardGap),
                _categoryCard(),
              ],
              const SizedBox(height: PetLifeSpacing.groupGap),
              _managementCard(s, tracker),
              const SizedBox(height: PetLifeSpacing.cardGap),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 筛选区
  // ---------------------------------------------------------------------------

  Widget _rangeToolbar() {
    return PetLifeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '统计范围',
            style: TextStyle(
              fontSize: PetLifeText.caption,
              fontWeight: FontWeight.w600,
              color: PetLifeTheme.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          PetLifePillSelector<UsageRange>(
            options: UsageRange.values,
            selected: _range,
            labelOf: (UsageRange r) => r.label,
            onSelected: (UsageRange next) {
              setState(() => _range = next);
              _reload();
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 应用排行 + 时间线（宽屏双栏 / 窄屏单栏）
  // ---------------------------------------------------------------------------

  /// 桌面宽屏下把「应用排行」与「时间线」并排；窄屏上下堆叠。
  ///
  /// 断点取在 1180：低于该宽度时两栏各自不足 ~560px，表格与进度条会挤在一起，
  /// 反而不如单栏可读。
  Widget _rankingAndTimeline() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double scale = MediaQuery.textScalerOf(context).scale(1.0);
        final bool twoColumns = constraints.maxWidth >= 1180 * scale;
        if (!twoColumns) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              PetLifeCardEntrance(child: _appRankingCard()),
              const SizedBox(height: PetLifeSpacing.cardGap),
              PetLifeCardEntrance(
                delay: const Duration(milliseconds: 40),
                child: _timelineCard(),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: PetLifeCardEntrance(child: _appRankingCard())),
            const SizedBox(width: PetLifeSpacing.cardGap),
            Expanded(
              child: PetLifeCardEntrance(
                delay: const Duration(milliseconds: 40),
                child: _timelineCard(),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 今日概览卡
  // ---------------------------------------------------------------------------

  Widget _overviewCard() {
    final UsageSummary summary = _summary!;
    final UsageOverview o = summary.overview;
    // Android 的原生采集只产出应用会话，没有设备级「屏幕会话 / 空闲」来源：
    // 这一项为 false 时**如实用应用时长表达总时长**，而不是摆三个 0 让人误判。
    final bool deviceMetrics = o.deviceMetricsAvailable;
    final PetLifePalette p = PetLifeTheme.of(context);

    return PetLifeCard(
      large: true,
      corner: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const PetLifeSectionTitle(
            title: '今日概览',
            marker: false,
          ),
          PetLifeStat(
            value: formatDurationZh(o.appActiveSeconds),
            label: '${_range.label}累计应用使用时长',
            note: summary.window.label,
            large: true,
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double scale = MediaQuery.textScalerOf(context).scale(1.0);
              final int columns = constraints.maxWidth < 340 * scale ? 2 : 3;
              const double gap = 12;
              final double itemWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              final List<Widget> stats = <Widget>[
                if (deviceMetrics) ...<Widget>[
                  PetLifeStat(
                    value: formatDurationZh(o.activeSeconds),
                    label: '活跃使用时间',
                    note: '屏幕会话中未超过空闲阈值的时间',
                  ),
                  PetLifeStat(
                    value: formatDurationZh(o.sessionSeconds),
                    label: '屏幕会话时间',
                    note: '设备解锁且未休眠的时间',
                  ),
                  PetLifeStat(
                    value: formatDurationZh(o.idleSeconds),
                    label: '空闲时间',
                    note: '解锁但用户超过空闲阈值的时间',
                  ),
                  PetLifeStat(
                    value: formatDurationZh(o.appActiveSeconds),
                    label: '应用使用时间',
                    note: '归属到有效前台应用的部分',
                  ),
                ] else
                  PetLifeStat(
                    value: '${summary.apps.length}',
                    label: '应用数量',
                    note: '本设备只采集应用使用时长',
                  ),
                PetLifeStat(
                  value: '${summary.apps.fold<int>(0, (int a, AppUsageRow r) => a + r.segmentCount)}',
                  label: '使用记录数量',
                  note: '有起止时间的应用会话条数',
                ),
                PetLifeStat(
                  value: formatDurationZh(o.longestContinuousSeconds),
                  label: '最长连续使用',
                  note: '同一段连续活跃的峰值',
                ),
                PetLifeStat(
                  value: _fmtClock(o.firstActiveAt),
                  label: '首次活跃',
                ),
                PetLifeStat(
                  value: _fmtClock(o.lastActiveAt),
                  label: '最后活跃',
                ),
              ];
              return Wrap(
                spacing: gap,
                runSpacing: 14,
                children: <Widget>[
                  for (final Widget stat in stats)
                    SizedBox(width: itemWidth, child: stat),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            deviceMetrics
                ? '四个时间口径互不相同：活跃 ≠ 屏幕会话（可能锁屏/休眠），'
                    '应用使用 ≤ 活跃使用（可能存在无有效前台应用的时间）。'
                : '本设备（Android）只统计「应用使用时长」：'
                    '没有可靠来源区分屏幕会话与空闲时间，因此不作展示，也不填 0 充数。',
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              color: p.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 实时状态
  // ---------------------------------------------------------------------------

  Widget _liveCard(AppServices s, ActivityTracker tracker) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return PetLifeCard(
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
          final String? trace = _nativeStateTrace();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '当前应用',
                          style: TextStyle(
                            fontSize: PetLifeText.caption,
                            color: p.textSecondary,
                          ),
                        ),
                        Text(
                          '${activity?.displayLabelZh ?? '读取中…'}'
                          '${category == null ? '' : '（${category.labelZh}）'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: PetLifeText.cardTitle,
                            fontWeight: FontWeight.w700,
                            color: p.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusChip(status, tracker.isPaused),
                ],
              ),
              if (activity != null && activity.packageName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '检测来源：${activity.sourceLabelZh}'
                    '${activity.detectionReason == null ? '' : '（${activity.detectionReason}）'}',
                    style: TextStyle(
                      fontSize: PetLifeText.captionSmall,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              PetLifeKeyValue(
                label: '桌宠状态',
                value: _petStateLabel(s),
              ),
              PetLifeKeyValue(
                label: '本段已持续',
                value: formatDurationZh(_sessionSeconds(tracker)),
              ),
              PetLifeKeyValue(
                label: '连续活跃',
                value: formatDurationZh(tracker.continuousActiveSeconds),
              ),
              if (trace != null)
                PetLifeKeyValue(label: '状态链路', value: trace),
              if (_collector != null)
                PetLifeKeyValue(
                  label: '使用记录采集',
                  value: '${_collector!.labelZh}'
                      '${_collector!.pendingCount > 0 ? ' · 待导入 ${_collector!.pendingCount} 条' : ''}'
                      '${_lastImportLabel()}',
                ),
              if (activity?.hintZh != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.warning_amber, size: 14, color: p.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          activity!.hintZh!,
                          style: TextStyle(
                            fontSize: PetLifeText.caption,
                            color: p.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 「当前桌宠状态」：Android 读**原生**诊断，其它平台读状态引擎。
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
    return '分类 $category → 目标 $target · 规则 $rule · 提交 $result'
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
    final PetLifePalette p = PetLifeTheme.of(context);
    final Color color = switch (status) {
      TrackingStatus.running => p.success,
      TrackingStatus.paused => p.warning,
      TrackingStatus.locked => p.onAccentSoft,
      TrackingStatus.idle => p.textSecondary,
      TrackingStatus.unavailable => p.textDisabled,
    };
    return PetLifeTag(
      label: status.labelZh,
      color: color,
      icon: Icons.circle,
      dense: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 应用排行（卡片式 + 横向进度条 + 点击展开现有明细）
  // ---------------------------------------------------------------------------

  Widget _appRankingCard() {
    final List<AppUsageRow> apps = _summary!.apps;
    return PetLifeCard(
      large: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PetLifeSectionTitle(
            title: '应用排行（${_range.label}）',
            subtitle: '按使用时长排序，点条目展开明细',
            marker: false,
            trailing: Text(
              '${apps.length} 个',
              style: TextStyle(
                fontSize: PetLifeText.caption,
                color: PetLifeTheme.of(context).textSecondary,
              ),
            ),
          ),
          if (apps.isEmpty)
            const PetLifeEmptyState(
              icon: Icons.hourglass_empty,
              title: '这一天还没有使用记录',
              message: '开启桌宠后，切换应用即会开始记录；\n'
                  '若刚刚用完应用，点右上角刷新即可看到。',
              compact: true,
              scrollable: false,
            )
          else
            for (final AppUsageRow row in apps.take(50))
              _AppRankingTile(
                row: row,
                excluded:
                    widget.services.applications.find(row.appKey)?.excluded ?? false,
                onAction: (String action) => _onAppAction(action, row),
              ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 时间线
  // ---------------------------------------------------------------------------

  Widget _timelineCard() {
    final List<UsageSegmentRow> rows = _timeline;
    final PetLifePalette p = PetLifeTheme.of(context);
    return PetLifeCard(
      large: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PetLifeSectionTitle(
            title: '时间线（${_range.label}）',
            subtitle: '按设备本地时区显示，跨小时 / 跨午夜保留真实起止时刻',
            marker: false,
            trailing: Text(
              '${rows.length} 条',
              style: TextStyle(
                fontSize: PetLifeText.caption,
                color: p.textSecondary,
              ),
            ),
          ),
          if (rows.isEmpty)
            const PetLifeEmptyState(
              icon: Icons.timeline,
              title: '这一天还没有使用记录',
              message: '开启桌宠后，切换应用即会开始记录。\n'
                  '进行中的会话只标「使用中」，不会提前写成已结束记录。',
              compact: true,
              scrollable: false,
            )
          else
            for (final UsageSegmentRow row in rows.take(100))
              _TimelineTile(row: row),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 分类统计
  // ---------------------------------------------------------------------------

  Widget _categoryCard() {
    final List<CategoryUsageRow> rows = _summary!.categories;
    final PetLifePalette p = PetLifeTheme.of(context);
    return PetLifeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PetLifeSectionTitle(
            title: '分类统计（${_range.label}）',
            marker: false,
          ),
          if (rows.isEmpty)
            Text(
              '该时间段内没有分类数据。',
              style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
            )
          else
            for (final CategoryUsageRow row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            row.category.labelZh,
                            style: TextStyle(
                              fontSize: PetLifeText.bodySmall,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          formatDurationZh(row.activeSeconds),
                          style: TextStyle(
                            fontSize: PetLifeText.caption,
                            color: p.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(row.ratioOfAppTime * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontSize: PetLifeText.caption,
                            fontWeight: FontWeight.w600,
                            color: p.onAccentSoft,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    PetLifeProgressBar(value: row.ratioOfAppTime),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 记录管理
  // ---------------------------------------------------------------------------

  Widget _managementCard(AppServices s, ActivityTracker tracker) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '记录管理',
          subtitle: '暂停 / 恢复、空闲阈值与已登记应用',
        ),
        PetLifeCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListenableBuilder(
                listenable: tracker,
                builder: (BuildContext context, Widget? _) {
                  final bool paused = tracker.isPaused;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          PetLifeSecondaryButton(
                            label: paused ? '恢复记录' : '暂停记录',
                            icon: paused ? Icons.play_arrow : Icons.pause,
                            onPressed: () => s.saveTrackingSettings(
                              tracker.settings.copyWith(paused: !paused),
                            ),
                          ),
                          Text(
                            paused
                                ? '当前已暂停：不计时、不写库、不切换状态'
                                : '当前正在记录',
                            style: TextStyle(
                              fontSize: PetLifeText.caption,
                              color: p.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _settingRow(
                        label: '空闲阈值',
                        note: '超过该时长视为「离开」，不计入活跃时间',
                        control: DropdownButton<int>(
                          value: tracker.settings.idleThresholdMs,
                          items: <DropdownMenuItem<int>>[
                            for (final int ms in ActivityTracking.idleThresholdOptionsMs)
                              DropdownMenuItem<int>(
                                value: ms,
                                child: Text('${ms ~/ 60000} 分钟'),
                              ),
                          ],
                          onChanged: (int? value) {
                            if (value == null) return;
                            s.saveTrackingSettings(
                              tracker.settings.copyWith(idleThresholdMs: value),
                            );
                          },
                        ),
                      ),
                      _settingRow(
                        label: '连续使用提醒',
                        note: '开启后：连续活跃 90 分钟切换为 tired（仅改变表情，不打断使用）',
                        control: Switch(
                          value: tracker.settings.continuousReminderEnabled,
                          onChanged: (bool value) => s.saveTrackingSettings(
                            tracker.settings
                                .copyWith(continuousReminderEnabled: value),
                          ),
                        ),
                      ),
                      _settingRow(
                        label: '今日活跃告警阈值',
                        note: '达到后切换为 concerned',
                        control: DropdownButton<int>(
                          value: tracker.settings.usageAlertThresholdMs,
                          items: <DropdownMenuItem<int>>[
                            const DropdownMenuItem<int>(
                              value: 0,
                              child: Text('关闭'),
                            ),
                            for (final int hours in <int>[2, 4, 6, 8, 10])
                              DropdownMenuItem<int>(
                                value: hours * 3600 * 1000,
                                child: Text('$hours 小时'),
                              ),
                          ],
                          onChanged: (int? value) {
                            if (value == null) return;
                            s.saveTrackingSettings(
                              tracker.settings
                                  .copyWith(usageAlertThresholdMs: value),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                '已登记应用（${s.applications.all.length}）',
                style: TextStyle(
                  fontSize: PetLifeText.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '隐私说明：只记录可执行文件名、启动时段与分类，'
                '不保存窗口标题、文档名、网页标题、键盘输入、鼠标内容或截图，也不上传任何数据。',
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  color: p.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final app in s.applications.all.take(60))
                    PetLifeTag(
                      label: '${app.displayName} · ${app.category.labelZh}'
                          '${app.excluded ? ' · 已排除' : ''}'
                          '${app.userOverridden ? ' · 人工' : ''}',
                      dense: true,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 一行设置：窄屏 / 大字体下自动改成上下两段，避免截断。
  Widget _settingRow({
    required String label,
    required String note,
    required Widget control,
  }) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = MediaQuery.textScalerOf(context).scale(1.0);
          final Widget text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: PetLifeText.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              Text(
                note,
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  color: p.textSecondary,
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 320 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                text,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: control),
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: text),
              const SizedBox(width: 12),
              control,
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 现有应用操作（完全保留）
  // ---------------------------------------------------------------------------

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

  /// 询问一段单行文本（例如修改应用显示名称）。
  ///
  /// 控制器由 [TextInputDialog] 自己的 State 持有并销毁 —— 调用方**不能**
  /// 在 `await` 之后自行 dispose（那会在弹窗退场动画期间销毁仍在使用的控制器，
  /// 触发 `'_dependents.isEmpty': is not true.`，见 docs/32）。
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
                    c == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
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

  String _fmtClock(DateTime? t) {
    if (t == null) return '—';
    final DateTime local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

/// 应用排行的一行：名称 + 时长 + 横向进度条；点击展开现有明细。
class _AppRankingTile extends StatefulWidget {
  const _AppRankingTile({
    required this.row,
    required this.excluded,
    required this.onAction,
  });

  final AppUsageRow row;
  final bool excluded;
  final ValueChanged<String> onAction;

  @override
  State<_AppRankingTile> createState() => _AppRankingTileState();
}

class _AppRankingTileState extends State<_AppRankingTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final AppUsageRow row = widget.row;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: PetLifeRadii.buttonBorder,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: p.accentSoft,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(Icons.apps, size: 16, color: p.onAccentSoft),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              row.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: PetLifeText.bodySmall,
                                fontWeight: FontWeight.w600,
                                color: p.textPrimary,
                              ),
                            ),
                            Text(
                              '${row.category.labelZh}'
                              '${widget.excluded ? ' · 已排除' : ''}',
                              style: TextStyle(
                                fontSize: PetLifeText.captionSmall,
                                color: p.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatDurationZh(row.activeSeconds),
                        style: TextStyle(
                          fontSize: PetLifeText.bodySmall,
                          fontWeight: FontWeight.w700,
                          color: p.onAccentSoft,
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: p.textSecondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  PetLifeProgressBar(value: row.ratioOfAppTime, height: 7),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: PetLifeDurations.press,
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  PetLifeKeyValue(label: '应用标识', value: row.appKey, selectable: true),
                  PetLifeKeyValue(label: '使用段次数', value: '${row.segmentCount}'),
                  PetLifeKeyValue(
                    label: '占应用时长',
                    value: '${(row.ratioOfAppTime * 100).toStringAsFixed(1)}%',
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      PetLifeTag(
                        label: '修改显示名称',
                        icon: Icons.edit_outlined,
                        onTap: () => widget.onAction('rename'),
                      ),
                      PetLifeTag(
                        label: '修改分类',
                        icon: Icons.category_outlined,
                        onTap: () => widget.onAction('category'),
                      ),
                      PetLifeTag(
                        label: widget.excluded ? '恢复记录' : '排除记录',
                        icon: widget.excluded
                            ? Icons.visibility
                            : Icons.visibility_off_outlined,
                        color: p.danger,
                        onTap: () => widget.onAction('exclude'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间线上的一个节点。
class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.row});

  final UsageSegmentRow row;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 时间节点：一列竖线 + 圆点，替代原来的灰色表格线。
          Column(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: row.running ? p.accent : p.accentSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.accent),
                ),
              ),
              Container(width: 1.5, height: 34, color: p.divider),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        row.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: PetLifeText.bodySmall,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      formatDurationZh(row.activeSeconds),
                      style: TextStyle(
                        fontSize: PetLifeText.caption,
                        fontWeight: FontWeight.w700,
                        color: p.onAccentSoft,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      '${_clock(row.startedAtUtc)} – '
                      '${row.running ? '使用中' : _clock(row.endedAtUtc)}',
                      style: TextStyle(
                        fontSize: PetLifeText.captionSmall,
                        color: p.textSecondary,
                      ),
                    ),
                    PetLifeTag(
                      label: row.category.labelZh,
                      dense: true,
                    ),
                    if (row.endReasonLabelZh.isNotEmpty)
                      PetLifeTag(
                        label: row.endReasonLabelZh,
                        dense: true,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(DateTime? t) {
    if (t == null) return '—';
    final DateTime local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
