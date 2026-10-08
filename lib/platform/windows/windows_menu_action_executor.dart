/// Windows 轮盘菜单动作执行器（增量 A 建立，增量 **C2** 收敛为唯一业务入口）。
///
/// 与 Android 的 `OverlayMenuActionExecutor` **并列**：两者共享
/// [MenuActionDefinitions] 里的稳定 id 与 [MenuExecutionResult] 结果协议，
/// 但**各自实现**，Windows 绝不绕 Android 的 `OverlayPet` 通道。
///
/// 增量 C2 的职责边界（需求 §3 / §15）：
/// * **窗口级动作**：`root_hide` / `pet_size_*` / `pet_home` / `tools_open_app`
///   由本类直接执行（走 host 注入的原生回调）；
/// * **只读信息项**：`pet_current` / `records_app` 由本类回报**真实状态**
///   （不再提示"只读信息项不触发动作"）；
/// * **全部业务动作**：**一律委托** [WindowsMenuActionHost.dispatchBusiness]
///   → `DesktopMenuActionBridge` → Android 既有的 `OverlayMenuActionExecutor`。
///   本类**不再**自己实现任何业务，也**不再**有"记录与同步将在增量 C2 接入"
///   这类占位文案 —— 需求 §15 要求正式目录里**零**泛化占位。
///
/// 依赖全部通过构造函数注入（回调），因此本类不 import 任何窗口库，
/// 可在 `flutter_tester` 里直接单测（见 `test/windows_menu_action_executor_test.dart`）。
library;

import '../../core/logger.dart';
import '../../menu/menu_contract.dart';
import '../../menu/wheel_action_dispatch.dart';

/// Windows 执行器需要的平台能力（由 `ui/desktop` 装配时注入）。
class WindowsMenuActionHost {
  const WindowsMenuActionHost({
    required this.setPetVisible,
    required this.increasePetScale,
    required this.decreasePetScale,
    required this.resetPetScale,
    required this.resetPetPosition,
    required this.openControlPanel,
    required this.dispatchBusiness,
    required this.currentPetStateLabel,
    required this.currentForegroundAppLabel,
  });

  /// 显示 / 隐藏桌宠窗口。
  final Future<void> Function(bool visible) setPetVisible;

  final Future<void> Function() increasePetScale;
  final Future<void> Function() decreasePetScale;
  final Future<void> Function() resetPetScale;

  /// 重置桌宠位置。
  final Future<void> Function() resetPetPosition;

  /// 打开 PetLife 控制面板（Windows 的设置 / 应用入口）。
  final Future<void> Function() openControlPanel;

  /// **唯一业务通道**：把动作 id 交给复用 Android 业务实现的桥。
  ///
  /// 需求 §3.1「唯一业务入口」+ §1「不得复制业务逻辑」的落点。
  final Future<MenuExecutionResult> Function(String actionId) dispatchBusiness;

  /// 只读信息项 `pet_current` 的文案（当前状态）。
  final Future<String> Function() currentPetStateLabel;

  /// 只读信息项 `records_app` 的文案（当前前台应用）。
  final Future<String> Function() currentForegroundAppLabel;
}

class WindowsMenuActionExecutor implements WheelMenuActionDispatcher {
  WindowsMenuActionExecutor(this._host);

  final WindowsMenuActionHost _host;

  /// 执行一个动作 id（兼容旧调用点；内部走 [dispatch]）。
  ///
  /// * 未知 id → `failed`（附 id，绝不静默）；
  /// * 导航 / 调整层入口 → `unavailable` + **明确原因**（它们由菜单栈处理）；
  /// * 业务动作 → 委托 host（真实业务在 canonical 执行器里）。
  ///
  /// [args] 保留给"带参数调用"的旧通道；当前所有动作都不需要参数。
  Future<MenuExecutionResult> execute(
    String actionId, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) {
    return _run(actionId, args);
  }

  /// 需求 §3.1：唯一业务入口。上下文当前只用于日志，因此不改变执行语义。
  @override
  Future<MenuExecutionResult> dispatch(
    String canonicalActionId,
    MenuActionContext context,
  ) {
    assert(
      !WheelActionRegistry.menuStackActionIds.contains(canonicalActionId),
      '菜单栈动作（$canonicalActionId）不得进入业务分发',
    );
    return _run(canonicalActionId, const <String, Object?>{});
  }

  Future<MenuExecutionResult> _run(
    String actionId,
    Map<String, Object?> args,
  ) async {
    final MenuActionDefinition? definition = MenuActionDefinitions.of(actionId);
    if (definition == null) {
      return MenuExecutionResult.failed('不支持的菜单动作：$actionId', actionId: actionId);
    }

    try {
      return await _dispatch(actionId, definition, args);
    } catch (e, st) {
      Loggers.window.warning('Windows 菜单动作执行失败：$actionId', e, st);
      return MenuExecutionResult.failed('$actionId 执行失败：$e', actionId: actionId);
    }
  }

  Future<MenuExecutionResult> _dispatch(
    String actionId,
    MenuActionDefinition definition,
    Map<String, Object?> args,
  ) {
    return switch (definition.kind) {
      // 导航项由菜单栈即时处理，不应进入业务执行器。
      MenuActionKind.navigation => Future<MenuExecutionResult>.value(
          MenuExecutionResult.unavailable(
            '导航项由菜单栈处理，不进入业务执行器：$actionId',
            actionId: actionId,
          ),
        ),
      MenuActionKind.info => _dispatchInfo(actionId),
      MenuActionKind.nativeWindow => _dispatchNative(actionId),
      // 需求 §3.1：业务动作**没有**第二处实现，一律交给唯一业务通道。
      MenuActionKind.dartAction => _host.dispatchBusiness(actionId),
      // 调整层入口由菜单栈处理（就地进层改设置），**不**走业务执行器。
      MenuActionKind.wheelAdjust => Future<MenuExecutionResult>.value(
          MenuExecutionResult.unavailable(
            '调整层由轮盘菜单栈处理，不进入业务执行器：$actionId',
            actionId: actionId,
          ),
        ),
    };
  }

  Future<MenuExecutionResult> _dispatchNative(String actionId) async {
    switch (actionId) {
      case WindowsWindowActionIds.rootHide:
        await _host.setPetVisible(false);
        return MenuExecutionResult.success('已隐藏桌宠（服务继续运行）', actionId);
      case WindowsWindowActionIds.petSizeDown:
        await _host.decreasePetScale();
        return MenuExecutionResult.success('已缩小桌宠', actionId);
      case WindowsWindowActionIds.petSizeUp:
        await _host.increasePetScale();
        return MenuExecutionResult.success('已放大桌宠', actionId);
      case WindowsWindowActionIds.petSizeReset:
        await _host.resetPetScale();
        return MenuExecutionResult.success('已恢复默认大小', actionId);
      case WindowsWindowActionIds.petHome:
        await _host.resetPetPosition();
        return MenuExecutionResult.success('已重置桌宠位置', actionId);
      case WindowsWindowActionIds.toolsOpenApp:
        await _host.openControlPanel();
        return MenuExecutionResult.success('已打开 PetLife 控制面板', actionId);
      default:
        // 注册表校验（[WheelActionRegistry.validate]）保证这里**不可达**；
        // 保留为防御性断言，绝不写成泛化的"不支持"。
        return MenuExecutionResult.failed('未登记的 Windows 窗口动作：$actionId', actionId: actionId);
    }
  }

  /// 只读信息项（需求 §5「当前状态」/ §7「当前应用」）：
  /// **只回报状态、无副作用**，文案取自既有服务（不新建统计口径）。
  Future<MenuExecutionResult> _dispatchInfo(String actionId) async {
    switch (actionId) {
      case MenuInfoIds.petCurrent:
        return MenuExecutionResult.success(await _host.currentPetStateLabel(), actionId);
      case MenuInfoIds.recordsApp:
        return MenuExecutionResult.success(
          await _host.currentForegroundAppLabel(),
          actionId,
        );
      default:
        return MenuExecutionResult.failed('未登记的只读信息项：$actionId', actionId: actionId);
    }
  }
}
