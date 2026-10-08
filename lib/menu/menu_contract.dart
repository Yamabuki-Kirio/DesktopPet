/// 跨平台轮盘菜单的**中立契约**（增量 A）。
///
/// 这一层是**纯 Dart、平台无关**的，只描述"菜单长什么样、有哪些稳定 id、
/// 一次动作执行会得到什么结果"，**不含任何平台实现**：
///
/// * 桌面专属能力（window_manager / tray_manager / screen_retriever）只允许出现在
///   `platform/windows/**`、`ui/desktop/**`（见 `test/platform_isolation_test.dart`），
///   因此本文件刻意不 import 它们，可被 Windows 与 Android 两端共用；
/// * Windows 的原生窗口动作**不在这里执行**，而是交给
///   `platform/windows/windows_menu_action_executor.dart` 注入实现。
///
/// 设计要点
/// --------
/// 1. **动作 id 单一来源**：canonical snake_case id 复用既有
///    [MenuActionIds.canonical]（Android 已在用，逐字不改）；Windows 原生动作
///    沿用同一套稳定 id（`root_hide` / `pet_size_*` / `pet_home` / `tools_open_app`）。
///    **严禁 camelCase**。
/// 2. **动作定义与执行器分离**：[MenuActionDefinition] 只声明 id 的分类与目标层级，
///    执行行为由各平台执行器实现（Android 用既有 `OverlayMenuActionExecutor`，
///    Windows 用新增的 `WindowsMenuActionExecutor`）。
/// 3. **结果协议**：Windows 执行器返回 [MenuExecutionResult]（`success` / `running` /
///    `unavailable` / `requires_login` / `requires_permission` / `failed`）。
///    它与 Android 既有的 `MenuActionResult`（`completed` / `failed` / `expired`）
///    是**两套协议**：Android 侧一行不改。
library;

import '../ui/overlay_menu_actions.dart' show MenuActionIds;

/// 动作的分类（"动作定义"与"平台执行器"分离的落点）。
///
/// * [navigation]：打开子菜单 / 返回，由**菜单栈**即时处理，不进入业务执行器；
/// * [nativeWindow]：平台窗口级动作（隐藏 / 改大小 / 重置位置 / 打开应用）；
/// * [dartAction]：需要 Dart 业务执行（素材 / 记录 / 设置 …），增量 C 才接真实业务；
/// * [info]：只读信息项（如"当前状态"），点击不产生副作用。
enum MenuActionKind {
  navigation,
  nativeWindow,
  dartAction,
  info,

  /// **轮盘内调整层**（增量 C1）：由菜单栈处理（进退层级 + 就地改设置），
  /// **不**进入业务执行器。`settings_theme` / `settings_wheel_size` /
  /// `settings_button_size` / `settings_menu_distance` 都属于这一类。
  wheelAdjust,
}

/// 一条**动作定义**：稳定 id + 分类（+ 导航目标层级）。
///
/// 这里只有"是什么"，没有"怎么做"——怎么做由平台执行器回答。
class MenuActionDefinition {
  const MenuActionDefinition(
    this.id,
    this.kind, {
    this.targetLevelId,
  });

  /// 稳定动作 id（snake_case，跨端逐字一致）。
  final String id;

  final MenuActionKind kind;

  /// 仅 [MenuActionKind.navigation]：`open_*` 要进入的子菜单层级 id。
  final String? targetLevelId;

  bool get isNavigation => kind == MenuActionKind.navigation;
}

/// 导航动作的稳定 id（原生树里的"进入子菜单 / 返回"，不发给业务执行器）。
class MenuNavigationIds {
  MenuNavigationIds._();

  static const String openPet = 'open_pet';
  static const String openAppearance = 'open_appearance';
  static const String openRecords = 'open_records';
  static const String openTools = 'open_tools';
  static const String openSettings = 'open_settings';
  static const String back = 'back';

  static const Set<String> all = <String>{
    openPet,
    openAppearance,
    openRecords,
    openTools,
    openSettings,
    back,
  };
}

/// Windows 平台原生窗口动作的稳定 id（与 Android 原生动作 id 逐字一致）。
class WindowsWindowActionIds {
  WindowsWindowActionIds._();

  /// 隐藏桌宠（摘窗口）；服务继续运行。
  static const String rootHide = 'root_hide';

  static const String petSizeDown = 'pet_size_down';
  static const String petSizeUp = 'pet_size_up';
  static const String petSizeReset = 'pet_size_reset';

  /// 重置桌宠位置回默认角落。
  static const String petHome = 'pet_home';

  /// 打开 PetLife 控制面板。
  static const String toolsOpenApp = 'tools_open_app';

  static const Set<String> all = <String>{
    rootHide,
    petSizeDown,
    petSizeUp,
    petSizeReset,
    petHome,
    toolsOpenApp,
  };
}

/// **Windows 新增**的动作 id —— 刻意**不进** Android 的 canonical 集合，
/// 以免破坏跨端逐字对账（需求：不得破坏已有 canonical ID）。
class WindowsOnlyActionIds {
  WindowsOnlyActionIds._();

  /// 菜单距离调整入口（共享 action ID）。
  static const String settingsMenuDistance = 'settings_menu_distance';

  static const Set<String> all = <String>{settingsMenuDistance};
}

/// 只读信息项的稳定 id（点击无副作用）。
class MenuInfoIds {
  MenuInfoIds._();

  static const String petCurrent = 'pet_current';
  static const String recordsApp = 'records_app';

  static const Set<String> all = <String>{petCurrent, recordsApp};
}

/// 全部动作定义的注册表（**唯一来源**）。
///
/// canonical id 直接复用 [MenuActionIds.canonical]，绝不复制字符串；
/// 因此"Android 已经在用的 id"在编译期就被钉死，不可能漂移。
class MenuActionDefinitions {
  MenuActionDefinitions._();

  /// 17 个 canonical（snake_case）业务动作 id —— 复用既有契约，逐字不改。
  static const Set<String> canonicalActionIds = MenuActionIds.canonical;

  static const List<MenuActionDefinition> navigation = <MenuActionDefinition>[
    MenuActionDefinition(MenuNavigationIds.openPet, MenuActionKind.navigation,
        targetLevelId: MenuCatalog.petLevelId),
    MenuActionDefinition(MenuNavigationIds.openAppearance, MenuActionKind.navigation,
        targetLevelId: MenuCatalog.appearanceLevelId),
    MenuActionDefinition(MenuNavigationIds.openRecords, MenuActionKind.navigation,
        targetLevelId: MenuCatalog.recordsLevelId),
    MenuActionDefinition(MenuNavigationIds.openTools, MenuActionKind.navigation,
        targetLevelId: MenuCatalog.toolsLevelId),
    MenuActionDefinition(MenuNavigationIds.openSettings, MenuActionKind.navigation,
        targetLevelId: MenuCatalog.settingsLevelId),
    MenuActionDefinition(MenuNavigationIds.back, MenuActionKind.navigation),
  ];

  /// Windows 原生窗口动作（增量 A 真正落地的只有这几个窗口级动作）。
  static const List<MenuActionDefinition> windowsNative = <MenuActionDefinition>[
    MenuActionDefinition(WindowsWindowActionIds.rootHide, MenuActionKind.nativeWindow),
    MenuActionDefinition(WindowsWindowActionIds.petSizeDown, MenuActionKind.nativeWindow),
    MenuActionDefinition(WindowsWindowActionIds.petSizeUp, MenuActionKind.nativeWindow),
    MenuActionDefinition(WindowsWindowActionIds.petSizeReset, MenuActionKind.nativeWindow),
    MenuActionDefinition(WindowsWindowActionIds.petHome, MenuActionKind.nativeWindow),
    MenuActionDefinition(WindowsWindowActionIds.toolsOpenApp, MenuActionKind.nativeWindow),
  ];

  static const List<MenuActionDefinition> info = <MenuActionDefinition>[
    MenuActionDefinition(MenuInfoIds.petCurrent, MenuActionKind.info),
    MenuActionDefinition(MenuInfoIds.recordsApp, MenuActionKind.info),
  ];

  /// 轮盘内调整层入口（增量 C1）：由菜单栈处理，不进业务执行器。
  static const List<MenuActionDefinition> wheelAdjust = <MenuActionDefinition>[
    MenuActionDefinition('settings_theme', MenuActionKind.wheelAdjust),
    MenuActionDefinition('settings_wheel_size', MenuActionKind.wheelAdjust),
    MenuActionDefinition('settings_button_size', MenuActionKind.wheelAdjust),
    MenuActionDefinition(
      WindowsOnlyActionIds.settingsMenuDistance,
      MenuActionKind.wheelAdjust,
    ),
  ];

  /// 17 个 canonical 业务动作（增量 A 只登记分类，不接真实业务）。
  static List<MenuActionDefinition> get dartActions => canonicalActionIds
      .map((String id) => MenuActionDefinition(id, MenuActionKind.dartAction))
      .toList(growable: false);

  /// 所有动作定义（顺序固定：导航 → 窗口 → 业务 → 信息）。
  static List<MenuActionDefinition> get all => <MenuActionDefinition>[
        ...navigation,
        ...windowsNative,
        // 调整层入口必须在 `dartActions` **之前**：`of()` 取首个匹配，
        // 而调整层的四个 id 也在 canonical 集合里（需要保持 canonical 对账）。
        ...wheelAdjust,
        ...dartActions,
        ...info,
      ];

  /// 按 id 查定义；未知返回 null（调用方据此如实报错，绝不静默成功）。
  static MenuActionDefinition? of(String id) {
    for (final MenuActionDefinition definition in all) {
      if (definition.id == id) return definition;
    }
    return null;
  }

  static bool isKnown(String id) => of(id) != null;
}

/// 一个菜单条目（node）。
///
/// [id] 是**稳定契约**（日志 / 请求 args / 诊断 / 单测都读它），
/// [labelZh] 只用于显示 —— **任何业务判断都不得依赖文案**。
class MenuNode {
  const MenuNode({
    required this.id,
    required this.actionId,
    required this.labelZh,
    this.titleEn,
    this.description,
    this.isBack = false,
  });

  /// 条目 id（`root_pet` / `pet_size_up` / `back` …）。
  final String id;

  /// 条目触发的稳定动作 id（导航 id / canonical id / 窗口动作 id / 信息 id）。
  final String actionId;

  final String labelZh;
  final String? titleEn;
  final String? description;

  /// 是否为固定的"返回"槽位（永远排在视觉最下方，不参与重排）。
  final bool isBack;
}

/// 一个菜单层级。
class MenuLevel {
  const MenuLevel({
    required this.id,
    required this.titleZh,
    required this.nodes,
    this.titleEn = '',
  });

  final String id;
  final String titleZh;
  final String titleEn;
  final List<MenuNode> nodes;

  int get itemCount => nodes.length;
}

/// 菜单目录：根菜单 + 5 个子菜单（与原生 `WheelMenuCatalog` 逐字对齐）。
class MenuCatalog {
  MenuCatalog._();

  static const String rootId = 'root';
  static const String petLevelId = 'pet';
  static const String appearanceLevelId = 'appearance';
  static const String recordsLevelId = 'records';
  static const String toolsLevelId = 'tools';
  static const String settingsLevelId = 'settings';

  /// 固定返回键（需求 §5）。
  static const MenuNode back = MenuNode(
    id: 'back',
    actionId: MenuNavigationIds.back,
    labelZh: '返回',
    description: '回到上一层',
    isBack: true,
  );

  /// 根菜单：桌宠 / 形象 / 记录 / 工具 / 设置 / 隐藏。
  static const MenuLevel root = MenuLevel(
    id: rootId,
    titleZh: '桌宠',
    titleEn: 'PETLIFE',
    nodes: <MenuNode>[
      MenuNode(
        id: 'root_pet',
        actionId: MenuNavigationIds.openPet,
        labelZh: '桌宠',
        titleEn: 'PET',
        description: 'AUTO MODE',
      ),
      MenuNode(
        id: 'root_appearance',
        actionId: MenuNavigationIds.openAppearance,
        labelZh: '形象',
        titleEn: 'APPEARANCE',
        description: '角色与素材',
      ),
      MenuNode(
        id: 'root_records',
        actionId: MenuNavigationIds.openRecords,
        labelZh: '记录',
        titleEn: 'RECORD',
        description: '今日使用时长',
      ),
      MenuNode(
        id: 'root_tools',
        actionId: MenuNavigationIds.openTools,
        labelZh: '工具',
        titleEn: 'TOOLS',
        description: '专注与快捷入口',
      ),
      MenuNode(
        id: 'root_settings',
        actionId: MenuNavigationIds.openSettings,
        labelZh: '设置',
        titleEn: 'SYSTEM',
        description: '主题与服务',
      ),
      MenuNode(
        id: 'root_hide',
        actionId: WindowsWindowActionIds.rootHide,
        labelZh: '隐藏',
        titleEn: 'HIDE',
        description: '隐藏桌宠（服务继续运行）',
      ),
    ],
  );

  /// 桌宠子菜单。
  static const MenuLevel pet = MenuLevel(
    id: petLevelId,
    titleZh: '桌宠',
    titleEn: 'PET',
    nodes: <MenuNode>[
      MenuNode(
        id: 'pet_size_down',
        actionId: WindowsWindowActionIds.petSizeDown,
        labelZh: '缩小',
      ),
      MenuNode(
        id: 'pet_size_up',
        actionId: WindowsWindowActionIds.petSizeUp,
        labelZh: '放大',
      ),
      MenuNode(
        id: 'pet_size_reset',
        actionId: WindowsWindowActionIds.petSizeReset,
        labelZh: '恢复默认',
      ),
      MenuNode(id: 'pet_auto', actionId: 'pet_auto', labelZh: '自动状态'),
      MenuNode(id: MenuInfoIds.petCurrent, actionId: MenuInfoIds.petCurrent, labelZh: '当前状态'),
      MenuNode(
        id: 'pet_home',
        actionId: WindowsWindowActionIds.petHome,
        labelZh: '重置位置',
      ),
      back,
    ],
  );

  /// 形象子菜单。
  static const MenuLevel appearance = MenuLevel(
    id: appearanceLevelId,
    titleZh: '形象',
    titleEn: 'APPEARANCE',
    nodes: <MenuNode>[
      MenuNode(id: 'appearance_prev', actionId: 'appearance_prev', labelZh: '上一张'),
      MenuNode(id: 'appearance_next', actionId: 'appearance_next', labelZh: '下一张'),
      MenuNode(id: 'appearance_auto', actionId: 'appearance_auto', labelZh: '自动形象'),
      MenuNode(id: 'appearance_fav', actionId: 'appearance_fav', labelZh: '收藏'),
      MenuNode(
        id: 'appearance_mapping',
        actionId: 'appearance_mapping',
        labelZh: '编辑状态素材',
      ),
      MenuNode(
        id: 'appearance_library',
        actionId: 'appearance_library',
        labelZh: '打开素材库',
      ),
      back,
    ],
  );

  /// 记录子菜单。
  static const MenuLevel records = MenuLevel(
    id: recordsLevelId,
    titleZh: '记录',
    titleEn: 'RECORD',
    nodes: <MenuNode>[
      MenuNode(id: 'records_today', actionId: 'records_today', labelZh: '今日时长'),
      MenuNode(id: MenuInfoIds.recordsApp, actionId: MenuInfoIds.recordsApp, labelZh: '当前应用'),
      MenuNode(id: 'records_stats', actionId: 'records_stats', labelZh: '本机统计'),
      MenuNode(id: 'records_cloud', actionId: 'records_cloud', labelZh: '云端记录'),
      back,
    ],
  );

  /// 工具子菜单（采集 / 同步沿用 `records_*` 稳定 id）。
  static const MenuLevel tools = MenuLevel(
    id: toolsLevelId,
    titleZh: '工具',
    titleEn: 'TOOLS',
    nodes: <MenuNode>[
      MenuNode(id: 'records_track', actionId: 'records_track', labelZh: '暂停采集'),
      MenuNode(id: 'records_sync', actionId: 'records_sync', labelZh: '立即同步'),
      MenuNode(id: 'records_sync_state', actionId: 'records_sync_state', labelZh: '同步状态'),
      MenuNode(
        id: 'tools_open_app',
        actionId: WindowsWindowActionIds.toolsOpenApp,
        labelZh: '打开 PetLife',
      ),
      back,
    ],
  );

  /// 设置子菜单。
  static const MenuLevel settings = MenuLevel(
    id: settingsLevelId,
    titleZh: '设置',
    titleEn: 'SYSTEM',
    nodes: <MenuNode>[
      MenuNode(id: 'settings_theme', actionId: 'settings_theme', labelZh: '轮盘主题'),
      MenuNode(
        id: 'settings_wheel_size',
        actionId: 'settings_wheel_size',
        labelZh: '轮盘大小',
      ),
      MenuNode(
        id: 'settings_button_size',
        actionId: 'settings_button_size',
        labelZh: '按钮大小',
      ),
      // 菜单距离：Windows 新增入口（共享 action ID `settings_menu_distance`）。
      MenuNode(
        id: 'settings_menu_distance',
        actionId: WindowsOnlyActionIds.settingsMenuDistance,
        labelZh: '菜单距离',
      ),
      MenuNode(id: 'settings_open', actionId: 'settings_open', labelZh: '完整设置'),
      back,
    ],
  );

  /// 所有层级（顺序固定）。
  static const List<MenuLevel> levels = <MenuLevel>[
    root,
    pet,
    appearance,
    records,
    tools,
    settings,
  ];

  /// 子菜单层级（根之外的 5 个）。
  static List<MenuLevel> get submenus =>
      levels.where((MenuLevel level) => level.id != rootId).toList(growable: false);

  static MenuLevel? level(String id) {
    for (final MenuLevel level in levels) {
      if (level.id == id) return level;
    }
    return null;
  }

  static bool isRoot(String id) => id == rootId;

  /// 按条目 id 查node；未知返回 null。
  static MenuNode? node(String nodeId) {
    for (final MenuLevel level in levels) {
      for (final MenuNode node in level.nodes) {
        if (node.id == nodeId) return node;
      }
    }
    return null;
  }

  /// 一个层级最多多少项（几何层据此决定按钮尺寸与环带半径）。
  static int get maxItems =>
      levels.map((MenuLevel l) => l.itemCount).reduce((int a, int b) => a > b ? a : b);

  /// 所有条目里最长的中文标签**字数**（与 Android `WheelMenuCatalog.maxLabelChars` 同口径）。
  ///
  /// 用来估算"文字 chip 可能伸出刀刃多远"，好把它算进菜单窗口包围盒 ——
  /// 少了这一步就会出现"标签被窗口矩形裁切"。当前由 `"打开 PetLife"` 决定 → 10。
  static int get maxLabelChars {
    int longest = 1;
    for (final MenuLevel level in levels) {
      for (final MenuNode node in level.nodes) {
        if (node.labelZh.length > longest) longest = node.labelZh.length;
      }
    }
    return longest;
  }
}

/// 菜单栈：进入子菜单 = `push`，返回 = `pop`，关闭 = `clear`。
///
/// **只有这一处维护层级**：绝不为每个子菜单写独立的返回逻辑。
class MenuStack {
  final List<String> _ids = <String>[];

  int get depth => _ids.length;

  bool get isEmpty => _ids.isEmpty;

  String? get currentId => _ids.isEmpty ? null : _ids.last;

  MenuLevel? get current => currentId == null ? null : MenuCatalog.level(currentId!);

  List<String> path() => List<String>.unmodifiable(_ids);

  /// 打开根菜单（幂等：已打开时不清空子层级）。
  void open() {
    if (_ids.isEmpty) _ids.add(MenuCatalog.rootId);
  }

  /// 压入一个**动态**层级（例如轮盘内调整层：它不在 `MenuCatalog.levels` 里，
  /// 但确实是当前菜单树的一层）。
  ///
  /// 只做"非根 / 不等于当前层"的基本校验；层级内容由调用方保证。
  bool pushDynamic(String levelId) {
    if (MenuCatalog.isRoot(levelId)) return false;
    if (_ids.isEmpty) return false;
    if (_ids.last == levelId) return false;
    _ids.add(levelId);
    return true;
  }

  /// **恢复到指定层级**：把栈重置为 `[root, levelId]`（调整后自动重开用）。
  ///
  /// 比"反复 push / pop"更可判定：不依赖中间每一步都合法。
  bool restoreTo(String levelId) {
    if (MenuCatalog.isRoot(levelId)) {
      if (_ids.isEmpty) return false;
      _ids
        ..clear()
        ..add(MenuCatalog.rootId);
      return true;
    }
    _ids
      ..clear()
      ..add(MenuCatalog.rootId)
      ..add(levelId);
    return true;
  }

  /// 进入子菜单；非法层级拒绝（保持原层级，绝不产生非法路径）。
  bool push(String levelId) {
    if (MenuCatalog.level(levelId) == null) return false;
    if (MenuCatalog.isRoot(levelId)) return false;
    if (_ids.isEmpty) return false;
    if (_ids.last == levelId) return false;
    _ids.add(levelId);
    return true;
  }

  /// 按导航动作 id 进入对应子菜单（`open_*`）；非导航动作返回 false。
  bool pushByAction(String actionId) {
    final MenuActionDefinition? definition = MenuActionDefinitions.of(actionId);
    final String? target = definition?.targetLevelId;
    if (target == null) return false;
    return push(target);
  }

  /// 返回一级；在根菜单时返回 false（**不关闭菜单**，关闭是另一个动作）。
  bool pop() {
    if (_ids.length <= 1) return false;
    _ids.removeAt(_ids.length - 1);
    return true;
  }

  /// 一路回根。
  bool popToRoot() {
    if (_ids.length <= 1) return false;
    while (_ids.length > 1) {
      _ids.removeAt(_ids.length - 1);
    }
    return true;
  }

  void clear() => _ids.clear();
}

/// 一次菜单动作的执行结果状态（Windows 侧协议）。
///
/// 与 Android 既有的 `MenuRequestStatus`（completed / failed / expired）**互不影响**：
/// 这是增量 A 为跨平台执行器定义的更细语义。
enum MenuExecutionStatus {
  /// 已执行成功。
  success,

  /// 已受理、正在进行（如"正在同步"）。
  running,

  /// 当前平台/当前版本不支持该动作（**必须带明确原因**）。
  unavailable,

  /// 需要登录。
  requiresLogin,

  /// 需要用户授予权限。
  requiresPermission,

  /// 执行失败。
  failed;

  /// 跨端线上取值：snake_case（`requires_login` …）。
  String get wireName => switch (this) {
        MenuExecutionStatus.success => 'success',
        MenuExecutionStatus.running => 'running',
        MenuExecutionStatus.unavailable => 'unavailable',
        MenuExecutionStatus.requiresLogin => 'requires_login',
        MenuExecutionStatus.requiresPermission => 'requires_permission',
        MenuExecutionStatus.failed => 'failed',
      };

  /// 是否为终态（非 running）。
  bool get isTerminal => this != MenuExecutionStatus.running;

  static MenuExecutionStatus fromWire(String? raw) {
    for (final MenuExecutionStatus status in MenuExecutionStatus.values) {
      if (status.wireName == raw) return status;
    }
    return MenuExecutionStatus.failed;
  }
}

/// **强类型的控制面板目的地**（增量 C2，需求 §12.1）。
///
/// 为什么**不**扩展现有的 `AppDestination` 枚举：那个枚举被 Android 的
/// `ui/mobile/mobile_shell.dart` 用 `switch` **穷举**消费，加一个值就会让 Android
/// 编译失败 —— 而需求 §1 明令**不得修改 Android 代码**。
///
/// 因此这里另立一个**只属于轮盘 / Windows 控制面板**的密封类型：
/// * 它与菜单文案**无关**（禁止用中文名做路由，§12.1）；
/// * 已知的 6 个目的地可在外壳边界**一对一**映射回 `AppDestination`；
/// * `diagnostics` 等 Windows 独有目的地直接给出页签下标，不经过 `AppDestination`。
sealed class PanelDestination {
  const PanelDestination();

  /// 跨端/日志用的稳定取值（snake_case）。
  String get wireName;

  /// 材料化描述（诊断日志用）。
  @override
  String toString() => 'PanelDestination($wireName)';

  /// 桌宠主页（§12.3：关闭面板返回桌宠，而不是打开某个页签）。
  static const PanelDestination petHome = PanelPetHome();

  /// 本机使用统计。
  static const PanelDestination localUsage = PanelLocalUsage();

  /// 云端使用统计。
  static const PanelDestination cloudUsage = PanelCloudUsage();

  /// 时间线（「使用统计」页的时间线标签）。
  static const PanelDestination timeline = PanelTimeline();

  /// 账户与同步。
  static const PanelDestination accountSync = PanelAccountSync();

  /// 素材库。
  static const PanelDestination assetLibrary = PanelAssetLibrary();

  /// 状态素材映射编辑器（以当前角色为上下文）。
  static const PanelDestination stateMapping = PanelStateMapping();

  /// 设置。
  static const PanelDestination settings = PanelSettings();

  /// 诊断与日志。
  static const PanelDestination diagnostics = PanelDiagnostics();

  /// 全部目的地（注册表校验 / 测试用）。
  static const List<PanelDestination> all = <PanelDestination>[
    petHome,
    localUsage,
    cloudUsage,
    timeline,
    accountSync,
    assetLibrary,
    stateMapping,
    settings,
    diagnostics,
  ];

  static PanelDestination? fromWire(String? raw) {
    for (final PanelDestination d in all) {
      if (d.wireName == raw) return d;
    }
    return null;
  }
}

/// 桌宠主页（返回桌宠，不是某个页签）。
final class PanelPetHome extends PanelDestination {
  const PanelPetHome();
  @override
  String get wireName => 'pet_home';
}

/// 本机使用统计页。
final class PanelLocalUsage extends PanelDestination {
  const PanelLocalUsage();
  @override
  String get wireName => 'local_usage';
}

/// 云端使用统计页。
final class PanelCloudUsage extends PanelDestination {
  const PanelCloudUsage();
  @override
  String get wireName => 'cloud_usage';
}

/// 时间线。
final class PanelTimeline extends PanelDestination {
  const PanelTimeline();
  @override
  String get wireName => 'timeline';
}

/// 账户与同步页。
final class PanelAccountSync extends PanelDestination {
  const PanelAccountSync();
  @override
  String get wireName => 'account_sync';
}

/// 素材库页。
final class PanelAssetLibrary extends PanelDestination {
  const PanelAssetLibrary();
  @override
  String get wireName => 'asset_library';
}

/// 状态素材映射编辑器。
final class PanelStateMapping extends PanelDestination {
  const PanelStateMapping();
  @override
  String get wireName => 'state_mapping';
}

/// 设置页。
final class PanelSettings extends PanelDestination {
  const PanelSettings();
  @override
  String get wireName => 'settings';
}

/// 诊断与日志页。
final class PanelDiagnostics extends PanelDestination {
  const PanelDiagnostics();
  @override
  String get wireName => 'diagnostics';
}

/// 一次菜单动作的执行结果。
///
/// [reason] 是给开发/诊断看的明确原因（不支持的平台能力必须写清楚**为什么**），
/// [message] 是给用户看的中文说明。
///
/// 增量 C2（§3.3）：**导航**不再用 `bool` 表达，而是带上强类型的 [navigation]
/// 目的地；`closeMenu` 也不再与"成功"混为一谈。
class MenuExecutionResult {
  const MenuExecutionResult(
    this.status, {
    this.message,
    this.reason,
    this.actionId,
    this.navigation,
    this.closeMenu = false,
  });

  const MenuExecutionResult.success(
    [String? message, String? actionId, PanelDestination? navigation]
  )   : this(
          MenuExecutionStatus.success,
          message: message,
          actionId: actionId,
          navigation: navigation,
          closeMenu: navigation != null,
        );

  const MenuExecutionResult.running([String? message, String? actionId])
      : this(MenuExecutionStatus.running, message: message, actionId: actionId);

  const MenuExecutionResult.unavailable(String reason, {String? actionId})
      : this(MenuExecutionStatus.unavailable, reason: reason, actionId: actionId);

  const MenuExecutionResult.requiresLogin(
    String reason, {
    String? actionId,
    PanelDestination? navigation,
  }) : this(
          MenuExecutionStatus.requiresLogin,
          reason: reason,
          actionId: actionId,
          navigation: navigation,
        );

  const MenuExecutionResult.requiresPermission(String reason, {String? actionId})
      : this(MenuExecutionStatus.requiresPermission, reason: reason, actionId: actionId);

  const MenuExecutionResult.failed(String reason, {String? actionId})
      : this(MenuExecutionStatus.failed, reason: reason, actionId: actionId);

  final MenuExecutionStatus status;
  final String? message;

  /// 明确的失败/不支持原因（绝不写笼统的"不支持"）。
  final String? reason;

  /// 触发本次执行的动作 id（诊断用）。
  final String? actionId;

  /// 本次动作要求跳转的控制面板目的地（§12.1）；非导航动作一律为 `null`。
  final PanelDestination? navigation;

  /// 本次动作完成后是否应当收起轮盘（导航 / 隐藏 / 退出等）。
  final bool closeMenu;

  bool get isSuccess => status == MenuExecutionStatus.success;

  Map<String, Object?> toMap() => <String, Object?>{
        'status': status.wireName,
        if (message != null) 'message': message,
        if (reason != null) 'reason': reason,
        if (actionId != null) 'actionId': actionId,
        if (navigation != null) 'navigation': navigation!.wireName,
        if (closeMenu) 'closeMenu': true,
      };

  @override
  String toString() => 'MenuExecutionResult(${status.wireName}'
      '${actionId == null ? '' : ', $actionId'}'
      '${navigation == null ? '' : ', nav=${navigation!.wireName}'}'
      '${reason == null ? '' : ', $reason'})';
}
