/// **六种布局组合的评估与选择（C1.1.1 需求 §三 / §五 / §六）**。
///
/// 职责
/// ----
/// 给定「人物 Widget 屏幕矩形 + alpha 可见边界 + 显示器工作区 + 设置」，
/// 用**正式共享几何**（`WheelMenuGeometry.computeEnvelope` / `layoutFor`）
/// 与**正式视觉包围盒计算器**（`WheelVisualBoundsCalculator`）算出：
///
/// 1. 水平侧（沿用 C1.1 已验收的 `WheelDirectionPolicy`，含滞回 —— **不改**）；
/// 2. 三种纵向模式各自的完整 `visualBoundsScreen` 与**四侧溢出量**；
/// 3. 按需求 §三 的规则选出一种组合；
/// 4. 该组合的**唯一**信封（Painter / HitTest / Region / CanvasPlan 全部消费它）。
///
/// 为什么纵向模式必须由**真实绘制边界**决定（需求 §三）
/// ------------------------------------------------
/// 旧实现只看"人物中心点到工作区上下边缘的距离"（`above < below * 0.55`），
/// 而且 `resolveExpansion` 用 `lockMode` 把**上一次**的纵向模式锁住。前者是
/// "点估计"（与扇形真实外缘无关），后者让"从底部拖到顶部"继续沿用底部布局 ——
/// 两者叠加就是真机上左上 / 右上菜单上半截被裁的根因。
///
/// 现在改为：**逐候选算完整视觉包围盒 → 与 workArea 求四侧溢出 → 选零溢出者**。
/// 选择顺序见 [_select]：先采用「位置指示的模式」（顶部→top、底部→bottom、
/// 居中→middle），它放不下才退回 `middle`，还放不下才取溢出最小者，
/// 再交给既有的设备级应急缩放 / 窗口夹取兜底。**绝不先缩放再选方向**。
///
/// 本文件是**纯 Dart**：只依赖 `dart:math` / `dart:ui` 与纯几何模块，
/// 可在 `flutter_tester` 直接单测，也不破坏 Android 平台隔离。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show immutable;

import 'wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelContentBounds,
        WheelExpandDirection,
        WheelExpansionResolution,
        WheelMenuEnvelope,
        WheelMenuGeometry,
        WheelMenuLayout,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect;
import 'wheel_placement.dart';
import 'wheel_visual_bounds.dart' show WheelVisualBounds, WheelVisualBoundsCalculator;

/// 单个候选组合的**完整评估结果**（全部坐标均为屏幕逻辑像素）。
@immutable
class WheelPlacementCandidate {
  const WheelPlacementCandidate({
    required this.placement,
    required this.envelope,
    required this.layout,
    required this.visual,
    required this.workArea,
    required this.leftOverflowPx,
    required this.rightOverflowPx,
    required this.topOverflowPx,
    required this.bottomOverflowPx,
  });

  /// 该候选对应的组合。
  final WheelPlacement placement;

  /// 该候选的信封（屏幕坐标；`windowRect` 已按 Android 口径夹进工作区）。
  final WheelMenuEnvelope envelope;

  /// 该候选的层级几何（**屏幕坐标**，已把窗口局部平移过来）。
  final WheelMenuLayout layout;

  /// 该候选的完整视觉包围盒（屏幕坐标）。
  final WheelVisualBounds visual;

  /// 评估用的显示器工作区（屏幕坐标）。
  final Rect workArea;

  final double leftOverflowPx;
  final double rightOverflowPx;
  final double topOverflowPx;
  final double bottomOverflowPx;

  /// 四侧溢出之和（需求 §三 的判据）。
  double get overflowPx =>
      leftOverflowPx + rightOverflowPx + topOverflowPx + bottomOverflowPx;

  /// 是否**完整**落在工作区内（含 [WheelPlacementSolver.overflowTolerancePx] 容差）。
  bool get fitsWorkArea => overflowPx <= WheelPlacementSolver.overflowTolerancePx;

  /// 全部绘制像素（屏幕坐标）。
  Rect get visualBoundsScreen => visual.all;

  /// 交互内容（按钮 / 标签 / 文字）的并集（屏幕坐标）。
  Rect get interactiveBoundsScreen => WheelPlacementSolver.unionOf(
        <Rect>[visual.buttons, visual.labels, visual.texts],
      );

  /// 该候选所需画布的屏幕矩形（需求 §六）。
  Rect get canvasBoundsScreen => WheelPlacementSolver.canvasBoundsFor(this);

  Map<String, Object?> describe() => <String, Object?>{
        'placement': placement.wireName,
        'overflowPx': overflowPx,
        'topOverflowPx': topOverflowPx,
        'bottomOverflowPx': bottomOverflowPx,
        'leftOverflowPx': leftOverflowPx,
        'rightOverflowPx': rightOverflowPx,
        'fitsWorkArea': fitsWorkArea,
        'windowRect': _r(Rect.fromLTWH(
          envelope.windowRect.left,
          envelope.windowRect.top,
          envelope.windowRect.width,
          envelope.windowRect.height,
        )),
        'visualBoundsScreen': _r(visualBoundsScreen),
        'interactiveBoundsScreen': _r(interactiveBoundsScreen),
        'canvasBoundsScreen': _r(canvasBoundsScreen),
        'fanBiasDeg': envelope.fanBiasDeg,
        'actualScale': envelope.actualScale,
        'degraded': envelope.degraded,
      };

  static String _r(Rect r) => '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
      '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';
}

/// 一次「组合选择」的完整结果（= 需求 §五 的不可变快照素材）。
@immutable
class WheelPlacementSolution {
  const WheelPlacementSolution({
    required this.placement,
    required this.chosen,
    required this.candidates,
    required this.resolution,
    required this.reason,
    required this.previousPlacement,
  });

  /// 最终采用的组合（二元组）。
  final WheelPlacement placement;

  /// 最终采用的候选（信封 / 几何 / 视觉边界 / 画布矩形都在这里）。
  final WheelPlacementCandidate chosen;

  /// 参与评估的候选（按 `top / middle / bottom` 顺序，便于诊断对账）。
  final List<WheelPlacementCandidate> candidates;

  /// 水平侧决议（含不变量重试信息）。
  final WheelExpansionResolution resolution;

  /// 选择原因（诊断 / 测试断言用）。
  final String reason;

  /// 上一次的组合（仅诊断；**不参与**本次选择）。
  final WheelPlacement? previousPlacement;

  WheelHorizontalSide get horizontalSide => placement.horizontalSide;

  WheelVerticalPlacement get vertical => placement.vertical;

  /// 最终信封（**唯一**事实；Painter / HitTest / Region / CanvasPlan 只消费它）。
  WheelMenuEnvelope get envelope => chosen.envelope;

  /// 最终几何（屏幕坐标；仅用于测量 / 诊断 —— 渲染用的是窗口局部版本）。
  WheelMenuLayout get layout => chosen.layout;

  /// 最终视觉包围盒（屏幕坐标）。
  Rect get visualBoundsScreen => chosen.visualBoundsScreen;

  /// 最终画布所需矩形（屏幕坐标）。
  Rect get canvasBoundsScreen => chosen.canvasBoundsScreen;

  double get topOverflowPx => chosen.topOverflowPx;
  double get bottomOverflowPx => chosen.bottomOverflowPx;
  double get leftOverflowPx => chosen.leftOverflowPx;
  double get rightOverflowPx => chosen.rightOverflowPx;

  /// 诊断字段全集（`wheel.placement.*`）。
  Map<String, Object?> diagnostics() => <String, Object?>{
        'horizontal_side': horizontalSide.wireName,
        'vertical_placement': vertical.wireName,
        'placement': placement.wireName,
        'previous_placement': previousPlacement?.wireName ?? 'none',
        'selection_reason': reason,
        'candidate.top.overflow': _n(candidateOf(WheelVerticalPlacement.top)?.overflowPx),
        'candidate.middle.overflow':
            _n(candidateOf(WheelVerticalPlacement.middle)?.overflowPx),
        'candidate.bottom.overflow':
            _n(candidateOf(WheelVerticalPlacement.bottom)?.overflowPx),
        'candidate.top.topOverflow': _n(candidateOf(WheelVerticalPlacement.top)?.topOverflowPx),
        'candidate.middle.topOverflow':
            _n(candidateOf(WheelVerticalPlacement.middle)?.topOverflowPx),
        'candidate.bottom.topOverflow':
            _n(candidateOf(WheelVerticalPlacement.bottom)?.topOverflowPx),
        'visualBoundsScreen': _r(visualBoundsScreen),
        'canvasBoundsScreen': _r(canvasBoundsScreen),
        'topOverflowPx': topOverflowPx,
        'bottomOverflowPx': bottomOverflowPx,
        'leftOverflowPx': leftOverflowPx,
        'rightOverflowPx': rightOverflowPx,
        'fanBiasDeg': envelope.fanBiasDeg,
        'envelopeWindow': _r(Rect.fromLTWH(
          envelope.windowRect.left,
          envelope.windowRect.top,
          envelope.windowRect.width,
          envelope.windowRect.height,
        )),
        'actualScale': envelope.actualScale,
        'degraded': envelope.degraded,
      };

  /// 取某个纵向候选（未评估过为 null）。
  WheelPlacementCandidate? candidateOf(WheelVerticalPlacement vertical) {
    for (final WheelPlacementCandidate c in candidates) {
      if (c.placement.vertical == vertical) return c;
    }
    return null;
  }

  static Object? _n(double? v) => v == null ? 'none' : v.toStringAsFixed(1);

  static String _r(Rect r) => '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
      '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';
}

/// 组合求解器（**唯一入口**）。
abstract final class WheelPlacementSolver {
  /// 溢出的允许容差（浮点 / 取整）。
  ///
  /// 取 1px：包围盒是按 2° 采样 + 外接矩形算出来的保守上界，小于 1px 的"溢出"
  /// 没有视觉意义；而真实的裁切都是十几 px 量级，不会被这个容差掩盖。
  static const double overflowTolerancePx = 1.0;

  /// 求解一次布局组合（需求 §三 / §五）。
  ///
  /// [previousPlacement] **只用于诊断**，不参与选择 —— 纵向模式必须是当前
  /// 位置的纯函数，否则"从底部拖到顶部"会继续用底部布局（真机回归根因）。
  ///
  /// 水平侧仍然沿用 C1.1 已验收的 `WheelDirectionPolicy`（含位移滞回），
  /// 通过 [previousSide] / [previousPetCenterX] 传入历史值。
  static WheelPlacementSolution solve({
    required WheelRect petWindowRect,
    required WheelBounds workArea,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    WheelContentBounds? content,
    required int maxItemCount,
    WheelHorizontalSide? previousSide,
    double? previousPetCenterX,
    WheelPlacement? previousPlacement,
  }) {
    // ① 水平侧：完全沿用已验收的决议链（策略 → 信封 → 不变量 → 反向重试）。
    //    纵向模式这里传 null：绝不让"上一次"锁住这一次（§三 / §七）。
    final WheelExpansionResolution resolution = WheelMenuGeometry.resolveExpansion(
      bounds: workArea,
      petWindowRect: petWindowRect,
      content: content,
      maxItemCount: maxItemCount,
      spec: spec,
      settings: settings,
      previousDirection: previousSide == null
          ? null
          : (previousSide.isLeft ? WheelExpandDirection.left : WheelExpandDirection.right),
      previousVerticalMode: null,
      previousPetCenterX: previousPetCenterX,
    );
    final WheelHorizontalSide side = resolution.side;

    // ② 三种纵向模式：各自算完整几何 + 视觉包围盒 + 四侧溢出。
    final List<WheelPlacementCandidate> candidates = <WheelPlacementCandidate>[
      for (final WheelVerticalPlacement vertical in WheelVerticalPlacement.values)
        evaluate(
          side: side,
          vertical: vertical,
          petWindowRect: petWindowRect,
          workArea: workArea,
          spec: spec,
          settings: settings,
          content: content,
          maxItemCount: maxItemCount,
        ),
    ];

    // ③ "位置本身指示的纵向模式"：Android `decideVerticalMode` 的**纯启发式**
    //    （`previous = null`、`locked = false` → 没有滞回）。它是候选选择的**首选**
    //    —— 位置在顶部就该用靠上布局（§八 要求 top 场景的 verticalPlacement = top）。
    final WheelVerticalPlacement natural = WheelVerticalPlacement.fromMode(
      WheelMenuGeometry.decideVerticalMode(
        WheelMenuGeometry.petVisibleRect(petWindowRect, content),
        workArea,
        null,
        false,
      ),
    );

    // ④ 选择（需求 §三 的规则顺序）。
    final _Selection selection = _select(candidates, natural);
    return WheelPlacementSolution(
      placement: selection.candidate.placement,
      chosen: selection.candidate,
      candidates: candidates,
      resolution: resolution,
      reason: selection.reason,
      previousPlacement: previousPlacement,
    );
  }

  /// 评估**指定**组合（不参与选择；诊断 / 测试 / 画布规划复用）。
  static WheelPlacementCandidate evaluate({
    required WheelHorizontalSide side,
    required WheelVerticalPlacement vertical,
    required WheelRect petWindowRect,
    required WheelBounds workArea,
    required WheelMenuSpec spec,
    required WheelMenuLayoutSettings settings,
    WheelContentBounds? content,
    required int maxItemCount,
  }) {
    final WheelExpandDirection direction =
        side.isLeft ? WheelExpandDirection.left : WheelExpandDirection.right;
    // 方向与纵向**都锁死**：本函数只回答"给定组合时会长成什么样"。
    final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
      bounds: workArea,
      petWindowRect: petWindowRect,
      content: content,
      maxItemCount: maxItemCount,
      spec: spec,
      settings: settings,
      previousDirection: direction,
      previousVerticalMode: vertical.mode,
      lockMode: true,
    );
    // 借用**正式**层级几何（`layoutFor`）——与 Painter 逐字节同源。
    final WheelMenuLayout local = WheelMenuGeometry.layoutFor(
      envelope,
      WheelMenuGeometry.probeLevelFor(maxItemCount),
      spec,
    );
    // 窗口局部 → 屏幕：**唯一**一次平移（`windowRect` 是该坐标系的唯一偏移）。
    final WheelMenuLayout screen = local.shiftedBy(
      envelope.windowRect.left,
      envelope.windowRect.top,
    );
    final WheelVisualBounds visual = WheelVisualBoundsCalculator.compute(screen);

    final Rect area = Rect.fromLTRB(
      workArea.left,
      workArea.top,
      workArea.right,
      workArea.bottom,
    );
    final Rect all = visual.all;
    return WheelPlacementCandidate(
      placement: WheelPlacement(horizontalSide: side, vertical: vertical),
      envelope: envelope,
      layout: screen,
      visual: visual,
      workArea: area,
      // 需求 §三 的溢出公式**逐字实现**：
      //   max(0, workArea.left - bounds.left) + max(0, bounds.right - workArea.right)
      // + max(0, workArea.top  - bounds.top)  + max(0, bounds.bottom - workArea.bottom)
      //
      // ⚠️ 方向必须"外扩为正"：内容**越过**工作区边界才算溢出。
      // 早先用 `value > limit` 的统一助手把四个方向都写反了，
      // 于是"内容全部在工作区内"反而被算成最大溢出（真机上就选了错误模式）。
      leftOverflowPx: _positive(area.left - all.left),
      rightOverflowPx: _positive(all.right - area.right),
      topOverflowPx: _positive(area.top - all.top),
      bottomOverflowPx: _positive(all.bottom - area.bottom),
    );
  }

  /// 需求 §六：`canvasRectScreen = visualBoundsScreen.expand(padding).roundOut()`。
  ///
  /// 额外并入 `windowRect`（信封窗口）：它才是"菜单 widget 必须落在哪"的边界，
  /// 只按视觉包围盒生成会让窗口挂在画布边缘之外。
  static Rect canvasBoundsFor(WheelPlacementCandidate candidate) {
    final Rect base = unionOf(<Rect>[
      candidate.visualBoundsScreen,
      Rect.fromLTWH(
        candidate.envelope.windowRect.left,
        candidate.envelope.windowRect.top,
        candidate.envelope.windowRect.width,
        candidate.envelope.windowRect.height,
      ),
    ]);
    final Rect padded = base.inflate(WheelVisualBoundsCalculator.safetyPadding);
    return Rect.fromLTRB(
      padded.left.floorToDouble(),
      padded.top.floorToDouble(),
      padded.right.ceilToDouble(),
      padded.bottom.ceilToDouble(),
    );
  }

  /// 矩形并集（忽略退化矩形）；全部退化时返回 [Rect.zero]。
  static Rect unionOf(List<Rect> rects) {
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

  // -------------------------------------------------------------------------
  // 选择规则（需求 §三 逐条对应）
  // -------------------------------------------------------------------------

  /// 选择最终组合（需求 §三 的规则顺序，逐条对应）。
  ///
  /// 为什么"位置指示的模式"优先于"居中"（而不是反过来）
  /// --------------------------------------------------
  /// 三个候选的竖直外扩是**包含关系**：居中模式对称外扩 `e`；靠上模式把向上
  /// 外扩换成更小的值、向下换成更大的值（靠下镜像）。因此"居中放得下"时靠上 /
  /// 靠下**通常也**放得下 —— 若此时一律优先居中，`top` / `bottom` 就**永远**
  /// 不会被选中（顶部适配形同虚设，且与 §八 的 `verticalPlacement=top` 冲突）。
  ///
  /// 所以口径是：**位置说的模式优先**（顶部 → top、底部 → bottom、居中 → middle）；
  /// 只有它放不下时才退回居中，再不行才取溢出最小者。
  static _Selection _select(
    List<WheelPlacementCandidate> candidates,
    WheelVerticalPlacement natural,
  ) {
    if (candidates.isEmpty) {
      throw StateError('候选列表为空：至少需要 top/middle/bottom 三种纵向模式');
    }
    // 规则 1 + 3 + 4：位置指示的模式零溢出 → 直接采用。
    final WheelPlacementCandidate? byNatural = _find(candidates, natural);
    if (byNatural != null && byNatural.fitsWorkArea) {
      return _Selection(byNatural, 'fit_natural_${natural.wireName}');
    }
    // 规则 2：位置指示的模式放不下 → 退回"居中"（保持普通位置的现有观感）。
    final WheelPlacementCandidate? middle =
        _find(candidates, WheelVerticalPlacement.middle);
    if (middle != null && middle.fitsWorkArea) {
      return _Selection(middle, 'fit_fallback_middle');
    }
    // 规则 5：三个候选都放不下 → 取溢出最小者，
    // 再进入既有链路（`_plan` 的窗口夹取 + `deviceEmergencyScale`）。
    // **绝不**在这里发明新的缩放。
    final WheelPlacementCandidate best = _minOverflow(candidates);
    return _Selection(best, 'no_fit_pick_min_overflow');
  }

  /// 取指定纵向模式的候选（不存在为 null）。
  static WheelPlacementCandidate? _find(
    List<WheelPlacementCandidate> list,
    WheelVerticalPlacement vertical,
  ) {
    for (final WheelPlacementCandidate c in list) {
      if (c.placement.vertical == vertical) return c;
    }
    return null;
  }

  static WheelPlacementCandidate _minOverflow(List<WheelPlacementCandidate> list) {
    WheelPlacementCandidate best = list.first;
    for (final WheelPlacementCandidate c in list) {
      if (c.overflowPx < best.overflowPx - 1e-9) best = c;
    }
    return best;
  }

  /// 正部（负值记 0）—— 需求 §三 溢出公式里的 `max(0, ·)`。
  static double _positive(double value) => value > 0 ? value : 0;
}

/// 内部：一次选择的结论。
class _Selection {
  const _Selection(this.candidate, this.reason);

  final WheelPlacementCandidate candidate;
  final String reason;
}
