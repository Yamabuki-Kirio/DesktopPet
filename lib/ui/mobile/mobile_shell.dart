import 'dart:async';

import 'package:flutter/material.dart';

import '../../activity_tracking/activity_state_mapper.dart';
import '../../activity_tracking/activity_tracker.dart';
import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/models/state_mapping.dart';
import '../../core/error_handler.dart';
import '../../core/logger.dart';
import '../../core/paths.dart';
import '../../navigation/app_navigation.dart';
import '../../platform/android/android_overlay_menu_bridge.dart';
import '../../platform/overlay_pet.dart';
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
import '../pet/pet_view.dart';
import 'mobile_platform_notice.dart';

/// Android 外壳（Phase 4A）：普通 Material 应用 + 底部导航。
///
/// 与桌面外壳的区别（需求「Phase 4A 第 5 项」）：
/// * 没有桌宠窗口、没有托盘、没有鼠标穿透 —— 那些是 Windows 专属；
/// * 页面用底部导航切换：桌宠 / 使用统计 / 账户与同步 / 素材库 / 设置；
/// * **不申请任何权限**：Phase 4A 不采集应用使用时长，
///   因此"使用情况访问权限"完全不需要（Phase 4B 才引入）。
///
/// 启动顺序与桌面保持一致：恢复角色 → 启动渲染 → 采集（本阶段为不可用）→ 同步。
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

  /// Android 悬浮桌宠协调器（Phase 4C）。仅当平台具备该能力时创建。
  OverlayPetController? _overlay;

  /// 应用级跳转请求控制器（Phase 4C-6B-2：轮盘菜单 → 页面）。
  ///
  /// 外壳只**订阅**它，绝不把自己的下标暴露给调用方；页面未就绪时请求留在
  /// 控制器里，等外壳起来后再消费。
  late final AppNavigationController _navigation;
  StreamSubscription<AppDestination>? _navigationSub;

  /// 使用统计页的 Key：`records_cloud` 要切到该页的云端子页。
  final GlobalKey<UsageStatsPageState> _usageStatsKey =
      GlobalKey<UsageStatsPageState>();

  /// 原生轮盘菜单的待处理请求消费者（Phase 4C-6B-2）。仅 Android 创建。
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

  /// 订阅跳转请求。`AppDestination` 的语义与桌面外壳相同（若桌面需要，
  /// 映射到它自己的面板即可），但**不共享任何 widget 状态**。
  void _setupNavigation() {
    _navigation = AppNavigationController();
    _navigationSub = _navigation.requests.listen((AppDestination _) => _drainNavigation());
  }

  /// 原生轮盘菜单 → 页面/动作（Phase 4C-6B-2）。
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

  /// 建立"状态引擎 → 原生悬浮窗"的联动（Phase 4C-2）。
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
      // Phase 4C-5：状态 → 素材快照由**数据库**读出来交给原生，
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
      // Phase 4C-6A：规则与开关随快照一起下发（原生不需要另存一份规则）。
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

      // 采集：Phase 4A 的 Android 平台提供者是"不可用"实现，
      // 采集器据此不会驱动桌宠状态，也绝不会申请权限。
      await _s.startActivityTracking();

      // 同步：未登录时引擎停在 signedOut，不做任何网络请求。
      await _s.startSync();
    } catch (e, st) {
      ErrorHandler.record('MobileShell.bootstrap', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool collecting = _s.platform.capabilities.supportsSystemActivityTracking;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: <Widget>[
            _MobilePetPage(
              services: _s,
              // 4C-6A：桌宠状态在 Android 上由**原生**决定，页面显示原生真值。
              overlay: _overlay,
              onOpenLibrary: () => setState(() => _index = 3),
            ),
            UsageStatsPage(
              key: _usageStatsKey,
              services: _s,
              // 云端统计未登录时"去登录" → 切到「账户与同步」
              onOpenAccount: () => setState(() => _index = 2),
              overlay: _overlay,
            ),
            AccountSyncPage(services: _s),
            AssetLibraryPage(
              ownerId: _s.ownerId,
              importer: _s.importer,
              fileImportProvider: _s.fileImportProvider,
              library: _library,
              // 设为当前桌宠角色成功后立刻切回"桌宠"页，让用户马上看到效果。
              onActivated: () => setState(() => _index = 0),
              // Phase 4C-6A.1：状态映射编辑器的「预览」要用到悬浮控制器。
              overlay: _overlay,
            ),
            SettingsPage(services: _s, overlay: _overlay, library: _library),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int i) => setState(() => _index = i),
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: const Icon(Icons.pets_outlined),
            selectedIcon: const Icon(Icons.pets),
            label: '桌宠',
          ),
          NavigationDestination(
            icon: const Icon(Icons.bar_chart_outlined),
            selectedIcon: const Icon(Icons.bar_chart),
            // 采集能力未启用时明确标注"（本机）"，避免与服务器汇总混淆。
            label: collecting ? '使用统计' : '使用统计（本机）',
          ),
          const NavigationDestination(
            icon: Icon(Icons.sync_outlined),
            selectedIcon: Icon(Icons.sync),
            label: '账户与同步',
          ),
          const NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '素材库',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 应用内桌宠页（Phase 4A 只做展示；系统悬浮窗属于 Phase 4D）。
class _MobilePetPage extends StatelessWidget {
  const _MobilePetPage({
    required this.services,
    required this.onOpenLibrary,
    this.overlay,
  });

  final AppServices services;
  final VoidCallback onOpenLibrary;

  /// Android 悬浮桌宠协调器（4C-6A）：桌宠状态由原生决定，这里只读它显示。
  final OverlayPetController? overlay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: overlay == null
          ? services.settings
          : Listenable.merge(<Listenable>[services.settings, overlay!]),
      builder: (BuildContext context, Widget? _) {
        // 直接监听状态引擎快照：角色被"设为当前桌宠角色"后，桌宠必须立即重建，
        // 不能等用户切页、重开页面或重启应用（对应缺陷：激活后仍显示旧角色）。
        return ValueListenableBuilder<StateSnapshot>(
          valueListenable: services.stateEngineSnapshot,
          builder: (BuildContext context, StateSnapshot snapshot, Widget? __) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                SizedBox(
                  height: 320,
                  child: Center(
                    // 复用同一套渲染组件；Android 只把它放进应用页面里，
                    // 不操作任何原生窗口（manageWindowSize: false）。
                    // 素材由 PetPresenter 按最新 snapshot 驱动，这里不缓存任何角色/素材。
                    child: PetView(
                      renderer: services.renderer,
                      scale: services.settings.settings.scale,
                      smoothScaling: services.settings.settings.smoothScaling,
                      opacity: services.settings.settings.opacity,
                      lockPosition: true,
                      manageWindowSize: false,
                      onDoubleTap: onOpenLibrary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _statusCard(context, snapshot),
                const SizedBox(height: 12),
                MobilePlatformNotice(
                  collecting:
                      services.platform.capabilities.supportsSystemActivityTracking,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _statusCard(BuildContext context, StateSnapshot snapshot) {
    final tracker = services.activityTracker;
    final AppServices s = services;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('当前状态',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            // Android：桌宠状态由**原生**悬浮服务决定（显示原生真值），
            // Flutter 状态引擎在该平台不会被前台事件驱动 —— 读它只会永远显示"默认"。
            _kv('桌宠状态', _petStateLabel(snapshot)),
            _kv('当前角色', snapshot.currentCharacter?.displayName ?? '未选择'),
            _kv('当前应用', _currentAppLabel(tracker)),
            _kv('今日活跃', '${tracker.todayActiveSeconds} 秒'),
            _kv('同步状态', s.syncEngine.status.labelZh),
            _kv('待同步', '${s.syncEngine.pendingCount} 条'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: onOpenLibrary,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                  label: const Text('导入素材'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await s.saveTrackingSettings(
                      tracker.settings.copyWith(paused: !tracker.isPaused),
                    );
                  },
                  icon: Icon(tracker.isPaused ? Icons.play_arrow : Icons.pause, size: 16),
                  label: Text(tracker.isPaused ? '恢复记录' : '暂停记录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 桌宠状态：Android 读**原生**真值（与设置页 / 统计页同源），其它平台读状态引擎。
  String _petStateLabel(StateSnapshot snapshot) {
    final OverlayStateDiagnostics? d = overlay?.stateDiagnostics;
    if (d != null && d.stateId.isNotEmpty) {
      return '${d.stateLabel}（${d.stateId}）';
    }
    return snapshot.state.descriptionZh;
  }

  /// 当前应用：Android 读原生共享快照（与统计页显示的是同一份，不会两页不一致）。
  String _currentAppLabel(ActivityTracker tracker) {
    final String? label = overlay?.stateDiagnostics.foregroundAppLabel;
    if (label != null && label.isNotEmpty) return label;
    return tracker.currentAppDisplayName ?? '—';
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 76,
              child: Text(key,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
}
