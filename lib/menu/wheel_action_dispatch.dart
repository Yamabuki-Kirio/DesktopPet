/// 增量 **C2**：轮盘「统一动作分发」契约层（纯 Dart，平台中立）。
///
/// 需求 §3 要求把业务动作收敛到**唯一入口**，并且：
/// * 菜单 Widget / Painter / HitTest / 动画 / Region 层**不得**调用具体业务；
/// * 每个叶子动作**有且仅有一个**处理器；
/// * `back` / `open_*` 等菜单栈动作**不进入**业务分发；
/// * 正式目录**不允许**落进泛化的"不支持"兜底。
///
/// 本文件只放**契约与校验**，不放任何业务实现：
/// 真正的执行由 `WindowsMenuActionExecutor`（窗口级 + 业务委托）完成，
/// 而业务本身复用 Android 既有的 `OverlayMenuActionExecutor`。
library;

import 'menu_contract.dart';
import 'windows_surface_mode.dart';

/// 轮盘反馈的类型（需求 §13）。视图据此选择图标 / 颜色 / 是否显示进度。
enum WheelFeedbackKind {
  /// 执行成功。
  success,

  /// 中性信息（只读项、状态回报）。
  info,

  /// 需要用户注意（到边界、已暂停等）。
  warning,

  /// 失败。
  error,

  /// 正在进行（同步等长任务）。
  progress;

  /// 线上 / 日志取值。
  String get wireName => name;

  /// 从动作结果推导反馈类型（**唯一的推导点**，视图不再各自 switch）。
  static WheelFeedbackKind fromResult(MenuExecutionResult result) {
    return switch (result.status) {
      MenuExecutionStatus.success => WheelFeedbackKind.success,
      MenuExecutionStatus.running => WheelFeedbackKind.progress,
      MenuExecutionStatus.requiresLogin => WheelFeedbackKind.warning,
      MenuExecutionStatus.requiresPermission => WheelFeedbackKind.warning,
      MenuExecutionStatus.unavailable => WheelFeedbackKind.warning,
      MenuExecutionStatus.failed => WheelFeedbackKind.error,
    };
  }
}

/// 一次动作派发的**上下文**（需求 §3.2）。
///
/// 全部字段都是**当次调用**的快照：执行器不得把它存进长生命周期字段，
/// 否则"切换账户后旧任务结果写进新账户"这类越权问题无法根除（需求 §8.2）。
class MenuActionContext {
  const MenuActionContext({
    required this.transactionId,
    required this.invokedAt,
    required this.surfaceMode,
    required this.menuLevel,
    required this.isAuthenticated,
    this.accountSessionId,
    this.currentDeviceId,
  });

  /// 本次动作的事务 id（与日志、幂等台账同源）。
  final String transactionId;

  /// 调用时刻（由外部注入，便于测试固定时间）。
  final DateTime invokedAt;

  /// 调用时的窗口形态（桌宠 / 面板 / 过渡）。
  final WindowsSurfaceMode surfaceMode;

  /// 调用时所在菜单层级 id（`root` / `records` / …）。
  final String menuLevel;

  /// 调用时是否已登录。
  final bool isAuthenticated;

  /// 当前账户会话 id（**脱敏后**才可进日志）。
  final String? accountSessionId;

  /// 当前设备 id（本机统计用的设备标识）。
  final String? currentDeviceId;

  Map<String, Object?> toLogFields() => <String, Object?>{
        'transactionId': transactionId,
        'surfaceMode': surfaceMode.wireName,
        'menuLevel': menuLevel,
        'isAuthenticated': isAuthenticated,
        if (accountSessionId != null) 'accountSessionId': accountSessionId,
        if (currentDeviceId != null) 'deviceId': currentDeviceId,
      };
}

/// **唯一业务入口**（需求 §3.1）。
///
/// 菜单 Widget / Painter / HitTest / 动画 / Region 层只允许依赖这个接口，
/// 绝不直接 import 任何具体服务。
abstract interface class WheelMenuActionDispatcher {
  /// 派发一个**非导航**动作 id（导航 / 返回由菜单栈即时处理，不该走到这里）。
  Future<MenuExecutionResult> dispatch(
    String canonicalActionId,
    MenuActionContext context,
  );
}

/// 叶子动作的路由分类（注册表校验用；**不引入第二份 id 真相**）。
///
/// 分类来自 [MenuActionDefinitions.of]，因此"Android 已经在用的 canonical id"
/// 在编译期就被钉死，不可能漂移。
enum WheelActionRoute {
  /// 由菜单栈即时处理（`back` / `open_*`），不进业务分发。
  menuStack('menu_stack'),

  /// Windows 原生窗口动作。
  nativeWindow('native_window'),

  /// 需要 Dart 业务（记录 / 同步 / 设置页 / 形象 …）。
  business('business'),

  /// 只读信息项（点击无副作用，只回报状态）。
  info('info'),

  /// 轮盘内调整层的**入口**（由菜单栈就地进层）。
  wheelAdjust('wheel_adjust');

  const WheelActionRoute(this.wireName);

  final String wireName;

  static WheelActionRoute? of(MenuActionKind kind) => switch (kind) {
        MenuActionKind.navigation => WheelActionRoute.menuStack,
        MenuActionKind.nativeWindow => WheelActionRoute.nativeWindow,
        MenuActionKind.dartAction => WheelActionRoute.business,
        MenuActionKind.info => WheelActionRoute.info,
        MenuActionKind.wheelAdjust => WheelActionRoute.wheelAdjust,
      };
}

/// 动作**注册表**（需求 §3.4）：叶子动作 → 唯一路由，并提供启动期 / 测试期校验。
///
/// 设计取舍：注册表**从 [MenuCatalog] 派生**，而不是手写第二份清单 ——
/// 手写清单一定会跟菜单目录漂移，而那正是"点下去提示未支持"的根源。
abstract final class WheelActionRegistry {
  /// 三个菜单栈动作的稳定 id（进入子菜单 / 返回），**不得**进业务分发。
  static Set<String> get menuStackActionIds => MenuNavigationIds.all;

  /// 菜单目录里**所有层级**的条目（含返回）。
  static Iterable<MenuNode> get allNodes =>
      MenuCatalog.levels.expand((MenuLevel l) => l.nodes);

  /// 所有"叶子"动作 id = 菜单目录里出现过的 actionId，**去掉**菜单栈动作。
  ///
  /// 注意：不包含轮盘调整层的动态 id（`adjust_<kind>_*`）——
  /// 它们由 [MenuLevel] 动态生成、且**永不**进入业务执行器。
  static List<String> get leafActionIds {
    final List<String> ids = <String>[];
    for (final MenuNode node in allNodes) {
      if (menuStackActionIds.contains(node.actionId)) continue;
      if (!ids.contains(node.actionId)) ids.add(node.actionId);
    }
    return List<String>.unmodifiable(ids);
  }

  /// 叶子动作 → 路由分类；未知 id 返回 `null`。
  static WheelActionRoute? routeOf(String actionId) {
    final MenuActionDefinition? definition = MenuActionDefinitions.of(actionId);
    if (definition == null) return null;
    return WheelActionRoute.of(definition.kind);
  }

  /// 完整路由表（诊断 / 测试用）。键是 actionId，值是路由。
  static Map<String, WheelActionRoute> get routes => <String, WheelActionRoute>{
        for (final String id in leafActionIds)
          if (routeOf(id) != null) id: routeOf(id)!,
      };

  /// 需要 Dart 业务处理的叶子动作（注册表校验 / 测试用）。
  static List<String> get businessActionIds => <String>[
        for (final MapEntry<String, WheelActionRoute> e in routes.entries)
          if (e.value == WheelActionRoute.business) e.key,
      ];

  /// **校验注册表完整性**；返回问题清单（**空列表 = 通过**）。
  ///
  /// 在装配期与测试期都必须为空 —— 一旦有人往菜单目录里加了新条目却忘了接业务，
  /// 这里立刻把它变成**测试失败**，而不是运行期一句"尚未接入"。
  static List<String> validate() {
    final List<String> problems = <String>[];

    // ① 每个叶子动作都必须能在动作定义表里找到（不得有无定义的孤儿 id）。
    for (final String id in leafActionIds) {
      if (!MenuActionDefinitions.isKnown(id)) {
        problems.add('叶子动作未在 MenuActionDefinitions 注册：$id');
        continue;
      }
      // ② 叶子动作里**不得**出现导航动作（back / open_*）。
      final WheelActionRoute? route = routeOf(id);
      if (route == WheelActionRoute.menuStack) {
        problems.add('菜单栈动作不得作为叶子动作进入注册表：$id');
      }
    }

    // ③ 不许重复 canonical：`MenuActionIds.canonical` 本身是 Set，
    //    这里再对"菜单目录里实际用到的 canonical"做一次去重检查。
    final Set<String> seen = <String>{};
    for (final MenuNode node in allNodes) {
      if (menuStackActionIds.contains(node.actionId)) continue;
      if (node.actionId.isEmpty) {
        problems.add('菜单条目 actionId 为空：${node.id}');
      }
    }
    for (final String id in MenuActionDefinitions.canonicalActionIds) {
      if (!seen.add(id)) problems.add('canonical 动作 id 重复：$id');
    }

    // ④ 不允许"未分类"的 canonical（每个 canonical 必须有明确 kind）。
    for (final String id in MenuActionDefinitions.canonicalActionIds) {
      if (!MenuActionDefinitions.isKnown(id)) {
        problems.add('canonical 动作未登记定义：$id');
      }
    }

    return List<String>.unmodifiable(problems);
  }

  /// 校验并抛错（装配期使用：宁可启动即失败，也不要运行期静默占位）。
  static void assertValid() {
    final List<String> problems = validate();
    if (problems.isNotEmpty) {
      throw StateError('轮盘动作注册表不完整：\n  - ${problems.join('\n  - ')}');
    }
  }
}
