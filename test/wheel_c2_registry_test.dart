/// 增量 **C2**：动作注册完整性 / 唯一业务入口 / 强类型导航 / 反馈类型。
///
/// 对应需求 §16.1（注册完整性）、§3.1（唯一业务入口）、§12.1（强类型目的地）、
/// §13（反馈类型）、§15（清除全部占位动作）。
///
/// 这一层是**纯 Dart**（不需要 AppServices / 数据库 / 网络），因此跑得很快，
/// 并且能在**装配期之前**就把"新加了菜单项却忘了接业务"变成测试失败。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_action_dispatch.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/navigation/app_navigation.dart';
import 'package:petlife/platform/windows/windows_menu_action_executor.dart';
import 'package:petlife/sync/models/sync_models.dart' show SyncStatus;
import 'package:petlife/ui/desktop/desktop_menu_action_bridge.dart';

void main() {
  // ---------------------------------------------------------------------------
  // §16.1 注册完整性
  // ---------------------------------------------------------------------------

  group('§16.1 注册表完整性', () {
    test('validate() 无问题（叶子动作全部有且仅有唯一路由）', () {
      expect(WheelActionRegistry.validate(), isEmpty);
    });

    test('叶子动作总数为 26（菜单目录里的非导航条目）', () {
      // root_hide(1) + pet(6) + appearance(6) + records(4) + tools(4)
      //   + settings(5) = 26；6 个 `back` 与 5 个 `open_*` 都是菜单栈动作，不计入。
      // 数字写死是**故意的**：菜单目录一旦新增条目而忘了接业务，这里立刻红。
      expect(WheelActionRegistry.leafActionIds.length, 26);
    });

    test('每个叶子动作都能解析出路由，且**没有**叶子是菜单栈动作', () {
      for (final String id in WheelActionRegistry.leafActionIds) {
        final WheelActionRoute? route = WheelActionRegistry.routeOf(id);
        expect(route, isNotNull, reason: id);
        expect(route, isNot(WheelActionRoute.menuStack), reason: id);
      }
    });

    test('菜单栈动作（返回 / 进入子菜单）不在叶子动作里', () {
      for (final String nav in MenuNavigationIds.all) {
        expect(WheelActionRegistry.leafActionIds, isNot(contains(nav)),
            reason: nav);
      }
    });

    test('canonical 动作 id 无重复（Set 语义 + 定义齐全）', () {
      final Set<String> canonical = MenuActionDefinitions.canonicalActionIds;
      expect(canonical.length, 17);
      for (final String id in canonical) {
        expect(MenuActionDefinitions.isKnown(id), isTrue, reason: id);
      }
    });

    test('业务动作集合至少覆盖记录 / 同步 / 形象 / 桌宠 / 设置页', () {
      final List<String> business = WheelActionRegistry.businessActionIds;
      for (final String id in <String>[
        'pet_auto',
        'appearance_prev',
        'appearance_next',
        'appearance_auto',
        'appearance_fav',
        'appearance_mapping',
        'appearance_library',
        'records_today',
        'records_stats',
        'records_cloud',
        'records_track',
        'records_sync',
        'records_sync_state',
        'settings_open',
      ]) {
        expect(business, contains(id), reason: id);
      }
    });

    test('窗口级动作归入 nativeWindow（不走业务通道）', () {
      for (final String id in WindowsWindowActionIds.all) {
        expect(WheelActionRegistry.routeOf(id), WheelActionRoute.nativeWindow,
            reason: id);
      }
    });

    test('四个设置入口归入 wheelAdjust（由菜单栈处理）', () {
      for (final String id in <String>[
        'settings_theme',
        'settings_wheel_size',
        'settings_button_size',
        WindowsOnlyActionIds.settingsMenuDistance,
      ]) {
        expect(WheelActionRegistry.routeOf(id), WheelActionRoute.wheelAdjust,
            reason: id);
      }
    });

    test('只读信息项归入 info', () {
      for (final String id in MenuInfoIds.all) {
        expect(WheelActionRegistry.routeOf(id), WheelActionRoute.info,
            reason: id);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // §15 清除全部占位动作
  // ---------------------------------------------------------------------------

  group('§15 正式目录里没有任何泛化占位', () {
    late List<String> businessCalls;

    WindowsMenuActionExecutor build() => WindowsMenuActionExecutor(
          WindowsMenuActionHost(
            setPetVisible: (bool _) async {},
            increasePetScale: () async {},
            decreasePetScale: () async {},
            resetPetScale: () async {},
            resetPetPosition: () async {},
            openControlPanel: () async {},
            dispatchBusiness: (String actionId) async {
              businessCalls.add(actionId);
              return MenuExecutionResult.success('已执行 $actionId', actionId);
            },
            currentPetStateLabel: () async => '当前状态：focused',
            currentForegroundAppLabel: () async => '当前应用：Code',
          ),
        );

    setUp(() => businessCalls = <String>[]);

    test('遍历全部叶子动作：不得出现"不支持 / 尚未接入 / 增量 C2"字样', () async {
      final WindowsMenuActionExecutor executor = build();
      for (final String id in WheelActionRegistry.leafActionIds) {
        final MenuExecutionResult r = await executor.execute(id);
        final String text = '${r.reason ?? ''}${r.message ?? ''}';
        expect(text, isNot(contains('不支持')), reason: id);
        expect(text, isNot(contains('尚未接入')), reason: id);
        expect(text, isNot(contains('增量 C2')), reason: id);
        expect(text, isNot(contains('未支持')), reason: id);
        expect(text, isNot(contains('not implemented')), reason: id);
      }
    });

    test('全部业务动作都真的到达唯一业务通道', () async {
      final WindowsMenuActionExecutor executor = build();
      for (final String id in WheelActionRegistry.businessActionIds) {
        await executor.execute(id);
      }
      expect(businessCalls.toSet(), WheelActionRegistry.businessActionIds.toSet());
    });
  });

  // ---------------------------------------------------------------------------
  // §3.1 唯一业务入口
  // ---------------------------------------------------------------------------

  group('§3.1 唯一业务入口 WheelMenuActionDispatcher', () {
    test('dispatch() 把动作转交业务通道', () async {
      final List<String> calls = <String>[];
      final WindowsMenuActionExecutor executor = WindowsMenuActionExecutor(
        WindowsMenuActionHost(
          setPetVisible: (bool _) async {},
          increasePetScale: () async {},
          decreasePetScale: () async {},
          resetPetScale: () async {},
          resetPetPosition: () async {},
          openControlPanel: () async {},
          dispatchBusiness: (String id) async {
            calls.add(id);
            return MenuExecutionResult.success('ok', id);
          },
          currentPetStateLabel: () async => '当前状态：focused',
          currentForegroundAppLabel: () async => '当前应用：Code',
        ),
      );
      final MenuExecutionResult r = await executor.dispatch(
        'records_today',
        MenuActionContext(
          transactionId: 't1',
          invokedAt: DateTime(2026, 1, 1),
          surfaceMode: WindowsSurfaceMode.petFixedCanvas,
          menuLevel: 'records',
          isAuthenticated: true,
        ),
      );
      expect(r.status, MenuExecutionStatus.success);
      expect(calls, <String>['records_today']);
    });

    test('菜单栈动作不得进入业务分发（断言拦截）', () async {
      final WindowsMenuActionExecutor executor = WindowsMenuActionExecutor(
        WindowsMenuActionHost(
          setPetVisible: (bool _) async {},
          increasePetScale: () async {},
          decreasePetScale: () async {},
          resetPetScale: () async {},
          resetPetPosition: () async {},
          openControlPanel: () async {},
          dispatchBusiness: (String id) async =>
              MenuExecutionResult.success('ok', id),
          currentPetStateLabel: () async => '当前状态：focused',
          currentForegroundAppLabel: () async => '当前应用：Code',
        ),
      );
      final MenuActionContext context = MenuActionContext(
        transactionId: 't2',
        invokedAt: DateTime(2026, 1, 1),
        surfaceMode: WindowsSurfaceMode.petFixedCanvas,
        menuLevel: 'root',
        isAuthenticated: false,
      );
      expect(
        () => executor.dispatch(MenuNavigationIds.back, context),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // §12.1 强类型控制面板目的地
  // ---------------------------------------------------------------------------

  group('§12.1 PanelDestination', () {
    test('wireName 唯一且与中文文案无关', () {
      final Set<String> names =
          PanelDestination.all.map((PanelDestination d) => d.wireName).toSet();
      expect(names.length, PanelDestination.all.length);
      for (final String n in names) {
        expect(RegExp(r'^[a-z_]+$').hasMatch(n), isTrue, reason: n);
      }
    });

    test('fromWire 往返一致', () {
      for (final PanelDestination d in PanelDestination.all) {
        expect(PanelDestination.fromWire(d.wireName), same(d));
      }
      expect(PanelDestination.fromWire('nonsense'), isNull);
    });

    test('至少包含需求 §12.1 列出的 8 个目的地', () {
      final Set<String> names = PanelDestination.all
          .map((PanelDestination d) => d.wireName)
          .toSet();
      for (final String required in <String>[
        'pet_home',
        'local_usage',
        'cloud_usage',
        'timeline',
        'account_sync',
        'asset_library',
        'settings',
        'diagnostics',
      ]) {
        expect(names, contains(required), reason: required);
      }
    });

    test('AppDestination → PanelDestination 映射覆盖全部 6 个取值', () {
      for (final AppDestination d in AppDestination.values) {
        expect(DesktopMenuActionBridge.mapAppDestination(d), isNotNull,
            reason: d.name);
      }
    });

    test('导航动作 → 目的地声明与 canonical 执行器一一对应', () {
      expect(DesktopMenuActionBridge.destinations['appearance_library'],
          same(PanelDestination.assetLibrary));
      expect(DesktopMenuActionBridge.destinations['appearance_mapping'],
          same(PanelDestination.stateMapping));
      expect(DesktopMenuActionBridge.destinations['records_stats'],
          same(PanelDestination.localUsage));
      expect(DesktopMenuActionBridge.destinations['records_cloud'],
          same(PanelDestination.cloudUsage));
      expect(DesktopMenuActionBridge.destinations['settings_open'],
          same(PanelDestination.settings));
    });

    test('需要登录的动作集合只含"立即同步"', () {
      expect(DesktopMenuActionBridge.loginRequiredActions,
          <String>{'records_sync'});
    });
  });

  // ---------------------------------------------------------------------------
  // §8.1 同步文案（Windows 侧合成，纯函数）
  // ---------------------------------------------------------------------------

  group('§8.1 同步反馈文案', () {
    test('成功且有数据 → 「同步完成：上传 N 条，下载 M 条」', () {
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.success, '上传 12 条，下载 4 条'),
        '同步完成：上传 12 条，下载 4 条',
      );
    });

    test('成功但没有数据 → 「没有需要同步的数据」', () {
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.success, '没有需要同步的数据'),
        '没有需要同步的数据',
      );
    });

    test('离线 / 需重新登录 / 未登录 / 失败 各自的简短中文', () {
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.waitingForNetwork, '没有需要同步的数据'),
        '当前离线，记录已保留',
      );
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.needsReauthentication, '没有需要同步的数据'),
        '登录已失效，请重新登录',
      );
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.signedOut, '没有需要同步的数据'),
        '请先登录',
      );
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.failed, '没有需要同步的数据'),
        '同步失败，可稍后重试',
      );
      expect(
        DesktopMenuActionBridge.syncFeedbackMessage(
            SyncStatus.syncing, '没有需要同步的数据'),
        '同步正在进行',
      );
    });

    test('文案里不出现英文异常 / 技术细节（§14）', () {
      for (final SyncStatus status in SyncStatus.values) {
        final String text = DesktopMenuActionBridge.syncFeedbackMessage(
            status, '上传 1 条，下载 0 条');
        expect(RegExp(r'[A-Za-z]{3,}').hasMatch(text), isFalse,
            reason: '$status -> $text');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // §13 反馈类型
  // ---------------------------------------------------------------------------

  group('§13 WheelFeedbackKind 派生', () {
    test('按结果状态映射（唯一推导点）', () {
      expect(
        WheelFeedbackKind.fromResult(MenuExecutionResult.success('ok')),
        WheelFeedbackKind.success,
      );
      expect(
        WheelFeedbackKind.fromResult(const MenuExecutionResult.running('…')),
        WheelFeedbackKind.progress,
      );
      expect(
        WheelFeedbackKind.fromResult(
            const MenuExecutionResult.requiresLogin('请先登录')),
        WheelFeedbackKind.warning,
      );
      expect(
        WheelFeedbackKind.fromResult(
            const MenuExecutionResult.requiresPermission('权限')),
        WheelFeedbackKind.warning,
      );
      expect(
        WheelFeedbackKind.fromResult(
            const MenuExecutionResult.unavailable('暂不可用')),
        WheelFeedbackKind.warning,
      );
      expect(
        WheelFeedbackKind.fromResult(const MenuExecutionResult.failed('失败')),
        WheelFeedbackKind.error,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // §3.3 结果协议：导航 / 关闭不再用 bool 混淆
  // ---------------------------------------------------------------------------

  group('§3.3 MenuExecutionResult 导航与关闭', () {
    test('带目的地时自动要求收起菜单', () {
      const MenuExecutionResult r = MenuExecutionResult.success(
        '已打开素材库',
        'appearance_library',
        PanelDestination.assetLibrary,
      );
      expect(r.navigation, same(PanelDestination.assetLibrary));
      expect(r.closeMenu, isTrue);
      expect(r.toMap()['navigation'], 'asset_library');
    });

    test('非导航动作不要求收起菜单（除隐藏 / 退出外由动作自行决定）', () {
      const MenuExecutionResult r =
          MenuExecutionResult.success('已放大桌宠', 'pet_size_up');
      expect(r.navigation, isNull);
      expect(r.closeMenu, isFalse);
    });

    test('requiresLogin 可携带目的地（未登录同步 → 账户与同步）', () {
      const MenuExecutionResult r = MenuExecutionResult.requiresLogin(
        '请先登录',
        actionId: 'records_sync',
        navigation: PanelDestination.accountSync,
      );
      expect(r.navigation, same(PanelDestination.accountSync));
    });
  });
}
