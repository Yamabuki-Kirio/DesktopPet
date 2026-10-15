import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../activity_tracking/activity_state_mapper.dart';
import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/models/state_mapping.dart';
import '../../core/error_handler.dart';
import '../../core/logger.dart';
import '../../core/paths.dart';
import '../../navigation/app_navigation.dart';
import '../../platform/android/android_overlay_menu_bridge.dart';
import '../../platform/overlay_state_mapping.dart';
import '../../state_engine/state_snapshot.dart';
import '../../state_engine/system_state.dart';
import '../library_controller.dart';
import '../overlay_menu_actions.dart';
import '../overlay_pet_controller.dart';
import '../pages/account_sync_page.dart';
import '../pages/asset_library_page.dart';
import '../pages/settings_page.dart';
import '../pages/state_asset_mapping_page.dart';
import '../pages/usage_stats_page.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_nav.dart';
import '../widgets/petlife/petlife_page.dart';
import 'mobile_home_page.dart';
import 'root_pages.dart';

/// Android 外壳：统一的二次元卡片式控制面板 + 底部导航。
///
/// 视觉（本轮增量）：P3P 图形语言 + Animeko 信息层级 + Kazumi 卡片布局；
/// 白底为主色、P3P 粉为强调色；**所有颜色都来自统一主题对象**，
/// 页面里不允许硬编码粉色。
///
/// 业务上与本轮改造前完全一致：
/// * 五个根入口与既有路由不变：桌宠 / 使用统计 / 账户与同步 / 素材库 / 设置；
/// * 启动顺序不变：恢复角色 → 启动渲染 → 采集 → 同步；
/// * 所有业务控制器、服务与数据模型继续复用，没有为了新界面重写任何逻辑。
class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.services});

  final AppServices services;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  AppServices get _s => widget.services;

  int _index = 0;
  late final LibraryController _library;

  /// Android 悬浮桌宠协调器。仅当平台具备该能力时创建。
  OverlayPetController? _overlay;

  /// 应用级跳转请求控制器（轮盘菜单 → 页面）。
  ///
  /// 外壳只**订阅**它，绝不把自己的下标暴露给调用方；页面未就绪时请求留在
  /// 控制器里，等外壳起来后再消费。
  late final AppNavigationController _navigation;
  StreamSubscription<AppDestination>? _navigationSub;

  /// 使用统计页的 Key：`records_cloud` 要切到该页的云端子页。
  final GlobalKey<UsageStatsPageState> _usageStatsKey =
      GlobalKey<UsageStatsPageState>();

  /// 原生轮盘菜单的待处理请求消费者。仅 Android 创建。
  OverlayMenuRequestConsumer? _menuConsumer;

  @override
  void initState() {
    super.initState();
    _library = LibraryController(
      repository: _s.repository,
      ownerId: _s.ownerId,
      // 激活角色必须真正切换状态引擎并持久化，因此控制器直接拿到这两个依赖。
      stateEngine: _s.stateEngine,
      settings: _s.settings,
    )..onLibraryMutated = () async {
        // 素材/映射变化后重新解析当前状态；角色切换由 activateCharacter 负责。
        await _s.stateEngine.refresh();
      };
    _library.addListener(_onLibraryChanged);
    unawaited(_library.load());
    _setupOverlay();
    _setupNavigation();
    _setupMenuActions();
    unawaited(_bootstrap());
  }

  /// 订阅跳转请求。`AppDestination` 的语义与桌面外壳相同，
  /// 但**不共享任何 widget 状态**。
  void _setupNavigation() {
    _navigation = AppNavigationController();
    _navigationSub =
        _navigation.requests.listen((AppDestination _) => _drainNavigation());
  }

  /// 原生轮盘菜单 → 页面/动作。
  ///
  /// 只在具备系统级悬浮桌宠能力的平台装配（即 Android）：
  /// 其它平台根本没有这条原生通道，装配了只会得到"通道不存在"的日志噪音。
  void _setupMenuActions() {
    if (!_s.platform.capabilities.supportsFloatingPet) return;
    final OverlayMenuActionExecutor executor = OverlayMenuActionExecutor(
      snapshots: _s.stateEngineSnapshot,
      stateEngine: _s.stateEngine,
      listRenderableAssets: _s.repository.listRenderableAssets,
      settings: _s.settings,
      navigation: _navigation,
      // 「今日时长」必须与「使用统计（本机）」页同一个来源/口径：
      // 直接复用统计页用的 UsageAnalyticsService，而不是 Dart 采集器的
      // ActivityTracker.todayActiveSeconds（Android 上那是另一条来源）。
      usageAnalytics: _s.usageAnalytics,
      trackingSettings: () => _s.activityTracker.settings,
      saveTrackingSettings: _s.saveTrackingSettings,
      isSignedIn: () => _s.authenticatedApi.isSignedIn,
      syncStatus: () => _s.syncEngine.status,
      syncPendingCount: () => _s.syncEngine.pendingCount,
      syncLastSuccessAt: () => _s.syncEngine.lastSuccessAt,
      syncLastError: () => _s.syncEngine.lastError,
      syncNow: () => _s.syncEngine.syncNow(manual: true),
      // 懒取而不是注入实例：控制器与素材库控制器都属于本 State，
      // 随 State 释放；执行时现取现用，绝不会用到已 dispose 的对象。
      overlay: () => _overlay,
      library: () => _library,
    );
    _menuConsumer = OverlayMenuRequestConsumer(
      bridge: AndroidOverlayMenuBridge(),
      executor: executor,
      ledger: SqliteMenuRequestLedger(database: _s.database, ownerId: _s.ownerId),
    )..start();
  }

  /// 消费跳转请求：逐个应用，直到队列清空。
  void _drainNavigation() {
    if (!mounted) return;
    while (_navigation.hasPending) {
      final AppDestination? destination = _navigation.take();
      if (destination == null) break;
      _applyDestination(destination);
    }
  }

  void _applyDestination(AppDestination destination) {
    switch (destination) {
      case AppDestination.assetLibrary:
        setState(() => _index = 3);
      case AppDestination.localStatistics:
        setState(() => _index = 1);
      case AppDestination.accountSync:
        setState(() => _index = 2);
      case AppDestination.overlaySettings:
        setState(() => _index = 4);
      case AppDestination.cloudStatistics:
        setState(() => _index = 1);
        // 子页切换复用使用统计页自己的 `_selectTab`（含持久化）。
        // 放在帧后执行：本帧页面可能还没建好（Key 尚未绑定 State）。
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted) _usageStatsKey.currentState?.showCloudTab();
        });
      case AppDestination.stateAssetMapping:
        _openStateAssetMapping();
    }
  }

  /// 打开**当前角色**的状态素材映射编辑器。
  void _openStateAssetMapping() {
    final String? characterId = _s.stateEngineSnapshot.value.currentCharacter?.id;
    if (characterId == null) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => StateAssetMappingPage(
            library: _library,
            characterId: characterId,
            overlay: _overlay,
          ),
        ),
      ),
    );
  }

  /// 建立"状态引擎 → 原生悬浮窗"的联动。
  ///
  /// attach() 会立刻同步一次，因此**应用重启后**（悬浮服务仍在运行时）
  /// 也能把当前角色/素材推回原生层。
  void _setupOverlay() {
    if (!_s.platform.capabilities.supportsFloatingPet) return;
    _overlay = OverlayPetController(
      overlay: _s.platform.overlayPet,
      snapshots: _s.stateEngineSnapshot,
      // 原生侧只允许加载这个目录下的文件，因此这里给它同一个根。
      privateAssetsRoot: () => AppPaths.instance.assetsRoot.path,
      // 状态 → 素材快照由**数据库**读出来交给原生，
      // 这样 Flutter 退出后前台服务仍能按它继续联动。
      stateMappingLoader: _loadStateMapping,
    )..attach();
  }

  /// 读取当前角色的可用素材与状态映射，构建原生用的只读快照。
  ///
  /// 走的是**已有**的 `FallbackChain`（`buildOverlayStateMapping` 内部复用），
  /// 不新写一套映射规则。
  Future<OverlayStateMapping?> _loadStateMapping(
    StateSnapshot snapshot,
    int revision,
  ) async {
    final CharacterModel? character = snapshot.currentCharacter;
    if (character == null) return null;
    final List<EmotionAsset> assets =
        await _s.repository.listRenderableAssets(character.id);
    final List<StateMapping> mappings =
        await _s.repository.listMappings(character.id);
    return buildOverlayStateMapping(
      character: character,
      renderableAssets: assets,
      mappings: mappings,
      revision: revision,
      // 规则与开关随快照一起下发（原生不需要另存一份规则）。
      automaticStateEnabled: _s.settings.settings.overlayAutomaticState,
      defaultStateKey: SystemState.defaultState.wireName,
      categoryStateRules: ActivityStateMapper.categoryStateRules,
    );
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // 注销原生 → Dart 处理器，避免它持有即将释放的 State / 控制器。
    _menuConsumer?.dispose();
    _menuConsumer = null;
    unawaited(_navigationSub?.cancel());
    _navigationSub = null;
    _navigation.dispose();
    _overlay?.detach();
    _overlay?.dispose();
    _library.removeListener(_onLibraryChanged);
    _library.dispose();
    super.dispose();
  }

  /// 启动装配（与桌面外壳同序：先渲染，再采集，最后同步）。
  ///
  /// 全部包在 try 里：任何一步失败都不应让应用停在白屏上 ——
  /// 桌宠与本地统计是本地能力，必须始终可用。
  Future<void> _bootstrap() async {
    try {
      final String? lastCharacter = _s.settings.settings.lastCharacterId;
      final String? defaultCharacter = _s.settings.settings.defaultCharacterId;
      final String? characterId = lastCharacter ?? defaultCharacter;
      if (characterId != null) {
        await _s.stateEngine.start(ownerId: _s.ownerId, characterId: characterId);
        final String? manualAsset = _s.settings.settings.manualAssetId;
        if (manualAsset != null) {
          await _s.stateEngine.lockManual(
            assetId: manualAsset,
            reason: '恢复上次的 manual 锁定',
          );
        }
      } else {
        Loggers.app.info('尚无角色配置，等待用户导入素材');
      }

      await _s.presenter.start();
      await _s.startActivityTracking();
      await _s.startSync();
    } catch (e, st) {
      ErrorHandler.record('MobileShell.bootstrap', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool collecting = _s.platform.capabilities.supportsSystemActivityTracking;
    final PetLifePalette p = PetLifeTheme.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 状态栏与导航栏颜色跟随主题（需求 §2.1）。
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            p.isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: p.isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: p.surface,
        systemNavigationBarIconBrightness:
            p.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: p.divider,
      ),
      child: Scaffold(
        backgroundColor: p.surface,
        body: SafeArea(
          bottom: false,
          child: PetLifePageSwitcher(
            index: _index,
            children: <Widget>[
              MobileHomePage(
                services: _s,
                library: _library,
                overlay: _overlay,
                onOpenLibrary: () => _go(3),
              ),
              UsageStatsPage(
                key: _usageStatsKey,
                services: _s,
                // 云端统计未登录时"去登录" → 切到「账户与同步」
                onOpenAccount: () => _go(2),
                overlay: _overlay,
                showActivityQualifier: !collecting,
              ),
              AccountSyncPage(services: _s),
              AssetLibraryPage(
                ownerId: _s.ownerId,
                importer: _s.importer,
                fileImportProvider: _s.fileImportProvider,
                library: _library,
                // 设为当前桌宠角色成功后立刻切回"桌宠"页，让用户马上看到效果。
                onActivated: () => _go(0),
                overlay: _overlay,
              ),
              SettingsPage(
                services: _s,
                overlay: _overlay,
                library: _library,
                onOpenAccount: () => _go(2),
              ),
            ],
          ),
        ),
        bottomNavigationBar: PetLifeBottomNav(
          selectedIndex: _index,
          onSelected: _go,
          // 五个根入口的唯一真相在 root_pages.dart（导航测试直接断言它）。
          destinations: kPetLifeRootDestinations,
        ),
      ),
    );
  }

  void _go(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }
}
