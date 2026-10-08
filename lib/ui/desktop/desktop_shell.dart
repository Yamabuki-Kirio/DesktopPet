import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/pet_renderer.dart' show BuiltinPlaceholder;
import '../../core/error_handler.dart';
import '../../core/logger.dart';
import '../../desktop_window/tray_host.dart';
import '../../menu/context_menu_anchor.dart';
import '../../menu/fixed_canvas_contract.dart';
import '../../menu/fixed_canvas_geometry.dart';
import '../../character/models/emotion_asset.dart';
import '../../menu/menu_contract.dart'
    show
        MenuCatalog,
        MenuExecutionResult,
        PanelAccountSync,
        PanelAssetLibrary,
        PanelCloudUsage,
        PanelDestination,
        PanelDiagnostics,
        PanelLocalUsage,
        PanelPetHome,
        PanelSettings,
        PanelStateMapping,
        PanelTimeline;
import '../../menu/wheel_action_dispatch.dart' show WheelActionRegistry;
import '../../state_engine/state_snapshot.dart';
import '../../menu/pet_position_resolver.dart'
    show PetPositionResolver, WindowPositionSchema;
import '../../menu/wheel_adjustment_layer.dart' show WheelAdjustmentKind;
import '../../platform/windows/windows_menu_action_executor.dart';
import '../../menu/region_coordinator.dart';
import '../../menu/region_owner.dart';
import '../../menu/wheel_canvas_bridge.dart' show WheelCanvasBridge;
import '../../menu/wheel_canvas_plan.dart' show WheelCanvasPlan, WheelCanvasPlanner;
import '../../menu/wheel_geometry.dart' show WheelDisplayArea;
import '../../menu/wheel_geometry_ownership.dart';
import '../../menu/windows_surface_mode.dart';
import '../../platform/windows/windows_surface_channel.dart';
import '../../settings/app_settings.dart';
import '../pet/pet_view_wrapper.dart';
import 'control_panel.dart';
import 'fixed_canvas_probe.dart';
import 'desktop_menu_action_bridge.dart';
import 'panel_layout.dart';
import 'surface_mode_controller.dart';
import 'wheel_geometry_probe.dart';

/// 桌面外壳（Windows）：负责在「固定画布桌宠」与「控制面板」两种形态之间切换。
///
/// 为什么用同一个窗口而不是两个原生窗口：
/// Flutter 桌面的多窗口支持仍是实验性的，而阶段 0 的验收只要求
/// 「至少提供以下页面或面板」——用一个可切换形态的窗口即可满足，
/// 且能避免多窗口带来的焦点、置顶、托盘联动等一堆边界问题。
///
/// **回归修复（本轮）**：形态切换不再是一堆散落的布尔量，而是由
/// [WindowsSurfaceMode] 显式建模、由 [SurfaceModeController] 执行的**完整事务**
/// （进入面板 / 返回桌宠各自 14 / 10 步，带代际校验与回滚）。
///
/// **Region 所有权（本轮）**：窗口 Region 的唯一写入者是 [RegionCoordinator]；
/// 本类只负责**装配**它（`WindowsSurfaceBridge` → 协调器 → 探针 / 右键菜单），
/// 绝不直接调用原生 Region 方法。
///
/// Phase 4A：Android 使用 `ui/mobile/mobile_shell.dart`，两者由
/// `app/app_shell.dart` 按平台能力选择。
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.services});

  final AppServices services;

  /// 控制面板窗口尺寸（逻辑像素）。
  static const Size panelSize = Size(1180, 760);

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell>
    implements SurfaceTransactionHost {
  /// 当前是否显示 `ControlPanel` widget（由形态事务在正确时机翻转，
  /// 而不是直接跟随模式 —— 否则过渡早期就会提前换页，用户会看到中间态）。
  bool _panelWidgetActive = false;

  final GlobalKey<ControlPanelState> _panelKey = GlobalKey<ControlPanelState>();

  /// 轮盘菜单几何探针的句柄（旧方案，默认关闭；仅 `dynamicSetBoundsProbeEnabled` 时挂载）。
  final GlobalKey<WheelGeometryProbeState> _wheelProbeKey =
      GlobalKey<WheelGeometryProbeState>();

  /// 固定画布 + Region 探针的句柄（本轮新方向）。
  final GlobalKey<FixedCanvasProbeState> _fixedProbeKey =
      GlobalKey<FixedCanvasProbeState>();

  /// **增量 C1**：正式动作执行器（窗口级 + 业务动作）。
  ///
  /// 业务动作**委托**给共用的 `OverlayMenuActionExecutor`（见
  /// `DesktopMenuActionBridge`），绝不复制素材库 / 收藏 / 状态映射逻辑。
  late final WindowsMenuActionExecutor _menuActionExecutor =
      WindowsMenuActionExecutor(_menuActionHost());
  DesktopMenuActionBridge? _actionBridge;

  WindowsMenuActionHost _menuActionHost() => WindowsMenuActionHost(
        setPetVisible: (bool visible) => _s.windowController.setVisible(visible),
        increasePetScale: () => _bumpPetScale(1),
        decreasePetScale: () => _bumpPetScale(-1),
        resetPetScale: () async {
          await _s.settings.setScale(2.0);
          await _s.windowController.applySettings(_s.settings.settings);
        },
        resetPetPosition: () => resetPetPosition(),
        openControlPanel: () async {
          if (windowsSurfaceSession.mode == WindowsSurfaceMode.petFixedCanvas) {
            await openPanel();
          }
        },
        // 需求 §3.1「唯一业务入口」：**全部**业务动作走同一条通道，
        // 本外壳不再另写 pet_auto / appearance_* 的第二份实现。
        dispatchBusiness: _runBusinessAction,
        currentPetStateLabel: _currentPetStateLabel,
        currentForegroundAppLabel: _currentForegroundAppLabel,
      );

  /// 只读信息项「当前状态」：桌宠系统状态 + 正在显示的素材。
  ///
  /// **复用状态引擎快照**，不新建任何状态口径（需求 §7「不新增统计口径」）。
  Future<String> _currentPetStateLabel() async {
    final StateSnapshot snap = _s.stateEngine.snapshot;
    final String state = snap.state.label;
    final EmotionAsset? asset = snap.currentAsset;
    if (asset == null) return '当前状态：$state';
    return '当前状态：$state · ${asset.emotionName}/${asset.variantName}';
  }

  /// 只读信息项「当前应用」：前台应用（复用既有的当前活动提供者）。
  Future<String> _currentForegroundAppLabel() async {
    final String? app = _s.activityTracker.currentAppDisplayName;
    if (app == null || app.isEmpty) return '当前应用：暂无记录';
    return '当前应用：$app';
  }

  /// 业务动作：委托给共用的 `OverlayMenuActionExecutor`。
  Future<MenuExecutionResult> _runBusinessAction(String actionId) {
    final DesktopMenuActionBridge bridge = _actionBridge ??=
        DesktopMenuActionBridge(
      services: _s,
      onDestination: _applyDestination,
    );
    return bridge.run(actionId);
  }

  /// 页面跳转：打开控制面板并切到对应页（等价 Android 切底部 tab）。
  ///
  /// 需求 §12.2：所有打开控制面板的动作统一走**同一条事务**
  /// （`openPanel()` → `SurfaceModeController.enterPanel`，14 步 + 代际校验 + 回滚），
  /// 这里只负责"事务完成后再选页签"，**不使用任何固定延时**。
  ///
  /// 需求 §12.1：路由键是**强类型** [PanelDestination]，绝不用中文文案。
  Future<void> _applyDestination(PanelDestination destination) async {
    wheelGeometryJournal.record(
      'wheel.navigation.begin',
      fields: <String, Object?>{'destination': destination.wireName},
    );

    // 目的地「桌宠主页」= 返回桌宠（§12.3），不是某个页签。
    if (destination is PanelPetHome) {
      await closePanel();
      wheelGeometryJournal.record(
        'wheel.navigation.ready',
        fields: <String, Object?>{'destination': destination.wireName},
      );
      return;
    }

    if (windowsSurfaceSession.mode != WindowsSurfaceMode.panel) {
      await openPanel();
    }
    final ControlPanelState? panel = _panelKey.currentState;
    final int? tab = _tabIndexFor(destination);
    if (panel == null || tab == null) {
      wheelGeometryJournal.record(
        'wheel.navigation.failed',
        fields: <String, Object?>{
          'destination': destination.wireName,
          'reason': panel == null ? 'panel_not_mounted' : 'no_tab',
        },
      );
      return;
    }
    panel.selectTab(tab);
    wheelGeometryJournal.record(
      'wheel.navigation.ready',
      fields: <String, Object?>{
        'destination': destination.wireName,
        'tab': tab,
      },
    );
  }

  /// 强类型目的地 → 控制面板页签下标（**唯一映射点**）。
  ///
  /// 云端统计 / 时间线都落在「使用统计」页（页内子标签由设置记忆负责，
  /// 与移动端同一口径）。
  static int? _tabIndexFor(PanelDestination destination) =>
      switch (destination) {
        PanelAssetLibrary() => ControlPanel.assetLibraryTabIndex,
        PanelStateMapping() => ControlPanel.stateMappingTabIndex,
        PanelLocalUsage() => ControlPanel.usageStatsTabIndex,
        PanelCloudUsage() => ControlPanel.usageStatsTabIndex,
        PanelTimeline() => ControlPanel.usageStatsTabIndex,
        PanelAccountSync() => ControlPanel.accountSyncTabIndex,
        PanelSettings() => ControlPanel.settingsTabIndex,
        PanelDiagnostics() => ControlPanel.diagnosticsTabIndex,
        PanelPetHome() => null,
      };

  /// 写入轮盘几何设置（调整层的**唯一**写入口）。
  Future<void> _applyWheelSetting(WheelAdjustmentKind kind, double value) async {
    switch (kind) {
      case WheelAdjustmentKind.wheelScale:
        await _s.settings.setWheelScale(value);
      case WheelAdjustmentKind.buttonScale:
        await _s.settings.setWheelButtonScale(value);
      case WheelAdjustmentKind.menuDistance:
        await _s.settings.setWheelMenuDistance(value);
      case WheelAdjustmentKind.theme:
        break; // 主题走 applyWheelTheme（只改颜色）
    }
  }

  /// 读取轮盘几何设置当前值（调整层显示"当前值"用）。
  double _readWheelSetting(WheelAdjustmentKind kind) {
    final AppSettings s = _s.settings.settings;
    return switch (kind) {
      WheelAdjustmentKind.wheelScale => s.wheelScale,
      WheelAdjustmentKind.buttonScale => s.wheelButtonScale,
      WheelAdjustmentKind.menuDistance => s.wheelMenuDistance,
      WheelAdjustmentKind.theme => 0,
    };
  }

  /// 桌宠缩放（1×~4×，与设置页同一约束）。
  Future<void> _bumpPetScale(int delta) async {
    final double current = _s.settings.settings.scale;
    final double next = (current + delta).clamp(1.0, 4.0).toDouble();
    if (next == current) return;
    await _s.settings.setScale(next);
    await _s.windowController.applySettings(_s.settings.settings);
  }

  /// 固定画布 Region 原生桥（生产实现）——**只**交给 [RegionCoordinator]。
  final WindowsSurfaceBridge _surfaceBridge = WindowsSurfaceBridge();

  /// 固定画布窗口几何（`commitBounds` 是本轮唯一的矩形提交点）。
  final FixedCanvasWindowOps _fixedWindowOps = const WindowsFixedCanvasWindowOps();

  /// **窗口 Region 的唯一写入者**（owner / generation / 异步事务代际）。
  late final RegionCoordinator _regionCoordinator = RegionCoordinator(
    ops: _surfaceBridge,
    devicePixelRatio: () => _fixedWindowOps.devicePixelRatio(),
    journal: wheelGeometryJournal,
  );

  /// 形态事务执行器（真实副作用由本 State 实现）。
  late final SurfaceModeController _surfaceController =
      SurfaceModeController(this);

  /// 返回桌宠事务中已提交的画布矩形 / 锚点 / 桌宠尺寸。
  Rect? _pendingCanvasRect;
  Offset _pendingAnchor = Offset.zero;
  Size _pendingPetSize = Size.zero;

  /// 进入面板前捕获的**桌宠锚点屏幕位置**，返回时据此把桌宠放回原位（零漂移）。
  Offset? _panelReturnPetScreen;

  /// 本次进入面板使用的**适配后**面板尺寸（由 `openPanel` 依桌宠所在显示器
  /// workArea 算好，`commitPanelBounds` 与事务的尺寸校验都用它）。
  Size? _pendingPanelSize;

  /// 轮盘菜单是否打开（打开期间暂停"窗口跟随素材尺寸"）。
  bool _wheelMenuOpen = false;

  AppServices get _s => widget.services;

  static const FixedCanvasConfig _canvasConfig = FixedCanvasConfig();

  @override
  void initState() {
    super.initState();
    _bootstrapAsync();
  }

  Future<void> _bootstrapAsync() async {
    try {
      // 需求 §3.4 / §15：**装配期**校验动作注册表完整性 ——
      // 叶子动作必须每个都能被路由（不得落进"未支持"兜底）。
      WheelActionRegistry.assertValid();

      await _s.initializeTray();

      // 把托盘与 UI 之间的动作接上。
      AppServices.panelToggleHook = () async => togglePanel();
      AppServices.exitHook = () async => _exitApp();
      AppServices.toggleTrackingHook = () async => toggleTracking();
      AppServices.usageStatsHook = () async => openUsageStats();
      // 托盘「重置位置」：走固定画布安全重建事务 + 写回 v2（不再 moveTo(0,0)）。
      AppServices.resetPositionHook = () async => resetPetPosition();
      // 托盘显示 / 隐藏桌宠前先收起菜单（还原窗口矩形 / Region）。
      AppServices.beforePetVisibilityChangeHook = () async {
        await _wheelProbeKey.currentState?.close();
        await _fixedProbeKey.currentState?.close();
      };

      // C1.1 拖动生命周期（需求 §四）：窗口**真的被移动**时
      // （用户拖动 / 系统移动，`onWindowMoved` → 位置提交）：
      // 1) 判位置写入的是 petScreenPosition（v2）—— 由 controller 完成；
      // 2) 让探针**立刻**刷新空间快照（重算 petVisualScreenRect / 目标显示器 /
      //    expansionSide / Region），并把位置修订号 +1，使旧的异步结果作废；
      // 3) 轮盘开着时先收起（拖动期间不再重建菜单，避免"菜单留在旧位置"）。
      _s.windowController.onPositionCommitted((double x, double y) {
        unawaited(_fixedProbeKey.currentState?.onPetPositionChanged(x, y));
      });

      // 让托盘回调能定位到本 State。
      _shellRef = this;

      // 恢复上次的角色与表情（验收第 18 项）。
      final String? lastCharacter = _s.settings.settings.lastCharacterId;
      final String? defaultCharacter = _s.settings.settings.defaultCharacterId;
      final String? characterId = lastCharacter ?? defaultCharacter;

      if (characterId != null) {
        await _s.stateEngine.start(ownerId: _s.ownerId, characterId: characterId);
        final String? manualAsset = _s.settings.settings.manualAssetId;
        if (manualAsset != null) {
          await _s.stateEngine.lockManual(
            assetId: manualAsset,
            reason: '恢复上次的 manual 锁定',
          );
        }
      } else {
        Loggers.app.info('尚无角色配置，等待用户导入素材');
      }

      await _s.presenter.start();
      await _startPetMode();

      // 阶段 1：启动 Windows 活动采集（在状态引擎绑定角色之后）。
      // 失败不会影响桌宠，采集器内部已有降级路径。
      await _s.startActivityTracking();
      _s.activityTracker.addListener(_onTrackingChanged);
      _syncTrayTrackingState();

      // Phase 2：启动后台同步引擎（未登录时不做任何网络请求）。
      await _s.startSync();
    } catch (e, st) {
      ErrorHandler.record('DesktopShell.bootstrap', e, st);
    }
  }

  /// 启动进入稳定的桌宠固定画布态。
  ///
  /// **真机回归修复**：show 之前必须校验**人物**可见性，而不是只看 HWND。
  /// 校验不通过 → 安全回退（清 Region + 普通矩形窗口 + 主屏右下角 + show + 提示），
  /// **绝不**静默显示一个屏幕外的窗口。
  Future<void> _startPetMode() async {
    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.petFixedCanvas,
      source: 'shell.bootstrap',
    );
    wheelSurfaceGeometry.change(
      WindowsSurfaceGeometryOwner.pet,
      source: 'shell.bootstrap',
    );
    await _s.windowController.setResizable(false);
    // 注意：**不再**在这里 applySettings 决定位置 —— `applySettings` 在固定画布
    // 模式下已整体跳过旧小窗口的位置 / 尺寸写入，位置由下面的画布事务独占。
    await _s.windowController.applySettings(_s.settings.settings);

    final FixedCanvasProbeState? probe = _fixedProbeKey.currentState;
    final bool ready = probe == null ? false : await probe.prepareFixedCanvas();
    if (!ready) {
      await _startupSafeFallback(probe == null ? 'probe_absent' : 'canvas_not_validated');
      return;
    }

    await _s.windowController.setVisible(true);
    // 用户 §7 要求："桌宠显示"日志必须带这些字段。
    wheelGeometryJournal.record(
      'startup.window.show',
      fields: <String, Object?>{
        ...probe.startupShowEvidence(),
        'mode': windowsSurfaceSession.mode.wireName,
      },
    );
    Loggers.window.info('桌宠窗口已显示（人物可见性已校验通过）');
  }

  /// **启动可见性保护**（用户 §6）。
  ///
  /// 触发条件：画布初始化失败 / Region 为空 / 人物矩形完全不在任一显示器 /
  /// 可见面积低于阈值。
  ///
  /// 动作：清 Region → 恢复普通矩形桌宠窗口 → 移到主显示器右下角 → show →
  /// 诊断提示。托盘与退出入口不受影响。
  Future<void> _startupSafeFallback(String reason) async {
    final Size pet = petLogicalSize;
    wheelGeometryJournal.record(
      'startup.safe_fallback',
      fields: <String, Object?>{
        'reason': reason,
        'mode': windowsSurfaceSession.mode.wireName,
        'pet': '${pet.width}x${pet.height}',
      },
    );
    Loggers.window.warning('启动可见性保护触发：$reason，回退到普通桌宠窗口（主屏右下角）');

    try {
      // 1) 清除自定义 Region（恢复普通矩形窗口）。
      await _regionCoordinator.clear(
        owner: RegionOwner.panelTransition,
        source: 'shell.startupSafeFallback',
      );
      // 2) 退出固定画布（清 petAnchor，后续 position 持久化回到普通口径）。
      await _fixedProbeKey.currentState?.releaseFixedCanvas();
      fixedCanvasAnchor.clear();
      // 3) 恢复普通矩形桌宠窗口尺寸。
      await _s.windowController.resizeTo(pet);
      // 4) 移到主显示器右下角。
      final Offset target = await _defaultPetScreenPosition(pet);
      await _s.windowController.moveTo(target.dx, target.dy);
      // 5) 记住 v2 位置（否则下次启动又会读到坏的旧值）。
      await _s.settings.rememberWindowPosition(target.dx, target.dy);
    } catch (e, st) {
      Loggers.window.warning('启动安全回退过程中出错（仍会显示窗口）', e, st);
    }

    await _s.windowController.setVisible(true);
    _fixedProbeKey.currentState?.showStatusMessage(
      '桌宠位置数据异常，已回到屏幕右下角（原位置不可见）',
    );
  }

  @override
  void dispose() {
    _s.activityTracker.removeListener(_onTrackingChanged);
    // 兜底：外壳销毁时清除 Region 并复位锚点，绝不留下残留 Region / GDI 对象。
    unawaited(_regionCoordinator.dispose(source: 'shell.dispose'));
    fixedCanvasAnchor.clear();
    // 复位共享模式机，避免影响后续测试 / 重建。
    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.petFixedCanvas,
      source: 'shell.dispose',
    );
    super.dispose();
  }

  void _onTrackingChanged() {
    _syncTrayTrackingState();
  }

  /// 同步托盘「暂停 / 恢复记录」文案与提示。
  ///
  /// 只在暂停状态变化时重建菜单；提示文案按应用变化更新，避免高频调用原生 API。
  void _syncTrayTrackingState() {
    final TrayHost? tray = _s.trayHost;
    if (tray == null) return;
    final bool paused = _s.activityTracker.isPaused;
    unawaited(tray.refreshTrackingState(paused));

    final String? app = _s.activityTracker.currentAppDisplayName;
    final String tip = paused
        ? 'PetLife 桌宠 · 已暂停记录'
        : (app == null ? 'PetLife 桌宠' : 'PetLife 桌宠 · 当前：$app');
    if (tip != _lastTrayTip) {
      _lastTrayTip = tip;
      unawaited(tray.setTooltipText(tip));
    }
  }

  String? _lastTrayTip;

  /// 暂停 / 恢复记录（托盘与桌宠右键菜单共用）。
  Future<void> toggleTracking() async {
    final bool paused = _s.activityTracker.isPaused;
    await _s.saveTrackingSettings(_s.activityTracker.settings.copyWith(paused: !paused));
    _syncTrayTrackingState();
  }

  /// 打开控制面板并定位到「使用统计」。
  Future<void> openUsageStats() async {
    await openPanel();
    _panelKey.currentState?.selectTab(ControlPanel.usageStatsTabIndex);
  }

  static _DesktopShellState? _shellRef;

  /// 供托盘调用：切换控制面板。
  static Future<void> togglePanel() async {
    final _DesktopShellState? state = _shellRef;
    if (state == null) return;
    final WindowsSurfaceMode mode = windowsSurfaceSession.mode;
    if (mode == WindowsSurfaceMode.panel) {
      await state.closePanel();
    } else if (mode == WindowsSurfaceMode.petFixedCanvas) {
      await state.openPanel();
    }
  }

  /// 进入控制面板（完整事务）。已在面板 / 过渡中 → 直接忽略
  /// （快速双击只允许**一次**切换）。
  /// 桌宠当前所在显示器的可用工作区（逻辑像素）。
  ///
  /// 用**桌宠屏幕矩形中心**（而不是窗口左上角）选显示器，这样副屏 / 负坐标屏
  /// 也能落对；拿不到显示器时退化为一个保守的默认工作区。
  Future<Rect> _workAreaForPetScreenAsync(Rect petScreenRect) async {
    final WheelDisplayArea? display =
        await _fixedWindowOps.displayForPoint(petScreenRect.center);
    return display?.rect ?? const Rect.fromLTWH(0, 0, 1920, 1040);
  }

  /// 桌宠屏幕矩形（固定画布态：画布窗口矩形 + petAnchor）。
  Future<Rect> _petScreenRectNow() async {
    final Size pet = petLogicalSize;
    final Offset? anchor = fixedCanvasAnchor.anchor;
    if (anchor != null) {
      try {
        final Rect win = await _fixedWindowOps.currentBounds();
        return Rect.fromLTWH(win.left + anchor.dx, win.top + anchor.dy, pet.width, pet.height);
      } catch (e, st) {
        Loggers.window.warning('读取画布窗口矩形失败（将用保存值兜底）', e, st);
      }
    }
    final Offset petScreen =
        _savedPetScreenPosition() ?? await _defaultPetScreenPosition(pet);
    return Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
  }

  Future<void> openPanel() async {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) return;
    // 面板尺寸必须先按**桌宠所在显示器**的 workArea 算好：
    // 事务里的尺寸校验（`sizedLikePanel`）用的是同一个值。
    final Rect petScreenRect = await _petScreenRectNow();
    final Rect workArea = await _workAreaForPetScreenAsync(petScreenRect);
    final Size panel = PanelLayout.sizeFor(workArea.size);
    _pendingPanelSize = panel;
    wheelGeometryJournal.record(
      'panel.layout.planned',
      fields: <String, Object?>{
        'petScreen': WheelGeometryJournal.formatRect(petScreenRect),
        'workArea': WheelGeometryJournal.formatRect(workArea),
        'panel': '${panel.width}x${panel.height}',
        'preferred': '${DesktopShell.panelSize.width}x${DesktopShell.panelSize.height}',
      },
    );
    final SurfaceTransitionResult result =
        await _surfaceController.enterPanel(panelSize: panel);
    if (!result.success && mounted) {
      Loggers.window.warning('进入控制面板事务未成功：${result.error}');
    }
  }

  /// 返回桌宠（完整事务）。
  Future<void> closePanel() async {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.panel) return;
    final SurfaceTransitionResult result = await _surfaceController.returnToPet();
    if (!result.success && mounted) {
      Loggers.window.warning('返回桌宠事务未成功：${result.error}');
    }
  }

  Future<void> _exitApp() async {
    try {
      // 退出 / 销毁窗口前先收起菜单并清除 Region（不留残留 Region / GDI 对象）。
      await _wheelProbeKey.currentState?.close();
      await _fixedProbeKey.currentState?.close();
      await _regionCoordinator.clear(
        owner: RegionOwner.panel,
        source: 'shell.exitApp',
      );
      await _s.windowController.setPreventClose(false);
      await _s.shutdown();
    } catch (e, st) {
      ErrorHandler.record('exit', e, st);
    }
    // destroy 必须在 shutdown 之后，否则窗口先没了。
    await _s.windowController.destroy();
  }

  // ---------------------------------------------------------------------------
  // SurfaceTransactionHost（形态事务的真实副作用）
  // ---------------------------------------------------------------------------

  @override
  Future<void> closeWheelMenu() async {
    await _wheelProbeKey.currentState?.close();
    // 固定画布的左键轮盘也必须收起（它同样持有 Region）。
    await _fixedProbeKey.currentState?.close();
  }

  @override
  Future<void> dismissContextMenuAndWait() => contextMenuBridge.dismissAndWait();

  @override
  Future<void> suspendFixedCanvas() async {
    // 4) 几何所有权切到 panel：禁止一切桌宠 / 素材尺寸写窗口。
    wheelSurfaceGeometry.change(
      WindowsSurfaceGeometryOwner.panel,
      source: 'shell.enterPanel',
    );
    // 7) 禁用固定画布：停用探针 + 清除 petAnchor 换算。
    // 清除锚点之前先记下"桌宠锚点屏幕位置"，返回时据此把桌宠放回原位。
    final Offset? anchor = fixedCanvasAnchor.anchor;
    if (anchor != null) {
      try {
        final Rect win = await _fixedWindowOps.currentBounds();
        _panelReturnPetScreen = Offset(win.left + anchor.dx, win.top + anchor.dy);
      } catch (e, st) {
        Loggers.window.warning('进入面板前读取桌宠位置失败（将用保存值兜底）', e, st);
      }
    }
    final FixedCanvasProbeState? probe = _fixedProbeKey.currentState;
    if (probe != null) {
      await probe.releaseFixedCanvas();
    } else {
      await _regionCoordinator.clear(
        owner: RegionOwner.panelTransition,
        source: 'shell.suspendFixedCanvas',
      );
      fixedCanvasAnchor.clear();
    }
  }

  @override
  Future<void> invalidateAllRegionTransactions(String reason) async {
    // 面板切换必须让 contextMenu 与 wheel 的旧 Region 事务**全部失效**。
    _regionCoordinator.invalidateAll(source: reason);
  }

  @override
  Future<bool> clearRegionForPanel() async {
    final RegionCommitOutcome outcome = await _regionCoordinator.clear(
      owner: RegionOwner.panelTransition,
      source: 'shell.clearRegionForPanel',
    );
    return outcome.success;
  }

  @override
  Future<PhysicalRect?> readRegionBoundingBox() =>
      _regionCoordinator.regionBoundingBox();

  @override
  Future<void> setWindowVisible(bool visible) => _s.windowController.setVisible(visible);

  @override
  Future<void> restorePanelWindowAttributes() async {
    // ignoreMouseEvents=false（可点击）/ lockPosition=false（可拖动标题栏区域）。
    await _s.windowController.applySettings(
      _s.settings.settings.copyWith(ignoreMouseEvents: false, lockPosition: false),
    );
    await _s.windowController.setResizable(true);
  }

  @override
  Future<Rect> commitPanelBounds() async {
    // 真机回归 #3：面板左上角**绝不能**继承固定画布 HWND 的左上角。
    //
    // 旧实现用 `windowController.position()`（= 当前窗口左上角 = 画布左上角
    // = petScreen - petAnchor）直接当面板位置，于是面板整体偏离桌宠一个 petAnchor，
    // 再被夹取推到屏幕角落。
    //
    // 正确口径：用**进入前的桌宠屏幕矩形**选显示器 → 该显示器 workArea →
    // 适配尺寸（进入前已算好并缓存）→ 在 workArea 居中 → 一次提交。
    final Size pet = petLogicalSize;
    final Offset petScreen = _panelReturnPetScreen ??
        _savedPetScreenPosition() ??
        await _defaultPetScreenPosition(pet);
    final Rect petScreenRect =
        Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
    final Rect workArea = await _workAreaForPetScreenAsync(petScreenRect);
    final Size size = _pendingPanelSize ?? PanelLayout.sizeFor(workArea.size);
    final Rect target = PanelLayout.centeredIn(workArea, size);
    // 唯一的矩形提交点：一次 SetWindowPos。
    await _fixedWindowOps.commitBounds(target);
    wheelGeometryJournal.record(
      'panel.bounds.committed',
      fields: <String, Object?>{
        'rect': WheelGeometryJournal.formatRect(target),
        'workArea': WheelGeometryJournal.formatRect(workArea),
        'petScreen': WheelGeometryJournal.formatRect(petScreenRect),
        'size': '${size.width}x${size.height}',
      },
    );
    return target;
  }

  @override
  Future<void> showPanelWidgetAndSettle() async {
    _panelWidgetActive = true;
    if (mounted) setState(() {});
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<bool> isBoundsFullyVisible(Rect bounds) async {
    final WheelDisplayArea? display =
        await _fixedWindowOps.displayForPoint(bounds.center);
    final Rect area = display?.rect ?? const Rect.fromLTWH(0, 0, 1920, 1040);
    const double tolerance = 1.5;
    return bounds.left >= area.left - tolerance &&
        bounds.top >= area.top - tolerance &&
        bounds.right <= area.right + tolerance &&
        bounds.bottom <= area.bottom + tolerance;
  }

  @override
  Future<Rect> readWindowBounds() => _fixedWindowOps.currentBounds();

  @override
  Future<void> showWindowAndFocus() => _s.windowController.setVisible(true);

  @override
  Future<Rect> commitFixedCanvasBounds() async {
    final Size pet = petLogicalSize;
    final Offset? saved = _panelReturnPetScreen ?? _savedPetScreenPosition();
    final Offset petScreen = saved ?? await _defaultPetScreenPosition(pet);
    final WheelDisplayArea? display =
        await _fixedWindowOps.displayForPoint(petScreen);
    // 与探针同一口径：按「当前设置 + 当前显示器工作区」规划画布
    // （屏幕放不下时由 WheelCanvasPlanner 自动压缩轮盘，绝不建超大常驻窗口）。
    final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
      petSize: pet,
      workArea: display == null
          ? const Size(1920, 1080)
          : Size(display.width, display.height),
      settings: _s.settings.settings.wheelLayoutSettings,
      spec: WheelCanvasBridge.spec(),
      maxItemCount: MenuCatalog.maxItems,
    );
    final Offset anchor = plan.petAnchor;
    _pendingAnchor = anchor;
    _pendingPetSize = pet;

    final Rect rect = FixedCanvasGeometry.canvasWindowRect(
      petScreenPosition: petScreen,
      petAnchor: anchor,
      canvas: plan.canvasSize,
    );
    final Rect safe = _clampCanvasRect(rect, display);
    // 唯一的矩形提交点 = 一次 SetWindowPos。
    await _fixedWindowOps.commitBounds(safe);
    fixedCanvasAnchor.set(anchor, enabled: true);
    _pendingCanvasRect = safe;
    return safe;
  }

  @override
  Future<void> showPetWidgetAndSettle() async {
    _panelWidgetActive = false;
    if (mounted) setState(() {});
    // 等两帧：桌宠 widget 挂载 + 固定画布探针布局完成。
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<bool> applyPetOnlyRegion() async {
    final FixedCanvasProbeState? probe = _fixedProbeKey.currentState;
    final Rect? rect = _pendingCanvasRect;
    if (probe == null || rect == null) return false;
    // 采用已提交的画布矩形：只应用"仅桌宠" Region，绝不再次提交窗口矩形。
    return probe.adoptCommittedCanvas(
      canvasRect: rect,
      petAnchor: _pendingAnchor,
      petSize: _pendingPetSize,
    );
  }

  @override
  Future<Rect> readPetScreenRect() async {
    final Rect win = await _fixedWindowOps.currentBounds();
    return FixedCanvasGeometry.petScreenRect(
      canvasWindowRect: win,
      petAnchor: _pendingAnchor,
      petSize: _pendingPetSize,
    );
  }

  @override
  Future<void> rollbackToRectangularPet(String reason) async {
    // 绝不留下半个面板 / 大透明窗口：清 Region + 复位锚点 + 缩回桌宠尺寸。
    try {
      await _regionCoordinator.clear(
        owner: RegionOwner.panelTransition,
        source: 'shell.rollbackToRectangularPet',
      );
      fixedCanvasAnchor.clear();
      await _s.windowController.setResizable(false);
      await _s.windowController.resizeTo(petLogicalSize);
      _panelWidgetActive = false;
      if (mounted) setState(() {});
      await _s.windowController.setVisible(true);
    } catch (e, st) {
      Loggers.window.warning('回滚桌宠小窗口失败（$reason）', e, st);
    }
  }

  @override
  Future<void> showStatusMessage(String message) async {
    _fixedProbeKey.currentState?.showStatusMessage(message);
  }

  @override
  Size get petLogicalSize {
    final double scale = _s.settings.settings.scale;
    final Size content = _s.renderer.contentSize ?? BuiltinPlaceholder.size;
    return Size(content.width * scale, content.height * scale);
  }

  @override
  Size get fixedCanvasSize => _canvasConfig.canvasSize;

  // ---------------------------------------------------------------------------
  // 几何助手
  // ---------------------------------------------------------------------------

  /// 画布矩形夹取到可见显示器（保证至少 48px 可见；支持负坐标）。
  Rect _clampCanvasRect(Rect rect, WheelDisplayArea? display) {
    if (display == null) return rect;
    const double minVisible = 48;
    final double overlapX = _overlap(rect.left, rect.right, display.left, display.right);
    final double overlapY = _overlap(rect.top, rect.bottom, display.top, display.bottom);
    if (overlapX >= minVisible && overlapY >= minVisible) return rect;
    final double x = (display.right - rect.width - 24)
        .clamp(display.left, display.right - rect.width);
    final double y = (display.bottom - rect.height - 96)
        .clamp(display.top, display.bottom - rect.height);
    return Rect.fromLTWH(x, y, rect.width, rect.height);
  }

  double _overlap(double a1, double a2, double b1, double b2) {
    final double start = a1 > b1 ? a1 : b1;
    final double end = a2 < b2 ? a2 : b2;
    return end - start;
  }

  /// 已保存的位置 —— **语义由 `windowPositionSchema` 决定**。
  ///
  /// 只有 v2 才是 `petScreenPosition`；v1 / 无版本必须交给 `PetPositionResolver`
  /// 迁移（不可直接当人物位置使用）。
  Offset? _savedPetScreenPosition() {
    final AppSettings settings = _s.settings.settings;
    if (settings.windowX == null || settings.windowY == null) return null;
    if (!WindowPositionSchema.isPetScreenPosition(settings.windowPositionSchema)) {
      return null; // 旧语义 / 无版本 → 视为"没有可用的 v2 位置"
    }
    return Offset(settings.windowX!, settings.windowY!);
  }

  /// v1 数据迁移用：旧值写入时的**窗口尺寸**（= 素材尺寸 × 缩放）。
  ///
  /// v1 时代没有固定画布，窗口矩形就是人物矩形。因此当"旧窗口尺寸 ≈ 人物可见
  /// 尺寸"时 v1 可安全转换；否则解析器判定语义不确定并回退默认位置（不猜测）。
  ///
  /// 已迁移的 v2 会返回 null（无需迁移）。
  ///
  /// 注意：v1 的窗口尺寸**就是**当前人物尺寸（`petLogicalSize`），因为两者都由
  /// 同一份缩放设置推出；显式建模成方法是为了让"转换前提"在代码里可见。
  Size? legacyWindowSizeForMigration(AppSettings settings) {
    if (WindowPositionSchema.isPetScreenPosition(settings.windowPositionSchema)) {
      return null;
    }
    return petLogicalSize;
  }

  /// 主显示器（位置解析在保存值不可见时的回退目标）。
  Future<WheelDisplayArea?> _primaryDisplay() async {
    final List<WheelDisplayArea> all = await _fixedWindowOps.displays();
    if (all.isEmpty) return null;
    for (final WheelDisplayArea d in all) {
      if (d.isPrimary) return d;
    }
    return all.first;
  }

  /// 主显示器上的默认人物位置（右下角 + 安全边距）。
  Future<Offset> _defaultPetScreenPosition(Size pet) async {
    final WheelDisplayArea? display = await _primaryDisplay();
    if (display == null) return const Offset(200, 200);
    return PetPositionResolver.defaultPetScreenPosition(area: display, petSize: pet);
  }

  /// 托盘「把桌宠移回屏幕右下角」（用户 §5）。
  ///
  /// **不再**直接 `moveTo(0, 0)` 或只挪 HWND —— 那样在固定画布模式下只会把整块
  /// 画布窗口挪走、人物仍可能在屏外，而且不会写回 v2 位置。
  ///
  /// 正确流程：算默认 `petScreenPosition` → 固定画布**安全重建事务** → 保持隐藏 →
  /// 提交 canvas bounds → 应用 pet-only Region → 校验人物可见 → 写 v2 → 最后 show。
  Future<void> resetPetPosition() async {
    final Size pet = petLogicalSize;

    wheelGeometryJournal.record(
      'tray.reset_position',
      fields: <String, Object?>{
        'mode': windowsSurfaceSession.mode.wireName,
        'reason': 'reset_to_primary_corner',
      },
    );

    // 面板态 / 过渡态下先回到桌宠态。
    if (windowsSurfaceSession.mode == WindowsSurfaceMode.panel) {
      await closePanel();
    } else if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) {
      _fixedProbeKey.currentState
          ?.showStatusMessage('窗口正在切换形态，请稍后再试');
      return;
    }

    final WheelDisplayArea? primary = await _primaryDisplay();
    if (primary == null) {
      _fixedProbeKey.currentState?.showStatusMessage('未检测到可用显示器，无法重置位置');
      return;
    }
    final Offset target =
        PetPositionResolver.defaultPetScreenPosition(area: primary, petSize: pet);

    // 1) 写 v2 位置（**先**写，重建事务会读到它）。
    await _s.settings.rememberWindowPosition(target.dx, target.dy);
    // 2) 画布重建事务（隐藏 → 提交 bounds → Region → 校验 → show）。
    final FixedCanvasProbeState? probe = _fixedProbeKey.currentState;
    if (probe == null) {
      await _s.windowController.moveTo(target.dx, target.dy);
      await _s.windowController.setVisible(true);
      return;
    }
    final CanvasRebuildOutcome outcome = await probe.rebuildFixedCanvasAt(
      target,
      reason: 'tray.reset_position',
    );
    if (outcome != CanvasRebuildOutcome.applied) {
      // superseded 不会出现在这条路径上（托盘重置无并发设置变更）：
      // 非 applied 一律按失败处理，走安全回退。
      await _startupSafeFallback('tray_reset_failed');
      return;
    }
    await _s.windowController.setVisible(true);
    wheelGeometryJournal.record(
      'tray.reset_position.done',
      fields: <String, Object?>{...probe.startupShowEvidence()},
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_panelWidgetActive) {
      return _PetWindowMode(
        services: _s,
        onOpenPanel: openPanel,
        onExit: _exitApp,
        onToggleTracking: toggleTracking,
        onOpenUsageStats: openUsageStats,
        wheelProbeKey: _wheelProbeKey,
        fixedProbeKey: _fixedProbeKey,
        regionCoordinator: _regionCoordinator,
        menuOpen: _wheelMenuOpen,
        onMenuOpenChanged: (bool open) {
          if (_wheelMenuOpen != open) {
            setState(() => _wheelMenuOpen = open);
          }
        },
        menuActionExecutor: _menuActionExecutor,
        applyWheelSetting: _applyWheelSetting,
        applyWheelTheme: (String themeId) => _s.settings.setWheelThemeId(themeId),
        readWheelSetting: _readWheelSetting,
      );
    }
    return ControlPanel(
      key: _panelKey,
      services: _s,
      onClose: closePanel,
      onExit: _exitApp,
    );
  }
}

/// 桌宠模式：整个窗口只有立绘（外加探针菜单）。
///
/// 两种路线（由 [PetWindowProbeFlags] 决定）：
/// * **固定画布 + Region（新，默认）**：窗口物理矩形固定，开合菜单只改 Region；
/// * **动态 setBounds（旧，默认关闭，已标记 rejected）**：保留代码 / 日志 / 测试。
class _PetWindowMode extends StatelessWidget {
  const _PetWindowMode({
    required this.services,
    required this.onOpenPanel,
    required this.onExit,
    required this.onToggleTracking,
    required this.onOpenUsageStats,
    required this.wheelProbeKey,
    required this.fixedProbeKey,
    required this.regionCoordinator,
    required this.menuOpen,
    required this.onMenuOpenChanged,
    required this.menuActionExecutor,
    required this.applyWheelSetting,
    required this.applyWheelTheme,
    required this.readWheelSetting,
  });

  final AppServices services;
  final Future<void> Function() onOpenPanel;
  final Future<void> Function() onExit;
  final Future<void> Function() onToggleTracking;
  final Future<void> Function() onOpenUsageStats;

  /// 旧轮盘几何探针句柄（默认关闭）。
  final GlobalKey<WheelGeometryProbeState> wheelProbeKey;

  /// 固定画布探针句柄。
  final GlobalKey<FixedCanvasProbeState> fixedProbeKey;

  /// 窗口 Region 的唯一协调器（由外壳装配后向下传）。
  final RegionCoordinator regionCoordinator;

  /// 菜单是否打开（打开期间暂停"窗口跟随素材尺寸"）。
  final bool menuOpen;

  final ValueChanged<bool> onMenuOpenChanged;

  /// **增量 C1**：正式动作执行器（由外壳装配，含业务桥）。
  final WindowsMenuActionExecutor menuActionExecutor;

  /// 写入轮盘几何设置（调整层用）。
  final Future<void> Function(WheelAdjustmentKind kind, double value) applyWheelSetting;

  /// 即时切换轮盘主题（只改颜色）。
  final Future<void> Function(String themeId) applyWheelTheme;

  /// 读取轮盘几何设置当前值。
  final double Function(WheelAdjustmentKind kind) readWheelSetting;

  /// 只有稳定的桌宠态才允许交互 / 改 Region。
  bool get _interactive =>
      windowsSurfaceSession.mode == WindowsSurfaceMode.petFixedCanvas;

  /// 当前桌宠逻辑尺寸（素材尺寸 × 缩放；无素材时用内置占位图尺寸）。
  Size _petSize() {
    final double scale = services.settings.settings.scale;
    final Size content = services.renderer.contentSize ?? BuiltinPlaceholder.size;
    return Size(content.width * scale, content.height * scale);
  }

  @override
  Widget build(BuildContext context) {
    final bool useFixed = PetWindowProbeFlags.fixedCanvasRegionProbeEnabled;
    final bool useWheel = PetWindowProbeFlags.dynamicSetBoundsProbeEnabled;

    // 固定画布模式下窗口物理矩形固定，绝不由素材尺寸驱动窗口。
    final bool manageWindowSize = useFixed ? false : !menuOpen;

    final Widget pet = PetViewWrapper(
      services: services,
      onOpenPanel: onOpenPanel,
      onExit: onExit,
      onToggleTracking: onToggleTracking,
      onOpenUsageStats: onOpenUsageStats,
      // 单击桌宠打开 / 关闭**正式轮盘**（唯一入口 `toggleFormalWheel`）。
      //
      // 真机回归 #1 的接线纪律（本轮收紧）：
      //   * 只允许调用固定画布探针的 `toggleFormalWheel()` —— 它内部走
      //     `WheelInteractionGate` + `WheelMenuController` + `RegionCoordinator`；
      //   * **禁止**再落到六色块诊断菜单（那是 `_diagnosticMenuEnabled` 下的
      //     替代渲染，不是左键入口）；
      //   * **禁止**落到 `dynamicSetBoundsProbeEnabled`（已标记 rejected 的旧探针）；
      //   * **禁止**只改诊断状态、或直接裸写 Region。
      onPetTap: () {
        wheelGeometryJournal.record(
          'desktop.pet_tap.received',
          fields: <String, Object?>{
            'mode': windowsSurfaceSession.mode.wireName,
            'interactive': _interactive,
            'fixedCanvas': useFixed,
          },
        );
        if (!_interactive) return;
        if (!useFixed) {
          // 非固定画布（旧模式）下左键不开轮盘：正式轮盘只存在于固定画布宿主里。
          wheelGeometryJournal.record(
            'wheel.toggle.rejected',
            fields: <String, Object?>{'reason': 'not_fixed_canvas'},
          );
          return;
        }
        unawaited(fixedProbeKey.currentState?.toggleFormalWheel());
      },
      manageWindowSize: manageWindowSize,
      // 右键菜单（Overlay）的 Region 事务端口：打开前把 Region 切成
      // **pet ∪ 实际菜单矩形**，关闭后**按凭据**恢复"仅桌宠"
      // （过期即丢弃，绝不覆盖左键轮盘的 Region）。
      contextMenuRegion: useFixed
          ? _FixedProbeContextMenuPort(regionCoordinator, fixedProbeKey)
          : null,
      // 右键菜单的高度上限必须按**鼠标所在显示器**的 workArea 算。
      displayForPoint: useFixed
          ? (Offset global) => const WindowsFixedCanvasWindowOps().displayForPoint(global)
          : null,
    );

    if (useFixed) {
      return Material(
        type: MaterialType.transparency,
        child: FixedCanvasProbe(
          key: fixedProbeKey,
          windowOps: const WindowsFixedCanvasWindowOps(),
          coordinator: regionCoordinator,
          petSize: _petSize,
          // 位置的**唯一语义** = petScreenPosition（v2），由 `PetPositionResolver` 解析。
          // 这里把"原始值 + 版本 + 旧窗口尺寸"一并交出，让解析器决定是否迁移。
          savedWindowPosition: () {
            final AppSettings s = services.settings.settings;
            return (
              x: s.windowX,
              y: s.windowY,
              schema: s.windowPositionSchema,
              // v1 数据迁移用：旧值写入时的窗口尺寸 == 素材尺寸 × 缩放。
              legacyWindowSize: WindowPositionSchema.isPetScreenPosition(
                s.windowPositionSchema,
              )
                  ? null
                  : _petSize(),
            );
          },
          // 迁移 / 修正后**立刻**写回 v2，后续不再读取旧值。
          persistPetScreenPosition: (Offset petScreen, {required int schemaVersion}) =>
              services.settings.rememberWindowPositionWithSchema(
                petScreen.dx,
                petScreen.dy,
                schemaVersion: schemaVersion,
              ),
          isMousePassthrough: () => services.settings.settings.ignoreMouseEvents,
          // C1.1：人物**视觉**边界（alpha 包围盒）—— 缺口 / 方向 / 画布规划的
          // 唯一输入。渲染器在帧推进时逐帧测量并取稳定并集。
          petVisualBounds: () => services.renderer.visualBounds,
          ensurePetVisualBounds: () => services.renderer.ensureVisualBounds(),
          // 轮盘几何 / 主题：全部来自持久化设置（增量 B）。
          wheelSettings: () => services.settings.settings.wheelLayoutSettings,
          wheelTheme: () => services.settings.settings.wheelTheme,
          // 选中项实时信息：增量 B **不接业务**，因此留空（渲染层会跳过该行文字）。
          wheelInfoProvider: null,
          // 增量 C1：正式动作派发（窗口级 + 业务动作，全部走同一执行器）。
          wheelActionExecutor: menuActionExecutor,
          applyWheelSetting: applyWheelSetting,
          applyWheelTheme: applyWheelTheme,
          readWheelSetting: readWheelSetting,
          onOpenControlPanel: onOpenPanel,
          onOpenChanged: onMenuOpenChanged,
          // 缩放等设置变化时重新居中画布（画布尺寸不变，只重设 petAnchor + Region）。
          reestablishOn: services.settings,
          child: pet,
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: useWheel
          ? WheelGeometryProbe(
              key: wheelProbeKey,
              services: services,
              onOpenControlPanel: onOpenPanel,
              onOpenChanged: onMenuOpenChanged,
              child: pet,
            )
          : pet,
    );
  }
}

/// 把固定画布探针的 Region 事务暴露给右键菜单（owner = contextMenu）。
///
/// 它是"右键菜单"与 `RegionCoordinator` 之间的唯一桥：菜单只拿到
/// "能否打开 / 打开并给我凭据 / 按凭据恢复"三件事，拿不到任何原生 Region 能力。
class _FixedProbeContextMenuPort implements ContextMenuRegionPort {
  _FixedProbeContextMenuPort(this._coordinator, this._probeKey);

  final RegionCoordinator _coordinator;
  final GlobalKey<FixedCanvasProbeState> _probeKey;

  @override
  bool get canOpenContextMenu {
    // 优先级 wheel > contextMenu：轮盘持有 Region 时不弹右键菜单。
    if (_coordinator.owner == RegionOwner.wheel &&
        !_coordinator.isDesiredCleared) {
      return false;
    }
    // 面板侧独占 Region：也不弹。
    if (_coordinator.owner.isPanelLike) return false;
    return true;
  }

  @override
  Future<RegionLease> expandTo(Rect menuLocalRect) async {
    final FixedCanvasProbeState? probe = _probeKey.currentState;
    if (probe == null) return const RegionLease.none();
    return probe.expandRegionForOverlay(menuLocalRect);
  }

  @override
  Future<bool> restore(RegionLease lease) async {
    final FixedCanvasProbeState? probe = _probeKey.currentState;
    if (probe == null || !lease.isValid) return false;
    await probe.restorePetOnlyRegionNow(lease);
    // 只有协调器真的把 owner 交回 pet 才算"恢复成功"。
    return _coordinator.owner == RegionOwner.pet &&
        !_coordinator.isDesiredCleared;
  }
}
