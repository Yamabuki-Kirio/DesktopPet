import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/logger.dart';
import '../../sync/cloud_statistics_controller.dart';
import '../../sync/models/cloud_statistics_models.dart';
import '../../sync/sync_engine.dart';

/// 云端统计子页（Phase 4B）。
///
/// 与「本机统计」并列，嵌在同一个顶级页面里（本机 | 云端）。
///
/// 设计要点（每条都对应需求里的硬要求）：
/// * **不在 build 里发请求**：只有 [active] 首次变为 true 时才 `initialize()` 一次；
/// * **状态完整**：首次加载 / 刷新中（保留旧数据）/ 空数据 / 未登录 / 登录失效 /
///   离线缓存 / 无缓存错误 / 服务端错误；
/// * **列表可滚动且不嵌套**：整页只有一个 `ListView`，应用展开是行内插入，
///   不使用 `Expanded` 或无限高度 `GridView`（避免 RenderFlex overflow）；
/// * **局部加载态**：展开某个应用时只有该行显示加载指示器，失败也只影响那一行；
/// * **缓存优先与离线标记**：由 [CloudStatisticsController] 负责，这里只负责显示。
class CloudStatisticsPage extends StatefulWidget {
  const CloudStatisticsPage({
    super.key,
    required this.controller,
    required this.isSignedIn,
    this.syncEngine,
    this.onOpenAccount,
    this.clock,
    this.active = true,
  });

  final CloudStatisticsController controller;

  /// 是否已登录（未登录时不发任何统计请求）。
  final bool Function() isSignedIn;

  /// 可选：用于"本机上传成功后自动刷新云端统计"。
  final SyncEngine? syncEngine;

  /// 未登录时点「去登录」的回调（切到账户页）。
  final VoidCallback? onOpenAccount;

  /// 便于测试：注入"今天"。
  final DateTime Function()? clock;

  /// 是否是当前可见的子页（首次变为 true 时才初始化，切回不重复请求）。
  final bool active;

  @override
  State<CloudStatisticsPage> createState() => _CloudStatisticsPageState();
}

/// 应用统计 / 时间线两个视图的切换。
enum _CloudView { apps, timeline }

class _CloudStatisticsPageState extends State<CloudStatisticsPage>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();

  _CloudView _view = _CloudView.apps;
  bool _started = false;

  /// 正在执行 `initialize()`（防止 reset 通知引起的递归初始化）。
  bool _initializing = false;

  /// 每个应用的展开状态（刷新后保留）。
  final Set<String> _expandedApps = <String>{};

  /// 上次看到的"本机上传成功时间"，用于判断是否发生了新的上传。
  DateTime? _lastUploadSeen;

  CloudStatisticsController get _c => widget.controller;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  DateTime get _todayLocal {
    final DateTime now = _now;
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onControllerChanged);
    widget.syncEngine?.addListener(_onSyncChanged);
    if (widget.active) {
      // 首帧之后再发起请求，确保不在 build 期间触发网络 I/O。
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted());
    }
  }

  @override
  void didUpdateWidget(CloudStatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      _c.addListener(_onControllerChanged);
    }
    if (oldWidget.syncEngine != widget.syncEngine) {
      oldWidget.syncEngine?.removeListener(_onSyncChanged);
      widget.syncEngine?.addListener(_onSyncChanged);
    }
    if (widget.active && !oldWidget.active) {
      _ensureStarted();
    }
  }

  /// 确保云端统计已被初始化（**可重复触发**，不再是一次性闩锁）。
  ///
  /// 为什么不能"只做一次"（验收第 5 条「退出重登后仍然一致」）：
  /// 页面在 IndexedStack 里长期存活，退出登录 → 重新登录后如果不再初始化，
  /// 页面会一直停在 `idle`，直接显示"这一天还没有云端使用记录"，
  /// 让人误以为"这台设备没有数据"，而其实是一次请求都没发。
  ///
  /// [_initializing] 是必须的：`initialize()` 内部可能 `reset()`（账户变化），
  /// 而 reset 会通知监听者，没有这个闸门就会**递归**调用自己。
  void _ensureStarted() {
    if (!widget.active || _initializing) return;
    if (!widget.isSignedIn()) {
      // 退出登录：解除闩锁，下次登录后会重新初始化。
      _started = false;
      return;
    }
    // 已经有数据/正在加载就不重复初始化；只有 idle（未开始）才启动。
    if (_started && _c.status != CloudStatsStatus.idle) return;
    _started = true;
    _initializing = true;
    unawaited(() async {
      try {
        await _c.initialize();
      } catch (e, st) {
        Loggers.sync.warning('初始化云端统计失败', e, st);
      } finally {
        _initializing = false;
      }
    }());
  }

  @override
  void dispose() {
    widget.syncEngine?.removeListener(_onSyncChanged);
    _c.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onSyncChanged() {
    // 本机上传成功后刷新云端统计（需求：刷新时机包含"本机同步成功"）。
    final DateTime? lastSuccess = widget.syncEngine?.lastSuccessAt;
    if (lastSuccess == null || lastSuccess == _lastUploadSeen) return;
    final bool hadSeen = _lastUploadSeen != null;
    _lastUploadSeen = lastSuccess;
    if (!hadSeen || !widget.active) return;
    _c.onLocalSyncSucceeded().catchError((Object e, StackTrace st) {
      Loggers.sync.warning('上传成功后刷新云端统计失败', e, st);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台且距上次刷新超过阈值时刷新（阈值逻辑在控制器里）。
    if (state == AppLifecycleState.resumed && widget.active) {
      _c.onAppResumed().catchError((Object e, StackTrace st) {
        Loggers.sync.warning('回到前台刷新云端统计失败', e, st);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 每次重建都检查一次是否需要（重新）初始化：
    // 退出重登 / 换号 / 切回云端页都可能让控制器回到 idle，而父级重建
    // 不一定改变 [active]。_ensureStarted 自身是幂等且有闸门的，开销可忽略。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted());
    if (!widget.isSignedIn()) {
      return _signedOutView();
    }
    return Column(
      children: <Widget>[
        _filterBar(),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 未登录
  // ---------------------------------------------------------------------------

  Widget _signedOutView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined, size: 40),
            const SizedBox(height: 12),
            const Text('登录后即可查看其他设备的云端使用统计',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (widget.onOpenAccount != null)
              FilledButton.tonal(
                onPressed: widget.onOpenAccount,
                child: const Text('去登录'),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 筛选栏
  // ---------------------------------------------------------------------------

  Widget _filterBar() {
    final DateTime date = _c.date ?? _todayLocal;
    final bool canGoNext = date.isBefore(_todayLocal);
    final bool isToday = !date.isBefore(_todayLocal);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                tooltip: '前一天',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _changeDate(_c.shiftDay(-1)),
              ),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_formatDate(date), overflow: TextOverflow.ellipsis),
                ),
              ),
              IconButton(
                tooltip: '后一天',
                icon: const Icon(Icons.chevron_right),
                // 未来日期不产生请求：已到今天时禁用
                onPressed: canGoNext ? () => _changeDate(_c.shiftDay(1)) : null,
              ),
              TextButton(
                onPressed: isToday ? null : () => _changeDate(_c.goToToday()),
                child: const Text('今天'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text('设备：'),
              ),
              Expanded(child: _deviceSelector()),
              IconButton(
                tooltip: '刷新云端统计',
                icon: _c.status == CloudStatsStatus.refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: _c.status == CloudStatsStatus.refreshing
                    ? null
                    : () => _refresh(manual: true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _deviceSelector() {
    final List<CloudDevice> devices = _c.devices;
    final String? value = _c.deviceId;
    // 防止 value 不在 items 里（设备被撤销后仍在选中）导致 Dropdown 断言失败
    final bool known = value == null || devices.any((CloudDevice d) => d.id == value);

    return DropdownButton<String?>(
      isExpanded: true,
      value: known ? value : null,
      hint: const Text('全部设备'),
      items: <DropdownMenuItem<String?>>[
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('全部设备', overflow: TextOverflow.ellipsis),
        ),
        for (final CloudDevice device in devices)
          DropdownMenuItem<String?>(
            value: device.id,
            child: Text(
              _deviceOptionLabel(device),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (String? next) {
        if (next == value) return;
        _c.setDevice(next).catchError((Object e, StackTrace st) {
          Loggers.sync.warning('切换设备失败', e, st);
        });
      },
    );
  }

  /// 设备下拉里的标签。
  ///
  /// 为什么不能只显示"名称 · 平台"：同一台手机在重装/清除数据后会以新的
  /// `device_local_id` **再注册一台设备**，列表里就会同时出现两条同名同平台的记录，
  /// 而只有真正在用的那条有数据。这里补上「本机 / 已撤销 / 最近活动 / 型号」，
  /// 让人能一眼区分（真机已出现该情况）。
  String _deviceOptionLabel(CloudDevice device) {
    final List<String> parts = <String>[device.displayLabel];
    final String? model = device.modelName;
    if (model != null && model.isNotEmpty && !device.name.contains(model)) {
      parts.add(model);
    }
    if (device.isCurrent) parts.add('本机');
    if (device.revoked) parts.add('已撤销');
    final DateTime? seen = device.lastSeenAt;
    if (seen != null) parts.add('最近 ${_fmtShortDate(seen)}');
    return parts.join(' · ');
  }

  String _fmtShortDate(DateTime utc) {
    final DateTime local = utc.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate() async {
    final DateTime today = _todayLocal;
    final DateTime initial = _c.date ?? today;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(today) ? today : initial,
      firstDate: DateTime(2020, 1, 1),
      // 未来日期不产生请求，因此也不允许选择
      lastDate: today,
    );
    if (picked == null) return;
    await _changeDate(_c.setDate(picked));
  }

  Future<void> _changeDate(Future<void> task) async {
    try {
      await task;
    } catch (e, st) {
      Loggers.sync.warning('切换日期失败', e, st);
    }
  }

  Future<void> _refresh({bool manual = false}) async {
    try {
      await _c.refresh(manual: manual);
    } catch (e, st) {
      Loggers.sync.warning('刷新云端统计失败', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // 主体
  // ---------------------------------------------------------------------------

  Widget _body() {
    if (_c.status == CloudStatsStatus.loading && !_c.hasData) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在加载云端统计…'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _refresh(manual: true),
      child: ListView(
        controller: _scrollController,
        // 空/错误状态也能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: <Widget>[
          if (_c.isOfflineData) _offlineBanner(),
          // 有错误时错误卡自带「重试」，不再叠加另一个重试卡片
          if (_c.errorMessage != null) _errorCard(),
          if (_c.hasData) ...<Widget>[
            _summaryCard(),
            const SizedBox(height: 12),
            _viewSelector(),
            const SizedBox(height: 8),
            if (_view == _CloudView.apps) ..._appSection() else ..._timelineSection(),
          ] else if (_c.status == CloudStatsStatus.idle)
            _waitingCard()
          else if (_c.errorMessage == null)
            _emptyCard(),
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    final DateTime? at = _c.fetchedAt;
    return Card(
      color: const Color(0xFFFFF4E5),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('当前显示离线缓存',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              at == null
                  ? '尚未成功刷新过'
                  : '上次刷新：${_formatDateTime(at)}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() {
    final bool needsSignIn = _c.errorMessage?.contains('登录') ?? false;
    return Card(
      color: const Color(0xFFFFEBEE),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.error_outline, size: 18, color: Color(0xFFB71C1C)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _c.errorMessage!,
                style: const TextStyle(color: Color(0xFFB71C1C)),
              ),
            ),
            if (needsSignIn && widget.onOpenAccount != null)
              TextButton(
                onPressed: widget.onOpenAccount,
                child: const Text('去登录'),
              )
            else
              TextButton(
                onPressed: () => _refresh(manual: true),
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }

  /// 「还没开始加载」——**不能**复用空态文案，否则会被读成"这台设备没有数据"。
  Widget _waitingCard() {
    return const Card(
      margin: EdgeInsets.only(top: 24),
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Icon(Icons.cloud_queue_outlined, size: 32),
            SizedBox(height: 12),
            Text('正在准备云端统计…', textAlign: TextAlign.center),
            SizedBox(height: 6),
            Text(
              '如果是刚刚重新登录，稍候片刻或点右上角刷新',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() {
    // 把**当前选中的设备名**写进提示里：否则用户看到"没有记录"时
    // 无法判断是"这台设备确实没数据"还是"选错了设备"（真机排查过这个坑）。
    final CloudDevice? device = _c.selectedDevice;
    final String who = device == null
        ? '全部设备'
        : '${device.displayLabel}${device.revoked ? '（已撤销）' : ''}';
    return Card(
      margin: const EdgeInsets.only(top: 24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            const Icon(Icons.inbox_outlined, size: 32),
            const SizedBox(height: 12),
            Text('$who 在这一天还没有云端使用记录',
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            const Text(
              '请确认选中的是真正在用的那台设备；也可以换「全部设备」看看其他设备的数据',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard() {
    final CloudUsageSummary? summary = _c.summary;
    final String deviceLabel = _c.selectedDevice?.displayLabel ?? '全部设备';
    final DateTime? synced = summary?.lastSyncedAt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '今日累计 ${formatDurationZh(summary?.totalDuration ?? Duration.zero)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(deviceLabel, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '${summary?.appCount ?? 0} 个应用 · ${summary?.sessionCount ?? 0} 段记录',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              synced == null
                  ? '最近同步：暂无'
                  : '最近同步 ${formatLocalHm(synced, _c.timezoneOffsetMinutes)}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              _c.lastRefreshedAt == null
                  ? '最近刷新：暂无'
                  : '最近刷新 ${_formatDateTime(_c.lastRefreshedAt!)}',
              style: const TextStyle(fontSize: 12),
            ),
            if (summary?.overlapWarning != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                summary!.overlapWarning!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A6D3B)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _viewSelector() {
    return SegmentedButton<_CloudView>(
      segments: const <ButtonSegment<_CloudView>>[
        ButtonSegment<_CloudView>(
          value: _CloudView.apps,
          label: Text('应用统计'),
          icon: Icon(Icons.bar_chart, size: 18),
        ),
        ButtonSegment<_CloudView>(
          value: _CloudView.timeline,
          label: Text('时间线'),
          icon: Icon(Icons.timeline, size: 18),
        ),
      ],
      selected: <_CloudView>{_view},
      onSelectionChanged: (Set<_CloudView> selection) {
        setState(() => _view = selection.first);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 应用统计
  // ---------------------------------------------------------------------------

  List<Widget> _appSection() {
    // 防御性排序：无论数据来自服务端还是缓存，界面一律按时长降序。
    final List<CloudAppUsage> apps = <CloudAppUsage>[
      ...?_c.summary?.apps,
    ]..sort((CloudAppUsage a, CloudAppUsage b) => b.duration.compareTo(a.duration));
    if (apps.isEmpty) {
      return <Widget>[_emptyCard()];
    }
    return <Widget>[
      for (final CloudAppUsage app in apps) _appTile(app),
    ];
  }

  Widget _appTile(CloudAppUsage app) {
    final bool expanded = _expandedApps.contains(app.appId);
    final bool loading = _c.isLoadingSessions(app.appId);
    final List<CloudUsageSession> sessions = _c.sessionsOf(app.appId);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => _toggleApp(app.appId, expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      app.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(formatDurationZh(app.duration)),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
          if (expanded) ..._sessionSection(app, loading: loading, sessions: sessions),
        ],
      ),
    );
  }

  List<Widget> _sessionSection(
    CloudAppUsage app, {
    required bool loading,
    required List<CloudUsageSession> sessions,
  }) {
    if (loading && sessions.isEmpty) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: <Widget>[
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('正在加载时间段…', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ];
    }
    if (sessions.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(
            _c.errorMessage ?? '没有可显示的时间段',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ];
    }
    return <Widget>[
      for (final CloudUsageSession session in sessions) _sessionRow(session),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: <Widget>[
            if (_c.hasMoreSessions(app.appId))
              TextButton(
                onPressed: () => _c.loadMoreSessions(app.appId),
                child: const Text('加载更多'),
              ),
            if (loading)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _sessionRow(CloudUsageSession session) {
    final String range = session.endedAt == null
        ? '${formatLocalHm(session.startedAt, _c.timezoneOffsetMinutes)} 起'
        : '${formatLocalHm(session.startedAt, _c.timezoneOffsetMinutes)}–'
            '${formatLocalHm(session.endedAt!, _c.timezoneOffsetMinutes)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  range,
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  session.deviceDisplay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            session.endedAt == null ? '进行中' : formatDurationZh(session.duration),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleApp(String appId, bool expanded) async {
    setState(() {
      if (expanded) {
        _expandedApps.remove(appId);
      } else {
        _expandedApps.add(appId);
      }
    });
    if (expanded) return;
    try {
      await _c.expandApp(appId);
    } catch (e, st) {
      // 单个应用失败只影响这一行，整页照常显示。
      Loggers.sync.warning('加载云端使用时间段失败: $appId', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // 时间线
  // ---------------------------------------------------------------------------

  List<Widget> _timelineSection() {
    final List<CloudTimelineEntry> entries = _c.timeline;
    if (entries.isEmpty) {
      return <Widget>[_emptyCard()];
    }
    return <Widget>[
      for (final CloudTimelineEntry entry in entries) _timelineTile(entry),
    ];
  }

  Widget _timelineTile(CloudTimelineEntry entry) {
    final String range = entry.endedAt == null
        ? '${formatLocalHm(entry.startedAt, _c.timezoneOffsetMinutes)} 起'
        : '${formatLocalHm(entry.startedAt, _c.timezoneOffsetMinutes)}–'
            '${formatLocalHm(entry.endedAt!, _c.timezoneOffsetMinutes)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(range, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${entry.deviceDisplay} · ${entry.mergedSessionCount} 段',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatDurationZh(entry.duration), style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 格式化
  // ---------------------------------------------------------------------------

  String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _formatDateTime(DateTime at) =>
      '${_formatDate(at)} ${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}
