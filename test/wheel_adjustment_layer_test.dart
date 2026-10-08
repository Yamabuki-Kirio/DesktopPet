/// **增量 C1**：轮盘内调整层 + 设置动作 + 唯一入口契约。
///
/// 覆盖需求 §11 的 2 / 3 / 4 / 5 / 8 / 9 与 §一 / §十三 B。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_adjustment_layer.dart';
import 'package:petlife/menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import 'package:petlife/menu/wheel_theme.dart' show WheelThemeIds;
import 'package:petlife/ui/overlay_menu_actions.dart' show MenuActionIds;

void main() {
  // ---------------------------------------------------------------------------
  group('2. 设置根项进入正确的调整层', () {
    test('四个设置入口都是 wheelAdjust 类别（不进业务执行器）', () {
      const Map<String, WheelAdjustmentKind> expected = <String, WheelAdjustmentKind>{
        'settings_theme': WheelAdjustmentKind.theme,
        'settings_wheel_size': WheelAdjustmentKind.wheelScale,
        'settings_button_size': WheelAdjustmentKind.buttonScale,
        WindowsOnlyActionIds.settingsMenuDistance: WheelAdjustmentKind.menuDistance,
      };
      for (final MapEntry<String, WheelAdjustmentKind> e in expected.entries) {
        final MenuActionDefinition? def = MenuActionDefinitions.of(e.key);
        expect(def, isNotNull, reason: '缺少定义 ${e.key}');
        expect(def!.kind, MenuActionKind.wheelAdjust, reason: e.key);
      }
    });

    test('settings_open 仍是 dartAction（真的打开控制面板）', () {
      expect(
        MenuActionDefinitions.of('settings_open')!.kind,
        MenuActionKind.dartAction,
      );
    });

    test('设置子菜单确实含 菜单距离 条目，且用共享 action ID', () {
      final MenuNode node = MenuCatalog.settings.nodes
          .firstWhere((MenuNode n) => n.id == 'settings_menu_distance');
      expect(node.actionId, 'settings_menu_distance');
      expect(node.actionId, WindowsOnlyActionIds.settingsMenuDistance);
      // 顺序：主题 → 轮盘大小 → 按钮大小 → 菜单距离 → 完整设置 → 返回
      expect(
        MenuCatalog.settings.nodes.map((MenuNode n) => n.id).toList(),
        <String>[
          'settings_theme',
          'settings_wheel_size',
          'settings_button_size',
          'settings_menu_distance',
          'settings_open',
          'back',
        ],
      );
    });

    test('新增 ID **不**破坏 Android 的 canonical 集合', () {
      // canonical 仍是 17 个（Android 逐字对账用）。
      expect(MenuActionIds.canonical.length, 17);
      expect(MenuActionIds.canonical.contains('settings_menu_distance'), isFalse);
      // 调整层入口里那三个 canonical id 仍在 canonical 集合里。
      for (final String id in <String>[
        'settings_theme',
        'settings_wheel_size',
        'settings_button_size',
      ]) {
        expect(MenuActionIds.canonical.contains(id), isTrue, reason: id);
      }
    });

    test('调整层条目固定 5 个且顺序固定', () {
      for (final WheelAdjustmentKind kind in WheelAdjustmentKind.values) {
        final MenuLevel level = WheelAdjustmentLayer.build(kind, kind.defaultValue);
        expect(level.id, kind.levelId);
        expect(level.nodes.length, 5);
        expect(
          level.nodes.map((MenuNode n) => n.actionId).toList(),
          <String>[
            WheelAdjustmentActionIds.decrease(kind),
            WheelAdjustmentActionIds.value(kind),
            WheelAdjustmentActionIds.increase(kind),
            WheelAdjustmentActionIds.reset(kind),
            MenuNavigationIds.back,
          ],
        );
      }
    });

    test('"当前值"条目显示的就是**当前值**（不是默认值）', () {
      final MenuLevel level =
          WheelAdjustmentLayer.build(WheelAdjustmentKind.wheelScale, 1.8);
      expect(level.nodes[1].labelZh, '180%');
      final MenuLevel d =
          WheelAdjustmentLayer.build(WheelAdjustmentKind.menuDistance, 0.24);
      expect(d.nodes[1].labelZh, '0.24');
      final MenuLevel t =
          WheelAdjustmentLayer.build(WheelAdjustmentKind.theme, 0);
      expect(t.nodes[1].labelZh, 'P3P 粉色');
    });

    test('levelId 能被反查（外壳据此判断"这是个调整层"）', () {
      for (final WheelAdjustmentKind kind in WheelAdjustmentKind.values) {
        expect(WheelAdjustmentKind.fromLevelId(kind.levelId), kind);
      }
      expect(WheelAdjustmentKind.fromLevelId('settings'), isNull);
      expect(WheelAdjustmentKind.fromLevelId(null), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('3 / 4 / 5. 加减、边界、默认值、量化', () {
    test('wheelScale：50~250%，步进 10%', () {
      expect(WheelAdjustmentKind.wheelScale.min, 0.50);
      expect(WheelAdjustmentKind.wheelScale.max, 2.50);
      expect(WheelAdjustmentKind.wheelScale.step, 0.10);
      expect(WheelAdjustmentKind.wheelScale.defaultValue, 1.00);

      double v = 1.00;
      v = WheelAdjustmentLayer.stepped(WheelAdjustmentKind.wheelScale, v, 1);
      expect(v, closeTo(1.10, 1e-9));
      v = WheelAdjustmentLayer.stepped(WheelAdjustmentKind.wheelScale, v, 1);
      expect(v, closeTo(1.20, 1e-9));
      v = WheelAdjustmentLayer.stepped(WheelAdjustmentKind.wheelScale, v, -1);
      expect(v, closeTo(1.10, 1e-9));

      // 边界：不再变化（调用方据此显示"已到最大"而不是假装成功）。
      expect(WheelAdjustmentLayer.stepped(WheelAdjustmentKind.wheelScale, 2.50, 1),
          closeTo(2.50, 1e-9));
      expect(WheelAdjustmentLayer.stepped(WheelAdjustmentKind.wheelScale, 0.50, -1),
          closeTo(0.50, 1e-9));
      expect(WheelAdjustmentLayer.atMax(WheelAdjustmentKind.wheelScale, 2.50), isTrue);
      expect(WheelAdjustmentLayer.atMin(WheelAdjustmentKind.wheelScale, 0.50), isTrue);
      expect(WheelAdjustmentLayer.isDefault(WheelAdjustmentKind.wheelScale, 1.0), isTrue);
    });

    test('buttonScale：50~250%，步进 10%，默认 130%', () {
      expect(WheelAdjustmentKind.buttonScale.min, 0.50);
      expect(WheelAdjustmentKind.buttonScale.max, 2.50);
      expect(WheelAdjustmentKind.buttonScale.step, 0.10);
      expect(WheelAdjustmentKind.buttonScale.defaultValue, 1.30);
      expect(
        WheelAdjustmentLayer.stepped(WheelAdjustmentKind.buttonScale, 1.30, 1),
        closeTo(1.40, 1e-9),
      );
      expect(WheelAdjustmentKind.buttonScale.formatValue(1.3), '130%');
    });

    test('menuDistance：0.05~0.30，步进 0.01，默认 0.16', () {
      expect(WheelAdjustmentKind.menuDistance.min, 0.05);
      expect(WheelAdjustmentKind.menuDistance.max, 0.30);
      // ⚠️ 必须是 0.01：默认值 0.16 与上限 0.30 都要落在网格上，
      //    否则"恢复默认""加到最大"都到不了（0.05+k×0.02 两者都不含）。
      expect(WheelAdjustmentKind.menuDistance.step, 0.01);
      expect(WheelAdjustmentKind.menuDistance.defaultValue, 0.16);

      expect(
        WheelAdjustmentLayer.stepped(WheelAdjustmentKind.menuDistance, 0.16, 1),
        closeTo(0.17, 1e-9),
      );
      expect(
        WheelAdjustmentLayer.stepped(WheelAdjustmentKind.menuDistance, 0.16, -1),
        closeTo(0.15, 1e-9),
      );
      // 边界按"最近步进"量化到 min/max，不会越界。
      expect(WheelAdjustmentLayer.stepped(WheelAdjustmentKind.menuDistance, 0.30, 1),
          closeTo(0.30, 1e-9));
      expect(WheelAdjustmentLayer.stepped(WheelAdjustmentKind.menuDistance, 0.05, -1),
          closeTo(0.05, 1e-9));
    });

    test('默认值与上下限**都可精确到达**（网格对齐，关键回归）', () {
      for (final WheelAdjustmentKind kind in <WheelAdjustmentKind>[
        WheelAdjustmentKind.wheelScale,
        WheelAdjustmentKind.buttonScale,
        WheelAdjustmentKind.menuDistance,
      ]) {
        // 量化默认值必须原样返回（否则"恢复默认"到不了默认值）。
        expect(WheelAdjustmentLayer.quantize(kind, kind.defaultValue),
            closeTo(kind.defaultValue, 1e-9), reason: '${kind.id} 默认值不在网格上');
        // 两个端点也必须在网格上。
        expect(WheelAdjustmentLayer.quantize(kind, kind.min), closeTo(kind.min, 1e-9),
            reason: '${kind.id} 下限不在网格上');
        expect(WheelAdjustmentLayer.quantize(kind, kind.max), closeTo(kind.max, 1e-9),
            reason: '${kind.id} 上限不在网格上');
        expect(WheelAdjustmentLayer.isDefault(kind, kind.defaultValue), isTrue,
            reason: kind.id);
      }
    });

    test('量化用"最近步进"，不产生浮点尾巴', () {
      expect(WheelAdjustmentLayer.quantize(WheelAdjustmentKind.menuDistance, 0.173),
          closeTo(0.17, 1e-9));
      expect(WheelAdjustmentLayer.quantize(WheelAdjustmentKind.wheelScale, 0.94),
          closeTo(0.90, 1e-9));
      // 越界即夹取。
      expect(WheelAdjustmentLayer.quantize(WheelAdjustmentKind.wheelScale, 9.9),
          closeTo(2.50, 1e-9));
      expect(WheelAdjustmentLayer.quantize(WheelAdjustmentKind.wheelScale, -3),
          closeTo(0.50, 1e-9));
    });

    test('比例指示与格式化（供 UI 画条形 / 文案）', () {
      expect(WheelAdjustmentLayer.asPercent(0.5), 50);
      expect(WheelAdjustmentLayer.ratioOf(WheelAdjustmentKind.wheelScale, 0.50), 0);
      expect(WheelAdjustmentLayer.ratioOf(WheelAdjustmentKind.wheelScale, 2.50), 1);
      expect(WheelAdjustmentLayer.ratioOf(WheelAdjustmentKind.wheelScale, 1.50),
          closeTo(0.5, 1e-9));
    });

    test('六个主题与 Android 同款，默认 P3P 粉色，且**不建第二套 id**', () {
      expect(WheelAdjustmentLayer.themeIds(), <String>[
        WheelThemeIds.p3pPink,
        WheelThemeIds.blue,
        WheelThemeIds.red,
        WheelThemeIds.purple,
        WheelThemeIds.green,
        WheelThemeIds.custom,
      ]);
      expect(WheelAdjustmentLayer.themeIds().first, WheelThemeIds.p3pPink);
    });

    test('主题上下切换在离散列表里循环', () {
      expect(
        WheelAdjustmentLayer.nextThemeId(WheelThemeIds.p3pPink, 1),
        WheelThemeIds.blue,
      );
      expect(
        WheelAdjustmentLayer.nextThemeId(WheelThemeIds.custom, 1),
        WheelThemeIds.p3pPink,
        reason: '末尾的下一个回到开头',
      );
      expect(
        WheelAdjustmentLayer.nextThemeId(WheelThemeIds.p3pPink, -1),
        WheelThemeIds.custom,
        reason: '开头的上一个回到末尾（Dart 的 % 对负数返回非负）',
      );
    });

    test('动作 id 可反解成 (kind, verb)', () {
      final ({WheelAdjustmentKind kind, WheelAdjustmentVerb verb})? up =
          WheelAdjustmentActionIds.parse(
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.buttonScale),
      );
      expect(up!.kind, WheelAdjustmentKind.buttonScale);
      expect(up.verb, WheelAdjustmentVerb.increase);

      expect(
        WheelAdjustmentActionIds.parse('pet_size_up'),
        isNull,
        reason: '非调整动作不得被识别为调整动作',
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('8. 设置修订号（连续加减只应用最新值，不依赖延时）', () {
    test('bump 递增；只有最新 revision 是 current', () {
      final WheelSettingRevision rev = WheelSettingRevision();
      expect(rev.value, 0);
      final int a = rev.bump();
      expect(a, 1);
      final int b = rev.bump();
      expect(b, 2);
      expect(rev.isCurrent(a), isFalse, reason: '旧事务必须被判为过期');
      expect(rev.isCurrent(b), isTrue);
    });

    test('旧 revision 的事务必须放弃（不会把过期尺寸写回窗口）', () {
      final WheelSettingRevision rev = WheelSettingRevision();
      final int r1 = rev.bump(); // 用户第一次点"增大"
      final int r2 = rev.bump(); // 用户立刻又点一次
      // 第一次重建事务在提交前检查：
      expect(rev.isCurrent(r1), isFalse);
      // 第二次通过：
      expect(rev.isCurrent(r2), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('9 / 11. 契约与隔离', () {
    test('调整层模块是纯 Dart（不依赖桌面实现）', () {
      final String src = _read('lib/menu/wheel_adjustment_layer.dart');
      for (final String banned in <String>[
        'package:window_manager/',
        'package:screen_retriever/',
        'package:ffi/',
        'windows_surface_channel.dart',
        'windows_window_controller.dart',
      ]) {
        expect(src, isNot(contains(banned)), reason: banned);
      }
      expect(RegExp(r'Platform\.is(Windows|Android)').hasMatch(src), isFalse);
    });

    test('范围 / 步进全部取自 WheelMenuLayoutSettings（不重复字面量）', () {
      expect(WheelAdjustmentKind.wheelScale.min, WheelMenuLayoutSettings.minScale);
      expect(WheelAdjustmentKind.wheelScale.max, WheelMenuLayoutSettings.maxScale);
      expect(WheelAdjustmentKind.wheelScale.step, WheelMenuLayoutSettings.step);
      expect(
        WheelAdjustmentKind.wheelScale.defaultValue,
        WheelMenuLayoutSettings.defaultScale,
      );
      expect(
        WheelAdjustmentKind.buttonScale.defaultValue,
        WheelMenuLayoutSettings.defaultButtonScale,
      );
      expect(
        WheelAdjustmentKind.menuDistance.step,
        WheelMenuLayoutSettings.distanceStep,
      );
    });

    test('Painter 不执行第二次几何镜像（方向契约的另一半）', () {
      final String painter = _read('lib/ui/desktop/wheel_menu_painter.dart');
      expect(painter, isNot(contains('scale(-1')));
    });
  });
}

String _read(String relative) =>
    File(p.join(Directory.current.path, relative)).readAsStringSync();
