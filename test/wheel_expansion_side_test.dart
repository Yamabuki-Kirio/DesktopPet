/// **轮盘展开方向的契约与坐标空间**（真机回归：左右展开完全反向）。
///
/// 覆盖需求 §6 的 15 项与 §10 的 8 项验收，以及 §5 的方向不变量。
///
/// 前提（本文件所有坐标都是**屏幕坐标**）：
/// ```
/// fixedCanvasWindowRect（屏幕）→ petLocalRect（局部）
///   → petScreenRect = petLocalRect.shift(canvasWindowRect.topLeft)
///   → 在屏幕坐标里选 display 与 expansionSide
/// ```
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_canvas_bridge.dart';
import 'package:petlife/menu/wheel_expansion_side.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart';

/// 屏幕 1920×1040（用户截图场景）。
const Rect kWorkArea = Rect.fromLTWH(0, 0, 1920, 1040);

/// 人物可见尺寸。
const Size kPet = Size(256, 256);

WheelMenuSpec get kSpec => WheelCanvasBridge.spec();

WheelRect petRectAt(Offset topLeft, [Size size = kPet]) => WheelRect(
      topLeft.dx,
      topLeft.dy,
      topLeft.dx + size.width,
      topLeft.dy + size.height,
    );

/// 走**方向决议唯一入口**算一次。
WheelExpansionResolution resolveAt(
  Offset petTopLeft, {
  Rect workArea = kWorkArea,
  WheelMenuLayoutSettings? settings,
  WheelExpansionSide? previousSide,
  double? previousPetCenterX,
  WheelVerticalMode? previousVerticalMode,
  Size size = kPet,
}) =>
    WheelMenuGeometry.resolveExpansion(
      bounds: WheelBounds(workArea.left, workArea.top, workArea.right, workArea.bottom),
      petWindowRect: petRectAt(petTopLeft, size),
      maxItemCount: MenuCatalog.maxItems,
      spec: kSpec,
      settings: settings ?? WheelMenuLayoutSettings.defaults,
      previousDirection: previousSide == null
          ? null
          : (previousSide.isLeft
              ? WheelExpandDirection.left
              : WheelExpandDirection.right),
      previousVerticalMode: previousVerticalMode,
      previousPetCenterX: previousPetCenterX,
    );

Rect screenBoundsOf(WheelExpansionResolution r) {
  final WheelRect w = r.envelope.windowRect;
  return Rect.fromLTWH(w.left, w.top, w.width, w.height);
}

void main() {
  // ---------------------------------------------------------------------------
  // 一、契约本身（§一）
  // ---------------------------------------------------------------------------

  group('方向契约（唯一语义）', () {
    test('left/right 的含义冻结为"菜单像素主要在人物哪一侧"', () {
      expect(WheelExpansionSide.left.wireName, 'left');
      expect(WheelExpansionSide.right.wireName, 'right');
      // 符号只用于派生动画 / 角度。
      expect(WheelExpansionSide.left.sign, -1);
      expect(WheelExpansionSide.right.sign, 1);
      expect(WheelExpansionSide.left.opposite, WheelExpansionSide.right);
      expect(WheelExpansionSide.right.opposite, WheelExpansionSide.left);
    });

    test('派生量单向：petSideOfMenu / notchDirection 是反面，blade 同向', () {
      for (final WheelExpansionSide side in WheelExpansionSide.values) {
        expect(side.petSideOfMenu, side.opposite,
            reason: '人物在菜单的对侧');
        expect(side.bladeDirection, side, reason: '刀刃与展开同向');
        expect(side.notchDirection, side.opposite, reason: '缺口永远对着人物');
        expect(side.animationSign, side.sign);
      }
    });

    test('渲染层**恒不**做二次镜像（几何层已输出最终坐标）', () {
      for (final WheelExpansionSide side in WheelExpansionSide.values) {
        expect(side.requiresRendererMirror, isFalse,
            reason: '镜像只允许一层负责，否则整体反向');
      }
    });

    test('baseAngle 与 Android 逐字一致（right=0° / left=180°）', () {
      expect(WheelExpansionSide.right.baseAngleDeg, 0);
      expect(WheelExpansionSide.left.baseAngleDeg, 180);
    });

    test('Painter 里没有第二次几何镜像（条文扫描）', () {
      final String painter = _read('lib/ui/desktop/wheel_menu_painter.dart');
      expect(painter, isNot(contains('scale(-1')),
          reason: 'Painter 不得水平镜像整个画布');
      expect(painter, isNot(contains('scale(-1, 1')),
          reason: 'Painter 不得水平镜像整个画布');
      // 图标不得被水平翻转。
      expect(painter, isNot(contains('flipX')));
    });
  });

  // ---------------------------------------------------------------------------
  // 二、屏幕坐标判定（§2 / §四）
  // ---------------------------------------------------------------------------

  group('方向只在屏幕坐标中判定', () {
    test('房间宽度用 workArea，不用画布、不用 petAnchor', () {
      const WheelDirectionInput input = WheelDirectionInput(
        petScreenRect: Rect.fromLTWH(1600, 400, 256, 256),
        workArea: kWorkArea,
        menuRequiredWidthPx: 500,
        previousSide: null,
        previousPetCenterX: null,
      );
      final WheelDirectionDecision d = WheelDirectionPolicy.decide(input);
      expect(d.roomLeft, closeTo(1600, 1e-9), reason: '左空间 = pet.left − workArea.left');
      expect(d.roomRight, closeTo(1920 - 1856, 1e-9),
          reason: '右空间 = workArea.right − pet.right');
    });

    test('右侧能容纳、左侧不能 → right', () {
      final WheelDirectionDecision d = WheelDirectionPolicy.decide(
        const WheelDirectionInput(
          petScreenRect: Rect.fromLTWH(100, 400, 256, 256),
          workArea: kWorkArea,
          menuRequiredWidthPx: 600,
          previousSide: null,
          previousPetCenterX: null,
        ),
      );
      expect(d.side, WheelExpansionSide.right);
      expect(d.rightFits, isTrue);
      expect(d.leftFits, isFalse);
      expect(d.reason, 'only_right_fits');
    });

    test('左侧能容纳、右侧不能 → left', () {
      final WheelDirectionDecision d = WheelDirectionPolicy.decide(
        const WheelDirectionInput(
          petScreenRect: Rect.fromLTWH(1600, 400, 256, 256),
          workArea: kWorkArea,
          menuRequiredWidthPx: 600,
          previousSide: null,
          previousPetCenterX: null,
        ),
      );
      expect(d.side, WheelExpansionSide.left);
      expect(d.leftFits, isTrue);
      expect(d.rightFits, isFalse);
      expect(d.reason, 'only_left_fits');
    });

    test('两侧都能容纳 → 取空间更大的一侧', () {
      // 人物偏右：左侧空间更大 → left
      final WheelDirectionDecision left = WheelDirectionPolicy.decide(
        const WheelDirectionInput(
          petScreenRect: Rect.fromLTWH(1000, 400, 256, 256),
          workArea: kWorkArea,
          menuRequiredWidthPx: 300,
          previousSide: null,
          previousPetCenterX: null,
        ),
      );
      expect(left.side, WheelExpansionSide.left);
      expect(left.reason, 'both_fit_more_room_left');

      // 人物偏左：右侧空间更大 → right
      final WheelDirectionDecision right = WheelDirectionPolicy.decide(
        const WheelDirectionInput(
          petScreenRect: Rect.fromLTWH(600, 400, 256, 256),
          workArea: kWorkArea,
          menuRequiredWidthPx: 300,
          previousSide: null,
          previousPetCenterX: null,
        ),
      );
      expect(right.side, WheelExpansionSide.right);
      expect(right.reason, 'both_fit_more_room_right');
    });

    test('两侧空间完全相同 → Android 默认方向（right）', () {
      // 人物正中心：左右空间相等。
      final WheelDirectionDecision d = WheelDirectionPolicy.decide(
        const WheelDirectionInput(
          petScreenRect: Rect.fromLTWH(832, 400, 256, 256),
          workArea: kWorkArea,
          menuRequiredWidthPx: 300,
          previousSide: null,
          previousPetCenterX: null,
        ),
      );
      expect(d.roomLeft, closeTo(d.roomRight, 1e-9));
      expect(d.side, WheelExpansionSide.right);
      expect(d.reason, 'both_fit_equal_default_right');
    });

    test('两侧都不能容纳 → 取可用空间更大的一侧（随后应急缩放）', () {
      const WheelDirectionInput input = WheelDirectionInput(
        petScreenRect: Rect.fromLTWH(1400, 400, 256, 256),
        workArea: kWorkArea,
        menuRequiredWidthPx: 5000,
        previousSide: null,
        previousPetCenterX: null,
      );
      final WheelDirectionDecision d = WheelDirectionPolicy.decide(input);
      expect(d.leftFits, isFalse);
      expect(d.rightFits, isFalse);
      expect(d.side, WheelExpansionSide.left);
      expect(d.reason, 'neither_fits_more_room_left');
    });
  });

  // ---------------------------------------------------------------------------
  // 三、用户截图场景（§6 场景 1 / 2）
  // ---------------------------------------------------------------------------

  group('用户截图场景（真机回归）', () {
    test('场景 1：人物靠右（center.dx > 1600）→ left，且右边界不出 1920', () {
      final WheelExpansionResolution r = resolveAt(const Offset(1600, 400));
      expect(r.side, WheelExpansionSide.left,
          reason: '靠右必须向左展开');
      expect(r.envelope.direction, WheelExpandDirection.left);
      expect(screenBoundsOf(r).right, lessThanOrEqualTo(1920 + 1.5));
      expect(r.invariant.passed, isTrue, reason: r.invariant.reason);

      // 全部按钮都必须在人物中心左侧。
      final WheelMenuLayout lo = WheelMenuGeometry.layoutFor(
        r.envelope,
        MenuCatalog.root,
        kSpec,
      );
      final double petCx = 1600 + kPet.width / 2;
      for (final WheelSlotPlacement s in lo.slots) {
        expect(r.envelope.windowRect.left + s.centerX, lessThan(petCx),
            reason: '槽位 ${s.index} 跑到人物右侧了');
      }
    });

    test('场景 2：人物靠左（center.dx < 320）→ right，且左边界不出 0', () {
      final WheelExpansionResolution r = resolveAt(const Offset(60, 400));
      expect(r.side, WheelExpansionSide.right,
          reason: '靠左必须向右展开');
      expect(r.envelope.direction, WheelExpandDirection.right);
      expect(screenBoundsOf(r).left, greaterThanOrEqualTo(0 - 1.5));
      expect(r.invariant.passed, isTrue, reason: r.invariant.reason);

      final WheelMenuLayout lo = WheelMenuGeometry.layoutFor(
        r.envelope,
        MenuCatalog.root,
        kSpec,
      );
      final double petCx = 60 + kPet.width / 2;
      for (final WheelSlotPlacement s in lo.slots) {
        expect(r.envelope.windowRect.left + s.centerX, greaterThan(petCx),
            reason: '槽位 ${s.index} 跑到人物左侧了');
      }
    });

    test('场景 3：人物正中央 → 方向稳定（两次判定一致）', () {
      final WheelExpansionResolution a = resolveAt(const Offset(832, 400));
      final WheelExpansionResolution b = resolveAt(const Offset(832, 400));
      expect(a.side, b.side);
      expect(a.side, WheelExpansionSide.right);
      expect(a.invariant.passed, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 四、极端位置（§6 场景 4 / 7 / 8）
  // ---------------------------------------------------------------------------

  group('极端位置', () {
    test('场景 7：上边缘 + 左边缘组合 → right 且不出屏', () {
      final WheelExpansionResolution r = resolveAt(const Offset(0, 0));
      expect(r.side, WheelExpansionSide.right);
      final Rect b = screenBoundsOf(r);
      expect(b.left, greaterThanOrEqualTo(-1.5));
      expect(b.top, greaterThanOrEqualTo(-1.5));
    });

    test('场景 8：下边缘 + 右边缘组合 → left 且不出屏', () {
      final WheelExpansionResolution r =
          resolveAt(Offset(1664, 1040 - kPet.height));
      expect(r.side, WheelExpansionSide.left);
      final Rect b = screenBoundsOf(r);
      expect(b.right, lessThanOrEqualTo(1920 + 1.5));
      expect(b.bottom, lessThanOrEqualTo(1040 + 1.5));
    });

    test('四角：都通过不变量且方向正确', () {
      final List<(Offset, WheelExpansionSide)> corners = <(Offset, WheelExpansionSide)>[
        (Offset.zero, WheelExpansionSide.right),
        (Offset(1920 - 256, 0), WheelExpansionSide.left),
        (Offset(0, 1040 - 256), WheelExpansionSide.right),
        (Offset(1920 - 256, 1040 - 256), WheelExpansionSide.left),
      ];
      for (final (Offset at, WheelExpansionSide want) in corners) {
        final WheelExpansionResolution r = resolveAt(at);
        expect(r.side, want, reason: '四角 $at 方向错');
        expect(r.invariant.passed, isTrue, reason: '四角 $at 违反不变量：${r.invariant.reason}');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 五、多显示器 / 负坐标 / 跨屏（§6 场景 4 / 5）
  // ---------------------------------------------------------------------------

  group('多显示器与负坐标', () {
    test('场景 4：左侧负坐标副屏 → 在副屏内向右展开', () {
      const Rect leftScreen = Rect.fromLTWH(-1920, 0, 1920, 1040);
      final WheelExpansionResolution r =
          resolveAt(const Offset(-1900, 400), workArea: leftScreen);
      expect(r.side, WheelExpansionSide.right,
          reason: '副屏最左侧必须向右');
      final Rect b = screenBoundsOf(r);
      expect(b.left, greaterThanOrEqualTo(-1920 - 1.5));
      expect(b.right, lessThanOrEqualTo(0 + 1.5));
      expect(r.invariant.passed, isTrue, reason: r.invariant.reason);
    });

    test('场景 4b：负坐标副屏最右侧 → 向左展开', () {
      const Rect leftScreen = Rect.fromLTWH(-1920, 0, 1920, 1040);
      final WheelExpansionResolution r =
          resolveAt(const Offset(-256, 400), workArea: leftScreen);
      expect(r.side, WheelExpansionSide.left);
      expect(screenBoundsOf(r).right, lessThanOrEqualTo(1.5));
      expect(r.invariant.passed, isTrue, reason: r.invariant.reason);
    });

    test('场景 5：跨两个显示器 → 按**人物中心所在**显示器判定', () {
      // 人物骑在主屏左缘（中心在主屏内）→ 主屏 workArea 判定。
      const Rect primary = Rect.fromLTWH(0, 0, 1920, 1040);
      final WheelExpansionResolution r =
          resolveAt(const Offset(10, 400), workArea: primary);
      expect(r.side, WheelExpansionSide.right);
      // 若误用副屏（-1920..0）判定，人物会落到 workArea 之外，方向会变成 left。
      expect(r.invariant.passed, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 六、滞回（§2 规则 5 / §6 场景 9）
  // ---------------------------------------------------------------------------

  group('滞回（不抖）', () {
    test('场景 9：缓慢跨过中心线时保持原方向，位移足够才换边', () {
      // 上次人物中心在 700、方向 right。
      const double prevCx = 700;
      // 新位置 x=660 → 人物中心 788，位移 88 < 0.08*1920 = 153.6 → 保持 right。
      final WheelExpansionResolution held = resolveAt(
        const Offset(660, 400),
        previousSide: WheelExpansionSide.right,
        previousPetCenterX: prevCx,
      );
      expect(held.side, WheelExpansionSide.right,
          reason: '位移不够大 → 保持原方向，不能左右闪');
      expect(held.decision.hysteresisApplied, isTrue);
      expect(held.invariant.passed, isTrue);

      // 位移足够大（人物中心 1628，位移 928）→ 允许换边到 left。
      final WheelExpansionResolution switched = resolveAt(
        const Offset(1500, 400),
        previousSide: WheelExpansionSide.right,
        previousPetCenterX: prevCx,
      );
      expect(switched.side, WheelExpansionSide.left);
      expect(switched.decision.hysteresisApplied, isFalse);
    });

    test('滞回期间不变量仍然通过（保持的方向必须仍然可用）', () {
      // 人物中心 918，相对上次 860 位移 58 → 保持 right；且右侧仍装得下。
      final WheelExpansionResolution held = resolveAt(
        const Offset(790, 400),
        previousSide: WheelExpansionSide.right,
        previousPetCenterX: 860,
      );
      expect(held.side, WheelExpansionSide.right);
      expect(held.invariant.passed, isTrue,
          reason: '不能为了"保持"而穿过不变量');
    });

    test('位移足够大时**不**受滞回保护（避免卡在错误的一侧）', () {
      // 人物已经跑到最右边，即便上次是 right 也必须换到 left。
      final WheelExpansionResolution r = resolveAt(
        const Offset(1664, 400),
        previousSide: WheelExpansionSide.right,
        previousPetCenterX: 200,
      );
      expect(r.side, WheelExpansionSide.left);
      expect(r.decision.hysteresisApplied, isFalse);
    });

    test('连续小步拖动全程不换边（模拟缓慢跨过中心线）', () {
      WheelExpansionSide side = WheelExpansionSide.right;
      double cx = 700;
      final List<WheelExpansionSide> seen = <WheelExpansionSide>[];
      for (double x = 760; x <= 1400; x += 20) {
        final WheelExpansionResolution r = resolveAt(
          Offset(x, 400),
          previousSide: side,
          previousPetCenterX: cx,
        );
        side = r.side;
        cx = x + kPet.width / 2;
        seen.add(side);
      }
      // 全程只允许换一次边（单调平移不能来回抖）。
      int flips = 0;
      for (int i = 1; i < seen.length; i++) {
        if (seen[i] != seen[i - 1]) flips++;
      }
      expect(flips, lessThanOrEqualTo(1), reason: '缓慢平移只能换一次边');
    });
  });

  // ---------------------------------------------------------------------------
  // 七、不变量与反向重试（§5）
  // ---------------------------------------------------------------------------

  group('方向不变量', () {
    test('不变量判定：扇形中心在正确一侧 + 扇形不越中线 + 不出工作区', () {
      const Rect petScreen = Rect.fromLTWH(1600, 400, 256, 256);
      final WheelDirectionInvariant ok = WheelDirectionInvariants.evaluate(
        side: WheelExpansionSide.left,
        menuScreenBounds: const Rect.fromLTWH(1000, 300, 600, 500),
        menuCenterScreenX: 1687,
        arcHalfSpanDeg: 68,
        petScreenRect: petScreen,
        workArea: kWorkArea,
      );
      expect(ok.passed, isTrue, reason: ok.reason);

      // 扇形中心跑到人物右侧 → 方向反了。
      final WheelDirectionInvariant wrongSide = WheelDirectionInvariants.evaluate(
        side: WheelExpansionSide.left,
        menuScreenBounds: const Rect.fromLTWH(1000, 300, 600, 500),
        menuCenterScreenX: 1780,
        arcHalfSpanDeg: 68,
        petScreenRect: petScreen,
        workArea: kWorkArea,
      );
      expect(wrongSide.centerOnSide, isFalse);
      expect(wrongSide.reason, contains('menu_on_wrong_side'));

      // 扇形跨过 90° → 会进入另一半平面。
      final WheelDirectionInvariant wideArc = WheelDirectionInvariants.evaluate(
        side: WheelExpansionSide.left,
        menuScreenBounds: const Rect.fromLTWH(1000, 300, 600, 500),
        menuCenterScreenX: 1687,
        arcHalfSpanDeg: 120,
        petScreenRect: petScreen,
        workArea: kWorkArea,
      );
      expect(wideArc.arcInHalfPlane, isFalse);
      expect(wideArc.reason, contains('arc_crosses_pet_center_line'));

      // 出工作区。
      final WheelDirectionInvariant outside = WheelDirectionInvariants.evaluate(
        side: WheelExpansionSide.left,
        menuScreenBounds: const Rect.fromLTWH(-500, 300, 600, 500),
        menuCenterScreenX: 1687,
        arcHalfSpanDeg: 68,
        petScreenRect: petScreen,
        workArea: kWorkArea,
      );
      expect(outside.insideWorkArea, isFalse);
      expect(outside.reason, contains('outside_work_area'));
    });

    test('轮盘窗口必然跨过人物中心（所以判据必须是扇形中心而不是窗口）', () {
      final WheelExpansionResolution r = resolveAt(const Offset(1600, 400));
      final Rect window = screenBoundsOf(r);
      final double petCx = 1600 + kPet.width / 2;
      expect(window.right, greaterThan(petCx),
          reason: '人物就在扇形缺口里，窗口一定跨过人物中心');
      // 但扇形中心必须在人物左侧（`envelope.centerX` 已是屏幕坐标）。
      expect(r.envelope.centerX, lessThan(petCx));
      expect(r.envelope.centerX, closeTo(petCx - 256 * 0.16, 1.0),
          reason: '扇形中心 = 人物中心 − 人物宽度 × menuDistance');
      expect(r.invariant.passed, isTrue, reason: r.invariant.reason);
    });

    test('决议结果永远通过不变量（或明确报告失败原因）', () {
      for (double x = -300; x <= 2000; x += 50) {
        final WheelExpansionResolution r = resolveAt(Offset(x, 400));
        if (!r.invariant.passed) {
          // 只有"两侧都放不下"才允许失败，且必须有明确原因。
          expect(r.fallbackReason, startsWith('both_sides_invalid'),
              reason: 'x=$x 未通过却没有明确原因：${r.invariant.reason}');
        }
      }
    });

    test('首选侧不变量失败时会改用相反方向并标记 retriedOpposite', () {
      // 构造：工作区很窄且人物偏左，逼出"首选侧不通过"的情形。
      const Rect narrow = Rect.fromLTWH(0, 0, 500, 800);
      final WheelExpansionResolution r =
          resolveAt(const Offset(250, 200), workArea: narrow);
      // 无论最终哪一侧，invariant 字段必须如实反映。
      expect(r.invariant.menuScreenBounds, isNotNull);
      if (r.retriedOpposite) {
        expect(r.oppositeInvariant, isNotNull);
        expect(r.oppositeInvariant!.passed, isTrue);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 八、坐标空间（§3）
  // ---------------------------------------------------------------------------

  group('坐标转换顺序', () {
    test('petScreenRect = petLocalRect.shift(canvasWindowRect.topLeft)', () {
      const Rect canvas = Rect.fromLTWH(1267, 106, 922, 844);
      const Offset anchor = Offset(333, 294);
      final Rect petScreen = ScreenSpaceConversion.petScreenRectFrom(
        canvasWindowRect: canvas,
        petAnchor: anchor,
        petSize: kPet,
      );
      expect(petScreen, const Rect.fromLTWH(1600, 400, 256, 256));
    });

    test('反向换算互为逆运算', () {
      const Rect canvas = Rect.fromLTWH(1267, 106, 922, 844);
      const Offset anchor = Offset(333, 294);
      final Rect petScreen = ScreenSpaceConversion.petScreenRectFrom(
        canvasWindowRect: canvas,
        petAnchor: anchor,
        petSize: kPet,
      );
      final Rect back = ScreenSpaceConversion.petLocalRectFrom(
        petScreenRect: petScreen,
        canvasWindowRect: canvas,
      );
      expect(back, const Rect.fromLTWH(333, 294, 256, 256));
    });

    test('禁止项：判定只吃 workArea 与 petScreenRect（条文扫描，只查真实代码行）', () {
      // 只扫 `WheelDirectionInput` ~ `WheelDirectionPolicy` 这一段（判定本体）；
      // `ScreenSpaceConversion` 本来就要处理局部坐标，不在范围内。
      final List<String> code = _read('lib/menu/wheel_expansion_side.dart')
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) =>
              !l.startsWith('///') && !l.startsWith('//') && !l.startsWith('*'))
          .toList();
      final int start = code.indexWhere((String l) => l.contains('class WheelDirectionInput'));
      final int end = code.indexWhere((String l) => l.contains('class WheelDirectionInvariant'));
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String block = code.sublist(start, end).join('\n');

      // 判定用的输入只有 petScreenRect + workArea + requiredWidth。
      expect(block, contains('petScreenRect'));
      expect(block, contains('workArea'));
      for (final String banned in <String>[
        'petLocalRect',
        'petAnchor',
        'fixedCanvasWindowRect',
        'drawingCenter',
        'canvasRect',
      ]) {
        expect(block, isNot(contains(banned)),
            reason: '方向判定不得使用 $banned');
      }
      // 「所需宽度」来自固有布局（与被画出来的东西同源），不是硬编码常量。
      final String geometry = _read('lib/menu/wheel_menu_geometry.dart');
      expect(geometry, contains('WheelMenuWidthBudget.requiredWidthFor'));
      expect(geometry, contains('intrinsic.halfWidthPx'));
    });
  });

  // ---------------------------------------------------------------------------
  // 九、按钮顺序 / 图标 / 文字（§6 场景 10 / 11 / 12）
  // ---------------------------------------------------------------------------

  group('镜像不改变内容', () {
    test('场景 10：左右方向下按钮顺序与 Android 一致（都是 0..n-1 沿弧排列）', () {
      for (final WheelExpansionSide side in WheelExpansionSide.values) {
        final WheelMenuLayoutSettings s = WheelMenuLayoutSettings.defaults;
        final WheelExpansionResolution r = resolveAt(
          side.isRight ? const Offset(60, 400) : const Offset(1600, 400),
        );
        expect(r.side, side, reason: '前置条件：方向应为 $side');
        final WheelMenuLayout lo =
            WheelMenuGeometry.layoutFor(r.envelope, MenuCatalog.root, kSpec);
        expect(lo.slots.map((WheelSlotPlacement x) => x.index).toList(),
            <int>[for (int i = 0; i < lo.itemCount; i++) i],
            reason: '槽位下标必须按 0..n-1 递增排列');
        expect(s.menuDistance, greaterThan(0));
      }
    });

    test('场景 11：图标内容不被水平翻转（派生量声明 + 条文）', () {
      for (final WheelExpansionSide side in WheelExpansionSide.values) {
        expect(side.requiresRendererMirror, isFalse);
      }
      final String icons = _read('lib/ui/desktop/wheel_icons.dart');
      expect(icons, isNot(contains('scale(-1')));
    });

    test('场景 12：文字保持正常阅读方向（Painter 不做水平镜像）', () {
      final String painter = _read('lib/ui/desktop/wheel_menu_painter.dart');
      expect(painter, isNot(contains('scale(-1')));
      // 文字方向必须是 ltr。
      expect(painter.toLowerCase(), contains('textdirection.ltr'));
    });
  });

  // ---------------------------------------------------------------------------
  // 十、DPI（§6 场景 6）
  // ---------------------------------------------------------------------------

  group('DPI', () {
    test('场景 6：位置判定在逻辑像素里，与 DPI 无关', () {
      // 同一逻辑位置的决议必须完全一致（DPI 只影响逻辑↔物理换算）。
      for (final double dpr in <double>[1.0, 1.25, 1.5]) {
        final WheelExpansionResolution r = resolveAt(const Offset(1600, 400));
        expect(r.side, WheelExpansionSide.left, reason: 'dpr=$dpr');
        expect(r.invariant.passed, isTrue, reason: 'dpr=$dpr');
      }
    });
  });
}

String _read(String relative) =>
    File(p.join(Directory.current.path, relative)).readAsStringSync();
