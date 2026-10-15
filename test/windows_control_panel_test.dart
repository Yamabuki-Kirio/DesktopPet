import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/ui/desktop/control_panel_destinations.dart';
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';
import 'package:petlife/ui/widgets/petlife/petlife_desktop.dart';

/// Windows 控制面板的定向测试（需求 §13）。
///
/// 覆盖：七个导航入口、当前选中状态、页面切换状态保留、主色/强调色即时更新、
/// 1024×720 无溢出、125%/150% 缩放布局、桌面内容宽度约束。
///
/// 刻意**不**在 `flutter test` 里 pump 整个 `ControlPanel`：
/// 它会在 initState 里打开 SQLite、启动同步引擎与采集器，
/// 与 fake-async + "不得留下 pending Timer" 的契约冲突
/// （既有 `mobile_ui_test` 已写明同一取舍）。整壳联调放在真机/真桌面验收步骤里。
void main() {
  /// 桌面主题（与 app_shell.dart 的桌面分支一致）。
  ThemeData desktopTheme({
    Color primary = PetLifeColors.primaryDefault,
    Color accent = PetLifeColors.accentDefault,
  }) =>
      buildPetLifeThemeData(
        primary: primary,
        accent: accent,
        brightness: Brightness.light,
        fontFamily: 'Microsoft YaHei',
        cardEntranceAnimated: false,
      );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1280, 800),
    double devicePixelRatio = 1.0,
    double textScale = 1.0,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size * devicePixelRatio;
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? desktopTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('七个桌面导航入口（需求 §3）', () {
    test('恰好七个，顺序与标题符合需求', () {
      expect(kDesktopPanelDestinations, hasLength(7));
      expect(
        kDesktopPanelDestinations
            .map((PetLifeDesktopDestination d) => d.label)
            .toList(),
        kDesktopPanelTitles,
      );
      expect(kDesktopPanelTitles, <String>[
        '素材库',
        '状态映射',
        '状态调试器',
        '使用统计',
        '账户与同步',
        '设置',
        '诊断',
      ]);
    });

    test('每一项都有独立的线性 / 实心图标', () {
      for (final PetLifeDesktopDestination d in kDesktopPanelDestinations) {
        expect(d.icon, isNot(d.selectedIcon));
      }
    });

    testWidgets('宽窗口：左侧导航渲染全部七项，当前项用强调色胶囊',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopNavigationRail(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 3,
          onSelected: (_) {},
        ),
        size: const Size(1280, 800),
      );

      for (final String label in kDesktopPanelTitles) {
        expect(find.text(label), findsOneWidget);
      }
      // 选中项是实心图标，未选中是线性图标。
      expect(find.byIcon(Icons.insights), findsOneWidget);
      expect(find.byIcon(Icons.insights_outlined), findsNothing);
      expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);

      // 选中项的胶囊必须是强调色。
      final Iterable<AnimatedContainer> pills = tester
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
      final bool hasAccentPill = pills.any((AnimatedContainer c) {
        final Decoration? d = c.decoration;
        return d is BoxDecoration &&
            d.color == PetLifeColors.accentDefault &&
            d.borderRadius != null;
      });
      expect(hasAccentPill, isTrue, reason: '当前项没有强调色胶囊背景');
    });

    testWidgets('点击第 N 项回调 N', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pump(
        tester,
        PetLifeDesktopNavigationRail(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 0,
          onSelected: taps.add,
        ),
        size: const Size(1280, 800),
      );
      for (int i = 0; i < kDesktopPanelDestinations.length; i++) {
        await tester.tap(find.text(kDesktopPanelDestinations[i].label));
        await tester.pump();
      }
      expect(taps, <int>[0, 1, 2, 3, 4, 5, 6]);
    });

    testWidgets('仅图标模式：只有图标、没有文字，且宽度更窄',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopNavigationRail(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 1,
          onSelected: (_) {},
          compact: true,
        ),
        size: const Size(1000, 800),
      );
      for (final String label in kDesktopPanelTitles) {
        expect(find.text(label), findsNothing);
      }
      // 每个入口仍有 tooltip 兜底可读性。
      expect(find.byTooltip('素材库'), findsOneWidget);
      expect(
        tester.getSize(find.byType(PetLifeDesktopNavigationRail)).width,
        PetLifeDesktopBreakpoints.iconRailWidth,
      );
    });

    testWidgets('窄窗口：自动变成顶部紧凑导航（横向可滚动，不溢出）',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopTopNavigation(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 2,
          onSelected: (_) {},
        ),
        size: const Size(560, 200),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsWidgets);
      // 滚动容器里仍然有全部七项。
      for (final String label in kDesktopPanelTitles) {
        expect(find.text(label), findsOneWidget);
      }
    });
  });

  group('桌面外壳（需求 §3 结构图）', () {
    Widget scaffold({
      required int index,
      required ValueChanged<int> onSelected,
      List<Widget>? pages,
    }) =>
        PetLifeDesktopScaffold(
          destinations: kDesktopPanelDestinations,
          selectedIndex: index,
          onSelected: onSelected,
          pages: pages ??
              <Widget>[
                for (int i = 0; i < 7; i++) Center(child: Text('页 $i')),
              ],
          toolbar: const PetLifeDesktopToolbar(
            title: 'PetLife 控制面板',
            pageName: '使用统计',
          ),
        );

    testWidgets('结构：顶部栏 + 左侧导航 + 内容区', (WidgetTester tester) async {
      await pump(tester, scaffold(index: 0, onSelected: (_) {}));

      expect(find.text('PetLife 控制面板'), findsOneWidget);
      expect(find.byType(PetLifeDesktopNavigationRail), findsOneWidget);
      expect(find.byType(PetLifeDesktopTopNavigation), findsNothing);
      expect(find.text('页 0'), findsOneWidget);
    });

    testWidgets('宽度不足 900 时切换为顶部紧凑导航，导航栏消失',
        (WidgetTester tester) async {
      await pump(
        tester,
        scaffold(index: 0, onSelected: (_) {}),
        size: const Size(860, 720),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(PetLifeDesktopNavigationRail), findsNothing);
      expect(find.byType(PetLifeDesktopTopNavigation), findsOneWidget);
    });

    testWidgets('页面切换保留状态（IndexedStack，不重建）',
        (WidgetTester tester) async {
      int index = 0;
      await pump(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => Column(
            children: <Widget>[
              Expanded(
                child: PetLifeDesktopScaffold(
                  destinations: kDesktopPanelDestinations,
                  selectedIndex: index,
                  onSelected: (int i) => setState(() => index = i),
                  pages: <Widget>[
                    const _CounterPage(key: ValueKey<String>('p0')),
                    const Center(child: Text('页 1')),
                    for (int i = 2; i < 7; i++) Center(child: Text('页 $i')),
                  ],
                  toolbar: const PetLifeDesktopToolbar(title: 'PetLife 控制面板'),
                ),
              ),
            ],
          ),
        ),
      );

      // 在页 0 留下状态。
      await tester.tap(find.text('加一'));
      await tester.pumpAndSettle();
      expect(find.text('计数 1'), findsOneWidget);

      // 切到「状态映射」（下标 1），再切回「素材库」（下标 0）：
      // 计数器必须仍然是 1（页面没有被销毁重建）。
      await tester.tap(find.text('状态映射'));
      await tester.pumpAndSettle();
      expect(find.text('页 1'), findsOneWidget);
      await tester.tap(find.text('素材库'));
      await tester.pumpAndSettle();
      expect(find.text('计数 1'), findsOneWidget);
    });

    testWidgets('懒加载：未访问过的页面不会被构建（打开面板不拉起全部查询）',
        (WidgetTester tester) async {
      await pump(tester, scaffold(index: 0, onSelected: (_) {}));
      // 只有页 0 被构建过。
      expect(find.text('页 0'), findsOneWidget);
      expect(find.text('页 1'), findsNothing);
      expect(find.text('页 6'), findsNothing);
    });

    testWidgets('底部状态条可选显示', (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopScaffold(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 0,
          onSelected: (_) {},
          pages: <Widget>[for (int i = 0; i < 7; i++) Center(child: Text('页 $i'))],
          toolbar: const PetLifeDesktopToolbar(title: 'PetLife 控制面板'),
          footer: const SizedBox(height: 30, child: Center(child: Text('状态条'))),
        ),
      );
      expect(find.text('状态条'), findsOneWidget);
    });
  });

  group('顶部栏（需求 §4）', () {
    testWidgets('高度 56～64px，右侧动作可用，退出走危险色',
        (WidgetTester tester) async {
      int closed = 0;
      int exited = 0;
      await pump(
        tester,
        PetLifeDesktopToolbar(
          title: 'PetLife 控制面板',
          pageName: '设置',
          statusTag: const PetLifeTagStub(),
          actions: <Widget>[
            TextButton(
              onPressed: () => closed++,
              child: const Text('回到桌宠'),
            ),
            TextButton(
              onPressed: () => exited++,
              child: const Text('退出'),
            ),
          ],
        ),
        size: const Size(1280, 120),
      );

      final Size size = tester.getSize(find.byType(PetLifeDesktopToolbar));
      expect(size.height, inInclusiveRange(56, 64));
      expect(find.text('PetLife 控制面板'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      await tester.tap(find.text('回到桌宠'));
      await tester.tap(find.text('退出'));
      await tester.pump();
      expect(closed, 1);
      expect(exited, 1);
    });

    testWidgets('窄窗口逐步收起：页面名 / 状态标签 / 应用名依次隐藏，动作不溢出',
        (WidgetTester tester) async {
      for (final double width in <double>[1024, 760, 620, 520, 480]) {
        await pump(
          tester,
          PetLifeDesktopToolbar(
            title: 'PetLife 控制面板',
            pageName: '账户与同步',
            statusTag: const PetLifeTagStub(),
            actions: <Widget>[
              TextButton(onPressed: () {}, child: const Text('回到桌宠')),
              TextButton(onPressed: () {}, child: const Text('退出')),
            ],
          ),
          size: Size(width, 120),
        );
        expect(tester.takeException(), isNull, reason: '${width}px 下顶部栏溢出');
        // 动作按钮任何时候都必须在。
        expect(find.text('回到桌宠'), findsOneWidget);
        expect(find.text('退出'), findsOneWidget);
      }
    });

    testWidgets('标题栏拖拽通过回调注入（组件本身不认识 window_manager）',
        (WidgetTester tester) async {
      int drags = 0;
      await pump(
        tester,
        PetLifeDesktopToolbar(
          title: 'PetLife 控制面板',
          onTitleBarDrag: () => drags++,
        ),
        size: const Size(1280, 120),
      );
      await tester.drag(find.text('PetLife 控制面板'), const Offset(12, 0));
      await tester.pump();
      expect(drags, greaterThan(0));
    });
  });

  group('内容宽度约束（需求 §6：窗口放大后不无限拉伸）', () {
    testWidgets('1280 宽：内容占满可用宽度', (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopContentWidth(
          child: const SizedBox(key: ValueKey<String>('content'), height: 40),
        ),
        size: const Size(1280, 400),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('content'))).width,
        1280 - PetLifeSpacing.page * 2,
      );
    });

    testWidgets('2560 宽：内容被限制在 1440 并居中', (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopContentWidth(
          child: const SizedBox(key: ValueKey<String>('content'), height: 40),
        ),
        size: const Size(2560, 600),
      );
      final Rect rect =
          tester.getRect(find.byKey(const ValueKey<String>('content')));
      expect(rect.width, PetLifeDesktopBreakpoints.contentMaxWidth);
      // 居中：左右留白相等。
      expect(rect.left, closeTo(2560 - rect.right, 0.5));
    });

    testWidgets('设置页用更窄的内容宽度（960～1100）',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopContentWidth(
          maxWidth: PetLifeDesktopBreakpoints.settingsContentMaxWidth,
          child: const SizedBox(key: ValueKey<String>('content'), height: 40),
        ),
        size: const Size(2560, 600),
      );
      final double width =
          tester.getSize(find.byKey(const ValueKey<String>('content'))).width;
      expect(width, inInclusiveRange(960, 1100));
    });
  });

  group('窗口尺寸与缩放（需求 §10）', () {
    // 控制面板最小尺寸 960×640（PanelLayout 在 1024×720 工作区下给出 992×688）。
    for (final (String name, Size size) in <(String, Size)>[
      ('1024×720', Size(1024, 720)),
      ('1280×720', Size(1280, 720)),
      ('1366×768', Size(1366, 768)),
      ('1920×1080', Size(1920, 1080)),
      ('2560×1440', Size(2560, 1440)),
    ]) {
      testWidgets('$name：外壳无溢出', (WidgetTester tester) async {
        await pump(
          tester,
          PetLifeDesktopScaffold(
            destinations: kDesktopPanelDestinations,
            selectedIndex: 4,
            onSelected: (_) {},
            pages: <Widget>[
              for (int i = 0; i < 7; i++)
                PetLifeDesktopContentWidth(
                  child: ListView(
                    children: <Widget>[
                      for (int k = 0; k < 12; k++)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Card(
                            child: SizedBox(height: 90, child: Text('卡片')),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            toolbar: const PetLifeDesktopToolbar(
              title: 'PetLife 控制面板',
              pageName: '账户与同步',
              statusTag: PetLifeTagStub(),
            ),
            footer: const SizedBox(height: 30),
          ),
          size: size,
        );
        expect(tester.takeException(), isNull, reason: '$name 出现溢出');
        expect(find.text('PetLife 控制面板'), findsOneWidget);
      });
    }

    // Windows 缩放 100% / 125% / 150%：**物理像素固定 1024×720**，DPR 变化 →
    // 逻辑尺寸变小（这正是 Windows 缩放对 Flutter 的实际效果）。
    for (final double dpr in <double>[1.0, 1.25, 1.5]) {
      testWidgets('缩放 ${(dpr * 100).round()}%：1024×720 物理像素下无溢出',
          (WidgetTester tester) async {
        final double logicalWidth = 1024 / dpr;
        await pump(
          tester,
          PetLifeDesktopScaffold(
            destinations: kDesktopPanelDestinations,
            selectedIndex: 3,
            onSelected: (_) {},
            pages: <Widget>[
              for (int i = 0; i < 7; i++)
                PetLifeDesktopContentWidth(
                  child: ListView(
                    children: <Widget>[
                      for (int k = 0; k < 8; k++)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Card(child: SizedBox(height: 80)),
                        ),
                    ],
                  ),
                ),
            ],
            toolbar: const PetLifeDesktopToolbar(
              title: 'PetLife 控制面板',
              pageName: '使用统计',
            ),
          ),
          // 逻辑尺寸 = 物理 / DPR；pump 内部会还原成 1024×720 的物理像素。
          size: Size(logicalWidth, 720 / dpr),
          devicePixelRatio: dpr,
        );
        expect(tester.takeException(), isNull,
            reason: '缩放 ${(dpr * 100).round()}% 出现溢出');
        final bool expectRail =
            logicalWidth >= PetLifeDesktopBreakpoints.iconRail;
        expect(
          find.byType(PetLifeDesktopNavigationRail).evaluate().isNotEmpty,
          expectRail,
          reason: '缩放 ${(dpr * 100).round()}%（逻辑宽 '
              '${logicalWidth.toStringAsFixed(0)}px）的导航形态不对',
        );
      });
    }

    testWidgets('系统字体 1.5 倍：1024×720 无溢出', (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeDesktopScaffold(
          destinations: kDesktopPanelDestinations,
          selectedIndex: 0,
          onSelected: (_) {},
          pages: <Widget>[
            for (int i = 0; i < 7; i++)
              PetLifeDesktopContentWidth(
                child: ListView(
                  children: <Widget>[
                    for (int k = 0; k < 6; k++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Card(child: SizedBox(height: 120)),
                      ),
                  ],
                ),
              ),
          ],
          toolbar: const PetLifeDesktopToolbar(
            title: 'PetLife 控制面板',
            pageName: '使用统计',
            statusTag: PetLifeTagStub(),
          ),
        ),
        size: const Size(1024, 720),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('主色 / 强调色即时更新（需求 §5）', () {
    testWidgets('改强调色后，桌面导航当前项的胶囊颜色立即变化，不重启窗口',
        (WidgetTester tester) async {
      Future<Color?> pillColor(ThemeData theme) async {
        await pump(
          tester,
          PetLifeDesktopNavigationRail(
            destinations: kDesktopPanelDestinations,
            selectedIndex: 2,
            onSelected: (_) {},
          ),
          size: const Size(1280, 800),
          theme: theme,
        );
        for (final AnimatedContainer c
            in tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
          final Decoration? d = c.decoration;
          // 未选中项的背景是透明的，跳过；只取真正着色的那一颗胶囊。
          if (d is BoxDecoration &&
              d.borderRadius != null &&
              d.color != null &&
              d.color!.a > 0) {
            return d.color;
          }
        }
        return null;
      }

      final Color? before = await pillColor(desktopTheme());
      final Color? after = await pillColor(
        desktopTheme(accent: const Color(0xFF3B82F6)),
      );
      expect(before, PetLifeColors.accentDefault);
      expect(after, const Color(0xFF3B82F6));
    });

    testWidgets('改主色后，顶部栏与导航栏表面色立即变化',
        (WidgetTester tester) async {
      await pump(
        tester,
        const PetLifeDesktopToolbar(title: 'PetLife 控制面板'),
        size: const Size(1280, 120),
        theme: desktopTheme(primary: const Color(0xFFEEF4FF)),
      );
      final Material material = tester.widget<Material>(
        find.descendant(
          of: find.byType(PetLifeDesktopToolbar),
          matching: find.byType(Material),
        ).first,
      );
      expect(material.color, const Color(0xFFEEF4FF));
    });

    testWidgets('桌面主题关闭卡片进场动画（禁止逐卡片依次播放）',
        (WidgetTester tester) async {
      await pump(
        tester,
        const PetLifeDesktopContentWidth(
          child: Text('内容'),
        ),
        size: const Size(1280, 200),
      );
      final BuildContext ctx = tester.element(find.text('内容'));
      expect(PetLifeTheme.cardEntranceAnimatedOf(ctx), isFalse);
    });
  });
}

/// 极简占位（避免测试里依赖业务组件）。
class PetLifeTagStub extends StatelessWidget {
  const PetLifeTagStub({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(width: 40, height: 20);
}

class _CounterPage extends StatefulWidget {
  const _CounterPage({super.key});

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('计数 $_count'),
            TextButton(
              onPressed: () => setState(() => _count++),
              child: const Text('加一'),
            ),
          ],
        ),
      );
}
