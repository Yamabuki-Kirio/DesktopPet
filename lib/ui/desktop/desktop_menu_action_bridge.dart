/// **Windows 轮盘的业务动作桥**（增量 C1 建立，增量 **C2** 收敛为唯一业务通道）。
///
/// 设计要点（需求 §一 / §三：「不复制素材库、收藏或状态映射逻辑」）
/// ----------------------------------------------------------
/// Android 已经有一份**完整的**业务动作实现：`OverlayMenuActionExecutor`
/// （素材上一个 / 下一个、自动形象、收藏、状态映射、素材库、今日时长、
/// 本机 / 云端统计、暂停采集、立即同步、同步状态、完整设置……），
/// 它复用 `StateEngine` / `SettingsController` / `AppNavigationController` /
/// `LibraryController` / `UsageAnalyticsService` / `SyncEngine`。
///
/// Windows 这边**再写一份**必然出现"两端行为不一致"，而且正是用户明确禁止的。
/// 因此本文件只做三件事：
///
/// 1. 用 Windows 的 [AppServices] 装配**同一个** `OverlayMenuActionExecutor`；
/// 2. 把它的 [MenuActionResult] 翻译成轮盘的 [MenuExecutionResult]，
///    并**在翻译层做登录门控与强类型导航**（需求 §3.3 / §8.1 / §12.1）；
/// 3. 页面跳转沿用同一套 [AppNavigationController]：Windows 外壳订阅目的地，
///    打开控制面板并切到对应页（与 Android 切底部 tab 等价）。
library;

import '../../app/app_scope.dart';
import '../../menu/menu_contract.dart';
import '../../menu/wheel_geometry_ownership.dart' show wheelGeometryJournal;
import '../../navigation/app_navigation.dart';
import '../../sync/models/sync_models.dart' show SyncStatus;
import '../library_controller.dart';
import '../overlay_menu_actions.dart';

/// Windows 侧的目的地处理（由外壳注入：打开控制面板并切页）。
typedef DesktopDestinationHandler = Future<void> Function(
  PanelDestination destination,
);

class DesktopMenuActionBridge {
  DesktopMenuActionBridge({
    required AppServices services,
    required DesktopDestinationHandler onDestination,
  })  : _services = services,
        _onDestination = onDestination {
    _navigation.requests.listen(_drain);
  }

  final AppServices _services;
  final DesktopDestinationHandler _onDestination;

  /// 与 Android **同一个**导航契约。
  final AppNavigationController _navigation = AppNavigationController();

  LibraryController? _library;

  AppServices get _s => _services;

  /// **哪些动作必须先登录**（需求 §8.1「请先登录」/ §7.3「未登录 → 转到账户与同步」）。
  ///
  /// 只有"立即同步"是硬门槛：云端统计页自己会在未登录时提供"去登录"入口，
  /// 因此 `records_cloud` 仍然放行（导航过去由页面引导）。
  static const Set<String> loginRequiredActions = <String>{'records_sync'};

  /// actionId → 强类型目的地（与 canonical 执行器里的 `_navigate(...)` **一一对应**）。
  ///
  /// 这里只做**声明**：真正的跳转请求由 canonical 执行器发出（`_navigation.request`），
  /// 本表用于把"这一次动作要求去哪里"如实带进 [MenuExecutionResult.navigation]，
  /// 让**日志与测试**都能对账（需求 §14 `wheel.navigation.begin/ready`）。
  static const Map<String, PanelDestination> destinations =
      <String, PanelDestination>{
    'appearance_library': PanelDestination.assetLibrary,
    'appearance_mapping': PanelDestination.stateMapping,
    'records_stats': PanelDestination.localUsage,
    'records_cloud': PanelDestination.cloudUsage,
    'settings_open': PanelDestination.settings,
  };

  /// `AppDestination` → 强类型目的地的**唯一映射**（外壳边界的适配点）。
  static PanelDestination? mapAppDestination(AppDestination destination) {
    return switch (destination) {
      AppDestination.assetLibrary => PanelDestination.assetLibrary,
      AppDestination.stateAssetMapping => PanelDestination.stateMapping,
      AppDestination.localStatistics => PanelDestination.localUsage,
      AppDestination.cloudStatistics => PanelDestination.cloudUsage,
      AppDestination.accountSync => PanelDestination.accountSync,
      AppDestination.overlaySettings => PanelDestination.settings,
    };
  }

  /// 与 `mobile_shell` 逐字一致的装配（只是换成本平台的 services 实例）。
  late final OverlayMenuActionExecutor _executor = OverlayMenuActionExecutor(
    snapshots: _s.stateEngineSnapshot,
    stateEngine: _s.stateEngine,
    listRenderableAssets: _s.repository.listRenderableAssets,
    settings: _s.settings,
    navigation: _navigation,
    usageAnalytics: _s.usageAnalytics,
    trackingSettings: () => _s.activityTracker.settings,
    saveTrackingSettings: _s.saveTrackingSettings,
    isSignedIn: () => _s.authenticatedApi.isSignedIn,
    syncStatus: () => _s.syncEngine.status,
    syncPendingCount: () => _s.syncEngine.pendingCount,
    syncLastSuccessAt: () => _s.syncEngine.lastSuccessAt,
    syncLastError: () => _s.syncEngine.lastError,
    syncNow: () => _s.syncEngine.syncNow(manual: true),
    // Windows 没有 Android 的悬浮桌宠控制器；素材库控制器懒建（随首次使用）。
    overlay: () => null,
    library: () => _library ??= LibraryController(
      repository: _s.repository,
      ownerId: _s.ownerId,
      stateEngine: _s.stateEngine,
      settings: _s.settings,
    ),
  );

  /// 执行一个业务动作 id（已是 canonical id）。
  ///
  /// 结果翻译：
  /// * 未登录的登录门槛动作 → `requiresLogin` + 导航到「账户与同步」；
  /// * `completed → success`（并带上强类型目的地）；
  /// * 其余一律 `failed` 并把**执行器给出的中文原因**原样带出
  ///   （绝不改写成笼统文案）。
  /// 「立即同步」的 canonical id。
  static const String syncActionId = 'records_sync';

  Future<MenuExecutionResult> run(String actionId) async {
    final PanelDestination? navigation = destinations[actionId];

    // --- 登录门控（需求 §8.1「请先登录」）---
    if (loginRequiredActions.contains(actionId) &&
        !_s.authenticatedApi.isSignedIn) {
      return MenuExecutionResult.requiresLogin(
        '请先登录',
        actionId: actionId,
        navigation: PanelDestination.accountSync,
      );
    }

    // --- 「立即同步」：Windows 侧按 §8.1 合成"上传 / 下载摘要"---
    //
    // 同步**本身**仍然由 canonical 执行器跑（`SyncEngine.syncNow`，
    // 内部单任务互斥）；这里只把**引擎自己的状态与摘要**翻译成用户文案 —
    // 因此不存在第二份同步实现，也不改动共享执行器的任何行为。
    if (actionId == syncActionId) {
      return _runSync(navigation);
    }

    final MenuActionResult result = await _executor.execute(
      actionId,
      const <String, Object?>{},
    );
    // 用线上取值比较，避免把 Android 的枚举类型拖进桌面层。
    final bool completed = result.status.wireName == 'completed';
    return completed
        ? MenuExecutionResult.success(result.message, actionId, navigation)
        : MenuExecutionResult.failed(result.message ?? '$actionId 执行失败', actionId: actionId);
  }

  /// 需求 §8.1：把**同步引擎自己的状态 + 摘要**翻译成用户文案。
  ///
  /// 刻意做成**纯函数**：文案规则可以单独单测，不需要启动 AppServices / 网络。
  /// 注意这里**没有**第二份同步实现 —— 同步本身仍然由 `SyncEngine` 跑。
  static String syncFeedbackMessage(SyncStatus status, String summary) =>
      switch (status) {
        SyncStatus.success =>
          summary == '没有需要同步的数据' ? summary : '同步完成：$summary',
        SyncStatus.syncing => '同步正在进行',
        SyncStatus.waitingForNetwork => '当前离线，记录已保留',
        SyncStatus.needsReauthentication => '登录已失效，请重新登录',
        SyncStatus.signedOut => '请先登录',
        SyncStatus.idle || SyncStatus.failed => '同步失败，可稍后重试',
      };

  /// 「立即同步」的 Windows 侧结果合成（需求 §8.1 / §8.2 / §14）。
  Future<MenuExecutionResult> _runSync(PanelDestination? navigation) async {
    // §8.2：连续点击只产生**一个**同步任务；第二次点击如实回报"同步正在进行"。
    if (_s.syncEngine.isSyncing) {
      wheelGeometryJournal.record(
        'wheel.sync.begin',
        fields: <String, Object?>{'trigger': 'wheel_menu', 'reused': true},
      );
      return MenuExecutionResult.success('同步正在进行', syncActionId);
    }

    wheelGeometryJournal.record(
      'wheel.sync.begin',
      fields: <String, Object?>{
        'trigger': 'wheel_menu',
        'pending': _s.syncEngine.pendingCount,
      },
    );

    // 真正的同步（引擎内部互斥：并发调用复用同一个任务）。
    await _executor.execute(syncActionId, const <String, Object?>{});

    final SyncStatus status = _s.syncEngine.status;
    final int uploaded = _s.syncEngine.lastUploadedCount;
    final int downloaded = _s.syncEngine.lastDownloadedCount;
    final String summary = _s.syncEngine.lastRunSummary;

    final String message = syncFeedbackMessage(status, summary);

    wheelGeometryJournal.record(
      'wheel.sync.summary',
      fields: <String, Object?>{
        'status': status.name,
        'uploaded': uploaded,
        'downloaded': downloaded,
        'message': message,
        'pending': _s.syncEngine.pendingCount,
      },
    );

    return switch (status) {
      SyncStatus.success || SyncStatus.syncing =>
        MenuExecutionResult.success(message, syncActionId, navigation),
      SyncStatus.signedOut => MenuExecutionResult.requiresLogin(
          message,
          actionId: syncActionId,
          navigation: PanelDestination.accountSync,
        ),
      _ => MenuExecutionResult.failed(message, actionId: syncActionId),
    };
  }

  /// 消费跳转请求（逐个应用，直到队列清空）。
  void _drain(AppDestination destination) {
    final PanelDestination? mapped = mapAppDestination(destination);
    if (mapped == null) return;
    // 立即应用；失败只记录不抛（菜单已经关掉了，不能让异常冒到 UI）。
    _onDestination(mapped).catchError((Object _) {});
  }

  void dispose() {
    _library?.dispose();
    _library = null;
    _navigation.dispose();
  }
}
