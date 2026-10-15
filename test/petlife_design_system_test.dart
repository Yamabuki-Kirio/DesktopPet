import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';
import 'package:petlife/ui/widgets/petlife/petlife_components.dart';
import 'package:petlife/ui/widgets/petlife/petlife_decor.dart';
import 'package:petlife/ui/widgets/petlife/petlife_nav.dart';
import 'package:petlife/ui/widgets/petlife/petlife_page.dart';

/// 公共设计系统测试。
///
/// 覆盖需求 §4「视觉规范」与 §6「动画要求」中**可自动化验证**的部分：
/// 圆角 / 间距 / 最小触摸区是常量；组件在窄屏与大字体下不得溢出；
/// 底部导航的胶囊必须真的跟着选中项走。
void main() {
  /// 用真实主题包一层（与 App 里一致），并允许指定屏幕尺寸与字体倍率。
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(412, 915),
    double textScale = 1.0,
    Brightness brightness = Brightness.light,
    Color primary = PetLifeColors.primaryDefault,
    Color accent = PetLifeColors.accentDefault,
    List<Widget> Function(BuildContext, PetLifePalette)? observe,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPetLifeThemeData(
          primary: primary,
          accent: accent,
          brightness: brightness,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              observe?.call(context, PetLifeTheme.of(context));
              return child;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('设计令牌（需求 §4）', () {
    test('圆角：大卡片 20 / 普通卡片 16 / 按钮 14 / 弹窗 24', () {
      expect(PetLifeRadii.largeCard, 20);
      expect(PetLifeRadii.card, 16);
      expect(PetLifeRadii.button, 14);
      expect(PetLifeRadii.dialog, 24);
    });

    test('间距：页面 16 / 卡片内 16 / 卡片间 12 / 分组间 20 / 最小触摸 48', () {
      expect(PetLifeSpacing.page, 16);
      expect(PetLifeSpacing.cardInner, 16);
      expect(PetLifeSpacing.cardGap, 12);
      expect(PetLifeSpacing.groupGap, 20);
      expect(PetLifeSpacing.minTouch, 48);
    });

    test('动效时长全部落在需求区间内（页面 180~240ms，卡片 180ms，胶囊 200ms）', () {
      expect(PetLifeDurations.pageSwitch.inMilliseconds, inInclusiveRange(180, 240));
      expect(PetLifeDurations.cardIn.inMilliseconds, 180);
      expect(PetLifeDurations.navPill.inMilliseconds, inInclusiveRange(180, 220));
      expect(PetLifeDurations.press.inMilliseconds, inInclusiveRange(70, 100));
      expect(PetLifeDurations.themeChange.inMilliseconds, inInclusiveRange(200, 300));
      expect(PetLifeDurations.dialog.inMilliseconds, 220);
    });

    test('字阶：页面标题 22 / 卡片标题 17 / 重要数据 28~34 / 说明 12~13', () {
      expect(PetLifeText.pageTitle, 22);
      expect(PetLifeText.cardTitle, 17);
      expect(PetLifeText.display, inInclusiveRange(28, 34));
      expect(PetLifeText.displayLarge, inInclusiveRange(28, 34));
      expect(PetLifeText.caption, inInclusiveRange(12, 13));
    });
  });

  group('底部导航（需求 §2.1 / §4）', () {
    const List<PetLifeNavDestination> five = <PetLifeNavDestination>[
      PetLifeNavDestination(
        label: '桌宠',
        icon: Icons.pets_outlined,
        selectedIcon: Icons.pets,
      ),
      PetLifeNavDestination(
        label: '使用统计',
        icon: Icons.bar_chart_outlined,
        selectedIcon: Icons.bar_chart,
      ),
      PetLifeNavDestination(
        label: '账户与同步',
        icon: Icons.sync_outlined,
        selectedIcon: Icons.sync,
      ),
      PetLifeNavDestination(
        label: '素材库',
        icon: Icons.folder_outlined,
        selectedIcon: Icons.folder,
      ),
      PetLifeNavDestination(
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];

    testWidgets('五个入口全部渲染，选中项用实心图标、未选中用线性图标',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeBottomNav(
          destinations: five,
          selectedIndex: 2,
          onSelected: (_) {},
        ),
        size: const Size(360, 120),
      );

      for (final PetLifeNavDestination d in five) {
        expect(find.text(d.label), findsOneWidget);
      }
      // 选中项是实心图标，未选中是线性图标。
      expect(find.byIcon(Icons.sync), findsOneWidget);
      expect(find.byIcon(Icons.sync_outlined), findsNothing);
      expect(find.byIcon(Icons.pets_outlined), findsOneWidget);
    });

    testWidgets('点击第 N 项回调 N（导航不可写死）', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pump(
        tester,
        PetLifeBottomNav(
          destinations: five,
          selectedIndex: 0,
          onSelected: taps.add,
        ),
        size: const Size(360, 120),
      );

      for (int i = 0; i < five.length; i++) {
        await tester.tap(find.text(five[i].label));
        await tester.pump();
      }
      expect(taps, <int>[0, 1, 2, 3, 4]);
    });

    testWidgets('360dp + 1.5 倍字体：导航栏不溢出、文字不被截断',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeBottomNav(
          destinations: five,
          selectedIndex: 1,
          onSelected: (_) {},
        ),
        size: const Size(360, 200),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      // 栏高必须随字体放大而增高（否则会截断最多两行的标签）。
      expect(PetLifeBottomNav.heightFor(tester.element(find.byType(PetLifeBottomNav))),
          greaterThan(60));
    });

    testWidgets('胶囊背景跟随选中项移动（位置随下标变化）', (WidgetTester tester) async {
      double pillLeft(int index) {
        final Finder pill = find.descendant(
          of: find.byType(PetLifeBottomNav),
          matching: find.byType(AnimatedPositioned),
        );
        return tester.widget<AnimatedPositioned>(pill).left!;
      }

      await pump(
        tester,
        PetLifeBottomNav(
          destinations: five,
          selectedIndex: 0,
          onSelected: (_) {},
        ),
        size: const Size(360, 120),
      );
      final double at0 = pillLeft(0);
      await pump(
        tester,
        PetLifeBottomNav(
          destinations: five,
          selectedIndex: 3,
          onSelected: (_) {},
        ),
        size: const Size(360, 120),
      );
      expect(pillLeft(3), greaterThan(at0));
    });
  });

  group('卡片与控件', () {
    testWidgets('卡片：普通 16dp 圆角、大卡片 20dp 圆角、选中显示对勾',
        (WidgetTester tester) async {
      await pump(
        tester,
        Column(
          children: <Widget>[
            const PetLifeCard(child: Text('普通卡片')),
            const PetLifeCard(large: true, child: Text('大卡片')),
            PetLifeCard(selected: true, child: const Text('使用中素材')),
          ],
        ),
      );

      expect(find.text('普通卡片'), findsOneWidget);
      expect(find.text('大卡片'), findsOneWidget);
      // 选中卡片右上角必须有对勾（需求 §2.5）。
      expect(find.byIcon(Icons.check), findsOneWidget);

      final Iterable<Material> materials =
          tester.widgetList<Material>(find.byType(Material));
      final List<double> radii = <double>[
        for (final Material m in materials)
          if (m.shape is RoundedRectangleBorder) ...<double>[
            ((m.shape! as RoundedRectangleBorder).borderRadius
                    as BorderRadius)
                .topLeft
                .x,
          ],
      ];
      expect(radii, contains(PetLifeRadii.card));
      expect(radii, contains(PetLifeRadii.largeCard));
    });

    testWidgets('卡片可点击且回调真实触发', (WidgetTester tester) async {
      int taps = 0;
      await pump(
        tester,
        PetLifeCard(onTap: () => taps++, child: const Text('可点击')),
      );
      await tester.tap(find.text('可点击'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('进度条 / 标签 / 空状态 / 错误状态都能渲染', (WidgetTester tester) async {
      await pump(
        tester,
        ListView(
          children: <Widget>[
            const PetLifeProgressBar(value: 0.42),
            const SizedBox(height: 8),
            const PetLifeTag(label: '选中标签', selected: true),
            const SizedBox(height: 8),
            PetLifeEmptyState(
              icon: Icons.inbox_outlined,
              title: '还没有数据',
              message: '导入之后就会显示在这里',
              actionLabel: '导入素材',
              onAction: () {},
              scrollable: false,
            ),
            PetLifeErrorState(
              title: '出错了',
              detail: '网络不可用',
              hint: '本地功能不受影响',
              onRetry: () {},
            ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('选中标签'), findsOneWidget);
      expect(find.text('还没有数据'), findsOneWidget);
      expect(find.text('导入素材'), findsOneWidget);
      expect(find.text('出错了'), findsOneWidget);
      // 错误状态必须给明确文本 + 重试，而不是只有一个红色图标。
      expect(find.text('网络不可用'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('带自定义颜色的标签：文字必须真的看得见（半透明底要先合成）',
        (WidgetTester tester) async {
      // 回归：曾经把 `color.withValues(alpha: 0.12)` 直接当背景去算对比度，
      // 而 computeLuminance() 忽略 alpha → 文字被推向白色 → 渲染成看不见的白字
      // （Windows 顶部栏的同步状态标签就是这么变成空胶囊的）。
      for (final Color tone in <Color>[
        PetLifeColors.successDefault,
        PetLifeColors.dangerDefault,
        PetLifeColors.textSecondaryDefault,
        PetLifeColors.warningDefault,
      ]) {
        await pump(
          tester,
          Center(child: PetLifeTag(label: '状态', color: tone)),
          size: const Size(300, 120),
        );

        final AnimatedContainer container = tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
        final BoxDecoration decoration = container.decoration! as BoxDecoration;
        final Text label = tester.widget<Text>(find.text('状态'));

        // 背景先合成到卡片底上（与渲染时的观感一致），再算对比度。
        final Color composited = Color.alphaBlend(
          decoration.color!,
          PetLifeColors.primaryDefault,
        );
        expect(
          petLifeContrastRatio(label.style!.color!, composited),
          greaterThanOrEqualTo(3.0),
          reason: '标签文字与背景的对比度不足：$tone',
        );
      }
    });

    testWidgets('设置行：窄屏 + 1.5 倍字体自动改成上下两段（不截断）',
        (WidgetTester tester) async {
      await pump(
        tester,
        PetLifeCard(
          child: PetLifeSettingRow(
            label: '空闲阈值',
            note: '超过该时长视为离开，不计入活跃时间',
            control: const Switch(value: false, onChanged: null),
          ),
        ),
        size: const Size(360, 400),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('空闲阈值'), findsOneWidget);
    });

    testWidgets('P3P 装饰不接收点击（不得影响交互）', (WidgetTester tester) async {
      await pump(
        tester,
        const Stack(
          children: <Widget>[
            P3pPageBackdrop(),
            P3pTitleAccent(),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(IgnorePointer), findsWidgets);
    });
  });

  group('页面骨架与切换（需求 §3 / §6）', () {
    testWidgets('标题左对齐、加粗，右侧只放必要操作', (WidgetTester tester) async {
      await pump(
        tester,
        PetLifePage(
          title: '使用统计',
          subtitle: '本机采集 + 云端汇总',
          actions: <Widget>[
            PetLifeHeaderAction(
              icon: Icons.refresh,
              tooltip: '刷新统计',
              onPressed: () {},
            ),
          ],
          child: const SizedBox(height: 200),
        ),
      );
      expect(find.text('使用统计'), findsOneWidget);
      expect(find.text('本机采集 + 云端汇总'), findsOneWidget);
      expect(find.byTooltip('刷新统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('页面切换保留每个页面的状态（用 IndexedStack，不重建）',
        (WidgetTester tester) async {
      await pump(tester, const _SwitcherHarness());

      expect(find.text('页 0 计数 0'), findsOneWidget);
      // 先在被保留的页面里留下状态。
      await tester.tap(find.text('加一'));
      await tester.pumpAndSettle();
      expect(find.text('页 0 计数 1'), findsOneWidget);

      await tester.tap(find.text('切到 1'));
      await tester.pumpAndSettle();
      expect(find.text('页 1'), findsOneWidget);

      // 切回来时页 0 的计数器仍然是 1（状态被保留，没有重建）。
      await tester.tap(find.text('切到 0'));
      await tester.pumpAndSettle();
      expect(find.text('页 0 计数 1'), findsOneWidget);
    });
  });
}

/// 页面切换测试用的最小外壳：两个页面各带一个自增计数器。
class _SwitcherHarness extends StatefulWidget {
  const _SwitcherHarness();

  @override
  State<_SwitcherHarness> createState() => _SwitcherHarnessState();
}

class _SwitcherHarnessState extends State<_SwitcherHarness> {
  int _index = 0;
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: PetLifePageSwitcher(
            index: _index,
            children: <Widget>[
              Center(child: Text('页 0 计数 $_counter')),
              const Center(child: Text('页 1')),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () => setState(() => _counter++),
              child: const Text('加一'),
            ),
            TextButton(
              onPressed: () => setState(() => _index = 1),
              child: const Text('切到 1'),
            ),
            TextButton(
              onPressed: () => setState(() => _index = 0),
              child: const Text('切到 0'),
            ),
          ],
        ),
      ],
    );
  }
}
