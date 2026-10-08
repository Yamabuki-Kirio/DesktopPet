import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../activity_tracking/activity_segment_service.dart';
import '../activity_tracking/activity_state_mapper.dart';
import '../activity_tracking/activity_tracker.dart';
import '../activity_tracking/android_usage_import_service.dart';
import '../activity_tracking/application_repository.dart';
import '../activity_tracking/current_activity_provider.dart';
import '../activity_tracking/foreground_app_provider.dart';
import '../activity_tracking/idle_detector.dart';
import '../activity_tracking/models/tracking_settings.dart';
import '../activity_tracking/session_state_provider.dart';
import '../activity_tracking/usage_analytics_service.dart';
import '../asset_decoder/asset_decoder.dart';
import '../asset_decoder/asset_validator.dart';
import '../asset_decoder/flutter_asset_decoder.dart';
import '../asset_import/asset_importer.dart';
import '../asset_import/default_asset_importer.dart';
import '../asset_import/import_router.dart';
import '../asset_import/zip_asset_importer.dart';
import '../character/character_repository.dart';
import '../character/pet_renderer.dart';
import '../character/sqlite_character_repository.dart';
import '../core/constants.dart';
import '../core/error_handler.dart';
import '../core/ids.dart';
import '../core/logger.dart';
import '../core/paths.dart';
import '../database/app_database.dart';
import '../database/dao/account_session_dao.dart';
import '../database/dao/activity_checkpoint_dao.dart';
import '../database/dao/activity_dao.dart';
import '../database/dao/application_dao.dart';
import '../database/dao/cloud_statistics_cache_dao.dart';
import '../database/dao/daily_usage_dao.dart';
import '../database/dao/sync_outbox_dao.dart';
import '../database/dao/sync_state_dao.dart';
import '../database/dao/tracking_settings_dao.dart';
import '../desktop_window/tray_host.dart';
import '../desktop_window/window_controller.dart';
import '../diagnostics/perf_sampler.dart';
import '../menu/fixed_canvas_geometry.dart' show fixedCanvasAnchor;
import '../menu/wheel_geometry_ownership.dart' show wheelGeometryJournal;
import '../menu/windows_surface_mode.dart' show WindowsSurfaceMode, windowsSurfaceSession;
import '../platform/file_import_provider.dart';
import '../platform/platform_services.dart';
import '../settings/settings_controller.dart';
import '../settings/settings_repository.dart';
import '../settings/sqlite_settings_repository.dart';
import '../settings/startup_registration_service.dart';
import '../state_engine/default_state_engine.dart';
import '../state_engine/state_debouncer.dart';
import '../state_engine/state_engine.dart';
import '../state_engine/state_snapshot.dart';
import '../sync/authenticated_api.dart';
import '../sync/cloud_statistics_cache.dart';
import '../sync/cloud_statistics_controller.dart';
import '../sync/cloud_statistics_repository.dart';
import '../sync/credential_store.dart';
import '../sync/device_identity.dart';
import '../sync/outbox_change_sink.dart';
import '../sync/outbox_producer.dart';
import '../sync/proxy/proxy_controller.dart';
import '../sync/proxy/proxy_models.dart';
import '../sync/proxy/proxy_resolver.dart';
import '../sync/proxy/system_proxy.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_preferences.dart';
import '../ui/pet/pet_frame_controller.dart';
import '../ui/pet/pet_host.dart';
import '../ui/pet/pet_presenter.dart';

/// 应用级依赖容器。
///
/// Phase 4A：所有平台专属能力都来自 [PlatformServices]（见 `lib/platform/`），
/// 本文件**不再 import 任何 Windows 专属实现**（win32 / window_manager /
/// tray_manager / FFI 凭据 / FFI 进程指标），因此同一份装配代码在
/// Windows 与 Android 上都能跑，差异只在平台层。
class AppServices {
  AppServices._({
    required this.platform,
    required this.ownerId,
    required this.database,
    required this.repository,
    required this.validator,
    required this.decoder,
    required this.importer,
    required this.settingsRepository,
    required this.settings,
    required this.startupRegistration,
    required this.windowController,
    required this.stateEngine,
    required this.renderer,
    required this.presenter,
    required this.trayHost,
    required this.petHost,
    required this.perfSampler,
    required this.applications,
    required this.activitySegments,
    required this.activityTracker,
    required this.currentActivity,
    required this.usageAnalytics,
    required this.trackingSettingsDao,
    required this.trackingDeviceLocalId,
    required this.androidUsageImport,
    required this.authenticatedApi,
    required this.syncEngine,
    required this.syncOutboxDao,
    required this.syncPreferences,
    required this.credentialStore,
    required this.proxyController,
    required this.cloudStatisticsRepository,
    required this.cloudStatisticsCache,
    required this.cloudStatistics,
  });

  /// 平台服务（能力 / 数据库后端 / 凭据工厂 / 采集提供者 …）。
  final PlatformServices platform;

  final String ownerId;
  final AppDatabase database;
  final CharacterRepository repository;
  final AssetValidator validator;
  final AssetDecoder decoder;

  /// 素材导入的**唯一入口**（[AssetImportRouter]）。
  ///
  /// 界面只依赖它，绝不自行决定"哪个请求该喂哪个导入器" ——
  /// 那正是 Phase 4A 真机上 ZIP 必然失败的根因。
  final AssetImporter importer;

  final SettingsRepository settingsRepository;
  final SettingsController settings;

  /// 开机自启开关的协调器（Windows 真实写注册表；Android 为不支持实现）。
  final StartupRegistrationService startupRegistration;

  final WindowController windowController;
  final StateEngine stateEngine;
  final PetRenderer renderer;
  final PetPresenter presenter;

  /// 系统托盘；Android 为 null（没有托盘）。
  final TrayHost? trayHost;

  /// 桌宠宿主（Windows 拖动窗口；Android no-op）。
  final PetHost petHost;

  final PerfSampler perfSampler;

  // --- 阶段 1：活动采集与使用统计 ---
  final ApplicationRepository applications;
  final ActivitySegmentService activitySegments;
  final ActivityTracker activityTracker;

  /// 「当前前台应用」提供者（Phase 4C-5.1A）。
  ///
  /// 使用统计页与任何需要"当前应用"的界面都从这里取，**不再直接读**
  /// [activityTracker] 的 Windows 专用字段 —— 否则 Android 上会显示为空。
  final CurrentActivityProvider currentActivity;
  final UsageAnalyticsService usageAnalytics;
  final TrackingSettingsDao trackingSettingsDao;

  // --- Phase 4C-5.1B：Android 原生使用会话导入 ---

  /// 本机统计使用的**本地设备标识**（Android = 稳定安装 UUID；Windows = `desktop.local`）。
  ///
  /// Phase 4C-5.1A 起所有本地统计读写都用它，**不再写死常量**。
  final String trackingDeviceLocalId;

  /// Android 原生使用会话导入器；**非 Android 为 null**（Windows 由 Dart 采集器直接写库）。
  final AndroidUsageImportService? androidUsageImport;

  // --- Phase 2：账户与同步 ---
  final AuthenticatedApi authenticatedApi;
  final SyncEngine syncEngine;
  final SyncOutboxDao syncOutboxDao;
  final SyncPreferences syncPreferences;
  final CredentialStore credentialStore;

  /// Phase 2 补充：代理（Clash / HTTP CONNECT）配置与探测。
  final ProxyController proxyController;

  // --- Phase 4B：跨设备云端统计（只读） ---

  /// 云端统计数据层。**只读**：只发 GET，绝不写本机采集表，也不进 outbox。
  final CloudStatisticsRepository cloudStatisticsRepository;

  /// 云端统计缓存（独立表 `cloud_statistics_cache`，按账户隔离）。
  final CloudStatisticsCache cloudStatisticsCache;

  /// 云端统计页面控制器（移动端「云端统计」页使用）。
  final CloudStatisticsController cloudStatistics;

  /// 素材导入选择器（两端行为不同：文件夹仅桌面支持）。
  FileImportProvider get fileImportProvider => platform.fileImportProvider;

  /// 状态快照的可监听视图，UI 直接监听它重建。
  ValueListenable<StateSnapshot> get stateEngineSnapshot => stateEngine.snapshots;

  static AppServices? _instance;

  static AppServices get instance {
    final AppServices? i = _instance;
    if (i == null) throw StateError('AppServices 尚未初始化');
    return i;
  }

  static bool get isReady => _instance != null;

  /// 仅测试使用：释放单例，让下一个用例可以重新 bootstrap。
  static void resetForTest() {
    _instance = null;
    panelToggleHook = null;
    exitHook = null;
    toggleTrackingHook = null;
    usageStatsHook = null;
    beforePetVisibilityChangeHook = null;
  }

  /// 应用启动装配。
  ///
  /// [platform] 留空时使用当前平台的默认实现；[prepareForStartup] 是幂等的，
  /// 因此调用方可以（也应该）在更早的阶段先调用一次以取得"单实例"判定。
  /// [dataRoot] 仅测试使用：把应用数据目录指向临时目录。
  static Future<AppServices> bootstrap({
    String ownerId = AppConstants.localOwnerId,
    PlatformServices? platform,
    Directory? dataRoot,
  }) async {
    final AppServices? existing = _instance;
    if (existing != null) return existing;

    final PlatformServices host = platform ?? platformServices;

    // 0. ID 命名空间自检。
    //    命名空间非法会让 uuid v5 每次都抛 FormatException，所有导入都会失败。
    //    这类配置错误必须在启动时就炸掉，而不是等用户点「导入」才逐条报错。
    Ids.assertNamespaceValid();

    // 1. 应用数据目录（必须在任何写盘之前）
    await AppPaths.initialize(overrideRoot: dataRoot);
    final AppPaths paths = AppPaths.instance;

    // 2. 日志
    await AppLog.initialize(logFile: paths.logFile);
    Loggers.app.info('=== PetLife 启动 ===');
    Loggers.app.info('应用数据目录: ${paths.root.path}');
    Loggers.app.info(
      '运行环境: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
      '(${Platform.numberOfProcessors} 逻辑核心) Dart ${Platform.version.split(' ').first}',
    );

    // 3. 平台准备：单实例判定 + SQLite 后端初始化 + 设备信息（幂等）。
    if (!await host.prepareForStartup()) {
      throw StateError('已有 PetLife 实例在运行，本次启动中止（避免重复记录使用时长）');
    }
    // 让设备身份使用平台解析出的信息（Android 会带机型）。
    DeviceIdentity.configureEnvironment(host.device);

    // 4. 数据库（后端由平台决定，Schema/迁移完全共用）
    final AppDatabase db = await AppDatabase.open(path: paths.databaseFile.path);

    // 5. 仓储层
    final CharacterRepository repository = SqliteCharacterRepository.fromDatabase(db);
    final SettingsRepository settingsRepository = SqliteSettingsRepository.fromDatabase(db);

    // 6. 素材校验 / 解码
    const AssetValidator validator = DefaultAssetValidator();
    final AssetDecoder decoder = FlutterAssetDecoder();

    // 7. 导入器
    //
    //    DefaultAssetImporter 负责单张 / 多张 / 文件夹，ZipAssetImporter 复用它的
    //    落盘逻辑处理 ZIP；两者由 AssetImportRouter 统一对外分派 ——
    //    装配层不再把两个导入器分别暴露给界面（见 docs/29 Phase 4A ZIP 缺陷）。
    final DefaultAssetImporter fileImporter = DefaultAssetImporter(
      repository: repository,
      validator: validator,
      decoder: decoder,
    );
    final ZipAssetImporter zipImporter = ZipAssetImporter(
      inner: fileImporter,
      validator: validator,
    );
    final AssetImportRouter importer = AssetImportRouter(
      fileImporter: fileImporter,
      zipImporter: zipImporter,
    );

    // 8. 设置
    final SettingsController settings = SettingsController(
      repository: settingsRepository,
      ownerId: ownerId,
    );
    await settings.load();

    // 8.5 开机自启对齐：偏好为"开启"时重新写一次启动项，
    //     于是发布目录被移动/改名后，注册表里的路径会更新到当前 exe。
    final StartupRegistrationService startupRegistration =
        StartupRegistrationService(
      registrar: host.startupRegistrar,
      settings: settings,
      // 启动项必须指向**当前正在运行的** exe（完整绝对路径），
      // 这样把整个发布目录搬到别处后，下一次启动就会自动修正路径。
      executablePath: () => Platform.resolvedExecutable,
    );
    try {
      await startupRegistration.reconcileOnStartup();
    } catch (e, st) {
      // 自启对齐失败绝不能影响启动本身。
      Loggers.settings.warning('开机自启状态对齐失败（不影响启动）', e, st);
    }

    // 9. 窗口（Android 上是 no-op 实现）
    final WindowController windowController = host.createWindowController();
    await windowController.initialize(settings: settings.settings);

    // 10. 渲染 + 状态引擎
    final PetRenderer renderer = PetFrameController(decoder: decoder);
    final StateEngine stateEngine = DefaultStateEngine(repository: repository);
    final PetPresenter presenter = PetPresenter(
      engine: stateEngine,
      renderer: renderer,
      settings: settings,
    );

    // 11. 活动采集与使用统计。
    //
    //     提供者由平台给出：Windows 为 Win32；Android Phase 4A 为"不可用"实现，
    //     采集器据此不驱动桌宠状态（见 ActivityTracker.isAvailable）。
    final ActivityDao activityDao = ActivityDao(db.raw);
    final ApplicationDao applicationDao = ApplicationDao(db.raw);
    final ActivityCheckpointDao checkpointDao = ActivityCheckpointDao(db.raw);
    final DailyUsageDao dailyUsageDao = DailyUsageDao(db.raw);
    final TrackingSettingsDao trackingSettingsDao = TrackingSettingsDao(db.raw);

    // 12. Phase 2：账户与同步。
    //
    //     创建顺序刻意如此：outbox 相关的 DAO / producer / sink 必须先于采集层建好，
    //     这样采集层在写入本地数据后就能立刻声明变更（写 outbox）。
    final AccountSessionDao accountSessionDao = AccountSessionDao(db.raw);
    final SyncStateDao syncStateDao = SyncStateDao(db.raw);
    final SyncOutboxDao syncOutboxDao = SyncOutboxDao(db.raw);
    final SyncPreferences syncPreferences = SyncPreferences(db);
    final DeviceIdentity deviceIdentity = DeviceIdentity(db);

    final CredentialStore credentialStore = await host.credentialStoreFactory.create(
      fallbackDirectory: paths.credentialsDir,
    );

    // 代理：先把已保存的配置读出来，解析器与 UI 控制器共用同一个实例，
    // 这样"当前实际使用的出口"只有一处真相。
    final ProxySettings proxySettings = await syncPreferences.proxySettings();
    final SystemProxyReader systemProxyReader = host.systemProxyReader;
    final ProxySettingsResolver proxyResolver = ProxySettingsResolver(
      settings: proxySettings,
      systemReader: systemProxyReader,
    );

    final AuthenticatedApi authenticatedApi = AuthenticatedApi(
      credentialStore: credentialStore,
      accountSessionDao: accountSessionDao,
      deviceIdentity: deviceIdentity,
      preferences: syncPreferences,
      proxyResolver: proxyResolver,
    );
    await authenticatedApi.load();

    final ProxyController proxyController = ProxyController(
      api: authenticatedApi,
      credentialStore: credentialStore,
      resolver: proxyResolver,
      systemReader: systemProxyReader,
      initialSettings: proxySettings,
    );
    await proxyController.load();

    final OutboxProducer outboxProducer = OutboxProducer(
      db: db,
      outbox: syncOutboxDao,
      ownerId: ownerId,
    );
    final OutboxChangeSink changeSink = OutboxChangeSink(producer: outboxProducer);

    final ApplicationRepository applications =
        ApplicationRepository(dao: applicationDao, changeSink: changeSink);
    await applications.load();

    // --- Phase 4C-5.1A：本地统计的设备标识不再写死 ---
    //
    // Android 使用 DeviceIdentity 持久化的稳定安装 UUID（重启不变、每台设备唯一）；
    // Windows 保持现有 `desktop.local` 常量（本阶段不做数据迁移）。
    // 平台分支留在平台层（host），这里只做注入。
    final String trackingDeviceLocalId =
        await host.resolveTrackingDeviceLocalId(deviceIdentity: deviceIdentity);
    Loggers.activity.info(
      '本机统计设备标识：$trackingDeviceLocalId'
      '（平台 ${host.capabilities.platformName}）',
    );
    // Android 上如果还残留早期（before 4C-5.1A）写在 `desktop.local` 名下的
    // 采集行，这里**一次性迁到新标识**（只改 device_local_id，不改时间与秒数）：
    // 既不丢历史数据，也不会重复累计（daily_usage 目标行已存在时跳过）。Windows 一律不动。
    await _migrateLegacyDeviceRowsIfNeeded(
      host: host,
      activityDao: activityDao,
      dailyUsageDao: dailyUsageDao,
      ownerId: ownerId,
      trackingDeviceLocalId: trackingDeviceLocalId,
    );

    final TrackingSettings trackingSettings =
        await trackingSettingsDao.load(ownerId, trackingDeviceLocalId);

    final ActivitySegmentService activitySegments = ActivitySegmentService(
      activityDao: activityDao,
      checkpointDao: checkpointDao,
      dailyUsageDao: dailyUsageDao,
      applications: applications,
      ownerId: ownerId,
      deviceLocalId: trackingDeviceLocalId,
      settings: trackingSettings,
      changeSink: changeSink,
    );

    final ForegroundAppProvider foregroundProvider = host.createForegroundAppProvider();
    final IdleDetector idleDetector = host.createIdleDetector();
    final SessionStateProvider sessionProvider = host.createSessionStateProvider();

    final ActivityTracker activityTracker = ActivityTracker(
      service: activitySegments,
      applications: applications,
      foregroundProvider: foregroundProvider,
      idleDetector: idleDetector,
      sessionStateProvider: sessionProvider,
      stateMapper: const ActivityStateMapper(),
      readCurrentState: () => stateEngine.snapshot.state,
      // 自动状态一律 force=false + immediate=false：
      // 尊重优先级与最短展示时长，并保留「等当前动画播完一轮」的平滑切换。
      onDecision: (ActivityStateDecision decision) => stateEngine.requestState(
        StateChangeRequest(
          state: decision.state,
          trigger: decision.trigger,
          reason: decision.reason,
          force: false,
          immediate: false,
        ),
      ),
      settings: trackingSettings,
    );

    final UsageAnalyticsService usageAnalytics = UsageAnalyticsService(
      activityDao: activityDao,
      dailyUsageDao: dailyUsageDao,
      applications: applications,
      ownerId: ownerId,
      // Phase 4C-5.1A：设备标识由平台层给出（Android 为稳定安装 UUID），不再写死常量。
      deviceLocalId: trackingDeviceLocalId,
    );

    // 「当前前台应用」提供者：Windows 复用 Dart 采集器、Android 读原生共享快照。
    final CurrentActivityProvider currentActivity =
        host.createCurrentActivityProvider(activityTracker: activityTracker);

    // Phase 4C-5.1B：Android 原生使用会话导入器。
    //
    // **只在 Android 装配**：Windows 的 Dart 采集器直接写库，没有原生 journal 这回事；
    // 平台分支留在装配层（用能力位判断），导入器本身不 import 任何平台专属库。
    final AndroidUsageImportService? androidUsageImport =
        host.capabilities.platformName == 'android'
            ? AndroidUsageImportService(
                overlay: host.overlayPet,
                database: db,
                outboxDao: syncOutboxDao,
                outboxProducer: outboxProducer,
                applications: applications,
                ownerId: ownerId,
                deviceLocalId: trackingDeviceLocalId,
              )
            : null;

    // 13. Phase 2：同步引擎。
    //
    //     引擎依赖 producer（构造顺序在采集层之前已满足），
    //     这里再反向把「刷新待同步计数」的回调挂回 sink，打破构造顺序环。
    final SyncEngine syncEngine = SyncEngine(
      api: authenticatedApi,
      outboxDao: syncOutboxDao,
      stateDao: syncStateDao,
      producer: outboxProducer,
      preferences: syncPreferences,
      // Phase 4C-5.1B：同步前先把原生 journal 里的使用会话补进库（需求 §7）。
      beforePush: androidUsageImport == null
          ? null
          : () async {
              await androidUsageImport.importPending();
            },
    );
    changeSink.onChanged = () => unawaited(syncEngine.refreshPendingCount());

    // 14. 托盘（Android 为 null：没有系统托盘）
    final TrayHost? tray = host.createTrayHost(
      callbacks: TrayCallbacks(
        onTogglePet: () async {
          // 托盘显示 / 隐藏桌宠前，先让轮盘菜单收起（还原窗口矩形），
          // 否则隐藏时窗口还停在放大状态，再显示就是一块空的大窗。
          await beforePetVisibilityChangeHook?.call();
          final bool visible = await windowController.isVisible();
          await windowController.setVisible(!visible);
        },
        onTogglePanel: () async => panelToggleHook?.call(),
        onResetPosition: () async => resetPositionHook?.call(),
        onExit: () async => exitHook?.call(),
        onToggleTracking: () async => toggleTrackingHook?.call(),
        onOpenUsageStats: () async => usageStatsHook?.call(),
      ),
    );

    final PerfSampler perfSampler = PerfSampler(diagnostics: host.processDiagnostics);
    processMetricsAvailable.value = host.processDiagnostics.isAvailable;
    if (!host.processDiagnostics.isAvailable) {
      Loggers.app.info('本平台不提供进程 CPU / 句柄指标，诊断页将隐藏相应条目');
    }

    // 15. Phase 4B：跨设备云端统计。
    //
    //     数据层是**只读**的：只调用 GET，绝不写本机采集表，也绝不进 outbox
    //     （否则会造成循环同步与重复累计）。
    //     缓存写在独立的 cloud_statistics_cache 表里，按账户隔离，
    //     退出登录时只清这一张表。
    final CloudStatisticsCache cloudStatisticsCache = CloudStatisticsCache(
      CloudStatisticsCacheDao(db.raw),
      // 服务端地址进缓存键：同一个 userId 在不同服务器上必须分开缓存
      // （否则换服务器后会读到旧服务器的统计）。
      serverBaseUrl: () => authenticatedApi.baseUrl,
    );
    final CloudStatisticsRepository cloudStatisticsRepository =
        ApiCloudStatisticsRepository(api: authenticatedApi);
    final CloudStatisticsController cloudStatistics = CloudStatisticsController(
      repository: cloudStatisticsRepository,
      cache: cloudStatisticsCache,
      currentAccountUserId: () => authenticatedApi.lastAccount?.userId,
    );

    final AppServices services = AppServices._(
      platform: host,
      ownerId: ownerId,
      database: db,
      repository: repository,
      validator: validator,
      decoder: decoder,
      importer: importer,
      settingsRepository: settingsRepository,
      settings: settings,
      startupRegistration: startupRegistration,
      windowController: windowController,
      stateEngine: stateEngine,
      renderer: renderer,
      presenter: presenter,
      trayHost: tray,
      petHost: host.createPetHost(windowController: windowController),
      perfSampler: perfSampler,
      applications: applications,
      activitySegments: activitySegments,
      activityTracker: activityTracker,
      currentActivity: currentActivity,
      usageAnalytics: usageAnalytics,
      trackingSettingsDao: trackingSettingsDao,
      trackingDeviceLocalId: trackingDeviceLocalId,
      androidUsageImport: androidUsageImport,
      authenticatedApi: authenticatedApi,
      syncEngine: syncEngine,
      syncOutboxDao: syncOutboxDao,
      syncPreferences: syncPreferences,
      credentialStore: credentialStore,
      proxyController: proxyController,
      cloudStatisticsRepository: cloudStatisticsRepository,
      cloudStatisticsCache: cloudStatisticsCache,
      cloudStatistics: cloudStatistics,
    );
    _instance = services;
    return services;
  }

  /// Phase 4C-5.1A：把"旧设备标识"下的本机采集行迁到当前标识。
  ///
  /// * **只在 Android 执行**：Windows 保持 `desktop.local`，本阶段不做任何迁移；
  /// * 迁移**只改 `device_local_id`**，不改时间与秒数；
  /// * `daily_usage` 目标行已存在时跳过该天（绝不相加）→ **不会重复累计**；
  /// * 失败只记日志，绝不阻塞启动。
  static Future<void> _migrateLegacyDeviceRowsIfNeeded({
    required PlatformServices host,
    required ActivityDao activityDao,
    required DailyUsageDao dailyUsageDao,
    required String ownerId,
    required String trackingDeviceLocalId,
  }) async {
    const String legacy = AppConstants.localDeviceId;
    if (trackingDeviceLocalId == legacy) return;
    if (host.capabilities.platformName != 'android') return;
    try {
      final int segments = await activityDao.migrateDeviceLocalId(
        legacy,
        trackingDeviceLocalId,
      );
      final int days = await dailyUsageDao.migrateDeviceLocalId(
        legacy,
        trackingDeviceLocalId,
      );
      if (segments > 0 || days > 0) {
        Loggers.activity.info(
          '已把本机采集记录迁移到稳定设备标识：segments=$segments days=$days '
          '（$legacy → $trackingDeviceLocalId，owner=$ownerId）',
        );
      }
    } catch (e, st) {
      // 迁移失败不能阻止启动：新数据仍会写到新标识，旧行只是暂时不参与统计。
      Loggers.activity.warning('本机采集记录迁移失败（不影响启动）', e, st);
    }
  }

  /// 启动活动采集。
  ///
  /// 必须在状态引擎绑定好角色之后调用（采集会根据分类驱动桌宠状态）。
  /// 幂等：重复调用不会启动第二个定时器。
  /// 平台不支持自动采集时（Android Phase 4A）采集器自身会记录"不可用"。
  Future<void> startActivityTracking() async {
    try {
      // Phase 4C-5.1B：先把"设备标识 + 暂停状态"同步给原生，再导入历史会话。
      // 顺序很重要：原生服务可能在任意时刻起来（用户点显示桌宠），
      // 它读的是 SharedPreferences 里的这两项，必须尽早写进去。
      final AndroidUsageImportService? importer = androidUsageImport;
      if (importer != null) {
        await importer.initialize(paused: activityTracker.settings.paused);
        await importer.importPending();
      }
      await activityTracker.start();
    } catch (e, st) {
      // 采集失败不能阻止桌宠运行。
      Loggers.activity.warning('启动活动采集失败（桌宠仍可正常使用）', e, st);
    }
  }

  /// 导入 Android 原生暂存的使用会话（幂等；非 Android 为 no-op）。
  ///
  /// 触发点：统计页打开前、应用从后台恢复、同步开始前（由 `SyncEngine.beforePush` 调）。
  Future<void> importAndroidUsageSessions() async {
    final AndroidUsageImportService? importer = androidUsageImport;
    if (importer == null) return;
    await importer.importPending();
  }

  /// 持久化采集设置。
  ///
  /// Phase 4C-5.1A：设备标识改为注入值（Android 是稳定安装 UUID）；
  /// Phase 4C-5.1B：暂停开关要**同时**同步给原生采集器，否则
  /// "界面已暂停、原生还在记"（需求 §9 要求三者一致）。
  Future<void> saveTrackingSettings(TrackingSettings next) async {
    await trackingSettingsDao.saveSettings(ownerId, trackingDeviceLocalId, next);
    await activityTracker.updateSettings(next);
    await androidUsageImport?.syncCollectionPaused(next.paused);
  }

  /// 启动后台同步引擎（自带定时、指数退避与单任务互斥）。
  ///
  /// 未登录时引擎会停在 `signedOut` 状态，不做任何网络请求。
  Future<void> startSync() async {
    try {
      await syncEngine.start();
    } catch (e, st) {
      // 同步启动失败绝不能影响桌宠与本地采集。
      Loggers.sync.warning('启动同步引擎失败（本地功能不受影响）', e, st);
    }
  }

  /// 托盘与 UI 之间的回调挂载点（在 UI 初始化后注入，避免反向依赖）。
  static Future<void> Function()? panelToggleHook;
  static Future<void> Function()? exitHook;

  /// 阶段 1：托盘「暂停 / 恢复记录」。
  static Future<void> Function()? toggleTrackingHook;

  /// 阶段 1：托盘「打开使用统计」（打开面板并定位到统计页）。
  static Future<void> Function()? usageStatsHook;

  /// 增量 A：托盘显示 / 隐藏桌宠**之前**调用（用于先收起轮盘菜单、还原窗口）。
  static Future<void> Function()? beforePetVisibilityChangeHook;

  /// 真机回归修复：托盘「把桌宠移回屏幕右下角」。
  ///
  /// 必须走外壳的固定画布安全重建事务（而不是 `moveTo(0,0)`），
  /// 因为固定画布模式下位置是 `petScreenPosition`，且要写回 v2。
  static Future<void> Function()? resetPositionHook;

  /// 是否有系统托盘（Android 为 false，界面据此隐藏托盘相关说明）。
  bool get hasTray => trayHost != null;

  /// 初始化系统托盘图标（没有托盘时是 no-op）。
  Future<void> initializeTray() async {
    final TrayHost? tray = trayHost;
    if (tray == null) return;
    final String icon = await platform.resolveTrayIconPath();
    await tray.initialize(iconPath: icon);
  }

  /// 正常退出：落盘 + 释放资源。
  Future<void> shutdown() async {
    Loggers.app.info('=== PetLife 退出中 ===');
    try {
      // ⚠️ 真机回归 #3 的配套修正：**绝不能**把"控制面板窗口"的位置当成桌宠位置。
      //
      // 面板模式下窗口矩形 = 面板矩形（1180×760，在 workArea 居中）；
      // 固定画布模式下窗口矩形 = 整块画布，桌宠位置 = 画布矩形左上角 + petAnchor。
      // 旧实现无条件保存"当前窗口左上角"，于是"打开面板 → 直接退出"会把面板
      // 位置写进 `window.x/y`，下次启动桌宠就跑到面板位置去了。
      final WindowsSurfaceMode mode = windowsSurfaceSession.mode;
      if (mode == WindowsSurfaceMode.petFixedCanvas) {
        final Offset? anchor = fixedCanvasAnchor.anchor;
        final ({double x, double y})? pos = await windowController.position();
        if (pos != null) {
          await settings.rememberWindowPosition(
            pos.x + (anchor?.dx ?? 0),
            pos.y + (anchor?.dy ?? 0),
          );
        }
      } else {
        wheelGeometryJournal.record(
          'pet.position.save_skipped',
          fields: <String, Object?>{'mode': mode.wireName},
        );
      }
      await settings.rememberSelection(
        characterId: stateEngine.snapshot.currentCharacter?.id,
        state: stateEngine.snapshot.state,
        assetId: stateEngine.snapshot.currentAsset?.id,
        manualAssetId: stateEngine.snapshot.manualAssetId,
      );
    } catch (e, st) {
      Loggers.settings.warning('退出前保存配置失败', e, st);
    }

    try {
      perfSampler.stop();
      // 先停采集：它会写入「正常退出」的结束原因并把最后一段排入 outbox，
      // 必须在数据库关闭前完成。
      await activityTracker.stop();
      // Phase 2：再做一次**严格超时**的快速同步（数据已经入队，能传多少传多少）。
      // 超时即放弃，绝不长时间阻塞退出。
      await syncEngine.syncOnShutdown();
      await syncEngine.stop();
      await presenter.dispose();
      (renderer as PetFrameController).dispose();
      await stateEngine.dispose();
      await trayHost?.dispose();
      await windowController.dispose();
      authenticatedApi.dispose();
      proxyController.dispose();
      cloudStatistics.dispose();
      await decoder.clear();
      await AppDatabase.close();
      await platform.dispose();
      await AppLog.dispose();
    } catch (e, st) {
      Loggers.app.warning('释放资源时发生异常', e, st);
    }
  }

  /// 诊断信息（诊断页展示）。
  Map<String, Object?> diagnostics() => <String, Object?>{
        'owner_id': ownerId,
        'app_data_dir': AppPaths.isInitialized ? AppPaths.instance.root.path : '<未初始化>',
        'database': AppPaths.isInitialized ? AppPaths.instance.databaseFile.path : '<未初始化>',
        'database_backend': database.backendName,
        'log_file': AppPaths.isInitialized ? AppPaths.instance.logFile.path : '<未初始化>',
        'db_open': AppDatabase.isOpen,
        'unhandled_errors': ErrorHandler.unhandledCount.value,
        'last_error': ErrorHandler.lastError.value ?? '',
        // --- Phase 4A：平台与设备 ---
        'platform_name': platform.capabilities.platformName,
        'form_factor': platform.capabilities.formFactor.name,
        'device_platform': platform.device.platform,
        'device_architecture': platform.device.architecture,
        'device_name': platform.device.deviceName,
        'device_model': platform.device.modelName ?? '<无>',
        'device_os_version': platform.device.osVersion,
        'supports_system_activity_tracking':
            platform.capabilities.supportsSystemActivityTracking,
        'supports_window_management': platform.capabilities.supportsWindowManagement,
        'supports_tray': platform.capabilities.supportsTray,
        'supports_precise_idle': platform.capabilities.supportsPreciseIdleDetection,
        // --- 开机自启（Windows）---
        'launch_at_startup_supported': startupRegistration.isSupported,
        'launch_at_startup_registered': startupRegistration.isRegistered(),
        'launch_at_startup_command':
            startupRegistration.registeredCommandOrNull() ?? '<未注册>',
        'launch_at_startup_preference': settings.settings.launchAtStartup,
        'process_metrics_available': processMetricsAvailable.value,
        'decoded_image_entries': decoder.cachedImageEntries,
        'decoded_image_mb': (decoder.cachedImageBytes / 1024 / 1024),
        'cached_file_entries': decoder.cachedFileEntries,
        'cached_file_mb': (decoder.cachedFileBytes / 1024 / 1024),
        // --- 阶段 1：活动采集 ---
        'activity_provider_available': activityTracker.isAvailable,
        'activity_tracking_running': activityTracker.isRunning,
        'activity_status': activityTracker.status.labelZh,
        'activity_paused': activityTracker.isPaused,
        'activity_current_app': activityTracker.currentAppDisplayName ?? '<无>',
        'activity_today_active_seconds': activityTracker.todayActiveSeconds,
        'activity_today_session_seconds': activityTracker.todaySessionSeconds,
        'activity_today_idle_seconds': activityTracker.todayIdleSeconds,
        'activity_continuous_seconds': activityTracker.continuousActiveSeconds,
        'activity_device_id': AppConstants.localDeviceId,
        'activity_known_apps': applications.all.length,
        'activity_failure_streak': activitySegments.consecutiveFailures,
        // --- Phase 2：账户与同步 ---
        'sync_signed_in': authenticatedApi.isSignedIn,
        'sync_account': authenticatedApi.lastAccount?.email ?? '<未登录>',
        'sync_server': authenticatedApi.baseUrl,
        'sync_device_id': authenticatedApi.deviceServerId ?? '<未绑定>',
        'sync_credential_backend': credentialStore.backendName,
        'sync_status': syncEngine.status.labelZh,
        'sync_pending': syncEngine.pendingCount,
        'sync_consecutive_failures': syncEngine.consecutiveFailures,
        'sync_last_success': syncEngine.lastSuccessAt?.toIso8601String() ?? '<无>',
        'sync_last_error': syncEngine.lastError ?? '<无>',
        'sync_needs_reauth': authenticatedApi.needsReauthentication,
        // --- Phase 2 补充：代理 ---
        'proxy_mode': proxyController.settings.mode.wireName,
        'proxy_route': authenticatedApi.proxyResolution.kind.labelZh,
        'proxy_authority': authenticatedApi.proxyResolution.usesProxy
            ? authenticatedApi.proxyResolution.authority
            : '<直连>',
        'proxy_source': authenticatedApi.proxyResolution.sourceLabel,
        'proxy_issue': authenticatedApi.proxyResolution.blockedReason ??
            authenticatedApi.proxyResolution.warning ??
            '<无>',
        'proxy_bypass_localhost': proxyController.settings.bypassLocalhost,
        'proxy_system_readable': proxyController.detected?.available ?? false,
        'proxy_system_proxy_server': proxyController.detected?.proxyServer ?? '<无>',
        'proxy_network_generation': authenticatedApi.networkGeneration,
      };
}

/// 用一个 ValueNotifier 暴露进程指标可用性，供诊断页展示（避免在 UI 里直接 import FFI）。
final ValueNotifier<bool> processMetricsAvailable = ValueNotifier<bool>(true);
