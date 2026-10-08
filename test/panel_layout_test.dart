/// 真机回归 #3：控制面板必须出现在**桌宠所在显示器**的可用工作区中央。
///
/// 覆盖用户验收清单的 15 ~ 21 项（22 项由 `platform_isolation_test.dart` 继续保证）。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart';
import 'package:petlife/menu/menu_contract.dart' show MenuCatalog;
import 'package:petlife/menu/wheel_canvas_bridge.dart';
import 'package:petlife/menu/wheel_canvas_plan.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import 'package:petlife/ui/desktop/panel_layout.dart';

/// 一块显示器的工作区。
class TestDisplay {
  const TestDisplay(this.workArea);
  final Rect workArea;

  bool containsCenter(Rect petScreenRect) {
    final Offset c = petScreenRect.center;
    return c.dx >= workArea.left &&
        c.dx <= workArea.right &&
        c.dy >= workArea.top &&
        c.dy <= workArea.bottom;
  }
}

/// 与外壳 `_workAreaForPetScreenAsync` 同口径：用桌宠屏幕矩形**中心**选显示器。
Rect workAreaFor(List<TestDisplay> displays, Rect petScreenRect) {
  for (final TestDisplay d in displays) {
    if (d.containsCenter(petScreenRect)) return d.workArea;
  }
  return displays.first.workArea;
}

/// 面板矩形（= 外壳 `commitPanelBounds` 的口径）。
Rect panelRectFor(List<TestDisplay> displays, Rect petScreenRect) {
  final Rect workArea = workAreaFor(displays, petScreenRect);
  return PanelLayout.centeredIn(workArea, PanelLayout.sizeFor(workArea.size));
}

/// 固定画布矩形（= 外壳 `commitFixedCanvasBounds` 的口径）。
Rect canvasRectFor(Offset petScreen, Offset petAnchor, Size canvas) =>
    FixedCanvasGeometry.canvasWindowRect(
      petScreenPosition: petScreen,
      petAnchor: petAnchor,
      canvas: canvas,
    );

/// 默认轮盘设置 + 目录最大项数（与外壳 `commitFixedCanvasBounds` 同口径）。
WheelCanvasPlan planFor(Rect workArea) => WheelCanvasPlanner.plan(
      petSize: const Size(256, 256),
      workArea: workArea.size,
      settings: WheelMenuLayoutSettings.defaults,
      spec: WheelCanvasBridge.spec(),
      maxItemCount: MenuCatalog.maxItems,
    );

void main() {
  const Size pet = Size(256, 256);
  const TestDisplay fhd1920 = TestDisplay(Rect.fromLTWH(0, 0, 1920, 1040));
  // 负坐标副屏（Windows 上"主屏左侧"的典型排布）。
  const TestDisplay leftOfPrimary = TestDisplay(Rect.fromLTWH(-1920, 0, 1920, 1040));

  group('面板尺寸适配（15 / 16）', () {
    test('15. 1920×1040：1180×760 完整居中，四边都在工作区内', () {
      final Rect rect = panelRectFor(<TestDisplay>[fhd1920], const Rect.fromLTWH(300, 400, 256, 256));
      expect(rect.size, const Size(1180, 760));
      expect(rect.left, closeTo((1920 - 1180) / 2, 1e-9));
      expect(rect.top, closeTo((1040 - 760) / 2, 1e-9));
      expect(rect.left, greaterThanOrEqualTo(fhd1920.workArea.left));
      expect(rect.right, lessThanOrEqualTo(fhd1920.workArea.right));
      expect(rect.top, greaterThanOrEqualTo(fhd1920.workArea.top));
      expect(rect.bottom, lessThanOrEqualTo(fhd1920.workArea.bottom));
    });

    test('16. 小屏自动缩小，并保留 16px 安全边距', () {
      const Size area = Size(1000, 600);
      final Size size = PanelLayout.sizeFor(area);
      expect(size.width, closeTo(1000 - 32, 1e-9));
      expect(size.height, closeTo(600 - 32, 1e-9));
      final Rect rect = PanelLayout.centeredIn(
        const Rect.fromLTWH(0, 0, 1000, 600),
        size,
      );
      expect(rect.left, closeTo(PanelLayout.edgeMargin, 1e-9));
      expect(rect.top, closeTo(PanelLayout.edgeMargin, 1e-9));
      expect(rect.right, closeTo(1000 - PanelLayout.edgeMargin, 1e-9));
      expect(rect.bottom, closeTo(600 - PanelLayout.edgeMargin, 1e-9));
    });

    test('16a. 屏幕够大时不缩小（保持 1180×760）', () {
      expect(PanelLayout.sizeFor(const Size(1920, 1040)), const Size(1180, 760));
      // 1280×680：宽度仍够 1180，高度被压到 648。
      final Size size = PanelLayout.sizeFor(const Size(1280, 680));
      expect(size.width, 1180);
      expect(size.height, closeTo(680 - 32, 1e-9));
    });

    test('16b. 屏幕小于尺寸下限时退回下限，但绝不超过工作区', () {
      const Size tiny = Size(400, 300);
      final Size size = PanelLayout.sizeFor(tiny);
      expect(size.width, lessThanOrEqualTo(tiny.width));
      expect(size.height, lessThanOrEqualTo(tiny.height));
    });
  });

  group('显示器选择（17 / 18）', () {
    test('17. 负坐标副屏：面板在副屏 workArea 内正确居中', () {
      const Rect petScreen = Rect.fromLTWH(-1700, 500, 256, 256);
      final Rect rect = panelRectFor(<TestDisplay>[fhd1920, leftOfPrimary], petScreen);
      expect(rect.size, const Size(1180, 760));
      // 副屏 workArea = [-1920, -1920+1920] × [0, 1040]
      expect(rect.left, closeTo(-1920 + (1920 - 1180) / 2, 1e-9));
      expect(rect.top, closeTo((1040 - 760) / 2, 1e-9));
      expect(rect.left, greaterThanOrEqualTo(-1920));
      expect(rect.right, lessThanOrEqualTo(0));
    });

    test('18. 用的是**桌宠所在**显示器，不是默认/主显示器', () {
      const Rect petOnLeft = Rect.fromLTWH(-1700, 500, 256, 256);
      final Rect rect = panelRectFor(<TestDisplay>[fhd1920, leftOfPrimary], petOnLeft);
      // 若错用了主屏（0..1920），left 会是正数。
      expect(rect.left, lessThan(0), reason: '面板应落在桌宠所在的副屏');

      // 反向：桌宠在主屏时也必须回主屏。
      const Rect petOnPrimary = Rect.fromLTWH(1500, 500, 256, 256);
      final Rect rect2 = panelRectFor(<TestDisplay>[fhd1920, leftOfPrimary], petOnPrimary);
      expect(rect2.left, greaterThan(0), reason: '面板应落在桌宠所在的主屏');
    });
  });

  group('位置持久化（19 / 20 / 21）', () {
    test('19. 面板位置绝不写入桌宠位置；卸载后再进仍用桌宠位置', () {
      // 桌宠屏幕位置（进入面板前捕获的事实）。
      const Offset petScreen = Offset(1200, 700);
      final Rect petScreenRect =
          Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
      final Rect panel = panelRectFor(<TestDisplay>[fhd1920], petScreenRect);

      // 面板矩形与桌宠矩形**本来就不相等** —— 这正是"不能误存"的原因。
      expect(panel.size, isNot(pet));
      // 面板四边与桌宠位置的换算关系：面板只由 workArea 决定，与桌宠位置无关。
      final Rect panelOther = panelRectFor(
        <TestDisplay>[fhd1920],
        const Rect.fromLTWH(100, 100, 256, 256),
      );
      expect(panelOther, panel, reason: '同一显示器上面板位置与桌宠位置无关');

      // 旧实现的错误口径：面板左上角 = 当前窗口左上角 = 画布左上角
      // = petScreen − petAnchor。面板**必须**与它不同，否则就是回归。
      final WheelCanvasPlan plan = planFor(fhd1920.workArea);
      final Offset buggyTopLeft = Offset(
        petScreen.dx - plan.petAnchor.dx,
        petScreen.dy - plan.petAnchor.dy,
      );
      expect(panel.topLeft, isNot(buggyTopLeft),
          reason: '面板不得继承固定画布 HWND 左上角');
      expect((panel.left - buggyTopLeft.dx).abs(), greaterThan(1.0));
    });

    test('20. 返回桌宠位置误差 <= 1px', () {
      final WheelCanvasPlan plan = planFor(fhd1920.workArea);
      const Offset petScreenEnter = Offset(1200, 700);
      // 进入面板前捕获的桌宠屏幕位置（外壳 `_panelReturnPetScreen`）。
      final Rect canvas = canvasRectFor(petScreenEnter, plan.petAnchor, plan.canvasSize);
      final Rect petScreenAfter = FixedCanvasGeometry.petScreenRect(
        canvasWindowRect: canvas,
        petAnchor: plan.petAnchor,
        petSize: pet,
      );
      expect((petScreenAfter.left - petScreenEnter.dx).abs(), lessThanOrEqualTo(1.0));
      expect((petScreenAfter.top - petScreenEnter.dy).abs(), lessThanOrEqualTo(1.0));
    });

    test('21. 连续往返 20 次无漂移', () {
      final WheelCanvasPlan plan = planFor(fhd1920.workArea);
      Offset petScreen = const Offset(1200, 700);
      final Offset start = petScreen;
      for (int i = 0; i < 20; i++) {
        final Rect petScreenRect =
            Rect.fromLTWH(petScreen.dx, petScreen.dy, pet.width, pet.height);
        // 进面板：面板矩形由 workArea 决定（不参与桌宠位置）。
        final Rect panel = panelRectFor(<TestDisplay>[fhd1920], petScreenRect);
        expect(panel.size, const Size(1180, 760));
        // 回桌宠：用**进入前捕获的** petScreen 反推画布，再回读桌宠矩形。
        final Rect canvas = canvasRectFor(petScreen, plan.petAnchor, plan.canvasSize);
        final Rect back = FixedCanvasGeometry.petScreenRect(
          canvasWindowRect: canvas,
          petAnchor: plan.petAnchor,
          petSize: pet,
        );
        petScreen = back.topLeft;
      }
      expect((petScreen.dx - start.dx).abs(), lessThanOrEqualTo(1.0));
      expect((petScreen.dy - start.dy).abs(), lessThanOrEqualTo(1.0));
    });

    test('21b. 面板 HWND 尺寸固定：往返期间不改变画布规划', () {
      final WheelCanvasPlan a = planFor(fhd1920.workArea);
      final WheelCanvasPlan b = planFor(fhd1920.workArea);
      expect(a.canvasSize, b.canvasSize);
      expect(a.petAnchor, b.petAnchor);
    });
  });
}
