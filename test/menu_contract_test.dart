import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/ui/overlay_menu_actions.dart' show MenuActionIds;

/// 增量 A：平台无关菜单**契约**用例。
///
/// 关键点：canonical id 必须与 Android 已在用的 [MenuActionIds.canonical]
/// 完全一致；树结构 / 返回行为 / 结果协议稳定；**不得出现 camelCase**。
void main() {
  final RegExp snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');

  group('动作 id 契约', () {
    test('canonical 动作 id 复用既有 MenuActionIds.canonical（逐字一致）', () {
      expect(MenuActionDefinitions.canonicalActionIds, MenuActionIds.canonical);
      expect(MenuActionDefinitions.canonicalActionIds.length, 17);
    });

    test('全部动作 id 都是 snake_case（不引入 camelCase）', () {
      for (final MenuActionDefinition definition in MenuActionDefinitions.all) {
        expect(
          snakeCase.hasMatch(definition.id),
          isTrue,
          reason: '动作 id 必须是 snake_case：${definition.id}',
        );
      }
    });

    test('Windows 原生窗口动作 id 已登记且完整', () {
      expect(WindowsWindowActionIds.all.length, 6);
      for (final String id in WindowsWindowActionIds.all) {
        expect(MenuActionDefinitions.isKnown(id), isTrue, reason: '未登记：$id');
        expect(
          MenuActionDefinitions.of(id)!.kind,
          MenuActionKind.nativeWindow,
          reason: '$id 应归类为 nativeWindow',
        );
      }
      expect(WindowsWindowActionIds.petHome, 'pet_home');
      expect(WindowsWindowActionIds.rootHide, 'root_hide');
      expect(WindowsWindowActionIds.toolsOpenApp, 'tools_open_app');
    });

    test('未知 id 返回 null', () {
      expect(MenuActionDefinitions.of('toggleAutomaticState'), isNull);
      expect(MenuActionDefinitions.isKnown('nope'), isFalse);
    });
  });

  group('菜单树', () {
    test('根菜单 6 项（5 个子菜单 + 隐藏），5 个子菜单各带返回', () {
      expect(MenuCatalog.root.nodes.length, 6);
      expect(MenuCatalog.submenus.length, 5);

      // 根菜单前 5 项是导航（进入子菜单），第 6 项是隐藏（窗口动作）。
      for (int i = 0; i < 5; i++) {
        final MenuNode node = MenuCatalog.root.nodes[i];
        expect(MenuActionDefinitions.of(node.actionId)!.kind, MenuActionKind.navigation);
      }
      final MenuNode hide = MenuCatalog.root.nodes[5];
      expect(hide.id, 'root_hide');
      expect(hide.actionId, WindowsWindowActionIds.rootHide);

      for (final MenuLevel level in MenuCatalog.submenus) {
        expect(level.nodes.last.isBack, isTrue, reason: '${level.id} 末尾必须是返回');
        expect(level.nodes.last.actionId, MenuNavigationIds.back);
      }
    });

    test('条目 id 稳定且不含大写', () {
      for (final MenuLevel level in MenuCatalog.levels) {
        for (final MenuNode node in level.nodes) {
          expect(snakeCase.hasMatch(node.id), isTrue, reason: node.id);
        }
      }
      expect(MenuCatalog.node('pet_size_up')!.actionId, WindowsWindowActionIds.petSizeUp);
      expect(MenuCatalog.node('back')!.isBack, isTrue);
    });

    test('maxItems 取最大层级项数（形象 7 项）', () {
      expect(MenuCatalog.maxItems, 7);
    });
  });

  group('菜单栈 / 返回行为', () {
    test('open → push → pop → clear', () {
      final MenuStack stack = MenuStack();
      expect(stack.isEmpty, isTrue);

      stack.open();
      expect(stack.currentId, MenuCatalog.rootId);

      expect(stack.push(MenuCatalog.petLevelId), isTrue);
      expect(stack.currentId, MenuCatalog.petLevelId);
      expect(stack.depth, 2);

      // 非法 push 被拒。
      expect(stack.push(MenuCatalog.rootId), isFalse);
      expect(stack.push('nope'), isFalse);
      expect(stack.push(MenuCatalog.petLevelId), isFalse); // 与栈顶相同

      // 返回一级，再返回（已在根）不关闭。
      expect(stack.pop(), isTrue);
      expect(stack.currentId, MenuCatalog.rootId);
      expect(stack.pop(), isFalse);
      expect(stack.currentId, MenuCatalog.rootId);

      stack.clear();
      expect(stack.isEmpty, isTrue);
    });

    test('pushByAction 按导航动作进入目标层级', () {
      final MenuStack stack = MenuStack()..open();
      expect(stack.pushByAction(MenuNavigationIds.openRecords), isTrue);
      expect(stack.currentId, MenuCatalog.recordsLevelId);
      // 非导航动作（业务 / 窗口）不能被当成导航。
      expect(stack.pushByAction('records_sync'), isFalse);
      expect(stack.pushByAction(WindowsWindowActionIds.rootHide), isFalse);
    });

    test('popToRoot 一路回根', () {
      final MenuStack stack = MenuStack()..open();
      stack.push(MenuCatalog.appearanceLevelId);
      stack.push(MenuCatalog.settingsLevelId);
      expect(stack.depth, 3);
      expect(stack.popToRoot(), isTrue);
      expect(stack.currentId, MenuCatalog.rootId);
      expect(stack.depth, 1);
      expect(stack.popToRoot(), isFalse);
    });
  });

  group('执行结果协议', () {
    test('六个状态与 snake_case 线上取值', () {
      expect(MenuExecutionStatus.success.wireName, 'success');
      expect(MenuExecutionStatus.running.wireName, 'running');
      expect(MenuExecutionStatus.unavailable.wireName, 'unavailable');
      expect(MenuExecutionStatus.requiresLogin.wireName, 'requires_login');
      expect(MenuExecutionStatus.requiresPermission.wireName, 'requires_permission');
      expect(MenuExecutionStatus.failed.wireName, 'failed');
    });

    test('fromWire 往返；未知取值退化为 failed', () {
      for (final MenuExecutionStatus status in MenuExecutionStatus.values) {
        expect(MenuExecutionStatus.fromWire(status.wireName), status);
      }
      expect(MenuExecutionStatus.fromWire('nope'), MenuExecutionStatus.failed);
      expect(MenuExecutionStatus.fromWire(null), MenuExecutionStatus.failed);
    });

    test('结果携带明确原因，running 非终态', () {
      const MenuExecutionResult unavailable =
          MenuExecutionResult.unavailable('明确原因', actionId: 'settings_theme');
      expect(unavailable.status, MenuExecutionStatus.unavailable);
      expect(unavailable.reason, '明确原因');
      expect(unavailable.toMap()['status'], 'unavailable');
      expect(unavailable.toMap()['actionId'], 'settings_theme');

      const MenuExecutionResult running = MenuExecutionResult.running('正在同步');
      expect(running.status.isTerminal, isFalse);
      expect(const MenuExecutionResult.success('ok').status.isTerminal, isTrue);
    });
  });
}
