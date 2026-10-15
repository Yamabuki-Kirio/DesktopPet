import 'package:flutter/material.dart';

import '../../activity_tracking/activity_tracker.dart';
import '../../activity_tracking/models/usage_stats.dart';
import '../../app/app_scope.dart';
import '../../character/character_repository.dart';
import '../../character/models/character_model.dart';
import '../../character/models/character_pack.dart';
import '../../core/logger.dart';
import '../../platform/overlay_pet.dart';
import '../../state_engine/state_debouncer.dart';
import '../../state_engine/state_snapshot.dart';
import '../../state_engine/system_state.dart';
import '../../sync/sync_engine.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../pet/pet_view.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_decor.dart';
import '../widgets/petlife/petlife_page.dart';
import 'mobile_platform_notice.dart';
import 'pet_status_view.dart';

/// 桌宠首页（状态仪表盘）。
///
/// 需求 §2.2：把原本零散的状态与按钮整理成
/// 「当前桌宠状态卡 → 四个快捷操作 → 今日陪伴摘要」三段。
///
/// **只重新组织现有信息，不新增任何业务数据来源**：
/// * 状态 / 前台应用来自 [OverlayPetController.stateDiagnostics]（原生真值）；
/// * 角色来自 `stateEngineSnapshot`；
/// * 同步信息来自 [SyncEngine]；
/// * 今日时长与 7 日趋势来自 [AppServices.usageAnalytics]（与统计页同一个口径）；
/// * 四个快捷操作全部直接调用现有控制器方法。
class MobileHomePage extends StatefulWidget {
  const MobileHomePage({
    super.key,
    required this.services,
    required this.library,
    required this.onOpenLibrary,
    this.overlay,
  });

  final AppServices services;
  final LibraryController library;

  /// 「更换角色 / 打开素材库」都切到素材库根页面（由外壳提供的现有导航）。
  final VoidCallback onOpenLibrary;

  /// Android 悬浮桌宠协调器：桌宠状态由原生决定，这里只读它显示。
  final OverlayPetController? overlay;

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends State<MobileHomePage> {
  AppServices get _s => widget.services;

  UsageSummary? _today;
  List<DailyPoint> _trend = const <DailyPoint>[];
  bool _busy = false;
  String? _actionNotice;

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  /// 读取「今日陪伴」数据。
  ///
  /// 复用**现有**的 `UsageAnalyticsService.summarize`：今天用
  /// [UsageRange.today] 的窗口，趋势用同样的按天窗口各查一次
  /// （口径不变、不去重、不新增算法）。
  Future<void> _refreshStats() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final DateTime nowUtc = DateTime.now().toUtc();
      final Duration offset = DateTime.now().timeZoneOffset;

      final UsageSummary today = await _s.usageAnalytics.summarize(
        UsageWindow.dayContaining(nowUtc, offset, label: '今天'),
      );

      final List<DailyPoint> points = <DailyPoint>[];
      for (int i = 6; i >= 0; i--) {
        // 复用 `UsageWindow.dayContaining` 的 `dayOffset`：同一天口径，不新增算法。
        final UsageWindow window = UsageWindow.dayContaining(
          nowUtc,
          offset,
          dayOffset: -i,
        );
        final UsageSummary summary = await _s.usageAnalytics.summarize(window);
        points.add(
          DailyPoint(
            seconds: summary.overview.appActiveSeconds,
            weekday: window.fromUtc.add(offset).weekday,
            isToday: i == 0,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _today = today;
        _trend = points;
      });
    } catch (e, st) {
      // 首页的统计只是摘要：失败时**保持界面可用**，只在卡片里说明。
      Loggers.activity.warning('首页读取今日陪伴摘要失败', e, st);
      if (mounted) setState(() => _today = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 快捷操作（全部是**真实**业务动作）
  // ---------------------------------------------------------------------------

  Future<void> _togglePetVisibility() async {
    final OverlayPetController? overlay = widget.overlay;
    if (overlay == null) return;
    final OverlayRuntimeState? state = overlay.state;
    final bool running = state?.serviceRunning ?? false;
    final bool hidden = state?.hidden ?? false;
    try {
      if (running && !hidden) {
        await overlay.hide();
        _notify('已隐藏悬浮桌宠');
      } else {
        await overlay.show();
        _notify('已显示悬浮桌宠');
      }
    } catch (e, st) {
      Loggers.app.warning('切换悬浮桌宠显示状态失败', e, st);
      _notify('操作失败：${overlay.lastError ?? e}');
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    setState(() => _actionNotice = message);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 切换状态：Android 上状态由**原生**决定，因此下发手动覆盖；
  /// 其它平台回退到状态引擎（同一个 `StateChangeRequest` 语义）。
  Future<void> _openStateSwitcher() async {
    final _StatePickerResult? picked = await showModalBottomSheet<_StatePickerResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _StatePickerSheet(
        current: _currentState(),
        manualOverride: widget.overlay?.stateDiagnostics.manualOverride,
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.restoreAutomatic) {
      await _restoreAutoState();
      return;
    }
    final SystemState state = picked.state!;
    try {
      final OverlayPetController? overlay = widget.overlay;
      if (overlay != null) {
        await overlay.setManualState(state.wireName);
      } else {
        await _s.stateEngine.requestState(
          StateChangeRequest(
            state: state,
            trigger: StateTrigger.manual,
            reason: '首页手动切换 ${state.wireName}',
            force: true,
            immediate: true,
          ),
        );
      }
      _notify('已切换到「${state.descriptionZh}」');
    } catch (e, st) {
      Loggers.state.warning('切换桌宠状态失败', e, st);
      _notify('切换状态失败：$e');
    }
  }

  /// 恢复自动状态联动（清掉原生的手动覆盖）。
  Future<void> _restoreAutoState() async {
    final OverlayPetController? overlay = widget.overlay;
    if (overlay == null) return;
    await overlay.setManualState(null);
    _notify('已恢复自动状态联动');
  }

  /// 更换角色：列出素材库里已有角色，直接调用现有的 [LibraryController.activateCharacter]。
  Future<void> _openCharacterSwitcher() async {
    final List<LibraryCharacterOption> options = _characterOptions();
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => _CharacterPickerSheet(
        options: options,
        activeCharacterId: widget.library.activeCharacterId,
      ),
    );
    if (picked == null || !mounted) return;
    final String? error = await widget.library.activateCharacter(picked);
    if (!mounted) return;
    if (error != null) {
      _notify(error);
      return;
    }
    _notify('已切换角色');
  }

  List<LibraryCharacterOption> _characterOptions() {
    final LibrarySnapshot? snap = widget.library.snapshot;
    if (snap == null) return const <LibraryCharacterOption>[];
    String packNameOf(String packId) {
      for (final CharacterPack pack in snap.packs) {
        if (pack.id == packId) return pack.name;
      }
      return '未分组';
    }

    return <LibraryCharacterOption>[
      for (final CharacterModel character in snap.characters)
        LibraryCharacterOption(
          id: character.id,
          name: character.displayName,
          packName: packNameOf(character.packId),
          assetCount: snap.assetsOf(character.id).length,
        ),
    ];
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[
        _s.settings,
        widget.library,
        _s.syncEngine,
        widget.overlay,
      ]),
      builder: (BuildContext context, Widget? _) {
        return ValueListenableBuilder<StateSnapshot>(
          valueListenable: _s.stateEngineSnapshot,
          builder: (BuildContext context, StateSnapshot snapshot, Widget? __) {
            return PetLifePage(
              title: '桌宠',
              subtitle: '当前状态、快捷操作与今日陪伴',
              actions: <Widget>[
                PetLifeHeaderAction(
                  icon: Icons.refresh,
                  tooltip: '刷新今日数据',
                  onPressed: _busy ? null : _refreshStats,
                ),
              ],
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  PetLifeCardEntrance(child: _statusCard(snapshot)),
                  const SizedBox(height: PetLifeSpacing.cardGap),
                  PetLifeCardEntrance(
                    delay: const Duration(milliseconds: 40),
                    child: _quickActions(),
                  ),
                  const SizedBox(height: PetLifeSpacing.cardGap),
                  PetLifeCardEntrance(
                    delay: const Duration(milliseconds: 80),
                    child: _todayCard(snapshot),
                  ),
                  if (_actionNotice != null) ...<Widget>[
                    const SizedBox(height: PetLifeSpacing.cardGap),
                    PetLifeCard(
                      color: PetLifeTheme.of(context).muted,
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.info_outline,
                              size: 16, color: PetLifeTheme.of(context).textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _actionNotice!,
                              style: TextStyle(
                                fontSize: PetLifeText.caption,
                                color: PetLifeTheme.of(context).textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: PetLifeSpacing.cardGap),
                  MobilePlatformNotice(
                    collecting:
                        _s.platform.capabilities.supportsSystemActivityTracking,
                  ),
                  const SizedBox(height: PetLifeSpacing.cardGap),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- 当前桌宠状态卡 ---

  Widget _statusCard(StateSnapshot snapshot) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;

    return PetLifeCard(
      large: true,
      corner: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = MediaQuery.textScalerOf(context).scale(1.0);
          final bool stack = constraints.maxWidth < 300 * scale;
          final Widget preview = _characterPreview();
          final Widget info = _statusInfo(snapshot, d, p);
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(child: preview),
                const SizedBox(height: 12),
                info,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              preview,
              const SizedBox(width: 14),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }

  /// 角色缩略图。
  ///
  /// 复用现有的 [PetView]（= 应用内真实渲染，含"还没有素材"的占位图），
  /// 因此缩略图与实际显示**永远一致**，不需要新增任何素材读取逻辑。
  /// 用 `FittedBox` 保持宽高比，避免缩略图被拉变形。
  Widget _characterPreview() {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Container(
      width: 104,
      height: 118,
      decoration: BoxDecoration(
        color: p.muted,
        borderRadius: PetLifeRadii.cardBorder,
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: FittedBox(
          fit: BoxFit.contain,
          child: PetView(
            renderer: _s.renderer,
            // 缩略图只关心"是哪个角色 / 哪张素材"，与用户的缩放倍率无关，
            // 因此固定 1× 渲染再由 FittedBox 缩放（更省、且不变形）。
            scale: 1.0,
            smoothScaling: _s.settings.settings.smoothScaling,
            opacity: 1.0,
            lockPosition: true,
            manageWindowSize: false,
          ),
        ),
      ),
    );
  }

  Widget _statusInfo(
    StateSnapshot snapshot,
    OverlayStateDiagnostics? d,
    PetLifePalette p,
  ) {
    // 绑定逻辑全部在 PetLifePetStatusView（纯函数，可单测）。
    final PetLifePetStatusView view = PetLifePetStatusView.from(
      snapshot: snapshot,
      overlaySupported: widget.overlay != null,
      overlayRuntime: widget.overlay?.state,
      nativeStateLabel: (d != null && d.stateLabel.isNotEmpty) ? d.stateLabel : null,
      foregroundAppLabel: _foregroundAppLabel(d),
      autoStateEnabled: _s.settings.settings.overlayAutomaticState,
      syncStatus: _s.syncEngine.status,
      pendingCount: _s.syncEngine.pendingCount,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          view.characterName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: PetLifeText.cardTitle,
            fontWeight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: <Widget>[
            PetLifeTag(
              label: '情绪 ${view.emotionLabel}',
              icon: Icons.mood,
              selected: true,
            ),
            PetLifeTag(
              label: '当前 ${view.foregroundAppLabel}',
              icon: Icons.apps,
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _statusLine(
          view.autoStateEnabled ? Icons.autorenew : Icons.pause_circle_outline,
          view.autoStateLabel,
          view.autoStateEnabled ? p.success : p.textSecondary,
        ),
        const SizedBox(height: 4),
        _statusLine(
          Icons.layers_outlined,
          view.serviceLabel,
          _serviceColor(view.serviceState, p),
        ),
        const SizedBox(height: 4),
        _statusLine(
          Icons.cloud_sync_outlined,
          view.syncLabel,
          view.syncState == SyncVisualState.success ? p.success : p.textSecondary,
        ),
      ],
    );
  }

  Widget _statusLine(IconData icon, String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: PetLifeText.caption,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      );

  Color _serviceColor(OverlayServiceState state, PetLifePalette p) =>
      switch (state) {
        OverlayServiceState.running => p.success,
        OverlayServiceState.hidden => p.warning,
        OverlayServiceState.unsupported => p.textSecondary,
        OverlayServiceState.unknown => p.textSecondary,
        OverlayServiceState.stopped => p.textSecondary,
      };

  /// 当前前台应用：Android 读原生共享快照（与统计页 / 设置页同一份真值）。
  String _foregroundAppLabel(OverlayStateDiagnostics? d) {
    final String? native = d?.foregroundLabel;
    if (native != null && native.isNotEmpty) return native;
    final ActivityTracker tracker = _s.activityTracker;
    return tracker.currentAppDisplayName ?? '—';
  }

  SystemState _currentState() {
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;
    if (d != null && d.stateId.isNotEmpty) return SystemState.fromWire(d.stateId);
    return _s.stateEngineSnapshot.value.state;
  }

  // --- 快捷操作 ---

  Widget _quickActions() {
    final OverlayPetController? overlay = widget.overlay;
    final OverlayRuntimeState? runtime = overlay?.state;
    final bool running = runtime?.serviceRunning ?? false;
    final bool hidden = runtime?.hidden ?? false;
    final bool shown = running && !hidden;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '快捷操作',
          subtitle: '全部直接调用现有功能，没有纯展示按钮',
        ),
        PetLifeCard(
          large: true,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 1.5 倍字体 / 窄屏下 4 列会挤到溢出，因此按**文字缩放**降到 2 列。
              final double scale = MediaQuery.textScalerOf(context).scale(1.0);
              final int columns = constraints.maxWidth < 320 * scale ? 2 : 4;
              const double gap = 8;
              final double itemWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  SizedBox(
                    width: itemWidth,
                    child: _QuickAction(
                      icon: shown
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      label: shown ? '隐藏桌宠' : '显示桌宠',
                      active: shown,
                      onTap: overlay == null ? null : _togglePetVisibility,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _QuickAction(
                      icon: Icons.auto_awesome_outlined,
                      label: '切换状态',
                      onTap: _openStateSwitcher,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _QuickAction(
                      icon: Icons.swap_horiz,
                      label: '更换角色',
                      onTap: _characterOptions().isEmpty
                          ? widget.onOpenLibrary
                          : _openCharacterSwitcher,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _QuickAction(
                      icon: Icons.folder_open_outlined,
                      label: '素材库',
                      onTap: widget.onOpenLibrary,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // --- 今日陪伴 ---

  Widget _todayCard(StateSnapshot snapshot) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final UsageOverview overview = _today?.overview ?? UsageOverview.empty;
    final String duration = formatDurationZh(overview.appActiveSeconds);
    final SystemState state = _currentState();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '今日陪伴',
          subtitle: '数据来自本机使用统计，口径与「使用统计」页一致',
          marker: false,
        ),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_busy && _today == null)
                const PetLifeLoading(label: '正在统计…')
              else
                PetLifeStat(
                  value: duration,
                  label: '今日设备使用时长',
                  note: '本设备只统计「应用使用时长」（与统计页口径相同）',
                  large: true,
                ),
              const SizedBox(height: 14),
              _TrendBars(points: _trend, palette: p),
              const SizedBox(height: 14),
              PetLifeKeyValue(
                label: '当前状态',
                value: '${state.descriptionZh}（${state.wireName}）',
              ),
              PetLifeKeyValue(
                label: '当前角色',
                value: snapshot.currentCharacter?.displayName ?? '未选择',
              ),
              PetLifeKeyValue(
                label: '最近同步',
                value: _lastSyncLabel(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _lastSyncLabel() {
    final DateTime? at = _s.syncEngine.lastSuccessAt;
    if (at == null) return '还没有成功同步过';
    final DateTime local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// 一个快捷操作按钮（图标在上、文字在下；触摸区 ≥48dp）。
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: InkWell(
        borderRadius: PetLifeRadii.buttonBorder,
        onTap: onTap,
        child: AnimatedContainer(
          duration: PetLifeDurations.press,
          curve: PetLifeDurations.easing,
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          decoration: BoxDecoration(
            color: active ? p.accentSoft : p.muted,
            borderRadius: PetLifeRadii.buttonBorder,
            border: Border.all(color: active ? p.accent : p.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 22,
                color: enabled
                    ? (active ? p.onAccentSoft : p.accent)
                    : p.textDisabled,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: FontWeight.w600,
                  color: enabled ? p.textPrimary : p.textDisabled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 今日陪伴里的小型趋势图（最近 7 天的应用使用时长）。
class _TrendBars extends StatelessWidget {
  const _TrendBars({required this.points, required this.palette});

  final List<DailyPoint> points;
  final PetLifePalette palette;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return Text(
        '还没有足够的数据画出趋势',
        style: TextStyle(fontSize: PetLifeText.caption, color: palette.textSecondary),
      );
    }
    final int maxSeconds = points
        .map((DailyPoint p) => p.seconds)
        .fold<int>(1, (int a, int b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '最近 7 天',
              style: TextStyle(
                fontSize: PetLifeText.caption,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '峰值 ${formatDurationZh(maxSeconds)}',
              style: TextStyle(fontSize: PetLifeText.captionSmall, color: palette.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 62,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (final DailyPoint point in points)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: (point.seconds / maxSeconds).clamp(0.04, 1.0),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: point.isToday ? palette.accent : palette.accentSoft,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          point.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: point.isToday ? FontWeight.w700 : FontWeight.w400,
                            color: point.isToday ? palette.onAccentSoft : palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 趋势图上的一个数据点。
class DailyPoint {
  const DailyPoint({
    required this.seconds,
    required this.weekday,
    required this.isToday,
  });

  final int seconds;

  /// 1 = 周一 … 7 = 周日。
  final int weekday;
  final bool isToday;

  String get label {
    if (isToday) return '今';
    const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
    return names[(weekday - 1).clamp(0, 6)];
  }
}

/// 状态选择面板的返回值：要么选了一个状态，要么要求恢复自动联动。
class _StatePickerResult {
  const _StatePickerResult.state(this.state) : restoreAutomatic = false;
  const _StatePickerResult.restoreAutomatic()
      : state = null,
        restoreAutomatic = true;

  final SystemState? state;
  final bool restoreAutomatic;
}

/// 状态选择面板（BottomSheet）。
class _StatePickerSheet extends StatelessWidget {
  const _StatePickerSheet({required this.current, this.manualOverride});

  final SystemState current;
  final String? manualOverride;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const PetLifeSectionTitle(
              title: '切换桌宠状态',
              subtitle: '手动覆盖会暂停自动联动，可随时恢复',
              marker: false,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final SystemState state in SystemState.values)
                  PetLifeTag(
                    label: state.descriptionZh,
                    selected: state == current,
                    onTap: () => Navigator.pop(
                      context,
                      _StatePickerResult.state(state),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              manualOverride == null
                  ? '当前没有手动覆盖。'
                  : '当前手动覆盖：'
                      '${SystemState.fromWire(manualOverride!).descriptionZh}',
              style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
            ),
            const SizedBox(height: 10),
            PetLifeSecondaryButton(
              label: '恢复自动状态联动',
              icon: Icons.autorenew,
              onPressed: () => Navigator.pop(
                context,
                const _StatePickerResult.restoreAutomatic(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 素材库里的一个角色（用于「更换角色」面板）。
class LibraryCharacterOption {
  const LibraryCharacterOption({
    required this.id,
    required this.name,
    required this.packName,
    required this.assetCount,
  });

  final String id;
  final String name;
  final String packName;
  final int assetCount;
}

class _CharacterPickerSheet extends StatelessWidget {
  const _CharacterPickerSheet({
    required this.options,
    this.activeCharacterId,
  });

  final List<LibraryCharacterOption> options;
  final String? activeCharacterId;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const PetLifeSectionTitle(
              title: '更换角色',
              subtitle: '选择后立即成为当前桌宠角色',
              marker: false,
            ),
            if (options.isEmpty)
              Text(
                '素材库里还没有角色，请先导入素材。',
                style: TextStyle(fontSize: PetLifeText.bodySmall, color: p.textSecondary),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final LibraryCharacterOption option in options)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          option.id == activeCharacterId
                              ? Icons.check_circle
                              : Icons.person_outline,
                          color: option.id == activeCharacterId ? p.accent : p.textSecondary,
                        ),
                        title: Text(option.name),
                        subtitle: Text(
                          '${option.packName} · ${option.assetCount} 个素材',
                          style: TextStyle(fontSize: PetLifeText.caption),
                        ),
                        onTap: () => Navigator.pop(context, option.id),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `UsageWindow` 的构造辅助已由 `UsageWindow.dayContaining` 直接提供，
/// 这里不再包装（避免出现"两套窗口口径"）。
