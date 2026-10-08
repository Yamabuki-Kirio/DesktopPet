/// **轮盘展开方向的唯一契约**（真机回归：左右展开完全反向）。
///
/// 为什么要有这个文件
/// ------------------
/// 之前 `left` / `right` 同时被用来表达四五种不同概念：
///
/// * 刀刃朝向；
/// * 缺口朝向；
/// * 人物位于菜单哪一侧；
/// * Android renderer 的 mirror 标记；
/// * 动画进入方向。
///
/// 一旦某处按"另一种含义"理解，整体就会**正好反向**（对称设计的典型症状：
/// 镜像两次 = 看不出哪个是 bug）。
///
/// 因此这里把语义**冻结成一件事**：
///
/// > [WheelExpansionSide.left] = 菜单的像素**主要位于人物左侧**；
/// > [WheelExpansionSide.right] = 菜单的像素**主要位于人物右侧**。
///
/// 其它概念一律**单向派生**（见 [WheelExpansionSideX] 上的扩展方法），
/// 绝不允许反过来影响方向判定。
///
/// 本文件只依赖 `dart:ui` 的矩形类型，**纯 Dart**，可在 `flutter_tester` 直接单测，
/// 也不破坏 Android 平台隔离。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 菜单实际绘制在哪一侧（**唯一**方向语义）。
enum WheelExpansionSide {
  /// 菜单主体实际绘制在**桌宠左侧**。
  left('left'),

  /// 菜单主体实际绘制在**桌宠右侧**。
  right('right');

  const WheelExpansionSide(this.wireName);

  /// 日志 / 持久化取值。
  final String wireName;

  /// 水平方向的符号（仅用于**派生**动画与角度，不参与方向判定）。
  int get sign => this == WheelExpansionSide.right ? 1 : -1;

  bool get isLeft => this == WheelExpansionSide.left;

  bool get isRight => this == WheelExpansionSide.right;

  WheelExpansionSide get opposite =>
      this == WheelExpansionSide.left ? WheelExpansionSide.right : WheelExpansionSide.left;

  // ---------------------------------------------------------------------------
  // 派生量（**只能**从 side 单向计算；禁止反向影响方向判定）
  // ---------------------------------------------------------------------------

  /// 人物位于菜单的哪一侧（= side 的反面）。仅用于诊断 / 文案。
  WheelExpansionSide get petSideOfMenu => opposite;

  /// 刀刃（blade）朝向。与 [this] 同向：左展开时刀刃指向左。
  WheelExpansionSide get bladeDirection => this;

  /// 渲染层是否需要"镜像标记"。
  ///
  /// ⚠️ **恒为 false**：几何层已经输出最终坐标，Painter 不得再做水平镜像
  /// （这正是"镜像两次看不出谁是 bug"的那类缺陷）。保留这个 getter 是为了
  /// 让"是否需要二次镜像"成为一个**可断言的事实**，而不是散落的 if。
  bool get requiresRendererMirror => false;

  /// 缺口（notch）朝向。缺口永远对着人物，因此与 [petSideOfMenu] 同向。
  WheelExpansionSide get notchDirection => petSideOfMenu;

  /// 动画进入方向的符号（右侧 +1 / 左侧 −1）。
  int get animationSign => sign;

  /// 槽位 0 所在的绝对角度基准（与 Android `baseAngle` 逐字一致）。
  ///
  /// * right → 0°（+x 方向 = 屏幕右侧）
  /// * left → 180°（−x 方向 = 屏幕左侧）
  double get baseAngleDeg => this == WheelExpansionSide.right ? 0 : 180;
}

/// 与 Android 枚举的换算（迁移期唯一桥）。
///
/// Android 的 `WheelExpandDirection` 与这里的含义**逐字一致**：
/// 它的 `centerX = right ? anchorX + offset : anchorX - offset`
/// （见 `WheelMenuGeometry.kt`），即 "right = 菜单中心在人物右侧"。
abstract final class WheelExpansionSideCodec {
  /// Android / 旧 Dart 的 `WheelExpandDirection.name` → 本枚举。
  static WheelExpansionSide fromWireName(String name) =>
      name == WheelExpansionSide.left.wireName
          ? WheelExpansionSide.left
          : WheelExpansionSide.right;
}

/// 方向判定的**输入**（全部为屏幕坐标）。
class WheelDirectionInput {
  const WheelDirectionInput({
    required this.petScreenRect,
    required this.workArea,
    required this.menuRequiredWidthPx,
    required this.previousSide,
    required this.previousPetCenterX,
  });

  /// 人物在**屏幕坐标**里的矩形（唯一的位置来源）。
  final Rect petScreenRect;

  /// 人物所在显示器的**可用工作区**（屏幕坐标）。
  final Rect workArea;

  /// 正式轮盘在当前设置下**向单侧**实际需要的宽度（含标签与安全边距）。
  final double menuRequiredWidthPx;

  /// 上一次的展开方向（滞回用）。
  final WheelExpansionSide? previousSide;

  /// 上一次判定时人物的屏幕中心 X（滞回用：按"位移"而非"位置"判定，避免抖动）。
  final double? previousPetCenterX;
}

/// 方向判定结果（含全部诊断字段，可直接进日志）。
class WheelDirectionDecision {
  const WheelDirectionDecision({
    required this.side,
    required this.roomLeft,
    required this.roomRight,
    required this.requiredWidth,
    required this.leftFits,
    required this.rightFits,
    required this.previousSide,
    required this.hysteresisApplied,
    required this.reason,
  });

  final WheelExpansionSide side;

  /// `petScreenRect.left - workArea.left`
  final double roomLeft;

  /// `workArea.right - petScreenRect.right`
  final double roomRight;

  final double requiredWidth;

  final bool leftFits;
  final bool rightFits;

  final WheelExpansionSide? previousSide;

  /// 本次是否由滞回决定（"保持上一次方向，因为位移还不够大"）。
  final bool hysteresisApplied;

  /// 人类可读原因（直接进日志 / 测试断言）。
  final String reason;
}

/// 方向判定策略（**只在屏幕坐标里判**）。
abstract final class WheelDirectionPolicy {
  /// 滞回：人物横向移动超过这个比例 × 屏幕宽度，才允许换边。
  ///
  /// 用**位移**而不是"越过中线"判滞回 —— 人物在屏幕中心附近来回拖时，
  /// "越过中线"会让方向每帧翻转；"位移阈值"天然不抖。
  static const double hysteresisRatio = 0.08;

  /// 判定展开方向。
  ///
  /// 规则（与需求 §2 逐条对应）：
  /// 1. 右侧能完整容纳、左侧不能 → [WheelExpansionSide.right]；
  /// 2. 左侧能完整容纳、右侧不能 → [WheelExpansionSide.left]；
  /// 3. 两侧都能容纳 → 取**空间更大**的一侧；完全相同 → Android 默认方向（right）；
  /// 4. 两侧都不能完整容纳 → 取**可用空间更大**的一侧（随后由应急缩放 / 夹取兜底）。
  ///
  /// 滞回：当 [WheelDirectionInput.previousSide] 存在，且上一次方向上**仍然装得下**、
  /// 且人物横向位移未超过 [hysteresisRatio] × 屏幕宽度时，保持上一次方向。
  static WheelDirectionDecision decide(WheelDirectionInput input) {
    final Rect pet = input.petScreenRect;
    final Rect area = input.workArea;
    final double required = math.max(0, input.menuRequiredWidthPx);

    final double roomLeft = pet.left - area.left;
    final double roomRight = area.right - pet.right;
    final bool leftFits = required > 0 && roomLeft >= required;
    final bool rightFits = required > 0 && roomRight >= required;

    final WheelExpansionSide natural;
    final String naturalReason;
    if (rightFits && !leftFits) {
      natural = WheelExpansionSide.right;
      naturalReason = 'only_right_fits';
    } else if (leftFits && !rightFits) {
      natural = WheelExpansionSide.left;
      naturalReason = 'only_left_fits';
    } else if (leftFits && rightFits) {
      if (roomRight > roomLeft) {
        natural = WheelExpansionSide.right;
        naturalReason = 'both_fit_more_room_right';
      } else if (roomLeft > roomRight) {
        natural = WheelExpansionSide.left;
        naturalReason = 'both_fit_more_room_left';
      } else {
        // 完全相同 → Android 默认方向（right）。
        natural = WheelExpansionSide.right;
        naturalReason = 'both_fit_equal_default_right';
      }
    } else {
      // 两侧都装不下：取可用空间更大的一侧，由应急缩放 / 夹取兜底。
      if (roomRight >= roomLeft) {
        natural = WheelExpansionSide.right;
        naturalReason = 'neither_fits_more_room_right';
      } else {
        natural = WheelExpansionSide.left;
        naturalReason = 'neither_fits_more_room_left';
      }
    }

    // 滞回：只在"上一次方向仍然可用"且"位移不够大"时保持。
    final WheelExpansionSide? previous = input.previousSide;
    final double? previousCx = input.previousPetCenterX;
    if (previous != null && previousCx != null) {
      final bool previousStillUsable = previous.isRight ? rightFits : leftFits;
      final double threshold = area.width * hysteresisRatio;
      final bool movedEnough = (pet.center.dx - previousCx).abs() >= threshold;
      // 上一次方向尚可，且位移不足 → 保持；否则采用新判定。
      final bool keep = previousStillUsable && !movedEnough;
      // 但如果上一侧只因为"都装不下"才可用（neither_fits），不要靠它硬撑。
      final bool holdable = previousStillUsable || (!leftFits && !rightFits);
      if (keep && holdable) {
        return WheelDirectionDecision(
          side: previous,
          roomLeft: roomLeft,
          roomRight: roomRight,
          requiredWidth: required,
          leftFits: leftFits,
          rightFits: rightFits,
          previousSide: previous,
          hysteresisApplied: true,
          reason: 'hysteresis_hold_${previous.wireName}',
        );
      }
      return WheelDirectionDecision(
        side: natural,
        roomLeft: roomLeft,
        roomRight: roomRight,
        requiredWidth: required,
        leftFits: leftFits,
        rightFits: rightFits,
        previousSide: previous,
        hysteresisApplied: false,
        reason: naturalReason,
      );
    }

    return WheelDirectionDecision(
      side: natural,
      roomLeft: roomLeft,
      roomRight: roomRight,
      requiredWidth: required,
      leftFits: leftFits,
      rightFits: rightFits,
      previousSide: previous,
      hysteresisApplied: false,
      reason: naturalReason,
    );
  }
}

/// 方向**不变量**的评估结果。
class WheelDirectionInvariant {
  const WheelDirectionInvariant({
    required this.centerOnSide,
    required this.arcInHalfPlane,
    required this.insideWorkArea,
    required this.passed,
    required this.reason,
    required this.menuScreenBounds,
    required this.menuCenterScreenX,
    required this.petCenterScreenX,
  });

  /// **扇形中心**确实落在期望的一侧（这是"方向没反"的本质判据）。
  ///
  /// ⚠️ 不能用"轮盘窗口"判：窗口必然**跨过**人物中心（人物就在扇形缺口里），
  /// 所以窗口的 right 一定大于人物中心。只有扇形中心才能表达"菜单在哪一侧"。
  final bool centerOnSide;

  /// 扇形的角度跨度没有越过"过人物中心的竖直线"（半跨度 ≤ 90°）。
  final bool arcInHalfPlane;

  /// 整个轮盘窗口完整落在 workArea 内。
  final bool insideWorkArea;

  final bool passed;

  final String reason;

  /// 被检查的轮盘窗口屏幕矩形。
  final Rect menuScreenBounds;

  /// 扇形中心的屏幕 X。
  final double menuCenterScreenX;

  /// 人物中心的屏幕 X。
  final double petCenterScreenX;
}

/// 方向不变量检查（需求 §5）。
abstract final class WheelDirectionInvariants {
  /// 允许的越界容差（浮点 / DPI 取整）。
  static const double defaultTolerancePx = 1.5;

  /// 扇形中心相对人物中心的最小位移（防止"正好压在中线上"）。
  static const double minCenterOffsetPx = 1.0;

  /// 扇形半跨度上限：超过 90° 就会越过人物中心线进入另一半平面。
  static const double maxArcHalfSpanDeg = 90.0;

  /// 检查"菜单确实在 [side] 那一侧，且不出 workArea"。
  ///
  /// * [menuScreenBounds]：轮盘窗口在**屏幕坐标**里的矩形（只用于 workArea 检查）；
  /// * [menuCenterScreenX]：**扇形中心**的屏幕 X（用于"在哪一侧"）；
  /// * [arcHalfSpanDeg]：扇形半跨度（度）；
  /// * [petScreenRect] / [workArea]：人物与显示器工作区（**屏幕坐标**）。
  static WheelDirectionInvariant evaluate({
    required WheelExpansionSide side,
    required Rect menuScreenBounds,
    required double menuCenterScreenX,
    required double arcHalfSpanDeg,
    required Rect petScreenRect,
    required Rect workArea,
    double tolerancePx = defaultTolerancePx,
  }) {
    final double petCx = petScreenRect.center.dx;
    // 左侧：扇形中心必须明显在人物中心左侧；右侧反之。
    final bool centerOnSide = side.isLeft
        ? menuCenterScreenX <= petCx - minCenterOffsetPx - tolerancePx
        : menuCenterScreenX >= petCx + minCenterOffsetPx + tolerancePx;

    final bool arcInHalfPlane = arcHalfSpanDeg <= maxArcHalfSpanDeg + 0.5;

    final bool insideWorkArea =
        menuScreenBounds.left >= workArea.left - tolerancePx &&
            menuScreenBounds.right <= workArea.right + tolerancePx &&
            menuScreenBounds.top >= workArea.top - tolerancePx &&
            menuScreenBounds.bottom <= workArea.bottom + tolerancePx;

    final bool passed = centerOnSide && arcInHalfPlane && insideWorkArea;
    return WheelDirectionInvariant(
      centerOnSide: centerOnSide,
      arcInHalfPlane: arcInHalfPlane,
      insideWorkArea: insideWorkArea,
      passed: passed,
      reason: passed
          ? 'ok'
          : <String>[
              if (!centerOnSide) 'menu_on_wrong_side',
              if (!arcInHalfPlane) 'arc_crosses_pet_center_line',
              if (!insideWorkArea) 'outside_work_area',
            ].join('+'),
      menuScreenBounds: menuScreenBounds,
      menuCenterScreenX: menuCenterScreenX,
      petCenterScreenX: petCx,
    );
  }
}

/// 「菜单向单侧实际需要多少宽度」的估算。
///
/// 直接用**轮盘窗口宽度**（= 固有布局的宽度，含标签与安全边距）——
/// 它就是"向单侧展开时真正会占用的水平跨度"，不再另造一套估算公式。
/// 这样"能否容纳"的判据与实际绘制结果**同源**，不会出现"判定说能放下、
/// 画出来却出屏"。
abstract final class WheelMenuWidthBudget {
  /// 由轮盘窗口尺寸求"单侧所需宽度"。
  ///
  /// * [windowWidthPx]：轮盘窗口宽度（固有布局给出）；
  /// * [petVisibleWidthPx]：人物可见宽度；
  /// * [menuDistanceRatio]：菜单中心相对人物宽度的偏移比例（当前设置）。
  ///
  /// 单侧实际跨出人物的宽度 ≈ 窗口宽度 − 人物宽度的一半 − 偏移（夹到 ≥0）。
  static double requiredWidthFor({
    required double windowWidthPx,
    required double petVisibleWidthPx,
    required double menuDistanceRatio,
  }) {
    final double offset = petVisibleWidthPx * menuDistanceRatio;
    final double beyond = windowWidthPx - petVisibleWidthPx / 2 - offset;
    return math.max(0, beyond);
  }

  /// 兜底估算（窗口尺寸未知时）：人物宽度 × 系数。
  static double fallbackRequiredWidth({required double petVisibleWidthPx}) =>
      petVisibleWidthPx * 2.4;
}

/// 屏幕坐标 ↔ 固定画布局部坐标的**唯一换算**（需求 §3）。
///
/// 顺序固定为：
/// ```
/// fixedCanvasWindowRect（屏幕）
///   → petLocalRect（局部）
///   → petScreenRect = petLocalRect.shift(fixedCanvasWindowRect.topLeft)   ← 本类
///   → 在屏幕坐标里选 display 与 expansionSide
///   → 用 expansionSide 算轮盘局部几何
///   → Region 用局部坐标
/// ```
abstract final class ScreenSpaceConversion {
  /// 人物在屏幕上的矩形 = 画布窗口矩形 + 画布局部锚点。
  static Rect petScreenRectFrom({
    required Rect canvasWindowRect,
    required Offset petAnchor,
    required Size petSize,
  }) =>
      Rect.fromLTWH(
        canvasWindowRect.left + petAnchor.dx,
        canvasWindowRect.top + petAnchor.dy,
        petSize.width,
        petSize.height,
      );

  /// 反向：人物屏幕矩形 → 画布局部矩形。
  static Rect petLocalRectFrom({
    required Rect petScreenRect,
    required Rect canvasWindowRect,
  }) =>
      Rect.fromLTWH(
        petScreenRect.left - canvasWindowRect.left,
        petScreenRect.top - canvasWindowRect.top,
        petScreenRect.width,
        petScreenRect.height,
      );
}
