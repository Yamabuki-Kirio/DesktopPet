/// 固定画布**规划器**（增量 B 修正版：按「当前设置 + 当前显示器可用空间」算画布）。
///
/// 修正了什么问题
/// --------------
/// 上一版为了「拖动任何设置滑块都不改窗口矩形」，把画布按
/// `preferredScale / buttonVisualScale / menuDistance` 的**上限**预留
/// （2.50 / 2.50 / 0.30），结果 256px 桌宠也要一块 `2054×2054` 的常驻透明窗口 ——
/// 在 1920×1040 工作区上明显不可接受（见 `docs/38` §10）。
///
/// 现在的口径（操作者决策）
/// ------------------------
/// * 画布由**当前**设置 + **当前**桌宠可见尺寸 + **当前**显示器工作区共同决定；
/// * 菜单开 / 关、层级切换、返回、悬停、滑动、按压、选中反馈、右键菜单开关期间
///   **窗口矩形恒定**；
/// * 只有「几何设置变化 / 桌宠尺寸变化 / 显示器或 DPI 变化 / 从面板返回桌宠」
///   才在**菜单关闭**状态下原子重建一次画布（由探针的事务负责）。
///
/// 三条纪律
/// --------
/// 1. **不新造视觉常量**：所需空间完全由 Android 的
///    `WheelMenuGeometry.computeEnvelope` 在「虚拟大屏」上的绘制包围盒推导 ——
///    左右两种展开方向 × 三种竖直模式共 6 次测量取四侧最大外扩量；
/// 2. **屏幕放不下就用 Android 自己的设备级应急缩放**
///    （`WheelMenuGeometry.deviceEmergencyScale` 的同一口径）：二分求最大的
///    `screenFactor ∈ [minActualScale, 1]`，使画布不超过工作区预算的上限；
/// 3. **不裁切、也不建超大窗口**：压到 `minActualScale` 仍放不下时，把画布夹到
///    明确上限并标记 `truncated`，由上层给出「已按当前屏幕自动压缩」的提示。
///
/// dp 与逻辑像素
/// -------------
/// 与 `WheelCanvasBridge` 同口径：`density = 1.0`（1 dp = 1 逻辑像素）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show ValueNotifier, immutable;

import '../character/pet_visual_bounds.dart' show PetVisualBounds;
import 'menu_contract.dart' show MenuCatalog, MenuLevel, MenuNode;
import 'wheel_menu_geometry.dart'
    show
        WheelExpandDirection,
        WheelIntrinsicLayout,
        WheelMenuEnvelope,
        WheelMenuGeometry,
        WheelMenuLayout,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect,
        WheelVerticalMode;
import 'wheel_visual_bounds.dart' show WheelVisualBounds, WheelVisualBoundsCalculator;

/// 一次「屏幕适配」的结果快照（供设置页显示「当前屏幕实际显示」）。
@immutable
class WheelCanvasFit {
  const WheelCanvasFit({
    required this.requestedScale,
    required this.effectiveScale,
    required this.compressed,
    required this.truncated,
    required this.reason,
    required this.canvasSize,
    required this.workArea,
    required this.petSize,
  });

  /// 用户设置值（保存的仍然是它）。
  final double requestedScale;

  /// 当前屏幕上**实际**用的轮盘大小 = `requestedScale × screenFactor`。
  final double effectiveScale;

  /// 是否因为屏幕放不下而被压缩（`screenFactor < 1`）。
  final bool compressed;

  /// 是否压到最小仍超出屏幕（画布被夹到上限，属极端情形）。
  final bool truncated;

  /// 压缩原因（`null` = 未压缩）。
  final String? reason;

  /// 本次规划出的画布尺寸（逻辑像素）。
  final Size canvasSize;

  /// 当前显示器工作区（逻辑像素）。
  final Size workArea;

  /// 桌宠可见尺寸（设置页据此本地重算「实际显示」，无需等探针广播）。
  final Size petSize;

  /// 屏幕适配系数（`effectiveScale / requestedScale`）。
  double get screenFactor =>
      requestedScale <= 0 ? 1.0 : (effectiveScale / requestedScale).clamp(0.0, 1.0);

  /// 是否需要在设置页显示「受当前显示器可用空间限制」。
  bool get limitedByScreen => compressed;

  @override
  String toString() => 'WheelCanvasFit(请求 ${(requestedScale * 100).round()}% '
      '实际 ${(effectiveScale * 100).round()}% '
      'screenFactor=${screenFactor.toStringAsFixed(3)} '
      'canvas=${canvasSize.width.toStringAsFixed(0)}×${canvasSize.height.toStringAsFixed(0)} '
      'reason=${reason ?? 'none'})';
}

/// 模块级广播：探针每次算出画布计划后写入，设置页只读它显示「实际显示」。
///
/// 与 `FixedCanvasDiagnosticsFlags` 同思路：跨窗口（桌宠窗 ↔ 控制面板窗）
/// 共享的运行时状态，单例 + `ValueNotifier`，不需要任何原生通道。
final ValueNotifier<WheelCanvasFit?> wheelCanvasFit =
    ValueNotifier<WheelCanvasFit?>(null);

/// 一次固定画布规划的结果（纯数据，可单测）。
@immutable
class WheelCanvasPlan {
  const WheelCanvasPlan({
    required this.petSize,
    required this.workArea,
    required this.limit,
    required this.canvasSize,
    required this.petAnchor,
    required this.reachLeft,
    required this.reachRight,
    required this.reachUp,
    required this.reachDown,
    required this.requestedScale,
    required this.screenFactor,
    required this.compressed,
    required this.truncated,
    required this.reason,
    this.petVisualBounds = PetVisualBounds.full,
    this.visualBoundsInCanvas = Rect.zero,
    this.interactiveBoundsInCanvas = Rect.zero,
    this.visualFitsCanvas = true,
    this.interactiveFitsCanvas = true,
  });

  /// 人物 alpha 包围盒（本次规划用到的输入，留档以便复现）。
  final PetVisualBounds petVisualBounds;

  /// 全部绘制元素在**画布局部坐标**里的并集（= "轮盘真正画到哪"）。
  final Rect visualBoundsInCanvas;

  /// 交互内容（按钮 / 标签 / chip / 反馈）在画布局部坐标里的并集。
  final Rect interactiveBoundsInCanvas;

  /// `visualBounds + safetyPadding` 是否完整在画布内。
  final bool visualFitsCanvas;

  /// `interactiveBounds + safetyPadding` 是否完整在画布内。
  ///
  /// 为 false 时**不允许**打开轮盘（需求 §六：交互内容放不下必须明确拒绝，
  /// 而不是裁掉按钮还假装能用）。
  final bool interactiveFitsCanvas;

  /// 桌宠可见尺寸（画布的输入之一）。
  final Size petSize;

  /// 当前显示器工作区。
  final Size workArea;

  /// 画布尺寸的**明确上限**（= 工作区 + 允许的少量越界）。
  final Size limit;

  /// 最终画布尺寸（逻辑像素）。
  final Size canvasSize;

  /// 桌宠在画布内的锚点。
  final Offset petAnchor;

  /// 相对桌宠矩形四边的最大绘制外扩量（= 该侧预留的轮盘空间）。
  final double reachLeft;
  final double reachRight;
  final double reachUp;
  final double reachDown;

  /// 用户设置的轮盘大小。
  final double requestedScale;

  /// 屏幕适配系数 ∈ [minActualScale, 1]。
  final double screenFactor;

  /// 是否发生屏幕适配压缩。
  final bool compressed;

  /// 是否压到最小仍超出屏幕（画布被夹到 [limit]）。
  final bool truncated;

  final String? reason;

  /// 屏幕上**实际**的轮盘大小。
  double get effectiveScale => WheelMenuLayoutSettings.clampScale(
        requestedScale * screenFactor,
      );

  /// 供轮盘信封使用的设置：`preferredScale` 已按屏幕适配压缩。
  ///
  /// ⚠️ 只改 `preferredScale` —— 按钮倍率 / 菜单距离仍是用户原值，
  /// 保证「设置页显示的是用户值」这条语义不被破坏。
  WheelMenuLayoutSettings settingsFor(WheelMenuLayoutSettings base) {
    final WheelMenuLayoutSettings normalized = base.normalized();
    return normalized.copyWith(preferredScale: effectiveScale);
  }

  WheelCanvasFit get fit => WheelCanvasFit(
        requestedScale: requestedScale,
        effectiveScale: effectiveScale,
        compressed: compressed,
        truncated: truncated,
        reason: reason,
        canvasSize: canvasSize,
        workArea: workArea,
        petSize: petSize,
      );

  /// 本地化提示（设置页 / 探针消息条共用）。
  String get noticeZh {
    if (truncated) return '轮盘已压到最小仍超出屏幕可用空间，已按当前屏幕自动压缩';
    if (compressed) return '已按当前屏幕自动压缩';
    return '按当前设置完整显示';
  }

  @override
  String toString() => 'WheelCanvasPlan(canvas='
      '${canvasSize.width.toStringAsFixed(1)}×${canvasSize.height.toStringAsFixed(1)} '
      'anchor=${petAnchor.dx.toStringAsFixed(1)},${petAnchor.dy.toStringAsFixed(1)} '
      'requested=${requestedScale.toStringAsFixed(2)} '
      'screenFactor=${screenFactor.toStringAsFixed(3)} '
      'compressed=$compressed truncated=$truncated)';
}

/// 画布规划入口（纯 Dart，`flutter_tester` 直接单测）。
class WheelCanvasPlanner {
  WheelCanvasPlanner._();

  /// 逻辑像素 ↔ dp（与 `WheelCanvasBridge.density` 一致）。
  static const double density = 1.0;

  /// 允许的越界比例上限（工作区的 6%）。
  static const double maxOvershootRatio = 0.06;

  /// 允许的越界像素上限（48 逻辑像素）。
  static const double maxOvershootPx = 48;

  /// 画布四周最小安全带（抗锯齿 / 圆角溢出的余量）。
  static const double defaultMargin = 8;

  /// 二分次数（24 次 → 分辨率 ~6e-8，足够）。
  static const int _searchSteps = 24;

  /// 浮点容差。
  static const double _eps = 0.5;

  /// 显示器工作区 → 画布尺寸的**明确上限**。
  ///
  /// `limit = workArea × (1 + 6%)`，且不得超过 `workArea + 48px`；
  /// 下限是桌宠尺寸本身（桌宠比屏幕还大时只能按桌宠来）。
  static Size limitFor(Size workArea, {Size petSize = Size.zero}) {
    final double w = math.min(
      workArea.width * (1 + maxOvershootRatio),
      workArea.width + maxOvershootPx,
    );
    final double h = math.min(
      workArea.height * (1 + maxOvershootRatio),
      workArea.height + maxOvershootPx,
    );
    return Size(
      math.max(petSize.width, math.max(0, w)),
      math.max(petSize.height, math.max(0, h)),
    );
  }

  /// 相对桌宠矩形四边的最大绘制外扩量（**由视觉包围盒推导**）。
  ///
  /// C1.1 改口径（需求 §七）
  /// --------------------
  /// 旧实现用 6 次 `computeEnvelope` 的窗口矩形当近似外扩量 —— 而那个窗口只
  /// 覆盖"环带 + 刀刃 + chip"的**采样端点**，于是 Painter 真正画出来的
  /// 外缘齿轮 / 强调弧 / 按钮弹出 overshoot 会跑到窗口之外，
  /// 真机上就表现为"扇形 / 按钮 / 文字被硬直线裁切"。
  ///
  /// 现在改为**唯一来源**：先算出固有几何 → 用 [WheelVisualBoundsCalculator]
  /// 复算 Painter 会画的每一个元素 → 取并集 → 得到四侧外扩量。
  /// 画布、Region、Painter 从此同源。
  ///
  /// [petVisualBounds] 为人物 alpha 包围盒（归一化）；null = 按整张素材
  /// （调用方应在此之前 `await ensureVisualBounds()`）。
  static ({double left, double right, double up, double down}) measureReach({
    required Size petSize,
    required WheelMenuLayoutSettings settings,
    WheelMenuSpec? spec,
    int? maxItemCount,
    double density = density,
    PetVisualBounds? petVisualBounds,
  }) =>
      _visualInPetFrame(
        petSize: petSize,
        settings: settings,
        spec: spec,
        maxItemCount: maxItemCount,
        density: density,
        petVisualBounds: petVisualBounds,
      ).reach;

  /// **视觉包围盒**（相对桌宠 Widget 矩形的帧）+ 四侧外扩量。
  ///
  /// 这是画布规划与 Region 的**共同来源**：返回的 [PetFrameVisual.union] 就是
  /// "轮盘真正会画到哪"的矩形（桌宠帧坐标：人物 Widget 左上角 = (0,0)）。
  static PetFrameVisual _visualInPetFrame({
    required Size petSize,
    required WheelMenuLayoutSettings settings,
    WheelMenuSpec? spec,
    int? maxItemCount,
    double density = density,
    PetVisualBounds? petVisualBounds,
  }) {
    final WheelMenuSpec spec0 = spec ?? WheelMenuSpec.fromDensity(density);
    final int count = math.max(1, maxItemCount ?? MenuCatalog.maxItems);
    final Size pet = Size(math.max(1, petSize.width), math.max(1, petSize.height));
    final WheelMenuLayoutSettings normalized = settings.normalized();
    final PetVisualBounds bounds = petVisualBounds ?? PetVisualBounds.full;

    // 相对桌宠 Widget 矩形（左上角在 (0,0)）的帧。
    final Rect petRect = Rect.fromLTWH(0, 0, pet.width, pet.height);
    final Rect visibleRect = bounds.toRect(petRect);
    final Offset visibleCenter = visibleRect.center;

    final WheelIntrinsicLayout intrinsic = WheelMenuGeometry.intrinsicLayout(
      itemCount: count,
      spec: spec0,
      settings: normalized,
      petVisibleWidth: visibleRect.width,
      petVisibleHeight: visibleRect.height,
    );
    // 菜单中心相对人物视觉中心的偏移（与 `computeEnvelope` 同公式）。
    final double offset = math.max(
      visibleRect.width * normalized.menuDistance,
      spec0.dp(4),
    );

    double left = 0;
    double right = 0;
    double up = 0;
    double down = 0;

    void include(Rect rect) {
      left = math.max(left, -(rect.left));
      right = math.max(right, rect.right - pet.width);
      up = math.max(up, -(rect.top));
      down = math.max(down, rect.bottom - pet.height);
    }

    // 中央缺口（绑在人物视觉中心）—— 它本身也可能伸出桌宠矩形。
    include(Rect.fromCenter(
      center: visibleCenter,
      width: intrinsic.notchRx * 2 + spec0.dp(4) * 2,
      height: intrinsic.notchRy * 2 + spec0.dp(4) * 2,
    ));

    Rect union = Rect.fromCenter(
      center: visibleCenter,
      width: intrinsic.notchRx * 2,
      height: intrinsic.notchRy * 2,
    );
    // 交互内容（按钮 + 标签 + chip）的并集：截断时只允许裁**非交互装饰**。
    Rect interactive = Rect.zero;
    for (final WheelExpandDirection dir in WheelExpandDirection.values) {
      for (final WheelVerticalMode vertical in WheelVerticalMode.values) {
        final double centerX = dir == WheelExpandDirection.right
            ? visibleCenter.dx + offset
            : visibleCenter.dx - offset;
        final double centerY = visibleCenter.dy;
        final WheelVisualBounds vb = WheelVisualBoundsCalculator.compute(
          _probeLayout(
            intrinsic: intrinsic,
            direction: dir,
            verticalMode: vertical,
            centerX: centerX,
            centerY: centerY,
            itemCount: count,
            spec: spec0,
            settings: normalized,
          ),
        );
        final Rect all = vb.all;
        if (all.width <= 0 || all.height <= 0) continue;
        union = union.expandToInclude(all);
        include(all);
        // 交互内容的并集：不含 fanAndRim（纯装饰）。
        final Rect interactiveHere = _unionOf(<Rect>[vb.buttons, vb.labels, vb.texts]);
        if (interactiveHere.width > 0 && interactiveHere.height > 0) {
          interactive = interactive.width <= 0
              ? interactiveHere
              : interactive.expandToInclude(interactiveHere);
        }
      }
    }
    return PetFrameVisual(
      union: union,
      interactiveUnion: interactive,
      reach: (left: left, right: right, up: up, down: down),
    );
  }

  /// 矩形并集（忽略退化矩形）。
  static Rect _unionOf(List<Rect> rects) {
    double l = double.maxFinite;
    double t = double.maxFinite;
    double r = -double.maxFinite;
    double b = -double.maxFinite;
    for (final Rect rect in rects) {
      if (rect.width <= 0 || rect.height <= 0) continue;
      l = math.min(l, rect.left);
      t = math.min(t, rect.top);
      r = math.max(r, rect.right);
      b = math.max(b, rect.bottom);
    }
    if (l > r || t > b) return Rect.zero;
    return Rect.fromLTRB(l, t, r, b);
  }

  /// 构造一个"只用于测量包围盒"的布局（与 `layoutFor` 同公式、同输入）。
  ///
  /// 之所以不直接调 `computeEnvelope`：那个函数会**夹取到显示器**并做设备级应急
  /// 缩放，得到的窗口矩形已经被裁过，无法表达"真正会画多大"。
  static WheelMenuLayout _probeLayout({
    required WheelIntrinsicLayout intrinsic,
    required WheelExpandDirection direction,
    required WheelVerticalMode verticalMode,
    required double centerX,
    required double centerY,
    required int itemCount,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
  }) {
    // 合成信封：窗口左上角放在离中心很远的地方，使 `cx/cy` 落在"虚拟窗口"中央；
    // 测量只关心**相对中心**的尺寸，因此窗口的真实位置无关紧要。
    const double halfExtent = 100000;
    final WheelMenuEnvelope envelope = WheelMenuEnvelope(
      direction: direction,
      verticalMode: verticalMode,
      windowRect: WheelRect(
        centerX - halfExtent,
        centerY - halfExtent,
        centerX + halfExtent,
        centerY + halfExtent,
      ),
      centerX: centerX,
      centerY: centerY,
      petAnchorX: centerX,
      petAnchorY: centerY,
      holeRx: intrinsic.notchRx,
      holeRy: intrinsic.notchRy,
      allowedOffsetPx: 0,
      maxRingRadiusPx: intrinsic.ringRadiusPx,
      buttonDiameterPx: intrinsic.buttonDiameterPx,
      buttonTouchDiameterPx: math.max(
        intrinsic.buttonDiameterPx,
        spec.dp(WheelMenuLayoutSettings.buttonTouchMinDp),
      ),
      fanBiasDeg: verticalMode.biasDeg,
      preferredScale: settings.preferredScale,
      actualScale: 1.0,
      compact: intrinsic.compact,
      degraded: false,
      fallbackReason: null,
    );
    // 借用正式实现算槽位（保证与 Painter 完全同源）。
    final WheelMenuLayout layout = WheelMenuGeometry.layoutFor(
      envelope,
      _probeLevel(itemCount),
      spec,
    );
    // `layoutFor` 给的是**窗口局部**坐标（`cx = centerX - window.left = halfExtent`）
    // → 平移回"相对人物 Widget"的帧（目标 `cx = centerX`）。
    // 平移量 = 目标 − 当前 = centerX − halfExtent。
    return layout.shiftedBy(centerX - halfExtent, centerY - halfExtent);
  }

  /// 测量用的合成层级（条目数与真实根菜单一致即可影响按钮直径与张角）。
  static MenuLevel _probeLevel(int itemCount) => MenuLevel(
        id: '__probe__',
        titleZh: 'probe',
        titleEn: 'PROBE',
        nodes: <MenuNode>[
          for (int i = 0; i < itemCount; i++)
            MenuNode(id: 'probe_$i', actionId: 'probe_$i', labelZh: '测量项$i'),
        ],
      );

  /// 由外扩量得到画布尺寸（桌宠 + 四侧预留 + 最小安全带）。
  static Size canvasSizeFor({
    required Size petSize,
    required ({double left, double right, double up, double down}) reach,
    double margin = defaultMargin,
  }) {
    final double pad = math.max(0, margin);
    return Size(
      math.max(1, petSize.width) + reach.left + reach.right + pad * 2,
      math.max(1, petSize.height) + reach.up + reach.down + pad * 2,
    );
  }

  /// 规划一次固定画布。
  ///
  /// * [workArea]：当前显示器的**可用工作区**（逻辑像素）；
  /// * [settings]：用户当前设置（内部会 `normalized()`）；
  /// * [petVisualBounds]：人物 alpha 包围盒（归一化）—— 缺省按整张素材，
  ///   调用方应在此之前 `await ensureVisualBounds()`；
  /// * 结果里的 [WheelCanvasPlan.effectiveScale] 必须喂给轮盘信封，
  ///   否则轮盘会按用户原值绘制而装不进画布。
  static WheelCanvasPlan plan({
    required Size petSize,
    required Size workArea,
    required WheelMenuLayoutSettings settings,
    WheelMenuSpec? spec,
    int? maxItemCount,
    double density = density,
    double margin = defaultMargin,
    PetVisualBounds? petVisualBounds,
  }) {
    final WheelMenuSpec spec0 = spec ?? WheelMenuSpec.fromDensity(density);
    final int count = math.max(1, maxItemCount ?? MenuCatalog.maxItems);
    final WheelMenuLayoutSettings normalized = settings.normalized();
    final Size pet = Size(math.max(1, petSize.width), math.max(1, petSize.height));
    final Size area = workArea.width > 0 && workArea.height > 0
        ? workArea
        : const Size(1920, 1080);
    final Size limit = limitFor(area, petSize: pet);
    final PetVisualBounds bounds = petVisualBounds ?? PetVisualBounds.full;

    /// 给定屏幕适配系数，算出的视觉包围盒（桌宠帧）+ 画布尺寸。
    ({PetFrameVisual visual, Size canvas}) at(double factor) {
      final WheelMenuLayoutSettings scaled = normalized.copyWith(
        preferredScale:
            WheelMenuLayoutSettings.clampScale(normalized.preferredScale * factor),
      );
      final PetFrameVisual visual = _visualInPetFrame(
        petSize: pet,
        settings: scaled,
        spec: spec0,
        maxItemCount: count,
        petVisualBounds: bounds,
      );
      return (
        visual: visual,
        canvas: canvasSizeFor(petSize: pet, reach: visual.reach, margin: margin),
      );
    }

    /// 画布尺寸取整（窗口尺寸必须是整数像素）。
    Size rounded(Size s) =>
        Size(s.width.ceilToDouble(), s.height.ceilToDouble());

    /// 画布（取整后）是否不超过明确上限。
    ///
    /// 允许 **1px 取整容差**：`limit` 是策略值（工作区 + 48），而画布尺寸要取整；
    /// 若因为"1088.4 → 取整 1089 > 1088"就判"放不下"，会触发一次毫无意义的
    /// 屏幕适配压缩（并弹提示），这不是真实的空间不足。容差只在**取整**层面，
    /// 不会掩盖真正的越界（那至少是十几 px 量级）。
    bool fits(Size canvas) {
      final Size c = rounded(canvas);
      return c.width <= limit.width + 1 + _eps &&
          c.height <= limit.height + 1 + _eps;
    }

    double factor = 1.0;
    PetFrameVisual current = at(1.0).visual;
    Size canvas = canvasSizeFor(petSize: pet, reach: current.reach, margin: margin);
    bool truncated = false;
    if (!fits(canvas)) {
      final double lo0 = WheelMenuGeometry.minActualScale;
      final Size smallest = at(lo0).canvas;
      if (fits(smallest)) {
        // 二分求**最大**的可放下系数（canvasAt 对 k 单调不减）。
        double lo = lo0;
        double hi = 1.0;
        for (int i = 0; i < _searchSteps; i++) {
          final double mid = (lo + hi) / 2;
          if (fits(at(mid).canvas)) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        factor = lo;
      } else {
        // 压到最小仍放不下：夹到明确上限，交给上层提示「已按当前屏幕自动压缩」。
        factor = lo0;
        truncated = true;
      }
      current = at(factor).visual;
      canvas = canvasSizeFor(petSize: pet, reach: current.reach, margin: margin);
    }
    if (truncated) {
      canvas = Size(
        math.min(canvas.width, limit.width),
        math.min(canvas.height, limit.height),
      );
    }
    // 画布尺寸取整（避免小数尺寸的窗口矩形在真机上产生半像素边缘）。
    canvas = Size(
      math.max(canvas.width, pet.width).ceilToDouble(),
      math.max(canvas.height, pet.height).ceilToDouble(),
    );

    // 未截断时锚点按四侧预留摆放（左右大致对称 → 桌宠仍然居中）；
    // 被截断时退化为「桌宠居中」，避免桌宠跑到画布外。
    //
    // ⚠️ 锚点必须**取整**：它是"画布局部 → 屏幕"的唯一平移量，一旦是小数，
    // `Rect.fromLTWH(anchor, petSize).size` 会出现 `255.99999999999994` 这类
    // 浮点漂移，Region / 断言 / 位置持久化全部跟着抖（真机表现为 1px 抖动）。
    final Offset anchor = truncated
        ? Offset(
            ((canvas.width - pet.width) / 2).roundToDouble(),
            ((canvas.height - pet.height) / 2).roundToDouble(),
          )
        : Offset(
            (current.reach.left + margin).roundToDouble(),
            (current.reach.up + margin).roundToDouble(),
          );

    // 视觉包围盒（**画布局部坐标**）：桌宠帧原点 = 锚点。
    final Rect visualInCanvas = current.union.shift(anchor);
    // 交互内容（按钮 / 标签 / chip）是否完整在画布里 —— 截断时只允许裁装饰。
    final Rect interactiveInCanvas =
        current.interactiveUnion.shift(anchor);
    final bool interactiveFits = _contains(
      Rect.fromLTWH(0, 0, canvas.width, canvas.height),
      interactiveInCanvas.inflate(WheelVisualBoundsCalculator.safetyPadding),
    );
    final bool visualFits = _contains(
      Rect.fromLTWH(0, 0, canvas.width, canvas.height),
      visualInCanvas.inflate(WheelVisualBoundsCalculator.safetyPadding),
    );

    final bool compressed = factor < 1.0 - 1e-9;
    return WheelCanvasPlan(
      petSize: pet,
      workArea: area,
      limit: limit,
      canvasSize: canvas,
      petAnchor: anchor,
      reachLeft: current.reach.left,
      reachRight: current.reach.right,
      reachUp: current.reach.up,
      reachDown: current.reach.down,
      requestedScale: normalized.preferredScale,
      screenFactor: factor,
      compressed: compressed,
      truncated: truncated,
      petVisualBounds: bounds,
      visualBoundsInCanvas: visualInCanvas,
      interactiveBoundsInCanvas: interactiveInCanvas,
      visualFitsCanvas: visualFits,
      interactiveFitsCanvas: interactiveFits,
      reason: truncated
          ? 'screen-truncated'
          : (compressed ? 'screen-fit' : null),
    );
  }

  /// [outer] 是否完整包含 [inner]（半像素容差）。
  static bool _contains(Rect outer, Rect inner) =>
      inner.left >= outer.left - 0.5 &&
      inner.top >= outer.top - 0.5 &&
      inner.right <= outer.right + 0.5 &&
      inner.bottom <= outer.bottom + 0.5;
}

/// 桌宠帧（人物 Widget 左上角 = `(0,0)`）里的视觉包围盒 + 四侧外扩量。
@immutable
class PetFrameVisual {
  const PetFrameVisual({
    required this.union,
    required this.reach,
    this.interactiveUnion = Rect.zero,
  });

  /// 全部绘制元素的并集（桌宠帧）。
  final Rect union;

  /// 交互内容（按钮 / 标签 / chip）的并集（桌宠帧）—— 截断时**不允许**裁它。
  final Rect interactiveUnion;

  /// 四侧外扩量（相对桌宠 Widget 矩形）。
  final ({double left, double right, double up, double down}) reach;
}
