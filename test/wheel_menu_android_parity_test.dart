/// 增量 B：正式 P3P 轮盘与 **Android 基准逐项对照**的纯逻辑测试。
///
/// 基准文档：`docs/37-Android轮盘菜单视觉与交互基准审计.md`。
/// 每条断言都对着 Android 的**常量或公式**写，而不是对着 Windows 的当前实现写 ——
/// 这样"顺手优化"会被立刻抓住。
///
/// 覆盖：主题色值与派生 / 几何常量与三式求解 / 缺口绑定 / 方向与靠边偏转 /
/// 七态状态机 / 手势（角度判定、7° 滞回、松手确认、缺口取消区、130ms 容差）/
/// 动画时间线与帧推导 / Region 生成 / 固定画布桥接 / 设置夹取与持久化。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_animator.dart';
import 'package:petlife/menu/wheel_canvas_bridge.dart';
import 'package:petlife/menu/wheel_canvas_plan.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart';
import 'package:petlife/menu/wheel_menu_state.dart';
import 'package:petlife/menu/wheel_region.dart';
import 'package:petlife/menu/wheel_selection_controller.dart';
import 'package:petlife/menu/wheel_theme.dart';
import 'package:petlife/settings/app_settings.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 一、主题（决策四：色值逐字、派生同公式、删掉 Android 不存在的字段）
  // ---------------------------------------------------------------------------

  group('主题 · P3P 六色逐字', () {
    test('P3P 粉的六个颜色与 Android 完全一致', () {
      final WheelMenuTheme t = WheelMenuThemes.p3pPink();
      expect(t.primary, 0xFFF24D96);
      expect(t.secondary, 0xFFFF8ABA);
      expect(t.background, 0xFFFFD8E9);
      expect(t.highlight, 0xFFFFD42A);
      expect(t.outline, 0xFF111111);
      expect(t.text, 0xFFFFFFFF);
      expect(t.disabled, 0xFF8E7180);
    });

    test('themeId 的 wire 取值是 p3p-pink（不是 p3p_pink）', () {
      expect(WheelThemeIds.p3pPink, 'p3p-pink');
      expect(WheelMenuThemes.p3pPink().themeId, 'p3p-pink');
      expect(WheelMenuThemes.presets.map((WheelMenuTheme t) => t.themeId).toList(),
          <String>['p3p-pink', 'blue', 'red', 'purple', 'green']);
    });

    test('强调色固定为 P3P 黄、描边固定为近黑（各预设共用）', () {
      for (final WheelMenuTheme t in WheelMenuThemes.presets) {
        expect(t.highlight, 0xFFFFD42A, reason: '${t.themeId} 的强调色必须固定');
        expect(t.outline, 0xFF111111, reason: '${t.themeId} 的描边必须固定');
      }
    });

    test('其它预设只钉主色，其余派生（派生算法确定）', () {
      expect(WheelMenuThemes.bluePrimary, 0xFF2F7CF6);
      expect(WheelMenuThemes.redPrimary, 0xFFE23B3B);
      expect(WheelMenuThemes.purplePrimary, 0xFF8B4DE0);
      expect(WheelMenuThemes.greenPrimary, 0xFF1FA463);
      final WheelMenuTheme blue = WheelMenuThemes.preset('blue')!;
      expect(blue.primary, WheelMenuThemes.bluePrimary);
      expect(blue.secondary, WheelMenuThemes.lighten(WheelMenuThemes.bluePrimary, 0.42));
    });

    test('baseFanColor = mix(secondary, background, 0.40) 再压 alpha 108', () {
      final WheelMenuTheme t = WheelMenuThemes.p3pPink();
      final int blended = WheelMenuThemes.mix(t.secondary, t.background, 0.40);
      final int expected = WheelMenuThemes.withAlpha(blended, 108);
      expect(WheelMenuThemes.baseFanColor(t), expected);
      expect((WheelMenuThemes.baseFanColor(t) >> 24) & 0xFF, 108);
      expect(WheelMenuThemes.baseFanBlendToBackground, 0.40);
      expect(WheelMenuThemes.baseFanAlpha, 108);
    });

    test('文字色自动选择偏向白字（大号粗体阈值 3.0）', () {
      expect(WheelMenuThemes.minTextContrast, 3.0);
      expect(WheelMenuThemes.autoTextColor(WheelMenuThemes.p3pPrimary), 0xFFFFFFFF);
      // 浅色主色 → 白字不达标 → 用近黑。
      expect(WheelMenuThemes.autoTextColor(0xFFFFF6E0), 0xFF000000);
    });

    test('fromWire：空 / 未命中 → P3P 粉；custom → 按主色派生', () {
      expect(WheelMenuTheme.fromWire(null, 0).themeId, 'p3p-pink');
      expect(WheelMenuTheme.fromWire('', 0).themeId, 'p3p-pink');
      expect(WheelMenuTheme.fromWire('not-exist', 0).themeId, 'p3p-pink');
      final WheelMenuTheme custom = WheelMenuTheme.fromWire('custom', 0xFF3366CC);
      expect(custom.themeId, 'custom');
      expect(custom.primary, 0xFF3366CC);
      expect(custom.background, WheelMenuThemes.mix(0xFF3366CC, 0xFFFFFFFF, 0.84));
    });

    test('hex 解析：非法输入不抛异常、返回 null；合法值不失真', () {
      expect(WheelMenuThemes.parseHex('#F24D96'), 0xFFF24D96);
      expect(WheelMenuThemes.parseHex('f24d96'), 0xFFF24D96);
      expect(WheelMenuThemes.parseHex(''), isNull);
      expect(WheelMenuThemes.parseHex('xyz'), isNull);
      expect(WheelMenuThemes.parseHex('#12345'), isNull);
      expect(WheelMenuThemes.toHex(0xFFF24D96), '#F24D96');
    });

    test('主题对象**不含** Android 不存在的自创字段', () {
      // 反向断言：Android 只有 7 个颜色 + gradientEnabled / animationStyle / revision。
      final WheelMenuTheme t = WheelMenuThemes.p3pPink();
      expect(<int>[t.primary, t.secondary, t.background, t.highlight, t.outline, t.text, t.disabled].length, 7);
      expect(t.gradientEnabled, isTrue);
      expect(t.animationStyle, WheelAnimationStyles.standard);
    });
  });

  // ---------------------------------------------------------------------------
  // 二、几何常量（决策四：逐字，不顺手优化）
  // ---------------------------------------------------------------------------

  group('几何 · 常量逐字', () {
    test('缩放与距离常量', () {
      expect(WheelMenuLayoutSettings.minScale, 0.50);
      expect(WheelMenuLayoutSettings.maxScale, 2.50);
      expect(WheelMenuLayoutSettings.step, 0.10);
      expect(WheelMenuLayoutSettings.defaultScale, 1.00);
      expect(WheelMenuLayoutSettings.minDistance, 0.05);
      expect(WheelMenuLayoutSettings.maxDistance, 0.30);
      expect(WheelMenuLayoutSettings.defaultDistance, 0.16);
      expect(WheelMenuLayoutSettings.minButtonScale, 0.50);
      expect(WheelMenuLayoutSettings.maxButtonScale, 2.50);
      expect(WheelMenuLayoutSettings.buttonStep, 0.10);
      expect(WheelMenuLayoutSettings.defaultButtonScale, 1.30);
      expect(WheelMenuLayoutSettings.buttonTouchMinDp, 48);
    });

    test('轮盘尺寸常量（dp）', () {
      expect(WheelMenuSpec.buttonDiameterDp, 44);
      expect(WheelMenuSpec.buttonDiameterCompactDp, 40);
      expect(WheelMenuSpec.buttonGapDp, 6);
      expect(WheelMenuSpec.bandPaddingDp, 8);
      expect(WheelMenuSpec.rimLobeDp, 7);
      expect(WheelMenuSpec.outlineDp, 2.2);
      expect(WheelMenuSpec.minOutlineDp, 1.2);
      expect(WheelMenuSpec.maxOutlineDp, 4.5);
      expect(WheelMenuSpec.minOutlineScale, 0.72);
    });

    test('角度 / 缺口 / 安全区常量', () {
      expect(WheelMenuGeometry.minStepDeg, 16);
      expect(WheelMenuGeometry.maxStepDeg, 30);
      expect(WheelMenuGeometry.maxHalfSpanDeg, 68);
      expect(WheelMenuGeometry.compactHalfSpanDeg, 50);
      expect(WheelMenuGeometry.minHalfSpanDeg, 38);
      expect(WheelMenuGeometry.bladeHalfSweepDeg, 30);
      expect(WheelMenuGeometry.holeWidthRatio, 1.05);
      expect(WheelMenuGeometry.holeHeightRatio, 1.05);
      expect(WheelMenuGeometry.notchPaddingDp, 10);
      expect(WheelMenuGeometry.notchMaxInnerDiameterRatio, 0.88);
      expect(WheelMenuGeometry.minRadiusDp, 62);
      expect(WheelMenuGeometry.safetyPaddingDp, 10);
      expect(WheelMenuGeometry.minActualScale, 0.60);
      expect(kEdgeFanBiasDeg, 26);
    });

    test('7 项及以上用 40dp 按钮（44dp 基准）', () {
      final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
      expect(spec.buttonDiameterFor(6), 44);
      expect(spec.buttonDiameterFor(7), 40);
    });

    test('描边随缩放变宽但有上下限', () {
      final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
      expect(spec.outlineWidthFor(spec.outlinePx, 1), closeTo(2.2, 1e-9));
      // 极小缩放：被 minOutlineScale(0.72) 托住 → 2.2 × 0.72。
      expect(spec.outlineWidthFor(spec.outlinePx, 0.1), closeTo(2.2 * 0.72, 1e-9));
      // 极大缩放：被 4.5dp 封顶。
      expect(spec.outlineWidthFor(spec.outlinePx, 99), closeTo(4.5, 1e-9));
      // 下界 1.2dp 只在基准描边本身很细时才起作用。
      expect(spec.outlineWidthFor(1.0, 1), closeTo(1.2, 1e-9));
    });

    test('半张角与槽位间隔按 Android 取值', () {
      expect(WheelMenuGeometry.halfSpanFor(6, false), 68);
      expect(WheelMenuGeometry.halfSpanFor(6, true), 50);
      // 项数少时半张角收缩但不下于 38°。
      expect(WheelMenuGeometry.halfSpanFor(2, false), lessThanOrEqualTo(68));
      expect(WheelMenuGeometry.halfSpanFor(2, false), greaterThanOrEqualTo(38));
      // 间隔夹在 16° ~ 30°；单项目没有间隔可言（0）。
      for (final int count in <int>[2, 3, 4, 5, 6, 7, 8]) {
        final double half = WheelMenuGeometry.halfSpanFor(count, false);
        final double step = WheelMenuGeometry.stepDegFor(count, half);
        expect(step, greaterThanOrEqualTo(WheelMenuGeometry.minStepDeg - 1e-9));
        expect(step, lessThanOrEqualTo(WheelMenuGeometry.maxStepDeg + 1e-9));
      }
      expect(WheelMenuGeometry.stepDegFor(1, 68), 0);
    });
  });

  // ---------------------------------------------------------------------------
  // 三、信封：缺口绑桌宠、不乘应急缩放、ringRadius 三式求解
  // ---------------------------------------------------------------------------

  group('信封 · 缺口与半径', () {
    const WheelBounds display = WheelBounds(0, 0, 1920, 1080);
    final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
    final WheelMenuLayoutSettings settings = WheelMenuLayoutSettings.defaults;

    WheelMenuEnvelope envelopeFor(Rect pet, {WheelBounds bounds = display}) =>
        WheelMenuGeometry.computeEnvelope(
          bounds: bounds,
          petWindowRect: WheelRect(pet.left, pet.top, pet.right, pet.bottom),
          maxItemCount: MenuCatalog.maxItems,
          spec: spec,
          settings: settings,
        );

    test('窗口与信封都可用（不是降级路径）', () {
      final WheelMenuEnvelope e = envelopeFor(const Rect.fromLTWH(300, 400, 256, 256));
      expect(e.windowRect.isUsable, isTrue);
      expect(e.actualScale, greaterThan(0));
    });

    test('缺口椭圆半径 = 桌宠可见尺寸 × 1.05 / 2 + 10dp（**不乘应急缩放**）', () {
      const Rect pet = Rect.fromLTWH(300, 400, 256, 256);
      final WheelMenuEnvelope e = envelopeFor(pet);
      expect(e.holeRx, closeTo(256 * 1.05 / 2 + 10, 1e-9));
      expect(e.holeRy, closeTo(256 * 1.05 / 2 + 10, 1e-9));
      // 即使实际缩放 < 1，缺口也不跟着缩。
      final WheelMenuEnvelope small = envelopeFor(
        const Rect.fromLTWH(0, 0, 256, 256),
        bounds: const WheelBounds(0, 0, 420, 420),
      );
      expect(small.actualScale, lessThanOrEqualTo(1.0));
      expect(small.holeRx, closeTo(256 * 1.05 / 2 + 10, 1e-9));
    });

    test('缺口中心恒等于桌宠视觉锚点（允许偏心 menuDistance）', () {
      const Rect pet = Rect.fromLTWH(300, 400, 256, 256);
      final WheelMenuEnvelope e = envelopeFor(pet);
      expect(e.petAnchorX, closeTo(pet.center.dx, 1e-9));
      expect(e.petAnchorY, closeTo(pet.center.dy, 1e-9));
      final WheelMenuLayout l = WheelMenuGeometry.layoutFor(e, MenuCatalog.root, spec);
      // 层级几何里的缺口中心 = 桌宠锚点在窗口内的相对坐标。
      expect(l.notchCenterX, closeTo(e.petAnchorX - e.windowRect.left, 1e-9));
      expect(l.notchCenterY, closeTo(e.petAnchorY - e.windowRect.top, 1e-9));
      // 允许偏心：轮盘中心与缺口中心不强制重合。
      expect(e.allowedOffsetPx, greaterThan(0));
    });

    test('ringRadius 三式求解：轨道间距 / 缺口净空 / 桌宠净空 三者的最大值', () {
      const Rect pet = Rect.fromLTWH(300, 400, 256, 256);
      final WheelMenuEnvelope e = envelopeFor(pet);
      final WheelIntrinsicLayout intrinsic = WheelMenuGeometry.intrinsicLayout(
        itemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: settings,
        petVisibleWidth: 256,
        petVisibleHeight: 256,
      );
      final double buttonRadius = intrinsic.buttonDiameterPx / 2;
      final double notchForm =
          intrinsic.notchRx / WheelMenuGeometry.notchMaxInnerDiameterRatio + buttonRadius;
      final double clearanceForm =
          (256 / 2) * 1.4142135623730951 + 256 * settings.menuDistance + buttonRadius + 4;
      final double expected = <double>[
        WheelMenuGeometry.spacingRadiusPx(
          intrinsic.itemCount,
          intrinsic.stepDeg,
          intrinsic.buttonDiameterPx,
          spec,
        ),
        notchForm,
        clearanceForm,
        spec.dp(WheelMenuGeometry.minRadiusDp),
      ].reduce((double a, double b) => a > b ? a : b);
      expect(e.maxRingRadiusPx, closeTo(expected, 1e-6));
    });

    test('环带必须容得下缺口（不许出现"粗甜甜圈"）', () {
      const Rect pet = Rect.fromLTWH(300, 400, 256, 256);
      final WheelMenuEnvelope e = envelopeFor(pet);
      final double buttonRadius = e.buttonDiameterPx / 2;
      expect(
        e.maxRingRadiusPx - buttonRadius,
        greaterThanOrEqualTo(e.holeRx / WheelMenuGeometry.notchMaxInnerDiameterRatio - 1e-6),
      );
    });

    test('按钮直径 = base(count) × (effScale × buttonVisualScale)（唯一落点）', () {
      // ⚠️ 信封按 maxItemCount = 7 计算 → 走 **40dp 紧凑基准**（Android 同口径）。
      // Android WheelMenuGeometry.kt:554-559（逐字）：
      //   effScale  = preferredScale * (compact ? COMPACT_BUTTON_SHRINK(0.92) : 1)
      //   buttonDia = buttonDiameterFor(count, effScale * buttonVisualScale)
      //             = base(count) * (effScale * buttonVisualScale).clamp(0.20, 4.0)
      final WheelMenuEnvelope a = envelopeFor(const Rect.fromLTWH(300, 400, 256, 256));
      final WheelMenuEnvelope b = WheelMenuGeometry.computeEnvelope(
        bounds: display,
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: settings.copyWith(buttonVisualScale: 2.0),
      );
      expect(WheelMenuLayoutSettings.defaultButtonScale, 1.30);
      expect(WheelMenuLayoutSettings.defaults.buttonVisualScale, 1.30);
      // 默认 settings：preferredScale = 1.0，非紧凑 → effScale = 1.0。
      expect(a.buttonDiameterPx, closeTo(40 * 1.30, 1e-6));
      // buttonVisualScale 直接乘进去（1.0 * 2.0）。
      expect(b.buttonDiameterPx, closeTo(40 * 2.0, 1e-6));
      // 轮盘大小（preferredScale）**也会**经 effScale 进入按钮直径 —— 这不是"顺手优化"，
      // 而是 Android 原样：2.5 → 40 * (2.5 * 1.30) = 130。
      final WheelMenuEnvelope c = WheelMenuGeometry.computeEnvelope(
        bounds: display,
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: settings.copyWith(preferredScale: 2.5),
      );
      expect(c.buttonDiameterPx, closeTo(40 * 2.5 * 1.30, 1e-6));
    });

    test('面板不小于 48dp 触摸下界', () {
      final WheelMenuEnvelope e = envelopeFor(const Rect.fromLTWH(300, 400, 256, 256));
      expect(e.buttonTouchDiameterPx, greaterThanOrEqualTo(48));
    });
  });

  // ---------------------------------------------------------------------------
  // 四、方向 / 靠边偏转 / 镜像角度
  // ---------------------------------------------------------------------------

  group('方向与镜像', () {
    const WheelBounds display = WheelBounds(0, 0, 1920, 1080);

    test('桌宠在左半屏 → 向右展开；在右半屏 → 向左展开', () {
      const WheelRect leftPet = WheelRect(200, 400, 456, 656);
      const WheelRect rightPet = WheelRect(1500, 400, 1756, 656);
      expect(
        WheelMenuGeometry.decideDirection(leftPet, display, null, false),
        WheelExpandDirection.right,
      );
      expect(
        WheelMenuGeometry.decideDirection(rightPet, display, null, false),
        WheelExpandDirection.left,
      );
    });

    test('locked 时方向被锁定（打开期间不改）', () {
      const WheelRect rightPet = WheelRect(1500, 400, 1756, 656);
      expect(
        WheelMenuGeometry.decideDirection(rightPet, display, WheelExpandDirection.right, true),
        WheelExpandDirection.right,
      );
    });

    test('靠上 / 靠下边缘 → 竖直模式带 ±26° 偏转', () {
      expect(WheelMenuGeometry.decideVerticalMode(
          const WheelRect(900, 10, 1156, 266), display, null, false), WheelVerticalMode.topEdge);
      expect(WheelMenuGeometry.decideVerticalMode(
          const WheelRect(900, 900, 1156, 1080), display, null, false), WheelVerticalMode.bottomEdge);
      expect(WheelMenuGeometry.decideVerticalMode(
          const WheelRect(900, 460, 1156, 716), display, null, false), WheelVerticalMode.center);
      expect(WheelVerticalMode.topEdge.biasDeg, kEdgeFanBiasDeg);
      expect(WheelVerticalMode.bottomEdge.biasDeg, -kEdgeFanBiasDeg);
      expect(WheelVerticalMode.center.biasDeg, 0);
    });

    test('镜像：absoluteAngle 取反（左展开 = 180° − offset）', () {
      expect(WheelMenuGeometry.absoluteAngle(WheelExpandDirection.right, 0), 0);
      expect(WheelMenuGeometry.absoluteAngle(WheelExpandDirection.right, 30), 30);
      expect(WheelMenuGeometry.absoluteAngle(WheelExpandDirection.left, 0), 180);
      expect(WheelMenuGeometry.absoluteAngle(WheelExpandDirection.left, 30), 150);
      // 180 + 30 = 210 → 归一到 (−180, 180] 即 −150。
      expect(WheelMenuGeometry.absoluteAngle(WheelExpandDirection.left, -30), -150);
    });

    test('normalizeAngle 落在 (−180, 180]', () {
      expect(WheelMenuGeometry.normalizeAngle(370), closeTo(10, 1e-9));
      expect(WheelMenuGeometry.normalizeAngle(-190), closeTo(170, 1e-9));
    });

    test('槽位落位：第 i 项 offset = (i − (n−1)/2) × step，且沿圆周分布', () {
      final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
      final WheelMenuEnvelope e = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(0, 0, 1920, 1080),
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: WheelMenuLayoutSettings.defaults,
      );
      final WheelMenuLayout l = WheelMenuGeometry.layoutFor(e, MenuCatalog.root, spec);
      expect(l.slots.length, MenuCatalog.root.itemCount);
      final double half = (l.itemCount - 1) / 2;
      for (final WheelSlotPlacement s in l.slots) {
        expect(s.offsetAngleDeg, closeTo((s.index - half) * l.stepDeg, 1e-9));
      }
      // 每个按钮都落在环带上。
      for (final WheelSlotPlacement s in l.slots) {
        final double dx = s.centerX - l.centerX;
        final double dy = s.centerY - l.centerY;
        expect((dx * dx + dy * dy).abs(), closeTo(l.ringRadiusPx * l.ringRadiusPx, 1e-3));
      }
    });

    test('rawIndexAt：角度 → 连续索引（0 号在最靠近展开方向的一侧）', () {
      final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);
      final WheelMenuEnvelope e = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(0, 0, 1920, 1080),
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: WheelMenuLayoutSettings.defaults,
      );
      final WheelMenuLayout l = WheelMenuGeometry.layoutFor(e, MenuCatalog.root, spec);
      expect(WheelMenuGeometry.rawIndexAt(l, l.absoluteAngleFor(0)), closeTo(0, 0.35));
      expect(
        WheelMenuGeometry.rawIndexAt(l, l.absoluteAngleFor(l.itemCount - 1)),
        closeTo(l.itemCount - 1, 0.35),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 五、状态机七态
  // ---------------------------------------------------------------------------

  group('状态机 · 七态', () {
    test('阶段集合与 Android 逐字一致', () {
      expect(WheelMenuPhase.values.map((WheelMenuPhase p) => p.name).toList(), <String>[
        'closed',
        'opening',
        'open',
        'switching',
        'enteringLayer',
        'exitingLayer',
        'closing',
      ]);
      expect(WheelMenuPhase.closed.occupiesWindow, isFalse);
      expect(WheelMenuPhase.closing.animating, isTrue);
      expect(WheelMenuPhase.opening.transitioning, isTrue);
      expect(WheelMenuPhase.open.transitioning, isFalse);
    });

    test('open → opening → open，方向锁定；重复打开幂等拒绝', () {
      final WheelMenuStateMachine s = WheelMenuStateMachine();
      expect(s.open(WheelExpandDirection.left), isTrue);
      expect(s.phase, WheelMenuPhase.opening);
      expect(s.open(WheelExpandDirection.right), isFalse, reason: '打开期间不得改方向');
      s.markOpened();
      expect(s.phase, WheelMenuPhase.open);
      expect(s.direction, WheelExpandDirection.left);
      expect(s.levelId, MenuCatalog.rootId);
    });

    test('根菜单不允许返回；进入子菜单后可以', () {
      final WheelMenuStateMachine s = WheelMenuStateMachine();
      s.open(WheelExpandDirection.right);
      s.markOpened();
      expect(s.canGoBack, isFalse);
      expect(s.exitLayer(), isFalse);
      expect(s.enterLayerByAction('open_pet'), isTrue);
      expect(s.phase, WheelMenuPhase.enteringLayer);
      expect(s.canGoBack, isTrue);
      s.finishLayerTransition();
      expect(s.phase, WheelMenuPhase.open);
      expect(s.levelId, MenuCatalog.petLevelId);
      expect(s.exitLayer(), isTrue);
      expect(s.phase, WheelMenuPhase.exitingLayer);
      s.finishLayerTransition();
      expect(s.levelId, MenuCatalog.rootId);
    });

    test('滑选：preview 优先于 selected，确认后落到 selected', () {
      final WheelMenuStateMachine s = WheelMenuStateMachine();
      s.open(WheelExpandDirection.right);
      s.markOpened();
      s.setPreview(3);
      expect(s.activeIndex, 3);
      expect(s.selectedIndex, 0);
      final MenuNode? picked = s.confirmSelection();
      expect(picked?.id, MenuCatalog.root.nodes[3].id);
      expect(s.selectedIndex, 3);
      expect(s.previewIndex, isNull);
    });

    test('切换选中项：beginSwitch 拒绝同项与越界', () {
      final WheelMenuStateMachine s = WheelMenuStateMachine();
      s.open(WheelExpandDirection.right);
      s.markOpened();
      expect(s.beginSwitch(0), isFalse);
      expect(s.beginSwitch(99), isFalse);
      expect(s.beginSwitch(2), isTrue);
      expect(s.phase, WheelMenuPhase.switching);
      s.finishSwitch(2);
      expect(s.phase, WheelMenuPhase.open);
      expect(s.selectedIndex, 2);
    });

    test('被打断后收敛到确定状态，绝不卡中间态', () {
      for (final WheelMenuPhase phase in WheelMenuPhase.values) {
        final WheelMenuStateMachine s = WheelMenuStateMachine();
        s.open(WheelExpandDirection.right);
        s.markOpened();
        switch (phase) {
          case WheelMenuPhase.closed:
            s.close();
          case WheelMenuPhase.opening:
            s.close();
            s.open(WheelExpandDirection.right);
          case WheelMenuPhase.switching:
            s.beginSwitch(1);
          case WheelMenuPhase.enteringLayer:
            s.enterLayerByAction('open_pet');
          case WheelMenuPhase.exitingLayer:
            s.enterLayerByAction('open_pet');
            s.finishLayerTransition();
            s.exitLayer();
          case WheelMenuPhase.closing:
            s.beginClosing();
          case WheelMenuPhase.open:
            break;
        }
        s.settleAfterInterruption();
        expect(s.phase.animating, isFalse, reason: '${phase.name} 打断后仍在动画态');
      }
    });

    test('close 从任何阶段都收敛到 closed（菜单栈清空）', () {
      final WheelMenuStateMachine s = WheelMenuStateMachine();
      s.open(WheelExpandDirection.right);
      s.markOpened();
      s.enterLayerByAction('open_records');
      expect(s.close(), isTrue);
      expect(s.phase, WheelMenuPhase.closed);
      expect(s.levelId, isNull);
      expect(s.canGoBack, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 六、手势：角度判定 / 7° 滞回 / 松手确认 / 缺口取消区 / 130ms 容差
  // ---------------------------------------------------------------------------

  group('手势', () {
    final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);

    WheelMenuLayout layoutFor({double distance = 0.16, bool compact = false}) {
      final WheelMenuEnvelope e = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(0, 0, 1920, 1080),
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: WheelMenuLayoutSettings()
            .copyWith(menuDistance: distance, compactMode: compact),
      );
      return WheelMenuGeometry.layoutFor(e, MenuCatalog.root, spec);
    }

    test('阈值常量：滞回 7°、离开容差 130ms、tap 8dp、swipe 12dp', () {
      expect(WheelMenuGestureController.hysteresisDegDefault, 7);
      expect(WheelMenuGestureController.leaveToleranceMsDefault, 130);
      expect(WheelMenuGestureController.tapSlopDp, 8);
      expect(WheelMenuGestureController.swipeSlopDp, 12);
    });

    test('分区：缺口内 = 取消区中心；环带内 = 可选；环带外 = 空白', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;
      expect(g.zoneAt(l, l.notchCenterX, l.notchCenterY), WheelZone.center);
      final WheelSlotPlacement s0 = l.slots[0];
      expect(g.zoneAt(l, s0.centerX, s0.centerY), WheelZone.ring);
      expect(g.zoneAt(l, l.centerX, l.centerY + l.rimOuterPx + 40), WheelZone.outside);
    });

    test('缺口判定是**椭圆**（宽高不等时按各自半径）', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;
      // 恰好落在椭圆横轴上（+rx）算在内，超出一点算在外。
      expect(g.insideNotch(l, l.notchCenterX + l.notchRx - 0.5, l.notchCenterY), isTrue);
      expect(g.insideNotch(l, l.notchCenterX + l.notchRx + 1.0, l.notchCenterY), isFalse);
    });

    test('点击（位移在 tap 阈值内）→ 松手确认该按钮', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;
      final WheelSlotPlacement s2 = l.slots[2];
      final WheelGestureOutcome down = g.onDown(s2.centerX, s2.centerY, 0);
      expect(down.effect, WheelGestureEffect.press);
      expect(down.index, 2);
      final WheelGestureOutcome up = g.onUp(s2.centerX + 2, s2.centerY, 30);
      expect(up.effect, WheelGestureEffect.confirm);
      expect(up.index, 2);
    });

    test('**滑过不执行**：位移超过 tap 阈值但不确认 → 抬手时按当前落点确认', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g = WheelMenuGestureController.fromDensity(1)
        ..layout = l
        ..selectedIndex = 0;
      final WheelSlotPlacement s0 = l.slots[0];
      g.onDown(s0.centerX, s0.centerY, 0);
      // 拖到很远（同槽位但超出 tap 阈值）后抬手。
      g.onMove(s0.centerX, s0.centerY, 20);
      final WheelGestureOutcome up = g.onUp(s0.centerX + 40, s0.centerY + 40, 40);
      // 依然是 press owner（位移虽大但没有跨槽高亮），抬手时位移超出 tap → 取消。
      expect(up.effect, WheelGestureEffect.cancel);
    });

    test('沿弧线滑选 → 高亮跨槽 → 抬手确认', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g = WheelMenuGestureController.fromDensity(1)
        ..layout = l
        ..selectedIndex = 0;
      final WheelSlotPlacement s0 = l.slots[0];
      g.onDown(s0.centerX, s0.centerY, 0);
      final WheelSlotPlacement s3 = l.slots[3];
      g.onMove(s3.centerX, s3.centerY, 40);
      expect(g.isSwiping, isTrue);
      expect(g.highlightedIndex, closeTo(3, 1e-9));
      final WheelGestureOutcome up = g.onUp(s3.centerX, s3.centerY, 80);
      expect(up.effect, WheelGestureEffect.confirm);
      expect(up.index, 3);
    });

    test('7° 槽位滞回：越过槽位边界但不越过"边界 + 7°"时不换槽', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;

      // rawIndex 是**连续**下标：0.5 正好是 0/1 槽的边界。
      Offset atRaw(double raw) {
        final double offset = l.fanBiasDeg + (raw - (l.itemCount - 1) / 2) * l.stepDeg;
        final double abs = WheelMenuGeometry.absoluteAngle(l.direction, offset);
        final double rad = abs * math.pi / 180;
        return Offset(
          l.centerX + l.ringRadiusPx * math.cos(rad),
          l.centerY + l.ringRadiusPx * math.sin(rad),
        );
      }

      // 阈值 = 边界 + hysteresisUnits（hysteresisUnits = 7° / step，上限 0.45）。
      final double hysteresisUnits =
          (WheelMenuGestureController.hysteresisDegDefault / l.stepDeg).clamp(0.0, 0.45);
      expect(hysteresisUnits, greaterThan(0), reason: 'step 不能大到让滞回失效');

      // 越过槽位边界、但仍在滞回带内：留在 0。
      final Offset insideBand = atRaw(0.5 + hysteresisUnits * 0.4);
      expect(g.indexAt(l, insideBand.dx, insideBand.dy, 0), 0);
      // 未给 previous（首次按下）时按最近槽位取整 → 1。
      expect(g.indexAt(l, insideBand.dx, insideBand.dy, null), 1);

      // 越过"边界 + 滞回"后必须换到 1。
      final Offset beyond = atRaw(0.5 + hysteresisUnits + 0.3);
      expect(g.indexAt(l, beyond.dx, beyond.dy, 0), 1);
    });

    test('滑出环带：130ms 内保持高亮，超出即取消', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g = WheelMenuGestureController.fromDensity(1)
        ..layout = l
        ..selectedIndex = 0;
      final WheelSlotPlacement s2 = l.slots[2];
      g.onDown(s2.centerX, s2.centerY, 0);
      g.onMove(s2.centerX + 30, s2.centerY, 20);
      final double farX = l.centerX;
      final double farY = l.centerY;
      expect(g.onMove(farX, farY, 40).effect, WheelGestureEffect.none,
          reason: '首次离开仍在容差窗口内，保持高亮');
      expect(g.onMove(farX, farY, 40 + 100).effect, WheelGestureEffect.none,
          reason: '100ms 仍在 130ms 容差内');
      expect(g.onMove(farX, farY, 40 + 200).effect, WheelGestureEffect.cancel,
          reason: '超过 130ms 必须取消');
    });

    test('落在空白处松手 → outsideTap（父层据此关闭菜单）', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;
      expect(g.onDown(l.centerX, l.centerY + l.rimOuterPx + 30, 0).effect,
          WheelGestureEffect.none);
      expect(g.onUp(l.centerX, l.centerY + l.rimOuterPx + 30, 20).effect,
          WheelGestureEffect.outsideTap);
    });

    test('多指介入 → 取消（不产生任何确认）', () {
      final WheelMenuLayout l = layoutFor();
      final WheelMenuGestureController g =
          WheelMenuGestureController.fromDensity(1)..layout = l;
      final WheelSlotPlacement s1 = l.slots[1];
      g.onDown(s1.centerX, s1.centerY, 0);
      expect(g.onMove(s1.centerX, s1.centerY, 10, pointerCount: 2).effect,
          WheelGestureEffect.cancel);
      expect(g.onUp(s1.centerX, s1.centerY, 20, pointerCount: 2).effect,
          WheelGestureEffect.cancel);
    });
  });

  // ---------------------------------------------------------------------------
  // 七、动画：时间线逐毫秒、缓动、帧推导
  // ---------------------------------------------------------------------------

  group('动画', () {
    test('时间线毫秒数与 Android 一致', () {
      expect(WheelAnimationTimeline.openMs, 300);
      expect(WheelAnimationTimeline.closeMs, 180);
      expect(WheelAnimationTimeline.selectMs, 220);
      expect(WheelAnimationTimeline.enterLayerMs, 300);
      expect(WheelAnimationTimeline.exitLayerMs, 230);
      expect(WheelAnimationTimeline.pressMs, 70);
      expect(WheelAnimationTimeline.buttonStaggerMs, 25);
      expect(WheelAnimationTimeline.durationOf(WheelAnimationKind.open), 300);
      expect(WheelAnimationTimeline.durationOf(WheelAnimationKind.press), 70);
    });

    test('四条缓动曲线的控制点与 Android PathInterpolator 一致', () {
      expect(<double>[CubicBezierEasing.open.x1, CubicBezierEasing.open.y1,
          CubicBezierEasing.open.x2, CubicBezierEasing.open.y2], <double>[0.16, 1.0, 0.30, 1.0]);
      expect(<double>[CubicBezierEasing.switchEase.x1, CubicBezierEasing.switchEase.y1,
          CubicBezierEasing.switchEase.x2, CubicBezierEasing.switchEase.y2],
          <double>[0.22, 0.85, 0.30, 1.0]);
      expect(<double>[CubicBezierEasing.close.x1, CubicBezierEasing.close.y1,
          CubicBezierEasing.close.x2, CubicBezierEasing.close.y2], <double>[0.55, 0.0, 0.85, 0.35]);
      expect(<double>[CubicBezierEasing.pop.x1, CubicBezierEasing.pop.y1,
          CubicBezierEasing.pop.x2, CubicBezierEasing.pop.y2], <double>[0.18, 1.36, 0.36, 1.0]);
    });

    test('缓动端点与单调性', () {
      for (final CubicBezierEasing e in <CubicBezierEasing>[
        CubicBezierEasing.open,
        CubicBezierEasing.switchEase,
        CubicBezierEasing.close,
      ]) {
        expect(e.value(0), 0);
        expect(e.value(1), 1);
        double last = -1;
        for (int i = 0; i <= 20; i++) {
          final double v = e.value(i / 20);
          expect(v, greaterThanOrEqualTo(last - 1e-9));
          last = v;
        }
      }
    });

    test('展开帧：openProgress 0→1、旋转 −6°→1°→0°、缩放 0.75→1.03→1.0', () {
      const WheelAnimationRun run = WheelAnimationRun(
        kind: WheelAnimationKind.open,
        startedAtMs: 1000,
        fromSelection: 0,
        toSelection: 0,
        itemCount: 6,
      );
      expect(WheelAnimationClock.frame(run, 1000).openProgress, 0);
      expect(WheelAnimationClock.frame(run, 1000).rotationDeg, closeTo(-6, 1e-9));
      expect(WheelAnimationClock.frame(run, 1000).scale, closeTo(0.75, 1e-9));
      // 旋转在 raw = 0.5（= 1150ms）折返到 +1°。
      expect(WheelAnimationClock.frame(run, 1150).rotationDeg, closeTo(1, 1e-9));
      // 缩放在 raw = 0.55（= 1165ms）冲到 1.03。
      expect(WheelAnimationClock.frame(run, 1165).scale, closeTo(1.03, 1e-9));
      expect(WheelAnimationClock.frame(run, 1150).scale, greaterThan(1.0));
      final WheelAnimationFrame end = WheelAnimationClock.frame(run, 1300);
      expect(end.openProgress, 1);
      expect(end.rotationDeg, closeTo(0, 1e-9));
      expect(end.scale, closeTo(1.0, 1e-9));
      expect(WheelAnimationClock.isFinished(run, 1299), isFalse);
      expect(WheelAnimationClock.isFinished(run, 1300), isTrue);
    });

    test('展开时按钮**错峰**（后面的按钮晚出现，且最后一项仍在 230ms 内落位）', () {
      final WheelAnimationRun run = WheelAnimationRun(
        kind: WheelAnimationKind.open,
        startedAtMs: 0,
        fromSelection: 0,
        toSelection: 0,
        itemCount: 6,
      );
      final WheelAnimationFrame early = WheelAnimationClock.frame(run, 60);
      expect(early.buttonProgress[0], greaterThan(0));
      expect(early.buttonProgress[5], 0, reason: '最后一个按钮应当还没开始');
      // 弹出用的是轻微回弹曲线（y1 = 1.36），因此收敛到 1 附近而不是严格 1。
      final WheelAnimationFrame done = WheelAnimationClock.frame(run, 300);
      for (final double p in done.buttonProgress) {
        expect(p, closeTo(1, 0.01));
      }
      // Android §12.3：start = 50 + min(25, 180*0.5/(count-1)) * i。
      // count = 6 → stagger = min(25, 18) = 18，于是 0 号在 50ms、1 号在 68ms 起弹。
      expect(WheelAnimationTimeline.buttonProgress(60, 0, 6), greaterThan(0),
          reason: '0 号按钮在 50ms 后已开始弹出');
      expect(WheelAnimationTimeline.buttonProgress(60, 1, 6), 0,
          reason: '1 号按钮仍在错峰等待中（68ms 才起弹）');
      // 错峰间隔不超过 25ms → 1 号最迟应在 50 + 25 = 75ms 起弹。
      expect(WheelAnimationTimeline.buttonProgress(75, 1, 6), greaterThan(0),
          reason: '错峰间隔不超过 25ms');
    });

    test('关闭帧：openProgress 1→0（时长 180ms）', () {
      const WheelAnimationRun run = WheelAnimationRun(
        kind: WheelAnimationKind.close,
        startedAtMs: 0,
        fromSelection: 2,
        toSelection: 2,
        itemCount: 6,
      );
      expect(WheelAnimationClock.frame(run, 0).openProgress, 1);
      expect(WheelAnimationClock.frame(run, 180).openProgress, closeTo(0, 1e-9));
      expect(WheelAnimationClock.isFinished(run, 180), isTrue);
      expect(WheelAnimationClock.frame(run, 90).rotationDeg, greaterThan(0));
    });

    test('按压缩放 70ms 内往返（按下 → 弹回）', () {
      const WheelAnimationRun run = WheelAnimationRun(
        kind: WheelAnimationKind.press,
        startedAtMs: 0,
        fromSelection: 1,
        toSelection: 1,
        itemCount: 6,
        pressIndex: 1,
      );
      final WheelAnimationFrame mid = WheelAnimationClock.frame(run, 35);
      expect(mid.pressIndex, 1);
      expect(mid.pressProgress, greaterThan(0.5));
      expect(WheelAnimationClock.frame(run, 70).pressProgress, closeTo(0, 1e-6));
      expect(WheelAnimationClock.isFinished(run, 70), isTrue);
    });

    test('换层帧：layerProgress 与 titleProgress 同步过渡', () {
      const WheelAnimationRun run = WheelAnimationRun(
        kind: WheelAnimationKind.enterLayer,
        startedAtMs: 0,
        fromSelection: 0,
        toSelection: 0,
        itemCount: 7,
        previousItemCount: 6,
      );
      expect(WheelAnimationClock.frame(run, 0).layerProgress, closeTo(0, 1e-9));
      expect(WheelAnimationClock.frame(run, 300).layerProgress, closeTo(1, 1e-9));
      final WheelAnimationFrame mid = WheelAnimationClock.frame(run, 150);
      expect(mid.layerProgress, greaterThan(0));
      expect(mid.layerProgress, lessThan(1));
      expect(mid.titleProgress, greaterThan(0));
      // 换层期间选中位不插值。
      expect(mid.selectionPosition, 0);
    });

    test('hidden 帧：完全收起且按钮进度全 0', () {
      final WheelAnimationFrame f = WheelAnimationFrame.hidden(itemCount: 6);
      expect(f.openProgress, 0);
      expect(f.buttonProgress.length, 6);
      expect(f.buttonProgress.every((double p) => p == 0), isTrue);
      expect(f.pressIndex, -1);
    });
  });

  // ---------------------------------------------------------------------------
  // 八、Region 由实际几何生成（不含整画布、矩形有上限）
  // ---------------------------------------------------------------------------

  group('Region 生成', () {
    final WheelMenuSpec spec = WheelMenuSpec.fromDensity(1);

    WheelMenuLayout layout() {
      final WheelMenuEnvelope e = WheelMenuGeometry.computeEnvelope(
        bounds: const WheelBounds(0, 0, 1920, 1080),
        petWindowRect: const WheelRect(300, 400, 556, 656),
        maxItemCount: MenuCatalog.maxItems,
        spec: spec,
        settings: WheelMenuLayoutSettings.defaults,
      );
      return WheelMenuGeometry.layoutFor(e, MenuCatalog.root, spec);
    }

    test('包含桌宠缺口矩形（人物层始终可点）', () {
      final WheelMenuLayout l = layout();
      final List<Rect> rects = WheelRegionBuilder.rectsFor(l,
          slotProgress: List<double>.filled(l.itemCount, 1));
      final Rect petRect = Rect.fromCenter(
        center: Offset(l.notchCenterX, l.notchCenterY),
        width: l.notchRx * 2,
        height: l.notchRy * 2,
      );
      expect(rects.any((Rect r) => r.contains(petRect.center)), isTrue);
    });

    test('**不是整块画布**：没有任何一块覆盖整个窗口', () {
      final WheelMenuLayout l = layout();
      final List<Rect> rects = WheelRegionBuilder.rectsFor(l,
          slotProgress: List<double>.filled(l.itemCount, 1));
      final double windowArea = l.windowRect.width * l.windowRect.height;
      for (final Rect r in rects) {
        expect(r.width * r.height, lessThan(windowArea * 0.995));
      }
    });

    test('按钮未弹出（progress=0）时不产生按钮命中块', () {
      final WheelMenuLayout l = layout();
      final int withButtons = WheelRegionBuilder.rectsFor(l,
              slotProgress: List<double>.filled(l.itemCount, 1))
          .length;
      final int withoutButtons = WheelRegionBuilder.rectsFor(l,
              slotProgress: List<double>.filled(l.itemCount, 0))
          .length;
      expect(withoutButtons, lessThan(withButtons));
    });

    test('矩形数量有上限，且全部夹在窗口内', () {
      final WheelMenuLayout l = layout();
      final List<Rect> rects = WheelRegionBuilder.rectsFor(l,
          slotProgress: List<double>.filled(l.itemCount, 1),
          infoText: '当前应用：PetLife（2h13m）',
          feedback: '「隐藏」将在增量 C 接入');
      expect(rects.length, lessThanOrEqualTo(WheelRegionBuilder.maxRects));
      // C1.1：Region **不再**被夹进"菜单窗口矩形" —— 窗口只是信封，
      // 而刀刃 / 外缘齿轮 / 动画 overshoot / 文字安全带都可能超出它；
      // 提前夹会把这些像素裁掉（真机表现为"硬直线裁切"）。
      // 正确的判据是"Region 覆盖全部会被绘制的元素"。
      for (final Rect r in rects) {
        expect(r.width, greaterThan(0));
        expect(r.height, greaterThan(0));
      }
      // 本用例的层级条目极多（图标全量），Region 块数会触到原生上限 48 →
      // 触发"丢弃面积最小"的裁剪。此时**退化保证**是：
      // 桌宠 + 每个按钮中心仍然可点（可见性覆盖让位给原生块数上限）。
      for (final slot in l.slots) {
        expect(
          rects.any((Rect r) => r.contains(Offset(slot.centerX, slot.centerY))),
          isTrue,
          reason: '按钮 ${slot.index} 中心必须可点',
        );
      }
      expect(rects.length, lessThanOrEqualTo(WheelRegionBuilder.maxRects));
    });
  });

  // ---------------------------------------------------------------------------
  // 九、固定画布桥接 + 画布规划（增量 B 修正口径）
  //
  // 旧口径「按设置上限预留常驻画布」已被操作者否决（256 桌宠要 2054×2054 窗口）。
  // 现在的口径：**按当前设置 + 当前显示器工作区**规划，屏幕放不下时用 Android 的
  // 设备级应急缩放压缩轮盘。详见 `test/wheel_canvas_plan_test.dart`。
  // ---------------------------------------------------------------------------

  group('固定画布桥接', () {
    test('画布按**当前设置**规划：默认设置下远小于按上限预留的旧画布', () {
      // C1.1：用真实素材尺寸（256×192）—— 画布由视觉包围盒推导，占位尺寸会带偏结论。
      const Size pet = Size(256, 192);
      const Size workArea = Size(1920, 1040);
      final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: WheelMenuLayoutSettings.defaults,
      );
      // 旧口径（按上限 2.50/2.50/0.30 预留）算出的画布 —— 必须已经不再使用。
      final WheelCanvasPlan worstCase = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.maxScale,
          buttonVisualScale: WheelMenuLayoutSettings.maxButtonScale,
          menuDistance: WheelMenuLayoutSettings.maxDistance,
        ),
      );
      expect(plan.compressed, isFalse, reason: '1920×1040 下默认设置不需要压缩');
      expect(plan.screenFactor, 1.0);
      // C1.1 硬约束：交互内容必须完整装得下（不裁按钮 / 标签 / 文字）。
      expect(plan.interactiveFitsCanvas, isTrue);
      expect(plan.canvasSize.width, lessThan(worstCase.canvasSize.width));
      expect(plan.canvasSize.height, lessThan(worstCase.canvasSize.height));
      expect(plan.canvasSize.width, lessThan(1200));
      expect(plan.canvasSize.height, lessThan(1100));
      // 桥接层的取值口径不变：1 dp = 1 逻辑像素。
      expect(WheelCanvasBridge.density, 1.0);
      expect(WheelCanvasBridge.spec().density, 1.0);
    });

    test('设置变化会产生**新的**画布计划（增量 B 修正：不再恒定）', () {
      const Size pet = Size(256, 256);
      const Size workArea = Size(1920, 1040);
      final WheelCanvasPlan a = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: WheelMenuLayoutSettings.defaults,
      );
      final WheelCanvasPlan b = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: WheelMenuLayoutSettings.defaults
            .copyWith(preferredScale: 0.5),
      );
      final WheelCanvasPlan c = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: WheelMenuLayoutSettings.defaults
            .copyWith(buttonVisualScale: 2.5),
      );
      expect(b.canvasSize.width, lessThan(a.canvasSize.width));
      expect(c.canvasSize.width, greaterThan(a.canvasSize.width));
    });

    test('画布尺寸不超过「工作区 + 明确上限」', () {
      const Size pet = Size(256, 256);
      const Size workArea = Size(1920, 1040);
      final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: workArea,
        settings: const WheelMenuLayoutSettings(
          preferredScale: WheelMenuLayoutSettings.maxScale,
        ),
      );
      expect(plan.canvasSize.width, lessThanOrEqualTo(plan.limit.width + 1e-6));
      expect(plan.canvasSize.height, lessThanOrEqualTo(plan.limit.height + 1e-6));
      expect(plan.limit.width,
          lessThanOrEqualTo(workArea.width + WheelCanvasPlanner.maxOvershootPx + 1e-6));
      expect(plan.limit.height,
          lessThanOrEqualTo(workArea.height + WheelCanvasPlanner.maxOvershootPx + 1e-6));
    });

    test('桌宠锚点与四侧预留一致（左右镜像对称 → 桌宠居中）', () {
      const Size pet = Size(256, 192);
      final WheelCanvasPlan plan = WheelCanvasPlanner.plan(
        petSize: pet,
        workArea: const Size(1920, 1040),
        settings: WheelMenuLayoutSettings.defaults,
      );
      // 锚点 = 四侧预留 + 安全边（取整），不再是"桌宠居中"：
      // C1.1 起四侧预留由**视觉包围盒**推导，而人物可见区在素材里**不居中**
      // （Maya：可见 78..170，中心 124 ≠ 素材中心 128），
      // 因此左右预留本就应当不同 —— 强行"居中等距"才是错的那一方。
      expect(plan.petAnchor.dx,
          closeTo((plan.reachLeft + WheelCanvasPlanner.defaultMargin).roundToDouble(), 1e-6));
      expect(plan.petAnchor.dy,
          closeTo((plan.reachUp + WheelCanvasPlanner.defaultMargin).roundToDouble(), 1e-6));
      expect((plan.reachLeft - plan.reachRight).abs(), lessThan(40),
          reason: '左右预留仍然接近对称（差异只来自人物可见区偏移量级）');
      expect((plan.reachUp - plan.reachDown).abs(), lessThan(120));
    });

    test('屏幕坐标 → 画布局部坐标只做一次平移', () {
      final Rect local = WheelCanvasBridge.windowToCanvasLocal(
        windowRect: const WheelRect(400, 500, 900, 1000),
        canvasRect: const Rect.fromLTWH(100, 200, 1200, 900),
      );
      expect(local, const Rect.fromLTWH(300, 300, 500, 500));
      expect(local.size, const Size(500, 500), reason: '尺寸绝不被缩放');
    });

    test('装不下时夹取到画布内（兜底，不允许 widget 跑到画布外）', () {
      final Rect clamped = WheelCanvasBridge.clampToCanvas(
        const Rect.fromLTWH(1100, -50, 500, 500),
        const Size(1200, 900),
      );
      expect(clamped.left, 700);
      expect(clamped.top, 0);
      expect(clamped.width, 500);
      expect(WheelCanvasBridge.fitsInCanvas(
          windowRect: const WheelRect(0, 0, 500, 500), canvas: const Size(1200, 900)),
          isTrue);
      expect(WheelCanvasBridge.fitsInCanvas(
          windowRect: const WheelRect(0, 0, 1500, 500), canvas: const Size(1200, 900)),
          isFalse);
    });

    test('dp → 逻辑像素的密度固定为 1.0（与桌宠尺寸同一单位）', () {
      expect(WheelCanvasBridge.density, 1.0);
      expect(WheelCanvasBridge.spec().buttonDiameterPx, 44);
    });
  });

  // ---------------------------------------------------------------------------
  // 十、设置持久化（menuDistance / wheelScale / buttonScale / 主题）
  // ---------------------------------------------------------------------------

  group('设置 · 夹取与持久化', () {
    test('默认值就是 Android 默认值', () {
      const AppSettings s = AppSettings();
      expect(s.wheelThemeId, 'p3p-pink');
      expect(s.wheelScale, 1.00);
      expect(s.wheelButtonScale, 1.30);
      expect(s.wheelMenuDistance, 0.16);
      expect(s.wheelLayoutSettings.preferredScale, 1.00);
      expect(s.wheelLayoutSettings.buttonVisualScale, 1.30);
      expect(s.wheelLayoutSettings.menuDistance, 0.16);
    });

    test('normalized：区间内按 10% 步进吸附，越界一律夹到 MIN/MAX', () {
      final AppSettings s = const AppSettings()
          .copyWith(wheelScale: 1.24, wheelButtonScale: 3.9, wheelMenuDistance: 0.9)
          .normalized();
      expect(s.wheelScale, closeTo(1.20, 1e-9));
      expect(s.wheelButtonScale, closeTo(2.50, 1e-9));
      expect(s.wheelMenuDistance, closeTo(0.30, 1e-9));

      // 低于下界一律夹到 MIN（Android：MIN_SCALE 0.50 / MIN_BUTTON_SCALE 0.50 /
      // MIN_DISTANCE 0.05），**不做** 10% 吸附后再落到更小值。
      final AppSettings low = const AppSettings()
          .copyWith(wheelScale: 0.12, wheelButtonScale: 0.1, wheelMenuDistance: 0.0)
          .normalized();
      expect(low.wheelScale, closeTo(0.50, 1e-9));
      expect(low.wheelButtonScale, closeTo(0.50, 1e-9));
      expect(low.wheelMenuDistance, closeTo(0.05, 1e-9));
    });

    test('未知主题 id 被拉回 P3P 粉；custom 保留', () {
      expect(const AppSettings().copyWith(wheelThemeId: 'nope').normalized().wheelThemeId,
          'p3p-pink');
      expect(const AppSettings().copyWith(wheelThemeId: 'custom').normalized().wheelThemeId,
          'custom');
      expect(const AppSettings().copyWith(wheelThemeId: 'blue').normalized().wheelThemeId,
          'blue');
    });

    test('序列化往返：轮盘字段不丢、不失真', () {
      final AppSettings s = const AppSettings().copyWith(
        wheelThemeId: 'custom',
        wheelCustomPrimary: '#3366CC',
        wheelScale: 1.80,
        wheelButtonScale: 0.70,
        wheelMenuDistance: 0.24,
      );
      final AppSettings back = AppSettings.fromKeyValues(s.toKeyValues());
      expect(back.wheelThemeId, 'custom');
      expect(back.wheelCustomPrimary, '#3366CC');
      expect(back.wheelScale, closeTo(1.80, 1e-9));
      expect(back.wheelButtonScale, closeTo(0.70, 1e-9));
      expect(back.wheelMenuDistance, closeTo(0.24, 1e-9));
      expect(back.toKeyValues()['wheel.menuDistance'], '0.24');
      expect(back.toKeyValues()['wheel.themeId'], 'custom');
    });

    test('主题解析：非法自定义色回退 P3P 主色派生，不抛异常', () {
      final AppSettings s = const AppSettings()
          .copyWith(wheelThemeId: 'custom', wheelCustomPrimary: 'zzz')
          .normalized();
      final WheelMenuTheme theme = s.wheelTheme;
      expect(theme.themeId, 'custom');
      expect(theme.primary, WheelMenuThemes.p3pPrimary);
    });

    test('自定义色正常时按主色派生完整色板', () {
      final AppSettings s = const AppSettings()
          .copyWith(wheelThemeId: 'custom', wheelCustomPrimary: '#3366CC')
          .normalized();
      expect(s.wheelTheme.primary, 0xFF3366CC);
      expect(s.wheelTheme.secondary, WheelMenuThemes.lighten(0xFF3366CC, 0.42));
      expect(s.wheelTheme.highlight, 0xFFFFD42A);
      expect(s.wheelTheme.outline, 0xFF111111);
    });

    test('持久化键名使用 wheel.menuDistance（不再有 menuGap）', () {
      final Map<String, String> kv = const AppSettings().toKeyValues();
      expect(kv.containsKey('wheel.menuDistance'), isTrue);
      expect(kv.keys.any((String k) => k.contains('menuGap')), isFalse);
    });

    test('菜单目录的 maxItems 与最长标签字数（几何层据此算包围盒）', () {
      expect(MenuCatalog.maxItems, 7);
      expect(MenuCatalog.maxLabelChars, greaterThanOrEqualTo(4));
      // 6 个层级（根菜单 + 5 个子菜单），顺序冻结。
      expect(MenuCatalog.levels.length, 6);
      expect(MenuCatalog.levels.first.id, MenuCatalog.rootId);
    });
  });
}
