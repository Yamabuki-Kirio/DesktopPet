import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/wheel_action_dispatch.dart';
import 'package:petlife/menu/windows_surface_mode.dart';
import 'package:petlife/platform/windows/windows_menu_action_executor.dart';

/// 增量 A 建立、增量 **C2** 收敛后的 Windows 动作执行器用例。
///
/// 约束（需求 §3.1 / §15）：
/// * 窗口级动作真正执行（通过注入回调）；
/// * **全部业务动作委托**给唯一业务通道 `dispatchBusiness`（不再有第二份实现，
///   也**不再**有"记录与同步将在增量 C2 接入"这类占位）；
/// * 只读信息项回报**真实状态**；
/// * 导航 / 调整层入口 → `unavailable` + 指向"菜单栈"的明确原因；
/// * 未知 id 才用 `failed`。
void main() {
  late List<String> calls;
  late List<String> businessCalls;

  setUp(() {
    calls = <String>[];
    businessCalls = <String>[];
  });

  WindowsMenuActionExecutor build() => WindowsMenuActionExecutor(
        WindowsMenuActionHost(
          setPetVisible: (bool visible) async => calls.add('visible=$visible'),
          increasePetScale: () async => calls.add('scale+'),
          decreasePetScale: () async => calls.add('scale-'),
          resetPetScale: () async => calls.add('scale0'),
          resetPetPosition: () async => calls.add('home'),
          openControlPanel: () async => calls.add('panel'),
          dispatchBusiness: (String actionId) async {
            businessCalls.add(actionId);
            return MenuExecutionResult.success('已执行 $actionId', actionId);
          },
          currentPetStateLabel: () async => '当前状态：focused',
          currentForegroundAppLabel: () async => '当前应用：Code',
        ),
      );

  group('窗口级动作真正执行', () {
    test('root_hide 隐藏窗口', () async {
      final MenuExecutionResult r = await build().execute(WindowsWindowActionIds.rootHide);
      expect(r.status, MenuExecutionStatus.success);
      expect(calls, <String>['visible=false']);
    });

    test('pet_size_up / down / reset', () async {
      final WindowsMenuActionExecutor executor = build();
      await executor.execute(WindowsWindowActionIds.petSizeUp);
      await executor.execute(WindowsWindowActionIds.petSizeDown);
      await executor.execute(WindowsWindowActionIds.petSizeReset);
      expect(calls, <String>['scale+', 'scale-', 'scale0']);
    });

    test('pet_home 重置位置', () async {
      await build().execute(WindowsWindowActionIds.petHome);
      expect(calls, <String>['home']);
    });

    test('tools_open_app 打开控制面板', () async {
      await build().execute(WindowsWindowActionIds.toolsOpenApp);
      expect(calls, <String>['panel']);
    });
  });

  group('需求 §3.1：全部业务动作委托唯一业务通道', () {
    test('桌宠 / 形象 / 记录 / 同步 / 设置 全部走 dispatchBusiness', () async {
      final WindowsMenuActionExecutor executor = build();
      const List<String> ids = <String>[
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
      ];
      for (final String id in ids) {
        final MenuExecutionResult r = await executor.execute(id);
        expect(r.status, MenuExecutionStatus.success, reason: id);
      }
      // 顺序与调用一致，且**一个都不少**。
      expect(businessCalls, ids);
      // 窗口级回调一次都没被误触。
      expect(calls, isEmpty);
    });

    test('业务动作不再出现任何"增量 C2 接入"占位文案', () async {
      final WindowsMenuActionExecutor executor = build();
      for (final String id in <String>[
        'records_today',
        'records_stats',
        'records_cloud',
        'records_track',
        'records_sync',
        'records_sync_state',
      ]) {
        final MenuExecutionResult r = await executor.execute(id);
        expect(r.status, isNot(MenuExecutionStatus.unavailable), reason: id);
        expect(r.reason ?? '', isNot(contains('增量 C2')), reason: id);
        expect(r.reason ?? '', isNot(contains('尚未接入')), reason: id);
      }
    });
  });

  group('只读信息项回报真实状态', () {
    test('pet_current → 当前状态文案', () async {
      final MenuExecutionResult r = await build().execute(MenuInfoIds.petCurrent);
      expect(r.status, MenuExecutionStatus.success);
      expect(r.message, contains('focused'));
    });

    test('records_app → 当前应用文案', () async {
      final MenuExecutionResult r = await build().execute(MenuInfoIds.recordsApp);
      expect(r.status, MenuExecutionStatus.success);
      expect(r.message, contains('Code'));
    });
  });

  group('导航 / 调整层入口不进入业务执行器', () {
    test('settings_* 调整层入口 → unavailable 且原因指向"菜单栈"', () async {
      final WindowsMenuActionExecutor executor = build();
      for (final String id in <String>[
        'settings_theme',
        'settings_wheel_size',
        'settings_button_size',
        WindowsOnlyActionIds.settingsMenuDistance,
      ]) {
        final MenuExecutionResult r = await executor.execute(id);
        expect(r.status, MenuExecutionStatus.unavailable, reason: id);
        expect(r.reason, contains('菜单栈'), reason: id);
      }
      expect(businessCalls, isEmpty);
    });

    test('导航项 → unavailable（由菜单栈处理）', () async {
      final MenuExecutionResult r = await build().execute(MenuNavigationIds.openPet);
      expect(r.status, MenuExecutionStatus.unavailable);
      expect(r.reason, contains('菜单栈'));
    });
  });

  group('未知 id', () {
    test('未知 id → failed 并附 id', () async {
      final MenuExecutionResult r = await build().execute('toggleAutomaticState');
      expect(r.status, MenuExecutionStatus.failed);
      expect(r.reason, contains('不支持的菜单动作'));
      expect(r.reason, contains('toggleAutomaticState'));
    });
  });

  group('需求 §3.1：dispatch 接口拒绝菜单栈动作', () {
    test('菜单栈动作不得进入业务分发（断言生效）', () async {
      final WindowsMenuActionExecutor executor = build();
      final MenuActionContext context = MenuActionContext(
        transactionId: 't1',
        invokedAt: DateTime(2026, 1, 1),
        surfaceMode: WindowsSurfaceMode.petFixedCanvas,
        menuLevel: 'root',
        isAuthenticated: false,
      );
      // 断言在 debug 下生效；release 下也只是分类为 unknown → unavailable/failed。
      expect(
        () => executor.dispatch(MenuNavigationIds.back, context),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
