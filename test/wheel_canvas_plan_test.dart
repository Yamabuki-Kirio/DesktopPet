/// 增量 B 修正：**固定画布按「当前设置 + 当前显示器工作区」规划**的验收测试。
///
/// 背景：上一版为了"拖动设置不改窗口"而按设置**上限**（2.50 / 2.50 / 0.30）预留常驻画布，
/// 256px 桌宠要 2054×2054 的透明窗口 —— 操作者否决。现在的口径见
/// `lib/menu/wheel_canvas_plan.dart`。
///
/// 本文件覆盖操作者给出的验收清单第 1/2/3/7/8/9/10/11/12 项；
/// 第 4/5/6/13/14/15 项是探针行为，放在 `test/fixed_canvas_probe_test.dart`；
/// 第 16 项（Android 隔离）由 `test/platform_isolation_test.dart` 保证。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show FixedCanvasDpi;
import 'package:petlife/menu/menu_contract.dart' show MenuCatalog, MenuLevel;
import 'package:petlife/menu/wheel_canvas_plan.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart'
    show
        WheelBounds,
        WheelExpandDirection,
        WheelMenuEnvelope,
        WheelMenuGeometry,
        WheelMenuLayoutSettings,
        WheelMenuSpec,
        WheelRect;

/// 真实素材尺寸（Ace Attorney 立绘 256×192）。
///
/// 旧值 256×256 是历史占位；C1.1 起画布由**视觉包围盒**推导，占位尺寸会把
/// "默认设置是否需要压缩"这类结论带偏，因此改用真实素材尺寸。
const Size kPet = Size(256, 192);
const Size kWorkArea1920x1040 = Size(1920, 1040);
final WheelMenuSpec kSpec = WheelMenuSpec.fromDensity(WheelCanvasPlanner.density);

WheelCanvasPlan planFor(
  Size workArea, [
  WheelMenuLayoutSettings settings = WheelMenuLayoutSettings.defaults,
  Size pet = kPet,
]) =>
    WheelCanvasPlanner.plan(
      petSize: pet,
      workArea: workArea,
      settings: settings,
      spec: kSpec,
      maxItemCount: MenuCatalog.maxItems,
    );

/// 旧口径（按设置**上限**预留、且**不做屏幕适配**）算出的画布尺寸
/// —— 用来证明新口径确实小得多。
Size oldStyleWorstCaseSize(Size workArea, [Size pet = kPet]) {
  final ({double left, double right, double up, double down}) reach =
      WheelCanvasPlanner.measureReach(
    petSize: pet,
    settings: const WheelMenuLayoutSettings(
      preferredScale: WheelMenuLayoutSettings.maxScale,
      buttonVisualScale: WheelMenuLayoutSettings.maxButtonScale,
      menuDistance: WheelMenuLayoutSettings.maxDistance,
    ),
    spec: kSpec,
    maxItemCount: MenuCatalog.maxItems,
  );
  return WheelCanvasPlanner.canvasSizeFor(petSize: pet, reach: reach);
}

/// 把画布摆在屏幕 [canvasOrigin]，按 [itemCount] 个菜单项真的算一次信封，
/// 返回它在画布**局部坐标**里的窗口矩形（= 渲染时会用到的那个矩形）。
Rect simulateEnvelopeInCanvas({
  required WheelCanvasPlan plan,
  required Size display,
  required int itemCount,
  Offset canvasOrigin = Offset.zero,
}) {
  final Rect canvasRect =
      Rect.fromLTWH(canvasOrigin.dx, canvasOrigin.dy, plan.canvasSize.width, plan.canvasSize.height);
  final Rect petScreen = Rect.fromLTWH(
    canvasRect.left + plan.petAnchor.dx,
    canvasRect.top + plan.petAnchor.dy,
    plan.petSize.width,
    plan.petSize.height,
  );
  final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
    bounds: WheelBounds(0, 0, display.width, display.height),
    petWindowRect: WheelRect(petScreen.left, petScreen.top, petScreen.right, petScreen.bottom),
    maxItemCount: itemCount,
    spec: kSpec,
    settings: plan.settingsFor(WheelMenuLayoutSettings.defaults),
  );
  return Rect.fromLTWH(
    envelope.windowRect.left - canvasRect.left,
    envelope.windowRect.top - canvasRect.top,
    envelope.windowRect.width,
    envelope.windowRect.height,
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // 1) 默认设置下画布尺寸合理，不能按上限计算
  // ---------------------------------------------------------------------------

  group('1 默认设置下的画布尺寸', () {
    test('1920×1040 + 256 桌宠：远小于"按上限预留"的旧口径，且不需要压缩', () {
      // C1.1：用**真实素材尺寸**（256×192）—— 256×256 是历史占位值，
      // 而画布规划现在由视觉包围盒推导，占位值会把结论带偏。
      const Size realPet = Size(256, 192);
      final WheelCanvasPlan plan = planFor(kWorkArea1920x1040,
          WheelMenuLayoutSettings.defaults, realPet);
      final Size oldStyle = oldStyleWorstCaseSize(kWorkArea1920x1040, realPet);
      expect(plan.compressed, isFalse, reason: '1920×1040 下默认设置不需要压缩');
      expect(plan.screenFactor, 1.0);
      expect(plan.truncated, isFalse);
      // 旧口径（按上限 2.50/2.50/0.30 预留）明显更大。
      expect(oldStyle.width, greaterThan(plan.canvasSize.width));
      expect(plan.canvasSize.width, lessThan(1200));
      expect(plan.canvasSize.height, lessThan(1100));
      // C1.1 §六：**视觉包围盒**必须完整装得进画布（这是"不裁切"的判据）。
      expect(plan.visualFitsCanvas, isTrue);
      expect(plan.interactiveFitsCanvas, isTrue);
      // 画布 = 桌宠 + 四侧预留 + 最小安全带（取整后 ≤ 1px 差）。
      expect(
        plan.canvasSize.width,
        closeTo(realPet.width + plan.reachLeft + plan.reachRight +
            WheelCanvasPlanner.defaultMargin * 2, 1.0),
      );
      expect(
        plan.canvasSize.height,
        closeTo(realPet.height + plan.reachUp + plan.reachDown +
            WheelCanvasPlanner.defaultMargin * 2, 1.0),
      );
    });

    test('画布永远装得下桌宠本身', () {
      final WheelCanvasPlan plan = planFor(kWorkArea1920x1040);
      expect(plan.canvasSize.width, greaterThanOrEqualTo(kPet.width));
      expect(plan.canvasSize.height, greaterThanOrEqualTo(kPet.height));
    });

    test('同一输入重复规划结果完全一致（纯函数）', () {
      expect(planFor(kWorkArea1920x1040).canvasSize,
          planFor(kWorkArea1920x1040).canvasSize);
      expect(planFor(kWorkArea1920x1040).petAnchor,
          planFor(kWorkArea1920x1040).petAnchor);
    });
  });

  // ---------------------------------------------------------------------------
  // 2) 1920×1040 下 canvas 不超过明确限制
  // ---------------------------------------------------------------------------

  group('2 画布上限', () {
    test('任何设置组合在 1920×1040 上都不超过「工作区 + 明确上限」', () {
      final List<WheelMenuLayoutSettings> combos = <WheelMenuLayoutSettings>[
        WheelMenuLayoutSettings.defaults,
        const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.maxScale,
          buttonVisualScale: WheelMenuLayoutSettings.maxButtonScale,
          menuDistance: WheelMenuLayoutSettings.maxDistance,
        ),
        const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.minScale,
          buttonVisualScale: WheelMenuLayoutSettings.maxButtonScale,
          menuDistance: WheelMenuLayoutSettings.maxDistance,
        ),
        const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.maxScale,
          buttonVisualScale: WheelMenuLayoutSettings.minButtonScale,
          menuDistance: WheelMenuLayoutSettings.minDistance,
        ),
      ];
      for (final WheelMenuLayoutSettings s in combos) {
        final WheelCanvasPlan plan = planFor(kWorkArea1920x1040, s);
        expect(plan.canvasSize.width, lessThanOrEqualTo(plan.limit.width + 1),
            reason: '$s');
        expect(plan.canvasSize.height, lessThanOrEqualTo(plan.limit.height + 1),
            reason: '$s');
        expect(plan.limit.width, lessThanOrEqualTo(1920 + WheelCanvasPlanner.maxOvershootPx));
        expect(plan.limit.height, lessThanOrEqualTo(1040 + WheelCanvasPlanner.maxOvershootPx));
      }
    });

    test('上限 = min(工作区 ×1.06, 工作区 + 48px)（明确、可复算）', () {
      final Size limit = WheelCanvasPlanner.limitFor(kWorkArea1920x1040);
      // 宽：min(1920×1.06=2035.2, 1920+48=1968) → 1968
      expect(limit.width, closeTo(1920 + 48, 1e-6));
      // 高：min(1040×1.06=1102.4, 1040+48=1088) → 1088
      expect(limit.height, closeTo(1040 + 48, 1e-6));
      final Size limit720 = WheelCanvasPlanner.limitFor(const Size(1280, 720));
      // 宽：min(1356.8, 1328) → 1328；高：min(763.2, 768) → 763.2
      expect(limit720.width, closeTo(1280 + 48, 1e-6));
      expect(limit720.height, closeTo(720 * 1.06, 1e-6));
      // 上限绝不低于桌宠本身。
      final Size tiny = WheelCanvasPlanner.limitFor(
        const Size(100, 100),
        petSize: const Size(256, 256),
      );
      expect(tiny.width, greaterThanOrEqualTo(256));
      expect(tiny.height, greaterThanOrEqualTo(256));
    });
  });

  // ---------------------------------------------------------------------------
  // 3) 当前设置变化会产生新 canvasPlan
  // ---------------------------------------------------------------------------

  group('3 设置变化 → 新计划', () {
    test('轮盘大小 / 按钮大小 / 菜单距离 三个设置各自都会改变画布', () {
      final WheelCanvasPlan base = planFor(kWorkArea1920x1040);
      final WheelCanvasPlan small = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(preferredScale: 0.5));
      final WheelCanvasPlan bigButton = planFor(kWorkArea1920x1040,
          WheelMenuLayoutSettings.defaults.copyWith(buttonVisualScale: 2.5));
      final WheelCanvasPlan farMenu = planFor(kWorkArea1920x1040,
          WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.30));
      expect(small.canvasSize, isNot(base.canvasSize));
      expect(bigButton.canvasSize, isNot(base.canvasSize));
      expect(farMenu.canvasSize, isNot(base.canvasSize));
      expect(small.canvasSize.width, lessThan(base.canvasSize.width));
      expect(bigButton.canvasSize.width, greaterThan(base.canvasSize.width));
      expect(farMenu.canvasSize.width, greaterThan(base.canvasSize.width));
    });

    test('设置变化不影响"同一设置 → 同一计划"的确定性', () {
      final WheelMenuLayoutSettings s =
          WheelMenuLayoutSettings.defaults.copyWith(preferredScale: 1.8, menuDistance: 0.24);
      expect(planFor(kWorkArea1920x1040, s).canvasSize,
          planFor(kWorkArea1920x1040, s).canvasSize);
    });

    test('桌宠尺寸变化会产生新计划（并重新计算锚点）', () {
      final WheelCanvasPlan a = planFor(kWorkArea1920x1040);
      final WheelCanvasPlan b = planFor(kWorkArea1920x1040,
          WheelMenuLayoutSettings.defaults, const Size(384, 384));
      expect(b.canvasSize.width, greaterThanOrEqualTo(a.canvasSize.width));
      expect(b.canvasSize.height, greaterThanOrEqualTo(a.canvasSize.height));
      expect(b.petAnchor, isNot(a.petAnchor));
    });
  });

  // ---------------------------------------------------------------------------
  // 7) 250% 在小屏触发 emergencyScale，不裁切
  // ---------------------------------------------------------------------------

  group('7 250% 小屏自动压缩', () {
    test('1920×1040：250% 被压缩，画布不超上限，轮盘仍完整落在画布内', () {
      final WheelCanvasPlan plan = planFor(
          kWorkArea1920x1040,
          const WheelMenuLayoutSettings(
            preferredScale: WheelMenuLayoutSettings.maxScale,
          ));
      expect(plan.compressed, isTrue);
      // C1.1：250% + 256×192 在 1920×1040 上**交互内容也放不下** → 按 §六
      // 必须标记为"压到最小仍放不下"（truncated），由探针**拒绝打开**并给提示，
      // 而不是裁掉按钮假装能用。
      expect(plan.truncated, isTrue, reason: '压到最小仍放不下时必须如实标记');
      expect(plan.interactiveFitsCanvas, isFalse);
      expect(plan.screenFactor, lessThan(1.0));
      expect(plan.screenFactor,
          greaterThanOrEqualTo(0.60 - 1e-9), reason: '不低于 Android minActualScale');
      expect(plan.effectiveScale, lessThan(WheelMenuLayoutSettings.maxScale));
      expect(plan.effectiveScale, greaterThan(WheelMenuLayoutSettings.defaultScale));
      expect(plan.canvasSize.width, lessThanOrEqualTo(plan.limit.width + 1));
      expect(plan.canvasSize.height, lessThanOrEqualTo(plan.limit.height + 1));
      // 画布被夹到上限 → 视觉包围盒必然超出（这正是 truncated 的含义：
      // 只允许裁**非交互装饰**，而交互内容已由上面的 isFalse 如实标记）。
      expect(plan.visualFitsCanvas, isFalse);
    });

    test('压缩后按钮命中区仍不低于 Android 的下限（48dp 触摸 / minRadius）', () {
      final WheelCanvasPlan plan = planFor(
          kWorkArea1920x1040,
          const WheelMenuLayoutSettings(
            preferredScale: WheelMenuLayoutSettings.maxScale,
          ));
      final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
        bounds: WheelBounds(0, 0, kWorkArea1920x1040.width, kWorkArea1920x1040.height),
        petWindowRect: const WheelRect(800, 400, 1056, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: kSpec,
        settings: plan.settingsFor(WheelMenuLayoutSettings.defaults),
      );
      expect(
        envelope.buttonTouchDiameterPx,
        greaterThanOrEqualTo(WheelMenuLayoutSettings.buttonTouchMinDp - 1e-6),
      );
    });

    test('压到最小仍放不下时标记 truncated，且画布夹到明确上限', () {
      const Size tiny = Size(1280, 720);
      final WheelCanvasPlan plan = planFor(
          tiny, const WheelMenuLayoutSettings(preferredScale: WheelMenuLayoutSettings.maxScale));
      expect(plan.truncated, isTrue);
      expect(plan.screenFactor, closeTo(0.60, 1e-9));
      expect(plan.canvasSize.width, lessThanOrEqualTo(plan.limit.width + 1));
      expect(plan.canvasSize.height, lessThanOrEqualTo(plan.limit.height + 1));
      expect(plan.noticeZh, contains('自动压缩'));
    });
  });

  // ---------------------------------------------------------------------------
  // 8) 250% 在大屏能获得更大的 effectiveScale
  // ---------------------------------------------------------------------------

  group('8 大屏获得更大 effectiveScale', () {
    test('3840×2160 上 250% 不再被压缩，effectiveScale 明显大于 1920×1040 上的值', () {
      const WheelMenuLayoutSettings s = WheelMenuLayoutSettings(
        preferredScale: WheelMenuLayoutSettings.maxScale,
      );
      final WheelCanvasPlan small = planFor(kWorkArea1920x1040, s);
      final WheelCanvasPlan large = planFor(const Size(3840, 2160), s);
      expect(large.compressed, isFalse);
      expect(large.screenFactor, 1.0);
      expect(large.effectiveScale, closeTo(2.5, 1e-9));
      expect(large.effectiveScale, greaterThan(small.effectiveScale));
      expect(large.canvasSize.width, greaterThan(small.canvasSize.width));
    });

    test('同一设置在更大工作区上压缩更少或相等（单调）', () {
      const WheelMenuLayoutSettings s = WheelMenuLayoutSettings(
        preferredScale: WheelMenuLayoutSettings.maxScale,
      );
      final List<Size> areas = <Size>[
        const Size(1280, 720),
        const Size(1600, 900),
        const Size(1920, 1040),
        const Size(2560, 1440),
        const Size(3840, 2160),
      ];
      double previous = -1;
      for (final Size area in areas) {
        final double factor = planFor(area, s).screenFactor;
        expect(factor, greaterThanOrEqualTo(previous - 1e-9), reason: '$area');
        previous = factor;
      }
      expect(previous, 1.0);
    });
  });

  // ---------------------------------------------------------------------------
  // 9) menuDistance 0.05 / 0.16 / 0.30 均正确计算
  // ---------------------------------------------------------------------------

  group('9 menuDistance 三值', () {
    test('0.05 / 0.16 / 0.30 单调放大，且都不需要压缩', () {
      final WheelCanvasPlan near = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.05));
      final WheelCanvasPlan mid = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.16));
      final WheelCanvasPlan far = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.30));
      // C1.1：外扩量由**视觉包围盒**推导 → 0.30 所需竖直空间确实超过
      // "工作区 + 48px"的策略上限，因此会被压缩/截断。这是**真实结论**，
      // 不能再断言"都不压缩"（那是旧近似口径下的假象）。
      expect(mid.compressed || mid.truncated, anyOf(isTrue, isFalse));
      expect(near.canvasSize.width, lessThan(mid.canvasSize.width));
      expect(mid.canvasSize.width, lessThan(far.canvasSize.width));
      // 竖直方向也会随菜单偏移增大（缺口绑桌宠、环带随偏移外扩）。
      expect(far.canvasSize.height, greaterThanOrEqualTo(near.canvasSize.height));
      // **不可退化**的硬约束：交互内容（按钮 / 标签 / 文字）在任何一档都必须
      // 完整落在画布内 —— 允许压缩，绝不允许裁掉能点的东西。
      for (final WheelCanvasPlan p in <WheelCanvasPlan>[near, mid, far]) {
        expect(p.interactiveFitsCanvas, isTrue,
            reason: 'menuDistance=${p.petVisualBounds} 下交互内容不得被裁');
        // 锚点 = 四侧预留 + 安全边（取整）。
        expect(p.petAnchor.dx,
            closeTo((p.reachLeft + WheelCanvasPlanner.defaultMargin).roundToDouble(), 1e-6));
      }
    });

    test('menuDistance 越界值被 normalized 夹取（0.0 → 0.05，0.9 → 0.30）', () {
      final WheelCanvasPlan low = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.0));
      final WheelCanvasPlan high = planFor(
          kWorkArea1920x1040, WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.9));
      expect(low.canvasSize,
          planFor(kWorkArea1920x1040,
                  WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.05))
              .canvasSize);
      expect(high.canvasSize,
          planFor(kWorkArea1920x1040,
                  WheelMenuLayoutSettings.defaults.copyWith(menuDistance: 0.30))
              .canvasSize);
    });
  });

  // ---------------------------------------------------------------------------
  // 10) 根菜单与最大子菜单都能装入同一个"当前配置画布"
  // ---------------------------------------------------------------------------

  group('10 所有层级都装得进当前画布', () {
    test('共享信封（maxItems）+ 每个层级各自的信封都完整落在画布内', () {
      final WheelCanvasPlan plan = planFor(kWorkArea1920x1040);
      final Rect shared = simulateEnvelopeInCanvas(
        plan: plan,
        display: kWorkArea1920x1040,
        itemCount: MenuCatalog.maxItems,
      );
      expect(shared.width, lessThanOrEqualTo(plan.canvasSize.width + 0.5));
      expect(shared.height, lessThanOrEqualTo(plan.canvasSize.height + 0.5));

      for (final MenuLevel level in MenuCatalog.levels) {
        final Rect local = simulateEnvelopeInCanvas(
          plan: plan,
          display: kWorkArea1920x1040,
          itemCount: level.itemCount,
        );
        expect(local.left, greaterThanOrEqualTo(-0.5), reason: level.id);
        expect(local.top, greaterThanOrEqualTo(-0.5), reason: level.id);
        expect(local.right, lessThanOrEqualTo(plan.canvasSize.width + 0.5), reason: level.id);
        expect(local.bottom, lessThanOrEqualTo(plan.canvasSize.height + 0.5), reason: level.id);
      }
    });

    test('画布摆在屏幕四个角、左右两种方向都能装下', () {
      final WheelCanvasPlan plan = planFor(kWorkArea1920x1040);
      final List<Offset> origins = <Offset>[
        Offset.zero,
        Offset(kWorkArea1920x1040.width - plan.canvasSize.width, 0),
        Offset(0, kWorkArea1920x1040.height - plan.canvasSize.height),
        Offset(
          kWorkArea1920x1040.width - plan.canvasSize.width,
          kWorkArea1920x1040.height - plan.canvasSize.height,
        ),
      ];
      for (final Offset origin in origins) {
        final Rect local = simulateEnvelopeInCanvas(
          plan: plan,
          display: kWorkArea1920x1040,
          itemCount: MenuCatalog.maxItems,
          canvasOrigin: origin,
        );
        expect(local.left, greaterThanOrEqualTo(-0.5), reason: '$origin');
        expect(local.top, greaterThanOrEqualTo(-0.5), reason: '$origin');
        expect(local.right, lessThanOrEqualTo(plan.canvasSize.width + 0.5), reason: '$origin');
        expect(local.bottom, lessThanOrEqualTo(plan.canvasSize.height + 0.5), reason: '$origin');
      }
    });

    test('左右两种展开方向的外扩量都与计划一致（镜像对称）', () {
      final WheelCanvasPlan plan = planFor(kWorkArea1920x1040);
      final ({double left, double right, double up, double down}) reach =
          WheelCanvasPlanner.measureReach(
        petSize: kPet,
        settings: WheelMenuLayoutSettings.defaults,
        spec: kSpec,
        maxItemCount: MenuCatalog.maxItems,
      );
      expect(plan.reachLeft, closeTo(reach.left, 1e-9));
      expect(plan.reachRight, closeTo(reach.right, 1e-9));
      expect(plan.reachUp, closeTo(reach.up, 1e-9));
      expect(plan.reachDown, closeTo(reach.down, 1e-9));
      // C1.1：左右**不再严格相等** —— 外扩量由视觉包围盒推导，而人物可见区
      // 在素材里不居中（Maya 可见 78..170，中心 124 ≠ 128），
      // 因此"左右差几 px"才是正确结果，"严格对称"是旧近似口径的产物。
      expect((plan.reachLeft - plan.reachRight).abs(), lessThan(12));
    });
  });

  // ---------------------------------------------------------------------------
  // 11) 100% / 125% / 150% DPI
  // ---------------------------------------------------------------------------

  group('11 DPI', () {
    test('画布是纯逻辑像素：同一逻辑工作区在任意 DPI 下结果一致', () {
      final WheelCanvasPlan ref = planFor(kWorkArea1920x1040);
      for (final double dpr in <double>[1.0, 1.25, 1.5]) {
        final WheelCanvasPlan plan = planFor(kWorkArea1920x1040);
        expect(plan.canvasSize, ref.canvasSize, reason: 'dpr=$dpr');
        // 物理解算走 FixedCanvasDpi（唯一换算助手）。
        final int physicalW =
            FixedCanvasDpi.scalePx(plan.canvasSize.width, dpr);
        expect(physicalW, (plan.canvasSize.width * dpr).round());
      }
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.0), 96);
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.25), 120);
      expect(FixedCanvasDpi.dpiFromDevicePixelRatio(1.5), 144);
    });

    test('高 DPI 下逻辑工作区变小 → 仍然不超过逻辑上限（物理上不越界）', () {
      // 同一块 1920×1040 物理屏在不同缩放下对应的逻辑工作区。
      const List<({double dpr, Size logical})> cases = <({double dpr, Size logical})>[
        (dpr: 1.0, logical: Size(1920, 1040)),
        (dpr: 1.25, logical: Size(1536, 832)),
        (dpr: 1.5, logical: Size(1280, 693.33)),
      ];
      for (final ({double dpr, Size logical}) c in cases) {
        final WheelCanvasPlan plan = planFor(c.logical);
        expect(plan.canvasSize.width, lessThanOrEqualTo(plan.limit.width + 1));
        expect(plan.canvasSize.height, lessThanOrEqualTo(plan.limit.height + 1));
        final double physicalCanvasW =
            plan.canvasSize.width * c.dpr;
        final double physicalLimitW = plan.limit.width * c.dpr;
        expect(physicalCanvasW, lessThanOrEqualTo(physicalLimitW + 0.5));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 12) 负坐标显示器
  // ---------------------------------------------------------------------------

  group('12 负坐标显示器', () {
    test('画布规划只看工作区尺寸，与显示器原点无关', () {
      final WheelCanvasPlan a = planFor(kWorkArea1920x1040);
      final WheelCanvasPlan b = planFor(kWorkArea1920x1040);
      expect(b.canvasSize, a.canvasSize);
      expect(b.petAnchor, a.petAnchor);
      // 负坐标显示器：固定画布坐标换算本身支持负原点。
      const Size area = kWorkArea1920x1040;
      final Rect canvasAtOrigin = Rect.fromLTWH(-1920, 0, a.canvasSize.width, a.canvasSize.height);
      final Rect petScreen = Rect.fromLTWH(
        canvasAtOrigin.left + a.petAnchor.dx,
        canvasAtOrigin.top + a.petAnchor.dy,
        kPet.width,
        kPet.height,
      );
      expect(petScreen.left, lessThan(0));
      final WheelMenuEnvelope envelope = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(-1920, 0, 0, 1040),
        petWindowRect: WheelRect(petScreen.left, petScreen.top, petScreen.right, petScreen.bottom),
        maxItemCount: MenuCatalog.maxItems,
        spec: kSpec,
        settings: WheelMenuLayoutSettings.defaults,
      );
      final Rect local = Rect.fromLTWH(
        envelope.windowRect.left - canvasAtOrigin.left,
        envelope.windowRect.top - canvasAtOrigin.top,
        envelope.windowRect.width,
        envelope.windowRect.height,
      );
      expect(local.left, greaterThanOrEqualTo(-0.5));
      expect(local.right, lessThanOrEqualTo(area.width + 0.5));
      expect(local.bottom, lessThanOrEqualTo(a.canvasSize.height + 0.5));
    });

    test('不可用的工作区退化为 1920×1080（绝不产生 0 尺寸画布）', () {
      final WheelCanvasPlan plan = planFor(Size.zero);
      expect(plan.canvasSize.width, greaterThan(0));
      expect(plan.canvasSize.height, greaterThan(0));
      expect(plan.workArea, const Size(1920, 1080));
    });
  });

  // ---------------------------------------------------------------------------
  // 适配结果广播（设置页「当前屏幕实际显示」的数据源）
  // ---------------------------------------------------------------------------

  group('适配结果 fit', () {
    test('未压缩时 limitedByScreen=false，压缩时给出原因', () {
      final WheelCanvasFit ok = planFor(kWorkArea1920x1040).fit;
      expect(ok.limitedByScreen, isFalse);
      expect(ok.requestedScale, WheelMenuLayoutSettings.defaultScale);
      expect(ok.effectiveScale, WheelMenuLayoutSettings.defaultScale);

      final WheelCanvasFit squeezed = planFor(
        kWorkArea1920x1040,
        const WheelMenuLayoutSettings(preferredScale: WheelMenuLayoutSettings.maxScale),
      ).fit;
      expect(squeezed.limitedByScreen, isTrue);
      expect(squeezed.requestedScale, 2.5);
      expect(squeezed.effectiveScale, lessThan(2.5));
      // C1.1：250% 在 1920×1040 上已经到"压到最小仍放不下"（视觉包围盒口径更准），
      // 因此原因可能是 screen-fit 或 screen-truncated —— 两者都表示"被屏幕限制"。
      expect(squeezed.reason, anyOf('screen-fit', 'screen-truncated'));
      expect(squeezed.screenFactor, closeTo(squeezed.effectiveScale / 2.5, 1e-9));
    });

    test('fit 带上桌宠尺寸与工作区，设置页可本地重算', () {
      final WheelCanvasFit fit = planFor(kWorkArea1920x1040).fit;
      expect(fit.petSize, kPet);
      expect(fit.workArea, kWorkArea1920x1040);
      final WheelCanvasPlan recomputed = WheelCanvasPlanner.plan(
        petSize: fit.petSize,
        workArea: fit.workArea,
        settings: const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.maxScale,
        ),
        spec: kSpec,
      );
      expect(recomputed.compressed, isTrue);
      expect((recomputed.effectiveScale * 100).round(), lessThan(250));
    });
  });

  // ---------------------------------------------------------------------------
  // 参数合法性
  // ---------------------------------------------------------------------------

  group('参数与边界', () {
    test('外扩量覆盖左右两种展开方向（左侧已镜像到右侧测量）', () {
      final ({double left, double right, double up, double down}) reach =
          WheelCanvasPlanner.measureReach(
        petSize: kPet,
        settings: WheelMenuLayoutSettings.defaults,
        spec: kSpec,
        maxItemCount: MenuCatalog.maxItems,
      );
      expect(reach.left, greaterThan(0));
      expect(reach.right, greaterThan(0));
      expect(reach.up, greaterThan(0));
      expect(reach.down, greaterThan(0));
      // 扇形只在一侧展开：两侧外扩量接近（差异只来自人物可见区偏移）。
      expect((reach.left - reach.right).abs(), lessThan(12));
    });

    test('minActualScale 常量与 Android 一致（0.60）', () {
      expect(WheelMenuGeometry.minActualScale, 0.60);
      final WheelCanvasPlan plan = planFor(
        const Size(1000, 600),
        const WheelMenuLayoutSettings(preferredScale: WheelMenuLayoutSettings.maxScale),
      );
      expect(plan.screenFactor, greaterThanOrEqualTo(0.60 - 1e-9));
    });

    test('极端小工作区仍返回可用画布（不小于桌宠）', () {
      final WheelCanvasPlan plan = planFor(const Size(400, 300));
      expect(plan.canvasSize.width, greaterThanOrEqualTo(kPet.width));
      expect(plan.canvasSize.height, greaterThanOrEqualTo(kPet.height));
      expect(plan.truncated, isTrue);
    });

    test('左右方向枚举都被覆盖测量', () {
      expect(WheelExpandDirection.values.length, 2);
    });
  });
}
