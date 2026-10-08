/// 固定画布 + 窗口 Region 探针（本轮新方向，**仅探针**）。
///
/// 目标：在 Windows 真机上验证
/// "**一个固定物理矩形的 HWND + 只改窗口 Region**"这条链路，**不接**真实
/// P3P 轮盘菜单、不接任何业务动作。右键菜单仍是回退入口。
///
/// 关键不变量（硬约束）
/// --------------------
/// * 进入桌宠模式时**先**建立固定画布（一次 `commitBounds` = 一次 `SetWindowPos`）、
///   应用"仅桌宠"Region，**最后**才 show()；
/// * 打开 / 关闭菜单**只改 Region 与菜单 widget 可见性**，
///   绝不 `commitBounds` / `setSize` / `setPosition`，绝不改画布尺寸或桌宠局部偏移；
/// * **所有 Region 写入都经 `RegionCoordinator`**（owner / generation / 事务代际），
///   本文件不再直接调用原生 Region 方法；
/// * 左键入口由 [WheelInteractionGate] 四态机（closed / opening / open / closing）
///   把守：只有 `closed` 才能 `beginOpen`，且**在首个 await 之前同步**进入 `opening`；
/// * 桌宠绘制层**始终在菜单层之上**；
/// * 硬断言：`windowRectBeforeOpen == windowRectAfterOpen == windowRectAfterClose`，
///   且桌宠屏幕矩形在开合前后误差 ≤ 1px；任一违反 → 探针判失败并醒目提示。
/// * Region 应用失败 → **立即回退**旧的"小窗口桌宠"（清 Region + 缩回桌宠矩形），
///   绝不留下大块透明遮挡。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../character/pet_visual_bounds.dart';
import '../../menu/context_menu_anchor.dart' show contextMenuBridge;
import '../../menu/fixed_canvas_contract.dart';
import '../../menu/fixed_canvas_geometry.dart';
import '../../menu/menu_action_request.dart';
import '../../menu/menu_contract.dart'
    show
        MenuCatalog,
        MenuExecutionResult,
        MenuExecutionStatus,
        MenuNavigationIds,
        MenuNode;
import '../../menu/pet_position_resolver.dart';
import '../../menu/region_coordinator.dart';
import '../../menu/region_owner.dart';
import '../../menu/wheel_action_dispatch.dart' show WheelFeedbackKind;
import '../../menu/wheel_adjustment_layer.dart';
import '../../menu/wheel_animator.dart'
    show WheelAnimationKind, WheelAnimationTimeline;
import '../../menu/wheel_canvas_bridge.dart';
import '../../menu/wheel_canvas_plan.dart'
    show WheelCanvasPlan, WheelCanvasPlanner, wheelCanvasFit;
import '../../menu/wheel_expansion_side.dart';
import '../../menu/wheel_geometry.dart' show WheelDisplayArea;
import '../../menu/wheel_geometry_ownership.dart'
    show wheelGeometryJournal, WheelGeometryJournal;
import '../../menu/wheel_interaction_state.dart';
import '../../menu/wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelExpandDirection,
        WheelExpansionResolution,
        WheelMenuEnvelope,
        WheelMenuLayout,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect,
        WheelVerticalMode;
import '../../menu/wheel_menu_state.dart' show WheelMenuPhase;
import '../../menu/wheel_placement.dart'
    show WheelPlacement, WheelVerticalPlacement;
import '../../menu/wheel_placement_solver.dart'
    show WheelPlacementCandidate, WheelPlacementSolution, WheelPlacementSolver;
import '../../menu/wheel_space_pipeline.dart'
    show WheelCoordinatePipeline, WheelRevisionCounter, WheelSpaceSnapshot;
import '../../menu/wheel_theme.dart' show WheelMenuTheme, WheelMenuThemes, WheelThemeIds;
import '../../platform/windows/windows_menu_action_executor.dart';
import '../../menu/windows_surface_mode.dart';
import 'fixed_canvas_diagnostics_flags.dart' show FixedCanvasDiagnosticsFlags;
import 'wheel_menu_view.dart' show WheelMenuController, WheelMenuView;

/// 画布重建事务的**三种**结局。
///
/// 为什么必须是三态而不是 bool（真实缺陷回归）
/// ----------------------------------------
/// 连续调整设置（例如连点三次"增大"）会产生多个重建请求。被 **更新的设置修订号**
/// 取代的那几次请求什么都没做 —— 这是**正常**的，设置值本身已经写入且有效。
/// 若把它们当作 `failed`，调用方会执行"回滚到旧设置"，于是：
/// 用户看到的三次增大只剩两次、甚至回滚成一个早已过期的值。
enum CanvasRebuildOutcome {
  /// 真正重建成功（Region + 回读校验都通过）。
  applied,

  /// 被更新的修订号 / 在飞的重建取代：**不做任何事**，由最新那次负责提交。
  /// 设置值保持有效，**绝不回滚**。
  superseded,

  /// 真失败（Region 未提交 / 回读校验不过 / 异常）→ 调用方回滚设置。
  failed,
}

/// 探针状态（供外壳通过 GlobalKey 调用 `prepareFixedCanvas` / `toggle` / `close`）。
class FixedCanvasProbeState extends State<FixedCanvasProbe> {
  final GlobalKey _menuKey = GlobalKey();

  Size _canvas = const Size(0, 0);

  /// 桌宠在画布内的**固定**锚点（局部逻辑坐标）。
  Offset _petAnchor = Offset.zero;
  Size _petSize = Size.zero;

  /// 固定画布窗口矩形（逻辑像素）——即 HWND 的物理矩形。
  Rect? _canvasRect;

  /// 菜单是否**可见**（渲染开关）——与 [_gate] 的 `open` 态保持一致。
  bool _menuOpen = false;
  Rect? _menuLocalRect;
  bool? _menuOnRight;
  bool _regionVisualization = false;
  bool _fallback = false;
  String? _message;
  Timer? _messageTimer;

  /// 轮盘反馈条（"将在增量 C 接入"）的自动消失计时。
  Timer? _feedbackTimer;

  // --- 正式 P3P 轮盘（增量 B）---

  /// 轮盘控制器（纯逻辑 + ChangeNotifier）；未打开时为 null。
  WheelMenuController? _wheel;

  /// 本次打开的信封（窗口 + 中心 + 缺口）；关层 / 换层都复用它，**绝不改窗口**。
  WheelMenuEnvelope? _wheelEnvelope;

  // --- 固定画布计划（增量 B 修正：按「当前设置 + 当前工作区」算）---

  /// 最近一次**有效**的画布计划（重建失败时回退到它）。
  WheelCanvasPlan? _canvasPlanCurrent;

  /// 生成 [_canvasPlanCurrent] 时用的设置 / 桌宠尺寸 / 工作区（判"是否需要重建"）。
  WheelMenuLayoutSettings? _planSettings;
  Size? _planPetSize;
  Size? _planWorkArea;

  /// 重建事务是否进行中（同一时刻只允许一个）。
  bool _rebuilding = false;

  /// 成功完成的画布重建次数（验收「设置变化只重建一次窗口」）。
  int _canvasRebuildCount = 0;

  /// 重建事务连续失败次数（>0 表示走了回退路径）。
  int _canvasRebuildFailures = 0;

  /// 最近一次重建后的桌宠屏幕锚点误差（px，验收用）。
  double? _lastRebuildAnchorErrorPx;

  /// 最近一次重建是否发生了画布位置夹取。
  bool _lastRebuildClamped = false;

  // --- 启动位置语义（真机回归修复）---

  /// 启动时解析到的位置结果（诊断 / show 证据）。
  PetPositionResolution? _startupTarget;

  /// 启动时**回读**到的人物屏幕矩形。
  Rect? _startupActualPetScreen;

  /// 启动时实测的人物可见面积比例。
  double? _startupVisibleRatio;

  /// 上一次的展开方向 / 竖直模式（重开时保持稳定，减少"左右横跳"）。
  WheelExpandDirection? _lastDirection;
  WheelVerticalMode? _lastVerticalMode;

  // --- 方向契约（真机回归：左右展开完全反向）---

  /// 本次/上次采用的**唯一方向语义**（菜单像素在哪一侧）。
  WheelExpansionSide? _lastExpansionSide;

  /// 上一次判定时人物的屏幕中心 X（滞回按"位移"判，不按"越过中线"判）。
  double? _lastPetCenterX;

  /// 最近一次方向不变量检查结果（诊断 / 测试）。
  WheelDirectionInvariant? _directionInvariant;

  // --- 增量 C1：动作派发 / 幂等 / 设置修订 ---

  /// 幂等账本（防"同一次确认被派发两次"与双击重复执行）。
  final MenuActionLedger _actionLedger = MenuActionLedger();

  /// 单调递增的动作请求号。
  int _actionRequestSeq = 0;

  /// 执行中（尚未返回）的动作 id —— 期间同名按钮禁用。
  final Set<String> _inFlightActions = <String>{};

  /// 派发时的层级（用于判断晚到结果是否已过期）。
  String? _actionLevelAtStart;

  /// 本次动作的起算时刻（需求 §14：结果日志要带 `elapsedMs`）。
  DateTime? _actionStartedAt;

  /// 设置修订号（连续加减只应用最新值，不依赖延时）。
  final WheelSettingRevision _settingRevision = WheelSettingRevision();

  // --- C1.1：统一坐标管线 + 拖动修订 ---

  /// 人物视觉边界（alpha 包围盒，**缓存**；未量到时为 [PetVisualBounds.full]）。
  PetVisualBounds _petVisualBounds = PetVisualBounds.full;

  /// 本次打开用的**空间快照**（画布几何的唯一事实；关闭时置 null）。
  WheelSpaceSnapshot? _space;

  /// 本次打开采用的**布局组合决议**（C1.1.1 §三 / §五；关闭时置 null）。
  ///
  /// 它同时给出：选中的组合（水平侧 + 纵向模式）、唯一信封、三种纵向候选的
  /// 溢出量、完整视觉包围盒与画布所需矩形 —— 下游（Painter / HitTest / Region）
  /// 只消费它产出的 [WheelSpaceSnapshot]，**不得**再自行判断方向。
  WheelPlacementSolution? _placementSolution;

  /// 上一次采用的布局组合（**仅诊断**：不参与本次选择，见 §三 / §七）。
  WheelPlacement? _lastPlacement;

  /// 位置修订号（拖动结束 / 位置写入时自增）。
  final WheelRevisionCounter _positionRevision = WheelRevisionCounter();

  /// 几何修订号（设置 / 人物尺寸 / 显示器 / 视觉边界变化时自增）。
  final WheelRevisionCounter _geometryRevision = WheelRevisionCounter();

  /// 表面代际（面板 ↔ 桌宠切换时自增）。
  final WheelRevisionCounter _surfaceGeneration = WheelRevisionCounter();

  /// 最近一次打开用的快照（诊断 / 测试）。
  WheelSpaceSnapshot? get spaceForTest => _space;

  // ---------------------------------------------------------------------------
  // C1.1.1 诊断钩子：布局组合决议（**只读**）
  // ---------------------------------------------------------------------------

  /// 最近一次打开采用的**布局组合决议**（未打开为 null）。
  @visibleForTesting
  WheelPlacementSolution? get placementSolutionForTest => _placementSolution;

  /// 当前采用的**纵向模式**（靠上 / 居中 / 靠下；未打开为 null）。
  @visibleForTesting
  WheelVerticalPlacement? get verticalPlacementForTest =>
      _placementSolution?.vertical;

  /// 当前采用的**布局组合**（未打开为 null）。
  @visibleForTesting
  WheelPlacement? get placementForTest => _placementSolution?.placement;

  /// 三种纵向候选的溢出量（诊断；未打开为 null）。
  ///
  /// 键是 `top` / `middle` / `bottom`，值是四侧溢出之和（px）。
  @visibleForTesting
  Map<String, double>? get candidateOverflowsForTest {
    final WheelPlacementSolution? s = _placementSolution;
    if (s == null) return null;
    return <String, double>{
      for (final WheelPlacementCandidate c in s.candidates)
        c.placement.vertical.wireName: c.overflowPx,
    };
  }

  /// 当前选中组合的**上侧溢出**（px；未打开为 null）。
  @visibleForTesting
  double? get topOverflowPxForTest => _placementSolution?.topOverflowPx;

  /// 当前选中组合的**下侧溢出**（px；未打开为 null）。
  @visibleForTesting
  double? get bottomOverflowPxForTest => _placementSolution?.bottomOverflowPx;

  /// 缺口中心相对**人物视觉中心**的误差（px；需求 §八 的 `anchorErrorPx`）。
  ///
  /// 用实际布局的缺口中心（画布局部 → 屏幕）与快照里的人物的视觉中心比较：
  /// 二者必须 ≤1px（否则缺口没绑在人物上）。未打开菜单时返回 null。
  @visibleForTesting
  double? get anchorErrorPxForTest {
    final WheelMenuLayout? layout = _wheel?.layout;
    final WheelSpaceSnapshot? space = _space;
    final Rect? menuLocal = _menuLocalRect;
    if (layout == null || space == null || menuLocal == null) return null;
    final Offset notchScreen = Offset(layout.notchCenterX, layout.notchCenterY) +
        menuLocal.topLeft +
        space.canvasWindowRect.topLeft;
    return (notchScreen - space.petVisualScreenRect.center).distance;
  }

  /// 全部绘制像素的屏幕包围盒（需求 §八 的 `selectedVisualBounds`；未打开为 null）。
  @visibleForTesting
  Rect? get selectedVisualBoundsForTest =>
      _placementSolution?.visualBoundsScreen;

  /// 轮盘所需画布的屏幕矩形（需求 §八 的 `canvasBounds`；未打开为 null）。
  @visibleForTesting
  Rect? get canvasBoundsForTest => _placementSolution?.canvasBoundsScreen;

  /// 布局组合决议的完整诊断字段（`wheel.placement.*`）。
  @visibleForTesting
  Map<String, Object?>? get placementDiagnosticsForTest =>
      _placementSolution?.diagnostics();

  /// 当前位置 / 几何 / 表面修订号（诊断）。
  int get positionRevision => _positionRevision.value;
  int get geometryRevision => _geometryRevision.value;
  int get surfaceGeneration => _surfaceGeneration.value;

  /// 人物视觉边界（诊断）。
  PetVisualBounds get petVisualBounds => _petVisualBounds;

  /// 六色块**诊断**测试菜单：默认关闭（正式轮盘取代了它）。
  bool _diagnosticMenuEnabled = false;

  /// 诊断开关面板（默认关闭；正式轮盘下不再遮挡菜单）。
  bool _diagnosticsPanelEnabled = false;

  /// 左键入口**四态状态机**（本轮新增；禁止用"第二次点击"当布局修复手段）。
  late final WheelInteractionGate _gate = WheelInteractionGate(tag: 'wheel');

  /// 当前右键菜单事务凭据（供条件式恢复使用）。
  RegionLease _contextMenuLease = const RegionLease.none();

  /// 当前左键轮盘事务凭据。
  RegionLease _wheelLease = const RegionLease.none();

  List<Rect> _regionRects = const <Rect>[];
  RegionApplyResult? _lastApply;
  PhysicalRect? _regionBox;
  int? _gdiCount;

  // --- 硬断言记录 ---
  Rect? _windowRectBeforeOpen;
  Rect? _windowRectAfterOpen;
  Rect? _windowRectAfterClose;
  Rect? _petScreenBefore;
  Rect? _petScreenAfterOpen;
  Rect? _petScreenAfterClose;
  List<String> _assertionFailures = const <String>[];

  RegionCoordinator get _coordinator => widget.coordinator;

  double get _dpr {
    try {
      return widget.windowOps.devicePixelRatio();
    } catch (_) {
      return 1.0;
    }
  }

  bool get isOpen => _gate.state == WheelInteractionState.open;

  /// 当前左键轮盘交互状态（验收要求"三者一致"的第三个观测点）。
  WheelInteractionState get wheelState => _gate.state;

  // ---------------------------------------------------------------------------
  // 正式轮盘（增量 B）：几何设置 / 主题 / 诊断
  // ---------------------------------------------------------------------------

  /// 轮盘几何设置（来自持久化，`WheelMenuLayoutSettings`）。
  WheelMenuLayoutSettings get wheelSettings => widget.wheelSettings();

  /// 当前轮盘主题（来自持久化）。
  WheelMenuTheme get wheelTheme => widget.wheelTheme();

  /// 轮盘尺寸参数（dp→逻辑像素，见 `WheelCanvasBridge.density`）。
  WheelMenuSpec get wheelSpec => WheelCanvasBridge.spec();

  /// 当前轮盘七态阶段名（诊断用，未打开时 `none`）。
  String get wheelPhaseName => _wheel?.phaseName ?? 'none';

  /// 当前层级 id（诊断用）。
  String get wheelLevelId => _wheel?.levelIdName ?? 'none';

  /// 当前高亮槽位（诊断用）。
  int? get wheelHighlightIndex => _wheel?.highlightIndex;

  /// 本次打开的信封（诊断 / 验收用：窗口矩形、缺口椭圆、实际缩放）。
  WheelMenuEnvelope? get wheelEnvelope => _wheelEnvelope;

  /// 轮盘窗口是否完整落在固定画布内（false = 会被画布裁切，属异常）。
  bool get wheelFitsCanvas {
    final WheelMenuEnvelope? envelope = _wheelEnvelope;
    if (envelope == null) return true;
    return WheelCanvasBridge.fitsInCanvas(windowRect: envelope.windowRect, canvas: _canvas);
  }

  // --- 固定画布计划（增量 B 修正）---

  /// 最近一次有效的画布计划（诊断 / 验收 / 设置页共用）。
  WheelCanvasPlan? get canvasPlan => _canvasPlanCurrent;

  /// 当前画布计划是否发生了**屏幕适配压缩**。
  bool get canvasCompressed => _canvasPlanCurrent?.compressed ?? false;

  /// 当前画布计划里的屏幕适配系数（1.0 = 未压缩）。
  double get canvasScreenFactor => _canvasPlanCurrent?.screenFactor ?? 1.0;

  /// 当前屏幕上轮盘**实际**显示的大小比例（0.50 ~ 2.50）。
  double get effectiveWheelScale =>
      _canvasPlanCurrent?.effectiveScale ?? wheelSettings.preferredScale;

  /// 成功完成的画布重建次数。
  int get canvasRebuildCount => _canvasRebuildCount;

  /// 画布重建连续失败次数（> 0 = 走了回退路径）。
  int get canvasRebuildFailures => _canvasRebuildFailures;

  /// 生成当前计划时用的显示器工作区。
  Size? get planWorkArea => _planWorkArea;

  /// 最近一次重建后的桌宠屏幕锚点误差（px）；从未重建为 null。
  double? get lastRebuildAnchorErrorPx => _lastRebuildAnchorErrorPx;

  /// 当前桌宠在画布内的锚点（测试用）。
  @visibleForTesting
  Offset get petAnchorForTest => _petAnchor;

  /// 当前展开动画进度（测试用；>0 表示画面真的开始绘制了）。
  @visibleForTesting
  double get wheelOpenProgressForTest => _wheel?.frame.openProgress ?? 0;

  /// 是否处于"回退小窗口"状态（测试用）。
  @visibleForTesting
  bool get fallbackForTest => _fallback;

  /// 当前调整层 / 菜单层级 id（测试用）。
  @visibleForTesting
  String? get wheelLevelIdForTest => _wheel?.levelIdName;

  /// 当前轮盘阶段名（测试用）。
  @visibleForTesting
  String get wheelPhaseNameForTest => _wheel?.phaseName ?? 'none';

  /// 直接派发一个动作（测试用；**等价于**用户在轮盘里确认该条目）。
  ///
  /// 走 [_confirmEntry]（而不是绕过它直接 `_dispatchAction`），
  /// 这样 `wheel.entry_confirmed` 日志与真实路径一致。
  @visibleForTesting
  Future<MenuExecutionResult> dispatchActionForTest(MenuNode node) =>
      _confirmEntry(node, _wheel?.highlightIndex ?? 0);

  /// 当前轮盘是否处于交互态（测试用）。
  @visibleForTesting
  bool get wheelInteractiveForTest => _wheel?.interactive ?? false;

  /// 启动解析后的**人物屏幕矩形**（测试用；未启动过为 null）。
  @visibleForTesting
  Rect? get petScreenRectForTest =>
      _startupActualPetScreen ??
      (_canvasRect == null
          ? null
          : Rect.fromLTWH(
              _canvasRect!.left + _petAnchor.dx,
              _canvasRect!.top + _petAnchor.dy,
              _petSize.width,
              _petSize.height,
            ));

  /// 启动时实测的人物可见面积比例（测试用）。
  @visibleForTesting
  double? get startupVisibleRatioForTest => _startupVisibleRatio;

  /// 当前轮盘窗口在**画布局部坐标**里的矩形（测试 / 标定用）。
  @visibleForTesting
  Rect? get wheelMenuLocalRectForTest => _menuLocalRect;

  // ---------------------------------------------------------------------------
  // C1.1 诊断钩子：把"几何链"的每一环都暴露出来（**只读**）
  // ---------------------------------------------------------------------------
  //
  // 真机回归的教训：只打印"最终看起来对不对"无法定位问题 —— 必须能逐环读出
  // 画布 / 锚点 / 信封 / 布局 / Region，才能判定是哪一环算错。

  /// 当前画布规划（未准备好时为 null）。
  @visibleForTesting
  WheelCanvasPlan? get canvasPlanForTest => _canvasPlanCurrent;

  /// 当前画布窗口矩形（屏幕坐标；未准备好时为 null）。
  @visibleForTesting
  Rect? get canvasRectForTest => _canvasRect;

  /// 实际喂给轮盘信封的设置（`preferredScale` 已按屏幕适配压缩）。
  @visibleForTesting
  WheelMenuLayoutSettings get effectiveWheelSettingsForTest =>
      effectiveWheelSettings;

  /// 当前轮盘信封（未打开时为 null）。
  @visibleForTesting
  WheelMenuEnvelope? get wheelEnvelopeForTest => _wheelEnvelope;

  /// 当前层级布局（未打开时为 null）。
  @visibleForTesting
  WheelMenuLayout? get wheelLayoutForTest => _wheel?.layout;

  /// 当前展开侧（测试用；等价于 [expansionSide]）。
  @visibleForTesting
  WheelExpansionSide? get expansionSideForTest => _lastExpansionSide;

  /// 当前轮盘窗口矩形（画布局部坐标；未打开时为 null）。
  @visibleForTesting
  Rect? get menuLocalRectForTest => _menuLocalRect;

  /// 人物**视觉**矩形（画布局部坐标；= alpha 包围盒落在画布里的位置）。
  ///
  /// C1.1 的**核心量**：缺口中心必须等于它的中心，而不是 Widget 矩形中心。
  @visibleForTesting
  Rect get petVisualLocalRectForTest => petVisualLocalRect;

  /// 人物**视觉**矩形（屏幕坐标）。
  @visibleForTesting
  Rect get petVisualScreenRectForTest => petVisualScreenRect;

  /// 轮盘窗口是否**完整**落在画布内（false = 真机会被 HWND 矩形硬裁切）。
  @visibleForTesting
  bool get wheelWindowFitsCanvas {
    final Rect? menu = _menuLocalRect;
    final Rect? canvas = _canvasRect;
    final WheelMenuEnvelope? env = _wheelEnvelope;
    if (menu == null || canvas == null || env == null) return false;
    // 判据用**信封窗口矩形**（几何的真实边界），而不是 widget 矩形：
    // widget 矩形可能在 clamp 中被改小，掩盖"装不下"这个事实。
    final Size canvasSize = Size(canvas.width, canvas.height);
    return WheelCanvasBridge.fitsInCanvas(
      windowRect: env.windowRect,
      canvas: canvasSize,
    );
  }

  // ---------------------------------------------------------------------------
  // C1.1 §八：关闭状态下的**可断言事实**（残片回归）
  // ---------------------------------------------------------------------------

  /// 本轮是否还会绘制菜单（`false` ⇒ 屏幕上不可能有菜单像素）。
  ///
  /// 与 [WheelMenuRenderer.draw] 的首行判据**同源**：
  /// 只要 widget 不在、矩形为空、控制器已释放或进度为 0，就不可能画出菜单。
  bool get shouldPaintMenu =>
      _menuOpen &&
      _menuLocalRect != null &&
      _wheel != null &&
      _wheel!.frame.openProgress > 0.004;

  /// 关闭状态必须成立的五条不变量；返回违反项（空 = 全部通过）。
  ///
  /// 对应需求 §八 的断言清单：
  /// * `openProgress == 0`；
  /// * 菜单几何 inactive（widget 矩形已清空 + 控制器已释放）；
  /// * `shouldPaintMenu == false`；
  /// * `RegionOwner == pet`；
  /// * `interactionState == closed`。
  List<String> closedStateViolations() {
    final List<String> bad = <String>[];
    final double progress = _wheel?.frame.openProgress ?? 0;
    if (progress != 0) bad.add('openProgress=$progress');
    if (_menuLocalRect != null) bad.add('menuLocalRect_not_null');
    if (_wheel != null) bad.add('controller_not_disposed');
    if (shouldPaintMenu) bad.add('painter_would_paint_menu');
    if (_coordinator.owner != RegionOwner.pet) {
      bad.add('region_owner=${_coordinator.owner.wireName}');
    }
    if (_gate.state != WheelInteractionState.closed) {
      bad.add('interaction=${_gate.state.wireName}');
    }
    return bad;
  }

  /// 关闭状态下 Region 是否只剩桌宠（诊断 / 测试）。
  @visibleForTesting
  bool get regionIsPetOnly =>
      _coordinator.owner == RegionOwner.pet &&
      !_coordinator.isDesiredCleared &&
      _coordinator.desiredRects.length == 1;

  /// 当前展开侧（**唯一方向语义**；未打开时 null）。
  WheelExpansionSide? get expansionSide => _lastExpansionSide;

  /// 最近一次方向不变量检查结果（诊断；未打开时 null）。
  WheelDirectionInvariant? get directionInvariant => _directionInvariant;

  /// 方向不变量是否通过（诊断面板用；未打开时为 true）。
  bool get directionInvariantPassed => _directionInvariant?.passed ?? true;

  /// 供轮盘信封使用的**实际**设置：`preferredScale` 已按屏幕适配压缩。
  ///
  /// 只压缩 `preferredScale`；按钮倍率与菜单距离仍是用户原值
  /// （设置页显示的永远是用户值）。
  WheelMenuLayoutSettings get effectiveWheelSettings {
    final WheelMenuLayoutSettings base = wheelSettings;
    final WheelCanvasPlan? plan = _canvasPlanCurrent;
    return plan == null ? base.normalized() : plan.settingsFor(base);
  }

  /// 当前计划是否已经跟不上「设置 / 桌宠尺寸」（需要在关闭态重建一次）。
  bool get isCanvasPlanStale {
    final Size? plannedPet = _planPetSize;
    final WheelMenuLayoutSettings? planned = _planSettings;
    if (plannedPet == null || planned == null || _canvasPlanCurrent == null) {
      return true;
    }
    final Size pet = widget.petSize();
    if (pet.width <= 0 || pet.height <= 0) return false;
    if (pet != plannedPet) return true;
    final WheelMenuLayoutSettings now = wheelSettings;
    return now.preferredScale != planned.preferredScale ||
        now.buttonVisualScale != planned.buttonVisualScale ||
        now.menuDistance != planned.menuDistance;
  }

  /// 当前手势归属（诊断用）。
  String get wheelGestureOwner => _wheel?.gestureOwnerName ?? 'none';

  /// 当前 Region 矩形（**逻辑局部坐标**，由轮盘实际几何生成）。
  ///
  /// 注意：这是**轮盘窗口内**的坐标，仅用于在轮盘窗口里把命中块画出来对照；
  /// 提交给原生的那份见 `_regionRects`（已平移到画布坐标）。
  List<Rect> get wheelRegionRects => _wheel?.regionRects() ?? const <Rect>[];

  /// 六色块诊断菜单是否启用（默认关闭）。
  bool get diagnosticMenuEnabled => _diagnosticMenuEnabled;

  /// 开关六色块诊断菜单（写入运行时开关，设置页与探针共享同一份状态）。
  void setDiagnosticMenuEnabled(bool value) {
    FixedCanvasDiagnosticsFlags.legacyTestMenu.value = value;
  }

  /// 开关诊断面板。
  void setDiagnosticsPanelEnabled(bool value) {
    FixedCanvasDiagnosticsFlags.panelVisible.value = value;
  }

  /// 开关 Region 边界可视化（写入运行时开关，与设置页共享）。
  void _toggleRegionVisualization() {
    FixedCanvasDiagnosticsFlags.regionVisualization.value = !_regionVisualization;
  }

  @override
  void initState() {
    super.initState();
    widget.reestablishOn?.addListener(_onExternalChange);
    FixedCanvasDiagnosticsFlags.panelVisible.addListener(_onDiagnosticsFlagsChanged);
    FixedCanvasDiagnosticsFlags.legacyTestMenu.addListener(_onDiagnosticsFlagsChanged);
    FixedCanvasDiagnosticsFlags.regionVisualization
        .addListener(_onDiagnosticsFlagsChanged);
    _onDiagnosticsFlagsChanged();
  }

  @override
  void dispose() {
    widget.reestablishOn?.removeListener(_onExternalChange);
    FixedCanvasDiagnosticsFlags.panelVisible.removeListener(_onDiagnosticsFlagsChanged);
    FixedCanvasDiagnosticsFlags.legacyTestMenu.removeListener(_onDiagnosticsFlagsChanged);
    FixedCanvasDiagnosticsFlags.regionVisualization
        .removeListener(_onDiagnosticsFlagsChanged);
    _messageTimer?.cancel();
    _feedbackTimer?.cancel();
    _wheel?.dispose();
    _wheel = null;
    super.dispose();
  }

  /// 诊断开关变化（设置页 → 桌面探针）。
  void _onDiagnosticsFlagsChanged() {
    if (!mounted) return;
    setState(() {
      _diagnosticsPanelEnabled = FixedCanvasDiagnosticsFlags.panelVisible.value;
      _diagnosticMenuEnabled = FixedCanvasDiagnosticsFlags.legacyTestMenu.value;
      _regionVisualization = FixedCanvasDiagnosticsFlags.regionVisualization.value;
    });
    // 六色块 ↔ 正式轮盘 互换：Region 由当前渲染的菜单决定，因此要重算一次。
    unawaited(_refreshWheelRegion('diagnostic_flag'));
  }

  /// 外部变化（设置 / 桌宠尺寸 / 主题）。
  ///
  /// * **主题**是"即时生效"的设置：菜单开着也立刻换色，**不重开菜单**（主题不参与几何）；
  /// * **几何设置**（轮盘大小 / 按钮大小 / 菜单距离）或**桌宠可见尺寸**变化时，
  ///   按决策在**菜单关闭**状态下**原子重建一次**固定画布（见 [_rebuildFixedCanvas]）。
  ///
  /// 菜单开 / 关、层级切换、悬停、滑动、按压、右键菜单等**都不在这里**
  /// —— 它们一律不改窗口矩形。
  void _onExternalChange() {
    if (!mounted) return;
    _wheel?.applyTheme(wheelTheme);
    if (_fallback || _rebuilding) return;
    if (!isCanvasPlanStale) return;
    unawaited(_rebuildFixedCanvas('settings-or-pet-changed'));
  }

  // ---------------------------------------------------------------------------
  // 对外接口（外壳调用）
  // ---------------------------------------------------------------------------

  /// 建立固定画布（**必须**在窗口 show() 之前调用）。
  ///
  /// 启动顺序（真机回归修复后的唯一口径）：
  ///
  /// 1. 窗口保持隐藏（调用方保证）；
  /// 2. 加载保存位置与 **position schema**；
  /// 3. 取桌宠素材的实际可见尺寸；
  /// 4. 解析 `savedPetScreenPosition`（[PetPositionResolver]：迁移 + 校验 + 修正）；
  /// 5. 校验的是**人物可见矩形**（不是 HWND 左上角）；
  /// 6. 位置不可见 → 修正到**主显示器右下角**并**立刻持久化 v2**（禁止再读旧值）；
  /// 7. 算 canvasPlan + petAnchor；
  /// 8. `canvasWindowPosition = petScreenPosition - petAnchor`；
  /// 9. **一次** `commitBounds`（= 一次 `SetWindowPos`）；
  /// 10. 应用 pet-only Region；
  /// 11. 等一帧布局；
  /// 12. 回读 windowRect / Region / petScreenRect，校验可见比例；
  /// 13. 只有全部达标才返回 true（调用方才能 show）。
  ///
  /// Region 应用失败 / 可见性校验不通过 → 返回 false，由调用方执行安全回退
  /// （清 Region + 恢复普通矩形窗口 + 移到主屏右下角 + show + 诊断提示）。
  Future<bool> prepareFixedCanvas() async {
    // --- 3) 桌宠可见尺寸 -----------------------------------------------------
    final Size pet = widget.petSize();
    if (pet.width <= 0 || pet.height <= 0) {
      // 素材尺寸未知：不进入固定画布，交给外壳按小窗口处理。
      wheelGeometryJournal.record(
        'startup.pet_size.ready',
        fields: <String, Object?>{'ok': false, 'reason': 'unknown_pet_size'},
      );
      fixedCanvasAnchor.clear();
      return false;
    }
    wheelGeometryJournal.record(
      'startup.pet_size.ready',
      fields: <String, Object?>{'ok': true, 'w': pet.width, 'h': pet.height},
    );

    // --- 2) + 4) 位置语义解析（唯一入口） ------------------------------------
    final ({double? x, double? y, int schema, Size? legacyWindowSize})
        saved = widget.savedWindowPosition();
    wheelGeometryJournal.record(
      'startup.position.loaded',
      fields: <String, Object?>{
        'x': saved.x ?? 'none',
        'y': saved.y ?? 'none',
        'schema': saved.schema,
        'legacyWindowSize': saved.legacyWindowSize == null
            ? 'none'
            : '${saved.legacyWindowSize!.width}x${saved.legacyWindowSize!.height}',
      },
    );
    wheelGeometryJournal.record(
      'startup.position.schema',
      fields: <String, Object?>{
        'version': saved.schema,
        'name': WindowPositionSchema.nameOf(saved.schema),
        'current': WindowPositionSchema.current,
      },
    );

    final List<WheelDisplayArea> displays = await widget.windowOps.displays();
    final PetPositionResolution resolution = PetPositionResolver.resolve(
      savedX: saved.x,
      savedY: saved.y,
      savedSchema: saved.schema,
      petVisibleSize: pet,
      legacyWindowSize: saved.legacyWindowSize,
      displays: <PetDisplayTarget>[
        for (final WheelDisplayArea d in displays)
          PetDisplayTarget(area: d, isPrimary: d.isPrimary),
      ],
    );
    wheelGeometryJournal.record(
      'startup.pet_position.validated',
      fields: <String, Object?>{
        'source': resolution.source.wireName,
        'targetDisplayId': resolution.targetDisplayId ?? 'none',
        'visibleRatio': resolution.visibleRatio.toStringAsFixed(4),
        'petRect': WheelGeometryJournal.formatRect(resolution.petScreenRect),
        'reason': resolution.reason,
      },
    );

    // --- 6) 迁移 / 修正 → 立刻写回 v2，后续**只**用内存里的修正值 --------------
    if (resolution.corrected) {
      wheelGeometryJournal.record(
        resolution.source == PetPositionSource.correctedInvisible
            ? 'startup.pet_position.corrected'
            : 'startup.position.migration',
        fields: <String, Object?>{
          'source': resolution.source.wireName,
          'reason': resolution.reason,
          'fromX': saved.x ?? 'none',
          'fromY': saved.y ?? 'none',
          'fromSchema': WindowPositionSchema.nameOf(saved.schema),
          'toX': resolution.petScreenPosition.dx,
          'toY': resolution.petScreenPosition.dy,
          'toSchema': WindowPositionSchema.nameOf(resolution.schemaVersion),
          'visibleRatio': resolution.visibleRatio.toStringAsFixed(4),
        },
      );
    }
    if (resolution.needsPersist) {
      try {
        await widget.persistPetScreenPosition?.call(
          resolution.petScreenPosition,
          schemaVersion: resolution.schemaVersion,
        );
      } catch (e, st) {
        // 写库失败不阻断启动：内存里已经是修正后的值，本次会话不会用旧值。
        wheelGeometryJournal.record(
          'startup.pet_position.persist_failed',
          fields: <String, Object?>{'error': '$e', 'stack': '$st'},
        );
      }
    }
    // 内存中的唯一真值（旧 saved 值从这里起**不再被读取**）。
    final Offset savedPet = resolution.petScreenPosition;

    // --- 7) canvasPlan + petAnchor ------------------------------------------
    final ({WheelCanvasPlan plan, WheelDisplayArea? display}) planned =
        await _planCanvas(pet, atPetScreen: savedPet);
    final WheelCanvasPlan plan = planned.plan;
    _canvas = plan.canvasSize;
    _petAnchor = plan.petAnchor;
    _petSize = pet;
    _startupTarget = resolution;
    wheelGeometryJournal.record(
      'startup.canvas_plan.ready',
      fields: <String, Object?>{
        'canvas': '${plan.canvasSize.width.toStringAsFixed(1)}x'
            '${plan.canvasSize.height.toStringAsFixed(1)}',
        'petAnchor': '${plan.petAnchor.dx.toStringAsFixed(1)},'
            '${plan.petAnchor.dy.toStringAsFixed(1)}',
        'screenFactor': plan.screenFactor.toStringAsFixed(3),
        'compressed': plan.compressed,
      },
    );

    // 让窗口控制器在拖动结束 / 启动恢复时把"画布窗口坐标"换算成"桌宠锚点屏幕坐标"。
    fixedCanvasAnchor.set(_petAnchor, enabled: true);

    // --- 8) 画布窗口位置（唯一公式） -----------------------------------------
    final Offset windowPosition = PetWindowPosition.windowFromPetScreen(
      petScreenPosition: savedPet,
      petAnchor: _petAnchor,
    );
    final WheelDisplayArea? startupDisplay = planned.display ??
        (resolution.targetDisplayId == null
            ? null
            : _displayById(displays, resolution.targetDisplayId!));
    final Rect windowRect = Rect.fromLTWH(
      windowPosition.dx,
      windowPosition.dy,
      _canvas.width,
      _canvas.height,
    );
    final Rect safeRect = _clampCanvas(windowRect, startupDisplay);
    // ***唯一一次*** 窗口矩形提交（= 一次 SetWindowPos）。
    await widget.windowOps.commitBounds(safeRect);
    _canvasRect = safeRect;
    wheelGeometryJournal.record(
      'startup.canvas_bounds.commit',
      fields: <String, Object?>{
        'requested': WheelGeometryJournal.formatRect(windowRect),
        'committed': WheelGeometryJournal.formatRect(safeRect),
        'count': 1,
      },
    );

    // --- 10) pet-only Region -------------------------------------------------
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: pet,
    );
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.prepareFixedCanvas',
    );
    _regionRects = <Rect>[petLocal];
    _lastApply = _applyResultOf(outcome);
    await _refreshRegionDiagnostics();
    wheelGeometryJournal.record(
      'startup.region.applied',
      fields: <String, Object?>{
        'success': outcome.success,
        'error': outcome.error,
        'rects': _regionRects.length,
        'owner': _coordinator.owner.wireName,
      },
    );

    if (!outcome.success) {
      await _fallbackToSmallWindow(petLocal);
      return false;
    }

    // --- 11) 布局 ---
    //
    // ⚠️ 这里**不能** `await endOfFrame`：`prepareFixedCanvas` 是被外壳**直接 await**
    // 的启动调用，而 `endOfFrame` 依赖有人继续泵帧；在 `flutter_tester` 里直接 await
    // 会**死锁**（同样的原因也让真机上"等待首帧"变成不确定行为）。
    //
    // 启动路径不需要等帧：`petLocal` 只由 `petAnchor` + 人物尺寸推出（纯几何），
    // Region 与布局无关；而下面回读实际 bounds 的那次原生调用本身就会让出事件循环。
    //
    // 真正需要"布局完成"的是 `_rebuildFixedCanvas`（面板返回 / 设置变更），
    // 那条路径由 `pumpAndSettle` 驱动，因此保留 `endOfFrame`。

    // --- 12) 回读 + 可见性校验（校验**人物**，不是 HWND） ---------------------
    final Rect actualWindow = await widget.windowOps.currentBounds();
    _canvasRect = actualWindow;
    final Rect actualPet = FixedCanvasGeometry.petScreenRect(
      canvasWindowRect: actualWindow,
      petAnchor: _petAnchor,
      petSize: pet,
    );
    // 实际提交可能被夹取 → petAnchor 反推一次，保证"画布矩形 + 锚点"与人物矩形自洽。
    final Offset actualPetScreen = Offset(
      actualWindow.left + _petAnchor.dx,
      actualWindow.top + _petAnchor.dy,
    );
    final Rect actualPetRect = Rect.fromLTWH(
      actualPetScreen.dx,
      actualPetScreen.dy,
      pet.width,
      pet.height,
    );
    final PetDisplayTarget? checkTarget = _resolveTargetFor(
      actualPetRect,
      displays,
      resolution.targetDisplayId,
    );
    final double actualRatio = checkTarget == null
        ? 0
        : PetPositionResolver.visibleRatio(actualPetRect, checkTarget.rect);
    _startupActualPetScreen = actualPetRect;
    _startupVisibleRatio = actualRatio;

    wheelGeometryJournal.record(
      'startup.actual_window_rect',
      fields: <String, Object?>{'rect': WheelGeometryJournal.formatRect(actualWindow)},
    );
    wheelGeometryJournal.record(
      'startup.actual_pet_screen_rect',
      fields: <String, Object?>{
        'rect': WheelGeometryJournal.formatRect(actualPetRect),
        'declared': WheelGeometryJournal.formatRect(actualPet),
      },
    );
    wheelGeometryJournal.record(
      'startup.pet_visible_ratio',
      fields: <String, Object?>{
        'ratio': actualRatio.toStringAsFixed(4),
        'min': PetPositionResolver.minVisibleRatio.toStringAsFixed(2),
        'targetDisplayId': checkTarget?.id ?? 'none',
        'ok': actualRatio >= PetPositionResolver.minVisibleRatio,
      },
    );

    final bool visible = actualRatio >= PetPositionResolver.minVisibleRatio;
    if (!visible) {
      // 走安全回退：**绝不** show 一个屏幕外的窗口。
      await _fallbackToSmallWindow(petLocal);
      return false;
    }

    _fallback = false;
    _gate.forceClosed(reason: 'prepareFixedCanvas');
    if (mounted) setState(() {});
    return true;
  }

  /// 供外壳在"校验通过才 show"那一步记录完整证据（用户 §7 要求的字段）。
  Map<String, Object?> startupShowEvidence() => <String, Object?>{
        'actualWindowRect': _canvasRect == null
            ? 'none'
            : WheelGeometryJournal.formatRect(_canvasRect!),
        'actualPetScreenRect': _startupActualPetScreen == null
            ? 'none'
            : WheelGeometryJournal.formatRect(_startupActualPetScreen!),
        'targetDisplayId': _startupTarget?.targetDisplayId ?? 'none',
        'visibleRatio': _startupVisibleRatio?.toStringAsFixed(4) ?? 'none',
        'regionBoundingBox': _regionBox?.toString() ?? 'none',
        'regionRects': _regionRects.length,
      };

  static WheelDisplayArea? _displayById(List<WheelDisplayArea> all, String id) {
    for (final WheelDisplayArea d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  static PetDisplayTarget? _resolveTargetFor(
    Rect petRect,
    List<WheelDisplayArea> displays,
    String? preferredId,
  ) {
    for (final WheelDisplayArea d in displays) {
      if (d.rect.contains(petRect.center)) {
        return PetDisplayTarget(area: d, isPrimary: d.isPrimary);
      }
    }
    if (preferredId != null) {
      final WheelDisplayArea? wanted = _displayById(displays, preferredId);
      if (wanted != null) {
        return PetDisplayTarget(area: wanted, isPrimary: wanted.isPrimary);
      }
    }
    for (final WheelDisplayArea d in displays) {
      if (d.isPrimary) return PetDisplayTarget(area: d, isPrimary: true);
    }
    return displays.isEmpty
        ? null
        : PetDisplayTarget(area: displays.first, isPrimary: displays.first.isPrimary);
  }

  /// 把桌宠**移动**到指定 `petScreenPosition` 并重建画布（托盘「重置位置」用）。
  ///
  /// 用户 §5 要求的完整流程：保持窗口隐藏 → 重算计划 → 一次提交 canvas bounds →
  /// 重算 `petAnchor` → 应用 pet-only Region → 回读校验人物可见 → 通过才返回 applied。
  ///
  /// 与 [_rebuildFixedCanvas] 的区别：那个保持**人物屏幕位置不变**（只换画布尺寸），
  /// 本方法**要**改人物位置，因此是"移动到目标 + 重建"的合并事务。
  ///
  /// ⚠️ 返回 [CanvasRebuildOutcome] 而不是 bool：`superseded`（被更新的设置修订号
  /// 取代）**必须**与 `failed` 分开，否则连续加减会把已经写好的有效设置回滚掉。
  ///
  /// 关于"被取代的那几次是否会让画布停在中间那一档的几何上"：
  /// 重建事务**开头就会先关菜单**（`close(animate: false)`），用户在重建期间无法
  /// 再从轮盘发起新的调整；因此真实的"飞行中又改设置"只能来自程序化并发调用，
  /// 而那种情况下在飞的这次重建读的是**最新**设置（计划在写入之后才算），
  /// 结果仍然是最新几何。
  Future<CanvasRebuildOutcome> rebuildFixedCanvasAt(
    Offset petScreen, {
    required String reason,
    int? expectedRevision,
  }) async {
    if (!mounted) return CanvasRebuildOutcome.failed;
    // 明确的版本守卫（代替"延时合并"）：连续加减设置会产生多个重建请求，
    // 只有**最新 revision** 的那个允许真正提交；旧的直接放弃。
    if (expectedRevision != null && !_settingRevision.isCurrent(expectedRevision)) {
      wheelGeometryJournal.record(
        'wheel.canvas.rebuild.stale_revision',
        fields: <String, Object?>{
          'reason': reason,
          'expected': expectedRevision,
          'current': _settingRevision.value,
          'cause': 'newer_revision',
        },
      );
      return CanvasRebuildOutcome.superseded;
    }
    final Size pet = widget.petSize();
    if (pet.width <= 0 || pet.height <= 0) return CanvasRebuildOutcome.failed;
    // 已有重建在飞：并发的第二次请求**按定义**被在飞的那次取代（最新修订号胜出），
    // 所以是 superseded —— **绝不能**当成失败去回滚设置。
    if (_rebuilding) {
      wheelGeometryJournal.record(
        'wheel.canvas.rebuild.stale_revision',
        fields: <String, Object?>{
          'reason': reason,
          'expected': expectedRevision,
          'current': _settingRevision.value,
          'cause': 'in_flight',
        },
      );
      return CanvasRebuildOutcome.superseded;
    }

    _rebuilding = true;
    final WindowsSurfaceMode restoreMode = windowsSurfaceSession.mode;
    final WheelCanvasPlan? previousPlan = _canvasPlanCurrent;
    final Size previousPet = _petSize;
    final Offset previousAnchor = _petAnchor;
    final Rect? previousCanvasRect = _canvasRect;
    final Offset previousPetScreen = previousCanvasRect == null
        ? petScreen
        : Offset(
            previousCanvasRect.left + previousAnchor.dx,
            previousCanvasRect.top + previousAnchor.dy,
          );
    bool hid = false;
    try {
      // 轮盘 / 右键菜单开着 → 先关（不播动画）并等 Region 收敛。
      if (_menuOpen || _gate.isOpen || _gate.isTransitioning) {
        await close(animate: false);
      }
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPet,
        source: 'probe.rebuildAt($reason)',
      );
      // 保持窗口隐藏，避免 surface 重排期间露出半张画布。
      await widget.windowOps.setVisible(false);
      hid = true;

      final ({WheelCanvasPlan plan, WheelDisplayArea? display}) planned =
          await _planCanvas(pet, atPetScreen: petScreen);
      final WheelCanvasPlan plan = planned.plan;
      final Rect target = FixedCanvasGeometry.canvasWindowRect(
        petScreenPosition: petScreen,
        petAnchor: plan.petAnchor,
        canvas: plan.canvasSize,
      );
      final Rect safe = _clampCanvas(target, planned.display);
      _lastRebuildClamped = !_sameRect(safe, target);
      await widget.windowOps.commitBounds(safe);

      // 由**最终** windowRect 反推 petAnchor（保持人物屏幕位置不变）。
      final Offset anchor =
          Offset(petScreen.dx - safe.left, petScreen.dy - safe.top);
      _canvas = plan.canvasSize;
      _petAnchor = anchor;
      _petSize = pet;
      _canvasRect = safe;
      fixedCanvasAnchor.set(anchor, enabled: true);
      if (mounted) setState(() {});

      // 应用 pet-only Region。
      //
      // ⚠️ 这里**不**等待 `endOfFrame`：被直接 `await` 的事务（启动、
      // `rebuildFixedCanvasAt`）在"没人继续泵帧"时会**永久挂起** ——
      // `endOfFrame` 依赖后续帧，而 `Future.timeout` 的定时器在 `testWidgets`
      // 的假时钟里也不会自行触发。Region 与 Flutter 布局无关（只由 `petAnchor` +
      // 人物尺寸推出），因此一次事件循环让位就足够。
      await Future<void>.microtask(() {});
      final Rect petLocal = FixedCanvasGeometry.petLocalRect(
        petAnchor: anchor,
        petSize: pet,
      );
      final RegionCommitOutcome outcome = await _coordinator.apply(
        owner: RegionOwner.pet,
        rects: <Rect>[petLocal],
        source: 'probe.rebuildAt($reason)',
        stillValid: () => mounted,
      );
      _regionRects = <Rect>[petLocal];
      _lastApply = _applyResultOf(outcome);

      // 回读 + 可见性校验（校验人物，不是 HWND）。
      final Rect actual = await widget.windowOps.currentBounds();
      _canvasRect = actual;
      final Rect actualPet = Rect.fromLTWH(
        actual.left + anchor.dx,
        actual.top + anchor.dy,
        pet.width,
        pet.height,
      );
      final List<WheelDisplayArea> displays = await widget.windowOps.displays();
      final PetDisplayTarget? checkTarget =
          _resolveTargetFor(actualPet, displays, null);
      final double ratio = checkTarget == null
          ? 0
          : PetPositionResolver.visibleRatio(actualPet, checkTarget.rect);
      _startupActualPetScreen = actualPet;
      _startupVisibleRatio = ratio;

      final Rect wanted = Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
      final double error = _rectError(actualPet, wanted);
      _lastRebuildAnchorErrorPx = error;
      await _refreshRegionDiagnostics();

      final bool ok = outcome.success &&
          error <= FixedCanvasAssertions.tolerancePx &&
          _sameRect(actual, safe) &&
          ratio >= PetPositionResolver.minVisibleRatio;
      wheelGeometryJournal.record(
        ok ? 'wheel.canvas.rebuild' : 'wheel.canvas.rebuild.failed',
        fields: <String, Object?>{
          'reason': reason,
          'positioned': true,
          'target': WheelGeometryJournal.formatRect(
            Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height),
          ),
          'actual': WheelGeometryJournal.formatRect(actualPet),
          'visibleRatio': ratio.toStringAsFixed(4),
          'anchorErrorPx': error.toStringAsFixed(3),
          'regionOk': outcome.success,
          'rects': _regionRects.length,
        },
      );
      if (!ok) {
        await _restoreCanvasPlan(
          previousPlan,
          previousPet,
          previousAnchor,
          previousCanvasRect,
          previousPetScreen,
        );
        _canvasRebuildFailures++;
        return CanvasRebuildOutcome.failed;
      }
      _canvasRebuildCount++;
      _canvasRebuildFailures = 0;
      return CanvasRebuildOutcome.applied;
    } catch (e) {
      wheelGeometryJournal.record(
        'wheel.canvas.rebuild.exception',
        fields: <String, Object?>{'reason': reason, 'error': '$e'},
      );
      try {
        await _restoreCanvasPlan(
          previousPlan,
          previousPet,
          previousAnchor,
          previousCanvasRect,
          previousPetScreen,
        );
      } catch (_) {
        // 回退也失败：至少保证 Region 收敛到"仅桌宠"。
      }
      return CanvasRebuildOutcome.failed;
    } finally {
      if (mounted && hid) await widget.windowOps.setVisible(true);
      windowsSurfaceSession.changeTo(
        restoreMode == WindowsSurfaceMode.panel
            ? restoreMode
            : WindowsSurfaceMode.petFixedCanvas,
        source: 'probe.rebuildAt.done($reason)',
      );
      _rebuilding = false;
      if (mounted) setState(() {});
    }
  }

  /// 采用**已经由外壳提交**的画布矩形（面板 → 桌宠 的事务路径）。
  ///
  /// 与 [prepareFixedCanvas] 的区别：本方法**绝不**调用 `commitBounds` —— 画布矩形
  /// 已由外壳用"保存的桌宠屏幕位置"算好并提交，这里只同步内部状态并应用"仅桌宠"
  /// Region，因此整条返回路径仍然只有**一次**窗口矩形提交。
  ///
  /// 返回 Region 是否应用成功（false 时调用方需回滚到普通矩形窗口）。
  Future<bool> adoptCommittedCanvas({
    required Rect canvasRect,
    required Offset petAnchor,
    required Size petSize,
  }) async {
    // 画布矩形是外壳提交的事实，这里只如实采用；随后刷新一次计划快照
    // （设置页的「实际显示」与诊断读它），**绝不再次提交窗口矩形**。
    _canvas = canvasRect.size;
    _petAnchor = petAnchor;
    _petSize = petSize;
    _canvasRect = canvasRect;
    // 让窗口控制器把"画布窗口坐标"换算成"桌宠锚点屏幕坐标"（拖动持久化）。
    fixedCanvasAnchor.set(petAnchor, enabled: true);
    try {
      await _planCanvas(petSize, atPetScreen: canvasRect.topLeft + petAnchor);
    } catch (_) {
      // 计划刷新失败不影响采用已提交的画布。
    }

    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: petAnchor,
      petSize: petSize,
    );
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.adoptCommittedCanvas',
    );
    _regionRects = <Rect>[petLocal];
    _lastApply = _applyResultOf(outcome);
    _fallback = !outcome.success;
    _gate.forceClosed(reason: 'adoptCommittedCanvas');
    await _refreshRegionDiagnostics();
    if (mounted) setState(() {});
    return outcome.success;
  }

  /// 显示一条瞬时状态消息（外壳在面板 → 桌宠 回滚时用）。
  void showStatusMessage(String message) => _showMessage(message);

  /// 右键菜单等 Overlay 需要在**整块画布**内可见/可点：临时把 Region 放大到整块画布。
  ///
  /// 只在 Overlay（如右键 PopupMenu）打开期间生效，关闭后由
  /// [restorePetOnlyRegionNow] 按**凭据**恢复"仅桌宠"。
  ///
  /// 返回本次事务的凭据：调用方必须在关闭时把它交回 [restorePetOnlyRegionNow]，
  /// 否则协调器不会做任何恢复（这正是修掉"右键 finally 覆盖轮盘 Region"的关键）。
  /// 右键菜单需要在**它自己那块矩形**内可点：把 Region 设为 `pet ∪ 菜单矩形`。
  ///
  /// 真机回归 #2 的口径修正：旧实现提交的是 `Offset.zero & _canvas`（**整块固定
  /// 画布**），于是整块透明画布都变成可命中区域 —— 鼠标在画布任意位置都会被
  /// 吃掉，而且与轮盘 / 面板抢命中。现在由 `ContextMenuLayout` 先把菜单矩形算准，
  /// 再原样传进来。
  Future<RegionLease> expandRegionForOverlay(Rect menuLocal) async {
    if (_fallback || _canvas.width <= 0) return const RegionLease.none();
    // 优先级 wheel > contextMenu：轮盘已打开 / 正在过渡时，右键不应再改 Region。
    if (_gate.isOpen || _gate.isTransitioning || _menuOpen) {
      wheelGeometryJournal.record(
        'context_menu.rejected',
        fields: <String, Object?>{'reason': 'wheel_${_gate.state.wireName}'},
      );
      return const RegionLease.none();
    }
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: _petSize,
    );
    final List<Rect> rects = <Rect>[petLocal, menuLocal];
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.contextMenu,
      rects: rects,
      source: 'probe.expandRegionForOverlay',
    );
    _lastApply = _applyResultOf(outcome);
    if (!outcome.success) {
      _contextMenuLease = const RegionLease.none();
      return const RegionLease.none();
    }
    _regionRects = rects;
    _contextMenuLease = outcome.lease;
    await _refreshRegionDiagnostics();
    if (mounted) setState(() {});
    return outcome.lease;
  }

  /// 恢复"仅桌宠"Region（Overlay 关闭后）。
  ///
  /// [lease] 为 null 时使用最近一次 [expandRegionForOverlay] 的凭据。
  /// 只有凭据仍然有效（owner 仍为 contextMenu 且 transactionId / generation 一致）
  /// 才会真的写 Region；否则协调器记 `region.restore.dropped_stale` 并放弃。
  Future<void> restorePetOnlyRegionNow([RegionLease? lease]) async {
    if (_fallback || _canvas.width <= 0) return;
    final RegionLease effective = lease ?? _contextMenuLease;
    _contextMenuLease = const RegionLease.none();
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: _petSize,
    );
    final RegionCommitOutcome outcome = await _coordinator.restoreIfCurrent(
      effective,
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.restorePetOnlyRegionNow',
    );
    if (outcome.isDroppedStale) {
      // 过期恢复：绝不写 Region，保持当前 owner 的 Region（例如轮盘的 pet+menu）。
      await _refreshRegionDiagnostics();
      return;
    }
    _lastApply = _applyResultOf(outcome);
    _regionRects = <Rect>[petLocal];
    await _refreshRegionDiagnostics();
    if (mounted) setState(() {});
  }

  /// 退出固定画布（切控制面板 / 托隐藏 / 退出）：清除 Region 并复位锚点。
  ///
  /// 面板切换必须让 contextMenu 与 wheel **全部失效**，并由 panelTransition 独占 Region。
  Future<void> releaseFixedCanvas() async {
    _gate.forceClosed(reason: 'releaseFixedCanvas');
    _menuOpen = false;
    _menuLocalRect = null;
    _menuOnRight = null;
    _contextMenuLease = const RegionLease.none();
    _wheelLease = const RegionLease.none();
    _feedbackTimer?.cancel();
    _wheel?.dispose();
    _wheel = null;
    _wheelEnvelope = null;
    await _coordinator.clear(
      owner: RegionOwner.panelTransition,
      source: 'probe.releaseFixedCanvas',
    );
    fixedCanvasAnchor.clear();
    _lastApply = null;
    _regionBox = null;
    _fallback = false;
    if (mounted) {
      setState(() {
        _regionRects = const <Rect>[];
      });
    }
  }

  /// **左键的正式轮盘统一入口**（外壳只允许调用这一个）。
  ///
  /// 与 [toggle] 完全等价，但名字表达了"这是正式轮盘，不是诊断菜单、不是
  /// rejected 探针、不是裸写 Region"，避免以后又被接错。
  /// 完整链路都会落日志（`wheel.toggle.request` → … → `wheel.open.visible`）。
  Future<void> toggleFormalWheel() {
    wheelGeometryJournal.record(
      'wheel.toggle.request',
      fields: <String, Object?>{
        'mode': windowsSurfaceSession.mode.wireName,
        'gate': _gate.state.wireName,
        'menuOpen': _menuOpen,
        'fallback': _fallback,
        'passthrough': widget.isMousePassthrough(),
        'rebuilding': _rebuilding,
        'diagnosticMenu': _diagnosticMenuEnabled,
      },
    );
    return toggle();
  }

  /// 切换菜单（桌宠单击入口）。过渡 / 面板态直接拒绝（不得在切换期间改 Region）。
  Future<void> toggle() {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) {
      // 静默无反应是缺陷：必须留下可判定的原因，并在桌宠态下给出可见反馈。
      wheelGeometryJournal.record(
        'wheel.toggle.rejected',
        fields: <String, Object?>{'reason': 'mode_${windowsSurfaceSession.mode.wireName}'},
      );
      _showMessage('窗口正在切换形态，请稍后再点击桌宠');
      return Future<void>.value();
    }
    return _gate.isOpen ? close() : open();
  }

  /// 关闭菜单（外壳在切面板 / 托隐藏 / 退出前调用）。
  ///
  /// [animate] = true（默认）时先播 Android 的 CLOSE 动画（180ms），动画结束的
  /// 那一帧才收敛 Region —— 与 Android 的关闭节奏一致。
  /// 面板切换 / 退出等"必须**立即**让出 Region"的路径传 false。
  Future<void> close({bool animate = true}) async {
    if (!_gate.beginClose()) {
      // closing / opening / closed：重复点击一律忽略（不得作为布局修复手段）。
      _gate.recordReentryIgnored(action: 'close');
      return;
    }
    final WheelMenuController? wheel = _wheel;
    if (animate && wheel != null && _menuOpen && wheel.phase == WheelMenuPhase.open) {
      // 关闭序列：先撤掉输入，再收起（Region 保持不变，动画结束才收敛）。
      wheel.setInteractive(false);
      wheel.requestClose();
      wheelGeometryJournal.record(
        'wheel.close.animation.start',
        fields: <String, Object?>{
          'phase': wheel.phaseName,
          'gate': _gate.state.wireName,
        },
      );
      if (mounted) setState(() {});
      return;
    }
    await _finishClose();
  }

  /// 关闭动画播完 / 立即关闭的**唯一收尾**：Region 收敛回"仅桌宠"+ 断言回读。
  Future<void> _finishClose() async {
    if (_gate.state != WheelInteractionState.closing) return;
    _wheel?.setInteractive(false);
    _wheel?.freeze();
    // UI 立即隐藏（Region 随后收敛）。
    _menuOpen = false;
    if (mounted) setState(() {});

    final RegionLease lease = _wheelLease;
    _wheelLease = const RegionLease.none();
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: _petSize,
    );
    final RegionCommitOutcome outcome = await _coordinator.restoreIfCurrent(
      lease,
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.wheel.close',
    );
    if (!outcome.isDroppedStale) {
      _lastApply = _applyResultOf(outcome);
      _regionRects = <Rect>[petLocal];
    }

    _menuLocalRect = null;
    _menuOnRight = null;
    _wheel?.dispose();
    _wheel = null;
    _wheelEnvelope = null;
    // C1.1.1 §八：关闭 = 本轮布局决议作废（诊断读数必须回到"未打开"）。
    _placementSolution = null;
    _gate.completeClose();
    wheelGeometryJournal.record(
      'wheel.ui.state',
      fields: <String, Object?>{
        'phase': 'closed',
        'gate': _gate.state.wireName,
        'rects': _regionRects.length,
      },
    );
    await _refreshRegionDiagnostics();

    final Rect afterClose = await widget.windowOps.currentBounds();
    _windowRectAfterClose = afterClose;
    _petScreenAfterClose = _petScreenOf(afterClose);
    _assertionFailures = FixedCanvasAssertions.evaluate(
      before: _windowRectBeforeOpen,
      afterOpen: _windowRectAfterOpen,
      afterClose: _windowRectAfterClose,
      petScreenBefore: _petScreenBefore,
      petScreenAfterOpen: _petScreenAfterOpen,
      petScreenAfterClose: _petScreenAfterClose,
    );

    _verifyRegionConsistency('wheel.close');
    // C1.1 §八：**关闭残片**的可判定检查。
    // 关闭不只是"把 Region 收回 pet"——还必须保证**不再有任何菜单像素被绘制**，
    // 否则真机上会出现"远处的粉色扇形残片"。
    //
    // 这里做两件事：① 立刻 `setState` 并把菜单几何标为 inactive；
    // ② 主动 `scheduleFrame()` **强制再来一帧**（分层窗口必须被真正重绘一次，
    // 否则上一帧的像素会留在窗口表面上）。
    //
    // ⚠️ **不能** `await endOfFrame`：本方法可能被外壳直接 await（托盘隐藏、
    // 拖动收起），而 `endOfFrame` 依赖后续帧 —— 在 `flutter_tester` 里没人继续
    // 泵帧就会**永久挂起**（项目里已经踩过一次，见 `prepareFixedCanvas` 注释）。
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.scheduleFrame();
      await Future<void>.microtask(() {});
    }
    final List<String> violations = closedStateViolations();
    wheelGeometryJournal.record(
      violations.isEmpty
          ? 'wheel.close.invariants'
          : 'wheel.close.invariants.violated',
      fields: <String, Object?>{
        'shouldPaintMenu': shouldPaintMenu,
        'openProgress': _wheel?.frame.openProgress ?? 0,
        'regionOwner': _coordinator.owner.wireName,
        'regionRects': _regionRects.length,
        'interaction': _gate.state.wireName,
        'violations': violations.join(','),
      },
    );
    if (mounted) setState(() {});
    widget.onOpenChanged?.call(false);
  }

  /// 打开菜单（只改 Region 与菜单可见性）。
  Future<void> open({String? restoreLevelId, int? restoreIndex}) async {
    // 同步前置拒绝：穿透 / 回退态下连 opening 都不进入。
    if (widget.isMousePassthrough()) {
      _showMessage('鼠标穿透已开启：请先在设置里关闭「鼠标穿透」，再点击桌宠打开菜单');
      return;
    }
    if (_fallback) {
      _showMessage('窗口 Region 不可用，已回退小窗口桌宠模式，菜单暂不可用');
      return;
    }
    // 计划过期（几何设置 / 桌宠尺寸刚变）：先在**关闭态**原子重建一次画布，
    // 保证这次打开用的画布一定装得下按当前设置绘制的轮盘。
    if (isCanvasPlanStale) {
      await _rebuildFixedCanvas('plan-stale-before-open');
      if (!mounted || _fallback) return;
    }
    // C1.1 §六：**交互内容**装不进画布 → 明确拒绝打开（绝不裁掉按钮假装能用）。
    final WheelCanvasPlan? plan = _canvasPlanCurrent;
    if (plan != null && !plan.interactiveFitsCanvas) {
      wheelGeometryJournal.record(
        'wheel.open.refused',
        fields: <String, Object?>{
          'reason': 'interactive_content_does_not_fit_canvas',
          'canvas': '${plan.canvasSize.width.toStringAsFixed(0)}×'
              '${plan.canvasSize.height.toStringAsFixed(0)}',
          'interactive': WheelGeometryJournal.formatRect(
            plan.interactiveBoundsInCanvas,
          ),
          'truncated': plan.truncated,
        },
      );
      _showMessage('当前屏幕可用空间放不下轮盘按钮：请把桌宠拖离屏幕边缘，或调小「轮盘大小 / 按钮大小」');
      return;
    }
    // **同步**进入 opening：这是"快速双击只有一个事务"的关键（首个 await 之前）。
    if (!_gate.beginOpen()) {
      _gate.recordReentryIgnored(action: 'open');
      return;
    }

    try {
      final Rect before = await widget.windowOps.currentBounds();
      final Offset petScreen = before.topLeft + _petAnchor;
      final WheelDisplayArea? display =
          await widget.windowOps.displayForPoint(petScreen);
      if (display == null) {
        _showMessage('未检测到可用显示器');
        _gate.failOpen();
        return;
      }

      // **统一坐标管线**（C1.1 §一）：先刷新 alpha 边界，再一次构建空间快照。
      // 之后 Painter / Region / 方向判定 / 缺口全部只消费这个快照。
      final WheelSpaceSnapshot space =
          await _buildSpace(canvasWindowRect: before, bumpGeometry: false);
      final Rect petLocal = space.petWidgetLocalRect;
      final Rect petScreenRect = space.petVisualScreenRect;

      // 轮盘信封在**屏幕坐标**里算（方向 / 靠边偏转 / 应急缩放都看显示器边），
      // 再把窗口矩形平移到画布局部坐标 —— 与 Android「全屏 Overlay」语义一致。
      //
      // ⚠️ 用**屏幕适配后**的设置：轮盘大小在屏幕放不下时由画布计划压缩，
      // 这样绘制出来的轮盘才真的装得进固定画布。
      final WheelMenuLayoutSettings envelopeSettings = effectiveWheelSettings;
      // **布局决议的唯一入口**（C1.1.1 需求 §三 / §五 —— 取代 C1.1 的
      // `resolveExpansion` 直调）：
      //
      // ① 水平侧：沿用已验收的方向决议链（契约 + 不变量 + 反向重试 + 位移滞回）；
      // ② 纵向模式：**绝不沿用上一次**（`previousVerticalMode` 恒为 null）。
      //    对 top / middle / bottom 三种候选**各自算完整视觉包围盒**
      //    （`WheelVisualBoundsCalculator`，与 Painter 逐项同源），再与 workArea
      //    求四侧溢出，选**零溢出**者（多个零溢出优先 middle；全都溢出取最小者，
      //    随后进入既有的窗口夹取 / 设备级应急缩放）。**绝不先缩放再选方向**。
      //
      // 真机回归根因（左上 / 右上菜单上半截被系统裁切）：旧实现把上一次的纵向
      // 模式用 `lockMode` 锁住，于是"先在下半屏打开（bottomEdge）→ 把桌宠拖到
      // 左上 → 再打开"仍按**靠下**的 26° 偏转绘制，而那个偏转正好把内容推向
      // 屏幕上方。现在纵向模式是**当前位置的纯函数**（位置 / 几何变了就重算）。
      //
      // `petWindowRect` 传**人物 Widget**矩形 + `content` = alpha 边界：
      // 缺口中心因此恒等于**人物视觉中心**（不是 Widget 中心、更不是素材中心）。
      final WheelPlacementSolution placement = WheelPlacementSolver.solve(
        workArea: WheelBounds(
          display.left,
          display.top,
          display.right,
          display.bottom,
        ),
        petWindowRect: WheelRect(
          space.petWidgetScreenRect.left,
          space.petWidgetScreenRect.top,
          space.petWidgetScreenRect.right,
          space.petWidgetScreenRect.bottom,
        ),
        content: space.contentBounds,
        maxItemCount: MenuCatalog.maxItems,
        spec: wheelSpec,
        settings: envelopeSettings,
        previousSide: _lastExpansionSide,
        previousPetCenterX: _lastPetCenterX,
        previousPlacement: _lastPlacement,
      );
      final WheelExpansionResolution resolution = placement.resolution;
      final WheelMenuEnvelope envelope = placement.envelope;
      _placementSolution = placement;
      _lastPlacement = placement.placement;
      _lastExpansionSide = placement.horizontalSide;
      _lastPetCenterX = petScreenRect.center.dx;
      _directionInvariant = resolution.invariant;
      // 需求 §八：把三种候选的溢出量与选中组合整体落日志（**诊断字段全集**）。
      wheelGeometryJournal.record(
        'wheel.placement.decided',
        fields: <String, Object?>{
          ...placement.diagnostics(),
          'prevVertical': _lastVerticalMode?.name ?? 'none',
          'prevDirection': _lastDirection?.name ?? 'none',
        },
      );
      wheelGeometryJournal.record(
        'wheel.direction.decided',
        fields: resolution.diagnostics(
          petScreenRect: petScreenRect,
          workArea: Rect.fromLTWH(
            display.left,
            display.top,
            display.width,
            display.height,
          ),
          menuScreenBounds: Rect.fromLTWH(
            envelope.windowRect.left,
            envelope.windowRect.top,
            envelope.windowRect.width,
            envelope.windowRect.height,
          ),
        ),
      );
      // ⚠️ **不再**对菜单矩形做 clamp（C1.1 缺陷修复：矩形裁切 / 残片的根因之一）。
      //
      // 旧实现把窗口矩形 clamp / 缩小到画布内，于是：
      // * Painter 仍按 `layout.windowRect`（信封坐标系）绘制 → 内容与 widget 矩形错位；
      // * Region 由 `wheelLocal.topLeft` 平移得到 → Region 与像素错位；
      // * 结果就是真机上看到的"扇形 / 按钮 / 文字被 HWND 矩形硬裁切"。
      //
      // 正确口径：**画布必须装得下轮盘**（由 CanvasPlan 用 visualBounds 保证），
      // 装不下是**规划失败**，必须显式降级（emergencyScale / truncated），
      // 而不是偷偷挪 widget。
      final Rect wheelLocal = WheelCanvasBridge.windowToCanvasLocal(
        windowRect: envelope.windowRect,
        canvasRect: _canvasRect ?? before,
      );
      final bool fitsInCanvas = WheelCanvasBridge.fitsInCanvas(
        windowRect: envelope.windowRect,
        canvas: _canvas,
      );
      // 把空间快照补成最终形态（画布矩形可能因重建而变化），并把本次决议的
      // **布局组合 + 视觉 / 画布包围盒**一并附上（C1.1.1 §五：Painter / HitTest /
      // Region / CanvasPlan 只能读这一个不可变事实，不得再自行判断方向）。
      _space = WheelCoordinatePipeline.build(
        canvasWindowRect: _canvasRect ?? before,
        petAnchor: _petAnchor,
        petSize: _petSize,
        bounds: _petVisualBounds,
        positionRevision: _positionRevision.value,
        geometryRevision: _geometryRevision.value,
        surfaceGeneration: _surfaceGeneration.value,
      ).withPlacement(
        placement: placement.placement,
        visualBoundsScreen: placement.visualBoundsScreen,
        canvasBoundsScreen: placement.canvasBoundsScreen,
      );
      _syncVisualRects();
      wheelGeometryJournal.record(
        'wheel.canvas.fit',
        fields: <String, Object?>{
          'fits': fitsInCanvas,
          'canvas': WheelGeometryJournal.formatRect(
            Rect.fromLTWH(0, 0, _canvas.width, _canvas.height),
          ),
          'wheelWindow': WheelGeometryJournal.formatRect(
            Rect.fromLTWH(
              envelope.windowRect.left,
              envelope.windowRect.top,
              envelope.windowRect.width,
              envelope.windowRect.height,
            ),
          ),
          'menuLocal': WheelGeometryJournal.formatRect(wheelLocal),
          'petVisualLocal': WheelGeometryJournal.formatRect(petVisualLocalRect),
          'petVisualScreen': WheelGeometryJournal.formatRect(petVisualScreenRect),
          'alphaBounds': _petVisualBounds.describe(),
        },
      );
      _lastDirection = envelope.direction;
      // 契约不变量：`envelope.direction` 必须与决议出来的 side **恒一致**
      // （这是"Painter 不得二次镜像"的配套保证）。
      assert(
        (_lastExpansionSide == WheelExpansionSide.left) ==
            (envelope.direction == WheelExpandDirection.left),
        '方向契约不一致：side=$_lastExpansionSide direction=${envelope.direction}',
      );
      _lastVerticalMode = envelope.verticalMode;

      // 正式轮盘控制器：信封 + 根层级一次就位（此时**还没有**动画、不可交互）。
      final WheelMenuController wheel = WheelMenuController(
        spec: wheelSpec,
        theme: wheelTheme,
        density: WheelCanvasBridge.density,
      );
      wheel.onRequestClose = () => unawaited(close());
      wheel.onGeometryChanged = _onWheelGeometryChanged;
      wheel.onEntryConfirmed = _onWheelEntryConfirmed;
      wheel.onFeedback = _onWheelFeedback;
      wheel.onAnimationFinished = _onWheelAnimationFinished;
      wheel.infoProvider = widget.wheelInfoProvider;
      if (!wheel.prepareContent(envelope, wheelTheme)) {
        wheel.dispose();
        _showMessage('轮盘菜单目录为空，无法打开');
        _gate.failOpen();
        return;
      }
      _wheel?.dispose();
      _wheel = wheel;
      _wheelEnvelope = envelope;

      final List<Rect> region = _wheelRegion(petLocal, wheelLocal);

      // 1) 先让右键菜单事务**失效**，并等待 popup 真正关闭 ——
      //    这样它的 finally 再来恢复时会被判为 dropped_stale，不会覆盖轮盘 Region。
      _coordinator.invalidateOwner(
        RegionOwner.contextMenu,
        source: 'wheel.beginOpen',
      );
      _contextMenuLease = const RegionLease.none();
      await contextMenuBridge.dismissAndWait();

      // 2) 只由 wheel 提交 pet+menu Region。
      wheelGeometryJournal.record(
        'wheel.region.acquire.start',
        fields: <String, Object?>{
          'owner': RegionOwner.wheel.wireName,
          'rects': region.length,
          'menu': WheelGeometryJournal.formatRect(wheelLocal),
        },
      );
      final RegionCommitOutcome outcome = await _coordinator.apply(
        owner: RegionOwner.wheel,
        rects: region,
        source: 'probe.wheel.open',
        stillValid: () => mounted,
      );
      wheelGeometryJournal.record(
        'wheel.region.acquire.result',
        fields: <String, Object?>{
          'success': outcome.success,
          'error': outcome.error,
          'lease': outcome.lease.wireName,
          'owner': _coordinator.owner.wireName,
        },
      );
      if (!outcome.success) {
        // Region 失败：绝不留下"看得见的大透明块"，立即回退。
        await _fallbackToSmallWindow(petLocal);
        _showMessage('窗口 Region 应用失败，已回退小窗口模式：${outcome.error}');
        _gate.failOpen();
        return;
      }

      _windowRectBeforeOpen = before;
      _petScreenBefore = _petScreenOf(before);
      _lastApply = _applyResultOf(outcome);
      _regionRects = region;
      _menuLocalRect = wheelLocal;
      _menuOnRight = envelope.direction == WheelExpandDirection.right;
      _menuOpen = true;
      _wheelLease = outcome.lease;
      _gate.completeOpen();
      wheelGeometryJournal.record(
        'wheel.ui.state',
        fields: <String, Object?>{
          'phase': wheel.phaseName,
          'gate': _gate.state.wireName,
          'level': wheel.levelIdName,
        },
      );
      // 布局已就位：打开序列**恰好一次**，随后才允许交互。
      wheel.setInteractive(true);
      // 调整后的**自动重开**：恢复到原层级与原选中项（需求 §二.3）。
      if (restoreLevelId != null && restoreLevelId != MenuCatalog.rootId) {
        if (wheel.restoreLevel(restoreLevelId, index: restoreIndex)) {
          unawaited(_refreshWheelRegion('adjust_restore_level'));
        }
      }
      // 调整层的"当前值"读取器（视图只渲染，不持有设置）。
      wheel.adjustValueReader = widget.readWheelSetting;
      wheelGeometryJournal.record(
        'wheel.open.animation.start',
        fields: <String, Object?>{
          'openMs': WheelAnimationTimeline.openMs,
          'items': wheel.layout?.itemCount ?? 0,
        },
      );
      wheel.beginOpenAnimation();
      if (mounted) setState(() {});
      wheelGeometryJournal.record(
        'wheel.open.visible',
        fields: <String, Object?>{
          'phase': wheel.phaseName,
          'level': wheel.levelIdName,
          'rects': _regionRects.length,
          'windowRect': WheelGeometryJournal.formatRect(wheelLocal),
        },
      );
      widget.onOpenChanged?.call(true);
      wheelGeometryJournal.record(
        'wheel.open',
        fields: <String, Object?>{
          'mode': windowsSurfaceSession.mode.wireName,
          'lease': outcome.lease.wireName,
          'region': WheelGeometryJournal.formatRect(wheelLocal),
          'direction': envelope.direction.name,
          'vertical': envelope.verticalMode.name,
          'scale': envelope.actualScale.toStringAsFixed(2),
          'degraded': envelope.degraded,
        },
      );

      // 回读：开菜单期间窗口矩形与桌宠屏幕矩形必须完全不变。
      final Rect afterOpen = await widget.windowOps.currentBounds();
      _windowRectAfterOpen = afterOpen;
      _petScreenAfterOpen = _petScreenOf(afterOpen);
      _assertionFailures = FixedCanvasAssertions.evaluate(
        before: _windowRectBeforeOpen,
        afterOpen: _windowRectAfterOpen,
        afterClose: _windowRectAfterClose,
        petScreenBefore: _petScreenBefore,
        petScreenAfterOpen: _petScreenAfterOpen,
        petScreenAfterClose: _petScreenAfterClose,
      );
      await _refreshRegionDiagnostics();
      _verifyRegionConsistency('wheel.open');
      if (mounted) setState(() {});
    } catch (e) {
      // 异常路径：回到 closed，并由协调器恢复正确 owner / Region。
      wheelGeometryJournal.record(
        'wheel.open.exception',
        fields: <String, Object?>{'error': '$e'},
      );
      _gate.failOpen();
      _menuOpen = false;
      await _recoverToPet('wheel.open_exception:$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 按「**当前**设置 + **当前**显示器工作区」规划固定画布（增量 B 修正口径）。
  ///
  /// 不再按设置上限预留常驻大窗口；屏幕放不下时用 Android 的设备级应急缩放
  /// 压缩轮盘（`WheelCanvasPlanner`），并把结果广播给设置页显示「实际显示」。
  Future<({WheelCanvasPlan plan, WheelDisplayArea? display})> _planCanvas(
    Size pet, {
    required Offset atPetScreen,
  }) async {
    final WheelDisplayArea? display =
        await widget.windowOps.displayForPoint(atPetScreen);
    final Size workArea = display == null
        ? const Size(1920, 1080)
        : Size(display.width, display.height);
    final WheelMenuLayoutSettings settings = wheelSettings;
    // C1.1：规划前必须先有**真实** alpha 边界，否则缺口会按整张素材算。
    final PetVisualBounds bounds = await _refreshPetVisualBounds();
    final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
      petSize: pet,
      workArea: workArea,
      settings: settings,
      spec: wheelSpec,
      maxItemCount: MenuCatalog.maxItems,
      petVisualBounds: bounds,
    );
    _canvasPlanCurrent = plan;
    _planSettings = settings;
    _planPetSize = pet;
    _planWorkArea = workArea;
    wheelCanvasFit.value = plan.fit;
    wheelGeometryJournal.record(
      'wheel.canvas.plan',
      fields: <String, Object?>{
        'pet': '${pet.width.toStringAsFixed(0)}×${pet.height.toStringAsFixed(0)}',
        'alphaBounds': bounds.describe(),
        'canvas': '${plan.canvasSize.width.toStringAsFixed(1)}×'
            '${plan.canvasSize.height.toStringAsFixed(1)}',
        'anchor': '${plan.petAnchor.dx.toStringAsFixed(1)},'
            '${plan.petAnchor.dy.toStringAsFixed(1)}',
        'reach': 'L${plan.reachLeft.toStringAsFixed(0)} '
            'R${plan.reachRight.toStringAsFixed(0)} '
            'U${plan.reachUp.toStringAsFixed(0)} '
            'D${plan.reachDown.toStringAsFixed(0)}',
        'screenFactor': plan.screenFactor.toStringAsFixed(3),
        'effectiveScale': plan.effectiveScale.toStringAsFixed(3),
        'compressed': plan.compressed,
        'truncated': plan.truncated,
        'visualFits': plan.visualFitsCanvas,
        'interactiveFits': plan.interactiveFitsCanvas,
        'visualBoundsInCanvas': WheelGeometryJournal.formatRect(
          plan.visualBoundsInCanvas,
        ),
      },
    );
    return (plan: plan, display: display);
  }

  /// **拖动生命周期**（C1.1 §四）：窗口被移动后立刻用**新位置**刷新一切。
  ///
  /// 真机症状（截图 3/4）：桌宠移动后菜单仍可能出现在旧位置或错误一侧 ——
  /// 因为"位置"只被写进持久化，画布 / 空间快照 / 展开侧都还停在旧值。
  ///
  /// 语义（与需求 §四 逐条对应）：
  /// 1. 拖动**开始** = 位置开始变化 → 立刻收起已打开的轮盘（`close` 会把 Region
  ///    收敛回"仅桌宠"并取消 opening/closing 事务）；
  /// 2. 拖动**过程中**只移动固定画布 HWND —— 本方法**绝不** `commitBounds`、
  ///    绝不重建画布；
  /// 3. 位置落定后：回读 `actualWindowRect` → 重算人物视觉屏幕矩形 →
  ///    重新选目标显示器 → 重算展开侧 → 更新 Region → 位置修订号 +1。
  ///
  /// 位置修订号 +1 之后，任何**在飞**的旧位置计算在提交前都会被判为过期，
  /// 不会覆盖新位置。
  Future<void> onPetPositionChanged(double x, double y) async {
    if (!mounted || _fallback) return;
    final WheelSpaceSnapshot? before = _space;
    // 1) 位置真的变了吗？（同一像素的重复回调直接忽略，避免无意义的关闭）
    const double epsilon = 0.5;
    if (before != null &&
        (before.canvasWindowRect.topLeft + _petAnchor -
                    Offset(x, y))
                .distance <
            epsilon) {
      return;
    }
    // 2) 拖动开始：收起轮盘（含 opening / closing 事务的取消）。
    if (_menuOpen || _gate.isOpen || _gate.isTransitioning) {
      await close(animate: false);
    }
    if (!mounted) return;

    // 3) 位置修订号 +1（旧的在飞计算从此作废）。
    final int revision = _positionRevision.bump();
    // 4) 回读**实际**窗口矩形（拖动后的唯一事实），并重算空间快照。
    final Rect actual = await widget.windowOps.currentBounds();
    if (mounted) {
      _canvasRect = actual;
      final WheelSpaceSnapshot space = await _buildSpace(canvasWindowRect: actual);
      // 5) 位置落定后避免方向抖动：把滞回的"上一次"基准清掉（新位置就是新基准）。
      _lastPetCenterX = space.petVisualScreenRect.center.dx;
      wheelGeometryJournal.record(
        'pet.position.changed',
        fields: <String, Object?>{
          'requested': '${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}',
          'canvasRect': WheelGeometryJournal.formatRect(actual),
          'petWidgetScreen': WheelGeometryJournal.formatRect(space.petWidgetScreenRect),
          'petVisualScreen': WheelGeometryJournal.formatRect(space.petVisualScreenRect),
          'alphaBounds': space.bounds.describe(),
          'positionRevision': revision,
        },
      );
    }
    if (mounted) setState(() {});
  }

  /// 刷新人物视觉边界（alpha 包围盒）并自增几何修订号（**真的变了才自增**）。
  Future<PetVisualBounds> _refreshPetVisualBounds() async {
    final Future<PetVisualBounds> Function()? ensure =
        widget.ensurePetVisualBounds;
    PetVisualBounds bounds = _petVisualBounds;
    if (ensure != null) {
      bounds = await ensure();
    } else {
      bounds = widget.petVisualBounds?.call() ?? _petVisualBounds;
    }
    if (bounds != _petVisualBounds) {
      _petVisualBounds = bounds;
      _geometryRevision.bump();
    }
    return bounds;
  }

  /// **固定画布原子重建事务**（决策：只有几何设置 / 桌宠尺寸 / 显示器 / 面板返回
  /// 才允许重建，且必须在**菜单关闭**状态下一次完成）。
  ///
  /// 步骤与验收一一对应：
  /// 1. 轮盘打开 → 先关闭并等 Region 收敛到 pet；
  /// 2. surface mode → [WindowsSurfaceMode.transitioningToPet]；
  /// 3. 隐藏窗口；
  /// 4. 读当前桌宠屏幕锚点；
  /// 5/6. 用当前设置 + 当前工作区重算计划（含设备级应急缩放）；
  /// 7. **一次** `commitBounds`（= 一次 `SetWindowPos`）；
  /// 8. 保持桌宠屏幕锚点不变，反推新的 `petAnchor`；
  /// 9. Flutter 布局完成后应用 pet-only Region；
  /// 10. 回读 bounds / Region / petScreenRect 并校验；
  /// 11/12. 通过才显示窗口；失败回退最近一次有效计划（绝不留大透明窗口）。
  Future<void> _rebuildFixedCanvas(String reason) async {
    if (!mounted || _rebuilding || _fallback) return;
    if (!windowsSurfaceSession.mode.allowsFixedCanvasCommit) return;
    final Size pet = widget.petSize();
    if (pet.width <= 0 || pet.height <= 0) return;

    _rebuilding = true;
    final WindowsSurfaceMode restoreMode = windowsSurfaceSession.mode;
    final WheelCanvasPlan? previousPlan = _canvasPlanCurrent;
    final Size previousPet = _petSize;
    final Offset previousAnchor = _petAnchor;
    final Rect? previousCanvasRect = _canvasRect;
    bool hid = false;
    try {
      // 1) 轮盘开着 → 先关闭（不播动画）并等 Region 收敛到 pet。
      if (_menuOpen || _gate.isOpen || _gate.isTransitioning) {
        await close(animate: false);
      }
      // 2) 过渡态：期间禁止其它几何写入。
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.transitioningToPet,
        source: 'probe.rebuildCanvas($reason)',
      );
      // 4) 读当前桌宠屏幕锚点（旧计划 + 旧 bounds 换算）。
      final Rect oldBounds = await widget.windowOps.currentBounds();
      final Offset petScreen = (previousCanvasRect ?? oldBounds).topLeft + previousAnchor;
      // 3) 隐藏窗口（避免 surface 重排期间露出半张画布）。
      await widget.windowOps.setVisible(false);
      hid = true;
      // 5) + 6) 重新计算画布计划（含设备级应急缩放）。
      final ({WheelCanvasPlan plan, WheelDisplayArea? display}) planned =
          await _planCanvas(pet, atPetScreen: petScreen);
      final WheelCanvasPlan plan = planned.plan;
      // 7) 一次提交新画布矩形。
      final Rect target = FixedCanvasGeometry.canvasWindowRect(
        petScreenPosition: petScreen,
        petAnchor: plan.petAnchor,
        canvas: plan.canvasSize,
      );
      final Rect safe = _clampCanvas(target, planned.display);
      _lastRebuildClamped = !_sameRect(safe, target);
      await widget.windowOps.commitBounds(safe);
      // 8) 桌宠屏幕锚点**不变** → 由最终 windowRect 反推 petAnchor。
      final Offset anchor = Offset(
        petScreen.dx - safe.left,
        petScreen.dy - safe.top,
      );
      _canvas = plan.canvasSize;
      _petAnchor = anchor;
      _petSize = pet;
      _canvasRect = safe;
      fixedCanvasAnchor.set(anchor, enabled: true);
      if (mounted) setState(() {});
      // 应用 pet-only Region。
      //
      // ⚠️ 这里**不**等待 `endOfFrame`（见 `_restoreCanvasPlan` 的说明）：
      // 本事务可能被外壳直接 `await`，而 `endOfFrame` 依赖后续帧。
      // Region 与 Flutter 布局无关，一次事件循环让位即足够。
      await Future<void>.microtask(() {});
      final Rect petLocal = FixedCanvasGeometry.petLocalRect(
        petAnchor: anchor,
        petSize: pet,
      );
      final RegionCommitOutcome outcome = await _coordinator.apply(
        owner: RegionOwner.pet,
        rects: <Rect>[petLocal],
        source: 'probe.rebuildCanvas($reason)',
        stillValid: () => mounted,
      );
      _regionRects = <Rect>[petLocal];
      _lastApply = _applyResultOf(outcome);
      // 10) 回读 bounds / petScreenRect。
      final Rect actual = await widget.windowOps.currentBounds();
      _canvasRect = actual;
      final Rect petScreenActual = FixedCanvasGeometry.petScreenRect(
        canvasWindowRect: actual,
        petAnchor: anchor,
        petSize: pet,
      );
      final Rect petScreenWanted =
          Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
      final double error = _rectError(petScreenActual, petScreenWanted);
      _lastRebuildAnchorErrorPx = error;
      await _refreshRegionDiagnostics();

      final bool ok = outcome.success &&
          error <= FixedCanvasAssertions.tolerancePx &&
          _sameRect(actual, safe);
      if (ok) {
        _canvasRebuildCount++;
        _canvasRebuildFailures = 0;
        wheelGeometryJournal.record(
          'wheel.canvas.rebuild',
          fields: <String, Object?>{
            'reason': reason,
            'canvas': WheelGeometryJournal.formatRect(
              Rect.fromLTWH(0, 0, plan.canvasSize.width, plan.canvasSize.height),
            ),
            'limit': '${plan.limit.width.toStringAsFixed(0)}x'
                '${plan.limit.height.toStringAsFixed(0)}',
            'workArea': '${plan.workArea.width.toInt()}x${plan.workArea.height.toInt()}',
            'requestedScale': plan.requestedScale.toStringAsFixed(2),
            'screenFactor': plan.screenFactor.toStringAsFixed(3),
            'effectiveScale': plan.effectiveScale.toStringAsFixed(2),
            'compressed': plan.compressed,
            'truncated': plan.truncated,
            'clamped': _lastRebuildClamped,
            'anchorErrorPx': error.toStringAsFixed(3),
            'rects': _regionRects.length,
          },
        );
      } else {
        wheelGeometryJournal.record(
          'wheel.canvas.rebuild.failed',
          fields: <String, Object?>{
            'reason': reason,
            'regionOk': outcome.success,
            'regionError': outcome.error,
            'anchorErrorPx': error.toStringAsFixed(3),
            'windowMatched': _sameRect(actual, safe),
          },
        );
        await _restoreCanvasPlan(
          previousPlan,
          previousPet,
          previousAnchor,
          previousCanvasRect,
          petScreen,
        );
        _canvasRebuildFailures++;
        _showMessage('轮盘画布重建失败，已回退上一次有效画布');
      }
    } catch (e) {
      wheelGeometryJournal.record(
        'wheel.canvas.rebuild.exception',
        fields: <String, Object?>{'reason': reason, 'error': '$e'},
      );
      try {
        await _restoreCanvasPlan(
          previousPlan,
          previousPet,
          previousAnchor,
          previousCanvasRect,
          (previousCanvasRect ?? Rect.zero).topLeft + previousAnchor,
        );
      } catch (_) {
        // 回退也失败：至少保证 Region 收敛到"仅桌宠"，绝不留下大透明块。
      }
    } finally {
      if (mounted && hid) await widget.windowOps.setVisible(true);
      windowsSurfaceSession.changeTo(
        restoreMode == WindowsSurfaceMode.panel
            ? restoreMode
            : WindowsSurfaceMode.petFixedCanvas,
        source: 'probe.rebuildCanvas.done($reason)',
      );
      _rebuilding = false;
      if (mounted) setState(() {});
    }
  }

  /// 重建失败时回退到**最近一次有效画布计划**（绝不留大透明窗口）。
  Future<void> _restoreCanvasPlan(
    WheelCanvasPlan? plan,
    Size pet,
    Offset anchor,
    Rect? canvasRect,
    Offset petScreen,
  ) async {
    if (plan == null || canvasRect == null || pet.width <= 0 || pet.height <= 0) {
      return;
    }
    _canvasPlanCurrent = plan;
    _canvas = plan.canvasSize;
    _petAnchor = anchor;
    _petSize = pet;
    _canvasRect = canvasRect;
    fixedCanvasAnchor.set(anchor, enabled: true);
    wheelCanvasFit.value = plan.fit;
    await widget.windowOps.commitBounds(canvasRect);
    // ⚠️ 只用一次事件循环让位，**不**等 `endOfFrame`：本方法会在
    // `rebuildFixedCanvasAt` 的失败路径里被 `await`，而那条链在
    // `flutter_tester`（没人继续泵帧）会因 `endOfFrame` **永久挂起**。
    // Region 只由 `petAnchor` + 人物尺寸推出，与 Flutter 布局无关。
    await Future<void>.microtask(() {});
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: anchor,
      petSize: pet,
    );
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.rebuildCanvas.rollback',
    );
    if (outcome.success) {
      _regionRects = <Rect>[petLocal];
      _lastApply = _applyResultOf(outcome);
    }
    await _refreshRegionDiagnostics();
  }

  static double _rectError(Rect a, Rect b) =>
      (a.left - b.left).abs() +
      (a.top - b.top).abs() +
      (a.width - b.width).abs() +
      (a.height - b.height).abs();

  static bool _sameRect(Rect a, Rect b) => _rectError(a, b) <= 0.5;

  /// 轮盘 Region = 桌宠 ∪（轮盘内部几何块平移到画布坐标）。
  ///
  /// 轮盘那部分由 `WheelRegionBuilder` 按**实际几何**生成（弧带扇形 / 按钮命中圆 /
  /// 文字 chip / 反馈条），**不含整画布**。
  List<Rect> _wheelRegion(Rect petLocal, Rect wheelLocal) {
    final WheelMenuController? wheel = _wheel;
    if (wheel == null) return <Rect>[petLocal];
    return <Rect>[
      petLocal,
      for (final Rect r in wheel.regionRects())
        r.shift(wheelLocal.topLeft),
    ];
  }

  /// 层级 / 动画结束导致**几何**变化时重写 Region（不涉及窗口）。
  Future<void> _refreshWheelRegion(String source) async {
    if (!mounted || _fallback || !_menuOpen) return;
    final WheelMenuController? wheel = _wheel;
    final Rect? local = _menuLocalRect;
    final RegionLease lease = _wheelLease;
    if (wheel == null || local == null || !lease.isValid) return;
    if (_coordinator.owner != RegionOwner.wheel) return;
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: _petSize,
    );
    final List<Rect> region = _wheelRegion(petLocal, local);
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.wheel,
      rects: region,
      source: 'probe.wheel.$source',
      stillValid: () => mounted && _menuOpen,
    );
    if (!outcome.success) return;
    _wheelLease = outcome.lease;
    _lastApply = _applyResultOf(outcome);
    _regionRects = region;
    if (mounted) setState(() {});
    // C1.1.2 §七-1：**Region 已开放** → 按最近指针位置主动重算一次 hover
    // （Windows 上菜单可能直接在静止鼠标下方展开，不会有新的 move 事件）。
    wheel.recomputeHoverFromLastPointer();
  }

  void _onWheelGeometryChanged() {
    // 换层：窗口不变，只是内部几何变了 —— 等 enterLayer 动画结束后再重算 Region
    // （动画开始时按钮还没落位，提前重算会得到一块过大的命中区）。
  }

  /// 条目被确认（松开左键）——**增量 C1：正式动作派发入口**。
  ///
  /// 架构（需求 §八）：`MenuActionRequest`（带 requestId）
  /// → `WindowsMenuActionExecutor` / 调整层 → 现有 Controller/Service
  /// → `MenuExecutionResult` → 轮盘反馈层。
  ///
  /// 视图**不**直接写数据库、不直接操作服务：一切都经上面的链路。
  void _onWheelEntryConfirmed(MenuNode entry, int index) {
    unawaited(_confirmEntry(entry, index));
  }

  /// 确认一个条目：**记录日志 + 派发**。真实确认与测试钩子走同一条路径，
  /// 避免"测试绕过了日志"这种假绿。
  Future<MenuExecutionResult> _confirmEntry(MenuNode entry, int index) {
    wheelGeometryJournal.record(
      'wheel.entry_confirmed',
      fields: <String, Object?>{
        'action': entry.actionId,
        'index': index,
        'level': _wheel?.levelIdName ?? 'none',
      },
    );
    return _dispatchAction(entry.actionId, entry);
  }

  /// 派发一个动作 id。返回结果（供测试直接 await）。
  Future<MenuExecutionResult> _dispatchAction(String actionId, MenuNode entry) async {
    // ① 幂等：同一 requestId 只执行一次（防双击重复执行）。
    final int requestId = ++_actionRequestSeq;
    final String key = '$actionId#$requestId';
    if (!_actionLedger.begin(key)) {
      wheelGeometryJournal.record(
        'wheel.action.deduped',
        fields: <String, Object?>{'action': actionId, 'requestId': requestId},
      );
      // 需求 §14：忙碌态留痕（同一动作在执行中 → 用户看到"正在执行…"）。
      wheelGeometryJournal.record(
        'wheel.action.busy',
        fields: <String, Object?>{'action': actionId, 'requestId': requestId},
      );
      return const MenuExecutionResult(
        MenuExecutionStatus.running,
        actionId: 'deduped',
      );
    }
    // 需求 §14：`wheel.action.request` —— 一次动作派发的起点。
    wheelGeometryJournal.record(
      'wheel.action.request',
      fields: <String, Object?>{
        'action': actionId,
        'canonicalActionId': actionId,
        'requestId': requestId,
        'menuLevel': _wheel?.levelIdName ?? 'none',
        'surfaceMode': windowsSurfaceSession.mode.wireName,
      },
    );
    _actionStartedAt = DateTime.now();
    // ② 执行期间禁用相同按钮（记录 in-flight 动作）。
    _inFlightActions.add(actionId);
    _actionLevelAtStart = _wheel?.levelIdName;
    if (mounted) setState(() {});
    try {
      final MenuExecutionResult result = await _runAction(actionId, entry);
      // ③ 晚到结果不得恢复旧 UI：层级 / 菜单已变就只记日志。
      final bool stale = !_menuOpen || _actionLevelAtStart != _wheel?.levelIdName;
      if (stale) {
        wheelGeometryJournal.record(
          'wheel.action.late_result_dropped',
          fields: <String, Object?>{
            'action': actionId,
            'status': result.status.wireName,
          },
        );
      } else {
        _presentActionResult(actionId, result);
      }
      return result;
    } finally {
      _inFlightActions.remove(actionId);
      _actionLedger.finish(key);
      if (mounted) setState(() {});
    }
  }

  Future<MenuExecutionResult> _runAction(String actionId, MenuNode entry) async {
    // ① 轮盘内调整层的加减 / 恢复默认（就地生效，必要时重建画布）。
    final ({WheelAdjustmentKind kind, WheelAdjustmentVerb verb})? adjust =
        WheelAdjustmentActionIds.parse(actionId);
    if (adjust != null) {
      return _applyAdjustment(adjust.kind, adjust.verb);
    }
    // ② 层级入口 / 返回：由菜单栈处理，不产生业务结果。
    if (_targetLevelOf(actionId) != null ||
        WheelMenuController.adjustmentKindForAction(actionId) != null) {
      _wheel?.enterLayerByAction(actionId);
      return MenuExecutionResult.success('已进入「${entry.labelZh}」', actionId);
    }
    if (actionId == MenuNavigationIds.back) {
      _wheel?.back();
      return MenuExecutionResult.success('已返回', actionId);
    }
    // ③ 窗口级动作 + 业务动作：交给正式执行器（不在此处复制业务逻辑）。
    final WindowsMenuActionExecutor? executor = widget.wheelActionExecutor;
    if (executor == null) {
      return MenuExecutionResult.unavailable(
        '动作执行器未装配，暂时无法执行「${entry.labelZh}」',
        actionId: actionId,
      );
    }
    return executor.execute(actionId);
  }

  /// 调整层：加减 / 恢复默认 → 写设置 → （尺寸类）安全重建画布 → 恢复原层。
  Future<MenuExecutionResult> _applyAdjustment(
    WheelAdjustmentKind kind,
    WheelAdjustmentVerb verb,
  ) async {
    final double before = _readAdjustValue(kind);
    final double after = switch (verb) {
      WheelAdjustmentVerb.reset => kind.defaultValue,
      WheelAdjustmentVerb.increase =>
        kind.isNumeric ? WheelAdjustmentLayer.stepped(kind, before, 1) : before,
      WheelAdjustmentVerb.decrease =>
        kind.isNumeric ? WheelAdjustmentLayer.stepped(kind, before, -1) : before,
    };
    if (kind.isNumeric && after == before) {
      return MenuExecutionResult.unavailable(
        WheelAdjustmentLayer.atMax(kind, before)
            ? '${kind.labelZh}已到最大（${kind.formatValue(before)}）'
            : '${kind.labelZh}已到最小（${kind.formatValue(before)}）',
        actionId: WheelAdjustmentActionIds.increase(kind),
      );
    }

    // 主题：**只改颜色**，不需要重建 HWND；打开的轮盘即时重绘。
    if (kind == WheelAdjustmentKind.theme) {
      final String next = WheelAdjustmentLayer.nextThemeId(
        _currentThemeId(),
        verb == WheelAdjustmentVerb.decrease ? -1 : 1,
      );
      await widget.applyWheelTheme?.call(next);
      _settingRevision.bump();
      return MenuExecutionResult.success('主题已切换', WheelAdjustmentActionIds.increase(kind));
    }

    // 数值类：写设置。
    await widget.applyWheelSetting?.call(kind, after);
    final int revision = _settingRevision.bump();
    _refreshAdjustmentLayer(kind, after);

    // 几何变化 → 关闭态安全重建固定画布（保持 petScreenPosition 不变），
    // 然后自动重新打开轮盘并恢复到**原调整层**。
    if (_affectsCanvasGeometry(kind)) {
      final String? levelId = _wheel?.levelIdName;
      final int? selected = _wheel?.highlightIndex;
      final CanvasRebuildOutcome outcome = await rebuildFixedCanvasAt(
        _currentPetScreenPosition(),
        reason: 'adjust_${kind.id}',
        expectedRevision: revision,
      );
      switch (outcome) {
        case CanvasRebuildOutcome.applied:
          await _reopenAtLevel(levelId, selected);
        case CanvasRebuildOutcome.superseded:
          // 被更新的一次调整取代：设置**保持**（不回滚、不重开），
          // 让持有最新修订号的那次负责重建 + 重开。
          return MenuExecutionResult.success(
            '${kind.labelZh}：${kind.formatValue(after)}',
            WheelAdjustmentActionIds.increase(kind),
          );
        case CanvasRebuildOutcome.failed:
          // 真失败 → 回滚到旧设置 + 明确失败反馈
          // （绝不留错误位置 / 大透明遮挡）。
          await widget.applyWheelSetting?.call(kind, before);
          _settingRevision.bump();
          _refreshAdjustmentLayer(kind, before);
          return MenuExecutionResult.failed(
            '${kind.labelZh}调整失败，已回滚到 ${kind.formatValue(before)}',
            actionId: WheelAdjustmentActionIds.increase(kind),
          );
      }
    }
    return MenuExecutionResult.success(
      '${kind.labelZh}：${kind.formatValue(after)}',
      WheelAdjustmentActionIds.increase(kind),
    );
  }

  /// 主题是否需要重建 HWND：**不需要**（只改颜色）。
  static bool _affectsCanvasGeometry(WheelAdjustmentKind kind) =>
      kind == WheelAdjustmentKind.wheelScale ||
      kind == WheelAdjustmentKind.buttonScale ||
      kind == WheelAdjustmentKind.menuDistance;

  double _readAdjustValue(WheelAdjustmentKind kind) {
    if (kind == WheelAdjustmentKind.theme) return 0;
    return widget.readWheelSetting?.call(kind) ?? kind.defaultValue;
  }

  String _currentThemeId() =>
      widget.readWheelSetting == null ? WheelThemeIds.p3pPink : wheelTheme.themeId;

  /// 用最新值重建"当前值"那一行（不关菜单、不重建画布）。
  ///
  /// 调整层的动态解析器会读 `widget.readWheelSetting`，而设置**已经写完了**，
  /// 因此这里只需让控制器重新解析一次当前层。
  void _refreshAdjustmentLayer(WheelAdjustmentKind kind, double value) {
    assert(kind.isNumeric || kind == WheelAdjustmentKind.theme);
    _wheel?.refreshAdjustmentLevel();
    if (mounted) setState(() {});
  }

  /// 重建后自动重开轮盘并**恢复到原层级 / 原选中项**。
  Future<void> _reopenAtLevel(String? levelId, int? selectedIndex) async {
    final WheelExpansionSide? side = _lastExpansionSide;
    await open(restoreLevelId: levelId, restoreIndex: selectedIndex);
    wheelGeometryJournal.record(
      'wheel.adjust.reopened',
      fields: <String, Object?>{
        'side': side?.wireName ?? 'none',
        'level': levelId ?? 'root',
        'index': selectedIndex ?? 0,
      },
    );
  }

  /// 把执行结果呈现到轮盘反馈层（成功 / 已保存 / 需登录 / 权限 / 失败）。
  void _presentActionResult(String actionId, MenuExecutionResult result) {
    final String message = switch (result.status) {
      MenuExecutionStatus.success => result.message ?? '已完成',
      MenuExecutionStatus.running => result.message ?? '正在执行…',
      MenuExecutionStatus.requiresLogin => result.reason ?? '需要先登录',
      MenuExecutionStatus.requiresPermission => result.reason ?? '权限不足',
      MenuExecutionStatus.unavailable => result.reason ?? '暂不可用',
      MenuExecutionStatus.failed => result.reason ?? '操作失败',
    };

    // 需求 §14：每次动作结果留痕（含耗时与结果类型）。
    final DateTime? startedAt = _actionStartedAt;
    final int elapsedMs =
        startedAt == null ? 0 : DateTime.now().difference(startedAt).inMilliseconds;
    final Map<String, Object?> fields = <String, Object?>{
      'canonicalActionId': actionId,
      'menuLevel': _wheel?.levelIdName ?? 'none',
      'surfaceMode': windowsSurfaceSession.mode.wireName,
      'resultKind': result.status.wireName,
      'feedbackKind': WheelFeedbackKind.fromResult(result).wireName,
      'elapsedMs': elapsedMs,
      if (result.navigation != null) 'navigation': result.navigation!.wireName,
      if (result.reason != null) 'errorType': result.status.wireName,
    };
    wheelGeometryJournal.record(
      result.status == MenuExecutionStatus.failed
          ? 'wheel.action.failure'
          : 'wheel.action.result',
      fields: fields,
    );

    _onWheelFeedback(message);
  }

  /// 当前人物屏幕位置（重建时保持它不变）。
  Offset _currentPetScreenPosition() {
    final Rect? canvas = _canvasRect;
    if (canvas == null) return _petAnchor;
    return Offset(canvas.left + _petAnchor.dx, canvas.top + _petAnchor.dy);
  }

  void _onWheelFeedback(String message) {
    _wheel?.setFeedback(message);
    _showMessage(message);
    _forwardWheelFeedback(message);
  }

  /// 反馈条会改变 Region（窗口底部多一条）——单独重算一次。
  void _forwardWheelFeedback(String message) {
    unawaited(_refreshWheelRegion('feedback'));
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 1600), () {
      _wheel?.setFeedback(null);
      unawaited(_refreshWheelRegion('feedback_clear'));
    });
  }

  void _onWheelAnimationFinished(WheelAnimationKind kind) {
    switch (kind) {
      case WheelAnimationKind.open:
        // 按钮全部落位：这是**唯一**因动画而重写 Region 的时机。
        unawaited(_refreshWheelRegion('open_anim'));
      case WheelAnimationKind.close:
        unawaited(_finishClose());
      case WheelAnimationKind.enterLayer:
      case WheelAnimationKind.exitLayer:
        unawaited(_refreshWheelRegion('layer_anim'));
      case WheelAnimationKind.selectionSwitch:
      case WheelAnimationKind.press:
        break;
    }
  }

  /// 动作 id → 目标层级（子菜单入口）；非层级入口返回 null。
  static String? _targetLevelOf(String actionId) => switch (actionId) {
        'open_pet' => MenuCatalog.petLevelId,
        'open_appearance' => MenuCatalog.appearanceLevelId,
        'open_records' => MenuCatalog.recordsLevelId,
        'open_tools' => MenuCatalog.toolsLevelId,
        'open_settings' => MenuCatalog.settingsLevelId,
        _ => null,
      };

  // ---------------------------------------------------------------------------
  // C1.1 统一坐标管线：唯一入口 + 唯一换算
  // ---------------------------------------------------------------------------

  /// 刷新人物视觉边界（alpha 包围盒）并**构建空间快照**。
  ///
  /// 这是"画布几何"的唯一产生点：所有下游（Painter / Region / 方向判定 /
  /// 缺口 / CanvasPlan）都只消费返回的快照，禁止各自再算一套。
  ///
  /// [bumpGeometry] = true 表示"输入真的变了"（桌宠尺寸 / 位置 / 素材变化），
  /// 此时自增几何修订号，让**在飞的旧计算**在提交前被判定为过期。
  Future<WheelSpaceSnapshot> _buildSpace({
    required Rect canvasWindowRect,
    bool bumpGeometry = false,
  }) async {
    // ① 先拿 alpha 边界（渲染器已量到就用缓存；没量到就等一次首帧测量）。
    final Future<PetVisualBounds> Function()? ensure =
        widget.ensurePetVisualBounds;
    if (ensure != null) {
      final PetVisualBounds measured = await ensure();
      if (!identical(measured, _petVisualBounds) && measured != _petVisualBounds) {
        _petVisualBounds = measured;
        bumpGeometry = true;
      }
    } else {
      final PetVisualBounds? cached = widget.petVisualBounds?.call();
      if (cached != null && cached != _petVisualBounds) {
        _petVisualBounds = cached;
        bumpGeometry = true;
      }
    }
    if (bumpGeometry) _geometryRevision.bump();

    // ② 顺序固定：alpha bounds → Widget 局部 → 画布局部 → 屏幕。
    final WheelSpaceSnapshot space = WheelCoordinatePipeline.build(
      canvasWindowRect: canvasWindowRect,
      petAnchor: _petAnchor,
      petSize: _petSize,
      bounds: _petVisualBounds,
      positionRevision: _positionRevision.value,
      geometryRevision: _geometryRevision.value,
      surfaceGeneration: _surfaceGeneration.value,
    );
    _space = space;
    _syncVisualRects();
    return space;
  }

  /// 兼容占位：视觉矩形现在**按需现算**（[petVisualLocalRect]），不再存字段
  /// —— 存字段会让"画布刚就位、菜单还没开"的时刻读到 0。
  void _syncVisualRects() {}

  /// 当前人物视觉矩形（画布局部）。
  ///
  /// 没有空间快照时（例如刚 prepare 完还没打开菜单）**按需现算**一次：
  /// 这样"画布已就位、菜单还没开"的时刻读到的也是真值，而不是 0。
  Rect get petVisualLocalRect {
    final WheelSpaceSnapshot? space = _space;
    if (space != null) return space.petVisualLocalRect;
    final Rect? canvas = _canvasRect;
    if (canvas == null) return Rect.zero;
    return _buildSpaceSync(canvas).petVisualLocalRect;
  }

  /// 当前人物视觉矩形（屏幕逻辑像素）。
  Rect get petVisualScreenRect =>
      _space?.petVisualScreenRect ?? petVisualLocalRect.shift((_canvasRect ?? Rect.zero).topLeft);

  /// 同步版本的空间快照（不改修订号、不做 IO；只用于只读读取）。
  WheelSpaceSnapshot _buildSpaceSync(Rect canvasWindowRect) =>
      WheelCoordinatePipeline.build(
        canvasWindowRect: canvasWindowRect,
        petAnchor: _petAnchor,
        petSize: _petSize,
        bounds: _petVisualBounds,
        positionRevision: _positionRevision.value,
        geometryRevision: _geometryRevision.value,
        surfaceGeneration: _surfaceGeneration.value,
      );

  Rect _petScreenOf(Rect windowRect) => FixedCanvasGeometry.petScreenRect(
        canvasWindowRect: windowRect,
        petAnchor: _petAnchor,
        petSize: _petSize,
      );

  /// 回退：清 Region + 把窗口缩回桌宠矩形（旧的"小窗口桌宠"）。
  Future<void> _fallbackToSmallWindow(Rect petLocal) async {
    _gate.forceClosed(reason: 'fallbackToSmallWindow');
    _wheelLease = const RegionLease.none();
    _contextMenuLease = const RegionLease.none();
    _feedbackTimer?.cancel();
    _wheel?.dispose();
    _wheel = null;
    _wheelEnvelope = null;
    await _coordinator.clear(
      owner: RegionOwner.pet,
      source: 'probe.fallbackToSmallWindow',
    );
    final Rect? canvasRect = _canvasRect;
    if (canvasRect != null) {
      await widget.windowOps.commitBounds(
        FixedCanvasGeometry.petScreenRect(
          canvasWindowRect: canvasRect,
          petAnchor: _petAnchor,
          petSize: _petSize,
        ),
      );
    }
    fixedCanvasAnchor.clear();
    _fallback = true;
    _menuOpen = false;
    _menuLocalRect = null;
    _regionRects = const <Rect>[];
    if (mounted) setState(() {});
    widget.onFallback?.call();
  }

  /// **三者一致性自检**：可见 UI / RegionOwner / WheelInteractionState。
  ///
  /// 不一致时记录 `region.consistency.violation` 并**安全回退**到"仅桌宠"。
  void _verifyRegionConsistency(String label) {
    final String? violation = verifyRegionConsistencyNow();
    if (violation == null) return;
    wheelGeometryJournal.record(
      'region.consistency.violation',
      fields: <String, Object?>{'label': label, 'reason': violation},
    );
  }

  /// 执行一次一致性自检；发现不一致时**异步安全回退**（Region 拉回 pet、
  /// 状态机复位到 closed）。返回违规原因（null = 一致）。
  ///
  /// 面板侧（非稳定桌宠态）由面板事务负责，这里不介入。
  @visibleForTesting
  String? verifyRegionConsistencyNow() {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) {
      return null;
    }
    final String? violation = RegionUiConsistency.evaluate(
      owner: _coordinator.owner,
      desiredCleared: _coordinator.isDesiredCleared,
      wheelState: _gate.state,
      contextMenuOpen: contextMenuBridge.isOpen,
    );
    if (violation == null) return null;
    unawaited(_recoverToPet('consistency:$violation'));
    return violation;
  }

  /// 安全回退：把 Region 拉回"仅桌宠"，并把左键状态机复位到 closed。
  Future<void> _recoverToPet(String reason) async {
    _gate.forceClosed(reason: 'recoverToPet');
    _menuOpen = false;
    _menuLocalRect = null;
    _wheelLease = const RegionLease.none();
    _contextMenuLease = const RegionLease.none();
    _feedbackTimer?.cancel();
    _wheel?.dispose();
    _wheel = null;
    _wheelEnvelope = null;
    if (_canvasRect == null) return;
    final Rect petLocal = FixedCanvasGeometry.petLocalRect(
      petAnchor: _petAnchor,
      petSize: _petSize,
    );
    final RegionCommitOutcome outcome = await _coordinator.apply(
      owner: RegionOwner.pet,
      rects: <Rect>[petLocal],
      source: 'probe.recoverToPet($reason)',
    );
    if (!outcome.success) {
      await _coordinator.clear(
        owner: RegionOwner.pet,
        source: 'probe.recoverToPet.clear',
      );
    }
    if (mounted) {
      setState(() {
        _regionRects = <Rect>[petLocal];
      });
    }
  }

  RegionApplyResult? _applyResultOf(RegionCommitOutcome outcome) {
    switch (outcome.status) {
      case RegionCommitStatus.rejectedDisposed:
      case RegionCommitStatus.droppedStale:
      case RegionCommitStatus.rejectedLowerPriority:
      case RegionCommitStatus.rejectedMode:
      case RegionCommitStatus.rejectedEmptyRects:
        return null;
      case RegionCommitStatus.applied:
      case RegionCommitStatus.cleared:
      case RegionCommitStatus.unchanged:
        return RegionApplyResult(
          success: true,
          rectCount: outcome.rects.length,
          boundingBox: outcome.rects.isEmpty
              ? null
              : FixedCanvasDpi.rectToPhysical(outcome.rects.first, _dpr),
        );
      case RegionCommitStatus.nativeFailure:
        return RegionApplyResult.failure(outcome.error ?? outcome.wireName);
    }
  }

  Future<void> _refreshRegionDiagnostics() async {
    _regionBox = await _coordinator.regionBoundingBox();
    _gdiCount = await _coordinator.gdiObjectCount();
  }

  /// 画布矩形夹取到可见显示器（保证至少 [minVisible] 像素可见；支持负坐标）。
  Rect _clampCanvas(Rect rect, WheelDisplayArea? display) {
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

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _message = message);
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _message = null);
    });
  }

  FixedCanvasProbeDiagnostics _diagnostics() => FixedCanvasProbeDiagnostics(
        fixedCanvasRect: _canvasRect,
        petAnchor: _petAnchor,
        petSize: _petSize,
        petScreenRect: _canvasRect == null
            ? null
            : _petScreenOf(_canvasRect!),
        menuLocalRect: _menuLocalRect,
        interactionRegionRects: _regionRects,
        devicePixelRatio: _dpr,
        regionApplyResult: _lastApply,
        regionBoundingBox: _regionBox,
        gdiObjectCount: _gdiCount,
        windowRectBeforeOpen: _windowRectBeforeOpen,
        windowRectAfterOpen: _windowRectAfterOpen,
        windowRectAfterClose: _windowRectAfterClose,
        menuOnRight: _menuOnRight,
        assertionFailures: _assertionFailures,
        wheelUiState: _wheel?.phaseName,
        wheelInteractionState: _gate.state.wireName,
        regionOwner: _coordinator.owner.wireName,
        levelId: _wheel?.levelIdName,
        highlightIndex: _wheel?.highlightIndex,
        themeId: wheelTheme.themeId,
        wheelScale: wheelSettings.preferredScale,
        buttonScale: wheelSettings.buttonVisualScale,
        menuDistance: wheelSettings.menuDistance,
        effectiveWheelScale: effectiveWheelScale,
        canvasCompressed: canvasCompressed,
        canvasScreenFactor: canvasScreenFactor,
        canvasRebuildCount: _canvasRebuildCount,
        canvasAnchorErrorPx: _lastRebuildAnchorErrorPx,
      );

  @override
  Widget build(BuildContext context) {
    final WheelMenuController? wheel = _wheel;
    final Rect? menuRect = _menuLocalRect;
    final List<Widget> layers = <Widget>[
      // 菜单层（先画 → 在桌宠**之下**）。
      //
      // 正式 P3P 轮盘（增量 B）：整个「扇形 + 按钮 + 文字」由**一个** CustomPainter
      // 绘制，占位就是轮盘窗口矩形 —— 但**不**参与命中测试，鼠标事件由
      // 桌面层的 Region 决定（只有 Region 内的像素才会把事件送到窗口）。
      if (_menuOpen && menuRect != null && wheel != null && !_diagnosticMenuEnabled)
        Positioned(
          left: menuRect.left,
          top: menuRect.top,
          width: menuRect.width,
          height: menuRect.height,
          child: WheelMenuView(
            controller: wheel,
            debugBounds: _diagnosticsPanelEnabled,
            regionVisualization: _regionVisualization,
            regionRects: wheelRegionRects,
          ),
        ),
      // 六色块**诊断**测试菜单（默认关闭；仅诊断开关打开时替代正式轮盘）。
      if (_menuOpen && menuRect != null && _diagnosticMenuEnabled)
        Positioned(
          left: menuRect.left,
          top: menuRect.top,
          width: menuRect.width,
          height: menuRect.height,
          child: _FixedCanvasTestMenu(
            key: _menuKey,
            diagnostics: _diagnostics(),
            onClose: close,
            regionVisualization: _regionVisualization,
            onToggleRegionVisualization: _toggleRegionVisualization,
            openControlPanel: widget.onOpenControlPanel,
          ),
        ),
      // Region 可视化层（诊断），在桌宠之下。
      if (_regionVisualization)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RegionPainter(rects: _regionRects, petAnchor: _petAnchor),
            ),
          ),
        ),
      // 桌宠层（后画 → **始终在菜单之上**）。
      Positioned(
        left: _petAnchor.dx,
        top: _petAnchor.dy,
        child: widget.child,
      ),
      // 诊断面板（默认关闭；打开后显示轮盘 / Region / 原生状态快照）。
      if (_diagnosticsPanelEnabled)
        Positioned(
          right: 8,
          bottom: 8,
          width: 268,
          child: _WheelDiagnosticsCard(
            diagnostics: _diagnostics(),
            onClose: () => setDiagnosticsPanelEnabled(false),
            diagnosticMenuEnabled: _diagnosticMenuEnabled,
            onToggleDiagnosticMenu: () =>
                setDiagnosticMenuEnabled(!_diagnosticMenuEnabled),
            regionVisualization: _regionVisualization,
            onToggleRegionVisualization: _toggleRegionVisualization,
            onCloseWheel: close,
          ),
        ),
      // 瞬时提示。
      if (_message != null)
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: _MessageBanner(message: _message!, failed: !_fallback && _assertionFailures.isNotEmpty),
        ),
    ];

    return Stack(children: layers);
  }
}

/// Region 可视化画笔（绿框标出当前交互区域矩形）。
class _RegionPainter extends CustomPainter {
  const _RegionPainter({required this.rects, required this.petAnchor});

  final List<Rect> rects;
  final Offset petAnchor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF00E676);
    for (final Rect r in rects) {
      canvas.drawRect(r, border);
    }
  }

  @override
  bool shouldRepaint(covariant _RegionPainter oldDelegate) =>
      oldDelegate.rects != rects || oldDelegate.petAnchor != petAnchor;
}

/// 探针测试菜单：六色块按钮 + 镜像指示 + Region 可视化开关 + 诊断面板。
///
/// **不接任何真实业务动作**（本轮只做探针）。
class _FixedCanvasTestMenu extends StatelessWidget {
  const _FixedCanvasTestMenu({
    super.key,
    required this.diagnostics,
    required this.onClose,
    required this.regionVisualization,
    required this.onToggleRegionVisualization,
    this.openControlPanel,
  });

  final FixedCanvasProbeDiagnostics diagnostics;
  final Future<void> Function() onClose;
  final bool regionVisualization;
  final VoidCallback onToggleRegionVisualization;
  final Future<void> Function()? openControlPanel;

  static const List<Color> _swatches = <Color>[
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
  ];

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF21B2430),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: diagnostics.passed ? Colors.white24 : const Color(0xFFE53935),
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '固定画布 Region 探针 · TEST',
                    style: TextStyle(
                      color: diagnostics.passed
                          ? Colors.white
                          : const Color(0xFFFF8A80),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => onClose(),
                  icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                  tooltip: '关闭菜单',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 132,
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  for (int i = 0; i < _swatches.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        color: _swatches[i],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'B${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '镜像：${diagnostics.menuOnRight == true ? '右侧' : '左侧'} · '
                    'Region ${regionVisualization ? 'ON' : 'OFF'}',
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
                Switch(
                  value: regionVisualization,
                  onChanged: (_) => onToggleRegionVisualization(),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    diagnostics.toCopyText(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 9,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
            if (openControlPanel != null) ...<Widget>[
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: () => openControlPanel!(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  minimumSize: const Size.fromHeight(28),
                ),
                child: const Text('打开控制面板', style: TextStyle(fontSize: 11)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 轮盘 / Region **诊断卡片**（默认关闭）。
///
/// 保留增量 A 的诊断观测点：RegionOwner、WheelUiState、层级、槽位、主题、尺寸、
/// Region 矩形数、GDI 对象数、硬断言、Region 边界可视化，以及"复制诊断文本"与
/// **六色块测试菜单开关**（默认关闭）。
class _WheelDiagnosticsCard extends StatelessWidget {
  const _WheelDiagnosticsCard({
    required this.diagnostics,
    required this.onClose,
    required this.diagnosticMenuEnabled,
    required this.onToggleDiagnosticMenu,
    required this.regionVisualization,
    required this.onToggleRegionVisualization,
    required this.onCloseWheel,
  });

  final FixedCanvasProbeDiagnostics diagnostics;
  final VoidCallback onClose;
  final bool diagnosticMenuEnabled;
  final VoidCallback onToggleDiagnosticMenu;
  final bool regionVisualization;
  final VoidCallback onToggleRegionVisualization;
  final Future<void> Function() onCloseWheel;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xF21B2430),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: diagnostics.passed ? Colors.white24 : const Color(0xFFE53935),
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '轮盘诊断 · ${diagnostics.passed ? 'PASS' : 'FAIL'}',
                      style: TextStyle(
                        color: diagnostics.passed
                            ? Colors.white
                            : const Color(0xFFFF8A80),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: Colors.white70, size: 16),
                    tooltip: '关闭诊断面板',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  diagnostics.toCopyText(),
                  style: const TextStyle(color: Colors.white70, fontSize: 9, height: 1.3),
                ),
              ),
              const SizedBox(height: 4),
              _diagSwitch('六色块测试菜单', diagnosticMenuEnabled, onToggleDiagnosticMenu),
              _diagSwitch('显示 Region 边界', regionVisualization, onToggleRegionVisualization),
              const SizedBox(height: 4),
              OutlinedButton(
                onPressed: () => onCloseWheel(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  minimumSize: const Size.fromHeight(26),
                ),
                child: const Text('关闭轮盘', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      );

  Widget _diagSwitch(String label, bool value, VoidCallback onToggle) => Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ),
          Switch(
            value: value,
            onChanged: (_) => onToggle(),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      );
}

/// 默认轮盘几何设置（外壳未注入时的兜底 = Android 默认值）。
WheelMenuLayoutSettings _defaultWheelSettings() => WheelMenuLayoutSettings.defaults;

/// 默认轮盘主题（外壳未注入时的兜底 = P3P 粉）。
WheelMenuTheme _defaultWheelTheme() => WheelMenuThemes.p3pPink();

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, required this.failed});

  final String message;
  final bool failed;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: failed ? const Color(0xE6B71C1C) : const Color(0xE6313A4A),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      );
}

/// 固定画布探针宿主：包住桌宠视图，并把测试菜单叠在同一个固定窗口里。
class FixedCanvasProbe extends StatefulWidget {
  const FixedCanvasProbe({
    super.key,
    required this.child,
    required this.windowOps,
    required this.coordinator,
    required this.petSize,
    required this.savedWindowPosition,
    required this.isMousePassthrough,
    this.persistPetScreenPosition,
    this.wheelActionExecutor,
    this.applyWheelSetting,
    this.applyWheelTheme,
    this.readWheelSetting,
    this.petVisualBounds,
    this.ensurePetVisualBounds,
    this.wheelSettings = _defaultWheelSettings,
    this.wheelTheme = _defaultWheelTheme,
    this.wheelInfoProvider,
    this.onOpenControlPanel,
    this.onOpenChanged,
    this.onFallback,
    this.reestablishOn,
    this.config = const FixedCanvasConfig(),
    this.menuSize = const Size(360, 360),
  });

  /// 桌宠视图（外壳传入）。
  final Widget child;

  /// 窗口几何操作（生产 = `WindowsFixedCanvasWindowOps`；测试注入假实现）。
  final FixedCanvasWindowOps windowOps;

  /// **窗口 Region 的唯一协调器**（生产由外壳构造并注入；测试注入假原生实现）。
  final RegionCoordinator coordinator;

  /// 当前桌宠逻辑尺寸。
  final Size Function() petSize;

  /// 轮盘几何设置（来自持久化设置；缺省 = Android 默认值）。
  final WheelMenuLayoutSettings Function() wheelSettings;

  /// 当前轮盘主题（来自持久化设置；缺省 = P3P 粉）。
  final WheelMenuTheme Function() wheelTheme;

  /// 选中项实时信息（增量 C 接入业务后填充；B 阶段通常返回 null）。
  final String? Function(MenuNode entry)? wheelInfoProvider;

  /// 已保存的**位置**（含语义版本）。
  ///
  /// * `x` / `y`：null = 首次运行（用默认角落）；
  /// * `schema`：这些值被写入时的语义版本（[WindowPositionSchema]）。无版本 = 0；
  /// * `legacyWindowSize`：v1 数据写入时**窗口**的尺寸；仅当它 ≈ 人物尺寸时，
  ///   v1 的窗口左上角才等价于人物左上角（可安全迁移）。null = 语义无法确定。
  final ({double? x, double? y, int schema, Size? legacyWindowSize})
      Function() savedWindowPosition;

  /// 立刻持久化**修正后**的 `petScreenPosition`（v2）。
  ///
  /// 迁移 / 修正只执行一次；写回后本次会话**不再读取旧值**。
  final Future<void> Function(Offset petScreenPosition, {required int schemaVersion})?
      persistPetScreenPosition;

  /// 鼠标穿透是否开启（开启时拒绝打开菜单并给出明确提示）。
  final bool Function() isMousePassthrough;

  // --- C1.1：人物视觉边界（alpha 包围盒）注入点 ---

  /// 读取**已测量**的人物视觉边界（同步；未量到返回 null）。
  ///
  /// 缺口 / 方向 / 画布规划必须用它，**不得**用素材尺寸或 Widget 矩形顶替。
  final PetVisualBounds? Function()? petVisualBounds;

  /// 保证至少量到一帧视觉边界（异步；规划画布 / 打开菜单前 `await` 它）。
  final Future<PetVisualBounds> Function()? ensurePetVisualBounds;

  // --- 增量 C1：正式动作派发所需的注入点 ---

  /// **正式动作执行器**（窗口级 + 业务动作）。由外壳装配（含业务桥）。
  final WindowsMenuActionExecutor? wheelActionExecutor;

  /// 写入轮盘几何设置（供调整层使用）。**唯一**入口，视图不直接写库。
  final Future<void> Function(WheelAdjustmentKind kind, double value)? applyWheelSetting;

  /// 即时切换主题（只改颜色，不重建 HWND）。
  final Future<void> Function(String themeId)? applyWheelTheme;

  /// 读取轮盘几何设置当前值（供调整层显示"当前值"）。
  final double Function(WheelAdjustmentKind kind)? readWheelSetting;

  final Future<void> Function()? onOpenControlPanel;

  /// 菜单开合状态变化（外壳据此联动）。
  final ValueChanged<bool>? onOpenChanged;

  /// Region 应用失败回退到小窗口时触发。
  final VoidCallback? onFallback;

  /// 桌宠尺寸可能变化的信号（例如设置变化）；用于重新居中画布。
  final Listenable? reestablishOn;

  final FixedCanvasConfig config;

  /// 测试菜单包围盒尺寸（逻辑像素）。
  final Size menuSize;

  @override
  State<FixedCanvasProbe> createState() => FixedCanvasProbeState();
}
