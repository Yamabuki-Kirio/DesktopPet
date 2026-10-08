import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../activity_tracking/models/tracking_settings.dart';
import '../activity_tracking/models/usage_stats.dart';
import '../activity_tracking/usage_analytics_service.dart';
import '../character/models/character_model.dart';
import '../character/models/emotion_asset.dart';
import '../core/constants.dart';
import '../core/logger.dart';
import '../database/app_database.dart';
import '../database/dao/settings_dao.dart';
import '../navigation/app_navigation.dart';
import '../platform/android/android_overlay_menu_bridge.dart';
import '../platform/overlay_pet.dart';
import '../settings/settings_controller.dart';
import '../state_engine/state_engine.dart';
import '../state_engine/state_snapshot.dart';
import '../state_engine/system_state.dart';
import '../sync/models/sync_models.dart';
import 'library_controller.dart';
import 'overlay_pet_controller.dart';

/// 菜单动作的执行结果（Phase 4C-6B-2）。
///
/// `status` 直接就是回执给原生的取值：`completed` / `failed` / `expired`。
class MenuActionResult {
  const MenuActionResult(this.status, [this.message]);

  const MenuActionResult.completed([String? message])
      : this(MenuRequestStatus.completed, message);

  const MenuActionResult.failed(String message)
      : this(MenuRequestStatus.failed, message);

  final MenuRequestStatus status;

  /// 给用户看的中文说明。
  final String? message;

  Map<String, Object?> toMap() => <String, Object?>{
        'status': status.wireName,
        'message': message,
      };

  @override
  String toString() => 'MenuActionResult(${status.wireName}, $message)';
}

/// 「今日使用」的时长文案（契约要求形如 `2小时35分钟`）。
///
/// 注意：它只做**文案**格式化；数值来自既有的
/// [UsageAnalyticsService]（与「使用统计（本机）」页**同一个口径**），
/// 不新增任何统计口径。
String formatMenuDurationZh(int seconds) {
  if (seconds <= 0) return '0分钟';
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return minutes > 0 ? '$hours小时$minutes分钟' : '$hours小时';
  if (minutes > 0) return '$minutes分钟';
  return '${seconds % 60}秒';
}

/// 跨端菜单动作 id 的**唯一契约** + 旧版本兼容表（Phase 4C-6B-3 契约修复）。
///
/// 原生与 Dart 之间**只允许**一套 canonical（snake_case）动作 id。历史缺陷：原生
/// 发的是 camelCase（如 `toggleAutomaticState`），而执行器只认 snake_case
/// （如 `pet_auto`），于是每个 Dart 请求都以「不支持的菜单动作」失败。
///
/// [legacyAliases] **只用于接收侧**兼容"升级前已入队 / 已落盘"的旧请求，
/// 保留一个版本周期；新请求永远只会以 [canonical] 里的 id 产生，绝不反向使用别名。
class MenuActionIds {
  MenuActionIds._();

  /// 17 个 canonical 动作 id（与原生 `MenuActionIds.CANONICAL_DART_IDS` 逐字一致）。
  static const Set<String> canonical = <String>{
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
    'settings_theme',
    'settings_wheel_size',
    'settings_button_size',
    'settings_open',
  };

  /// 旧 camelCase → canonical 的兼容映射（仅接收侧使用，保留一个版本周期）。
  static const Map<String, String> legacyAliases = <String, String>{
    'toggleAutomaticState': 'pet_auto',
    'previousAsset': 'appearance_prev',
    'nextAsset': 'appearance_next',
    'toggleAutomaticAsset': 'appearance_auto',
    'toggleFavorite': 'appearance_fav',
    'openStateMapping': 'appearance_mapping',
    'openAssetLibrary': 'appearance_library',
    'showTodayUsage': 'records_today',
    'openUsageStatistics': 'records_stats',
    'openCloudRecords': 'records_cloud',
    'toggleTracking': 'records_track',
    'syncNow': 'records_sync',
    'showSyncState': 'records_sync_state',
    'selectTheme': 'settings_theme',
    'changeMenuScale': 'settings_wheel_size',
    'changeButtonScale': 'settings_button_size',
    'openSettings': 'settings_open',
  };

  /// 把收到的动作 id 归一化为 canonical；无法识别返回 `null`（调用方据此报错）。
  static String? normalize(String raw) {
    if (canonical.contains(raw)) return raw;
    return legacyAliases[raw];
  }
}

/// 轮盘菜单动作的执行器。
///
/// 设计约束（与需求一致）：
/// * **只调用既有服务**：设置控制器 / 状态引擎 / 素材库控制器 / 使用统计服务 /
///   同步引擎 / 悬浮桌宠控制器。这里不新建任何仓储、聚合器或同步引擎；
/// * **不持有已释放的对象**：`overlay` / `library` 都是**懒取函数**
///   （它们由外壳的 State 创建、随 State 释放），执行时现取现用，
///   绝不把实例存进长生命周期的字段；
/// * **绝不谎报成功**：前置条件不满足时返回 `failed` + 明确中文原因。
class OverlayMenuActionExecutor {
  OverlayMenuActionExecutor({
    required ValueListenable<StateSnapshot> snapshots,
    required StateEngine stateEngine,
    required Future<List<EmotionAsset>> Function(String characterId) listRenderableAssets,
    required SettingsController settings,
    required AppNavigationController navigation,
    required UsageAnalyticsService usageAnalytics,
    required TrackingSettings Function() trackingSettings,
    required Future<void> Function(TrackingSettings settings) saveTrackingSettings,
    required bool Function() isSignedIn,
    required SyncStatus Function() syncStatus,
    required int Function() syncPendingCount,
    required DateTime? Function() syncLastSuccessAt,
    required String? Function() syncLastError,
    required Future<void> Function() syncNow,
    OverlayPetController? Function()? overlay,
    LibraryController? Function()? library,
    DateTime Function()? clock,
  })  : _snapshots = snapshots,
        _stateEngine = stateEngine,
        _listRenderableAssets = listRenderableAssets,
        _settings = settings,
        _navigation = navigation,
        _usageAnalytics = usageAnalytics,
        _trackingSettings = trackingSettings,
        _saveTrackingSettings = saveTrackingSettings,
        _isSignedIn = isSignedIn,
        _syncStatus = syncStatus,
        _syncPendingCount = syncPendingCount,
        _syncLastSuccessAt = syncLastSuccessAt,
        _syncLastError = syncLastError,
        _syncNow = syncNow,
        _overlay = overlay ?? (() => null),
        _library = library ?? (() => null),
        _clock = clock ?? DateTime.now;

  final ValueListenable<StateSnapshot> _snapshots;
  final StateEngine _stateEngine;
  final Future<List<EmotionAsset>> Function(String characterId) _listRenderableAssets;
  final SettingsController _settings;
  final AppNavigationController _navigation;
  final UsageAnalyticsService _usageAnalytics;
  final TrackingSettings Function() _trackingSettings;
  final Future<void> Function(TrackingSettings settings) _saveTrackingSettings;
  final bool Function() _isSignedIn;
  final SyncStatus Function() _syncStatus;
  final int Function() _syncPendingCount;
  final DateTime? Function() _syncLastSuccessAt;
  final String? Function() _syncLastError;
  final Future<void> Function() _syncNow;
  final OverlayPetController? Function() _overlay;
  final LibraryController? Function() _library;
  final DateTime Function() _clock;

  StateSnapshot get _snapshot => _snapshots.value;

  String? get _currentCharacterId => _snapshot.currentCharacter?.id;

  /// 执行一个动作。
  ///
  /// **接收侧归一化**：先把收到的 [actionId] 用 [MenuActionIds.normalize] 折成
  /// canonical id（兼容一个版本周期的旧 camelCase 请求），并记录
  /// `menu.execute receivedActionId=... normalizedActionId=...`；无法识别的 id
  /// 返回 `failed`（绝不静默成功）。
  Future<MenuActionResult> execute(String actionId, Map<String, Object?> args) {
    final String? normalized = MenuActionIds.normalize(actionId);
    Loggers.app.info(
      'menu.execute receivedActionId=$actionId '
      'normalizedActionId=${normalized ?? '<unknown>'}',
    );
    if (normalized == null) {
      return Future<MenuActionResult>.value(
        MenuActionResult.failed('不支持的菜单动作：$actionId'),
      );
    }
    return switch (normalized) {
      'pet_auto' => _enableAutomaticState(),
      'appearance_prev' => _cycleAsset(forward: false),
      'appearance_next' => _cycleAsset(forward: true),
      'appearance_auto' => _releaseManualLock(),
      'appearance_fav' => _toggleFavorite(args),
      'appearance_mapping' => _openStateMapping(),
      'appearance_library' => _navigate(
          AppDestination.assetLibrary,
          successMessage: '已打开素材库',
        ),
      'records_today' => _todayUsage(),
      'records_stats' => _navigate(
          AppDestination.localStatistics,
          successMessage: '已打开本机统计',
        ),
      'records_cloud' => _navigate(
          AppDestination.cloudStatistics,
          successMessage: '已打开云端统计',
        ),
      'records_track' => _toggleTracking(args),
      'records_sync' => _sync(),
      'records_sync_state' => _syncState(),
      'settings_theme' => _selectTheme(args),
      'settings_wheel_size' => _setWheelSize(button: false, args: args),
      'settings_button_size' => _setWheelSize(button: true, args: args),
      'settings_open' => _navigate(
          AppDestination.overlaySettings,
          successMessage: '已打开悬浮桌宠设置',
        ),
      // 归一化后仍未知（理论上不可达）：如实报错，绝不静默成功。
      _ => Future<MenuActionResult>.value(
          MenuActionResult.failed('不支持的菜单动作：$actionId'),
        ),
    };
  }

  // ---------------------------------------------------------------------------
  // pet / appearance
  // ---------------------------------------------------------------------------

  /// `pet_auto`：重新开启「根据当前应用自动切换桌宠状态」。
  ///
  /// 与设置页 / 映射编辑器里的开关走**同一条**路径（`SettingsController` +
  /// 立刻把新配置推给原生），因此原生拿到的是同一份规则。
  Future<MenuActionResult> _enableAutomaticState() async {
    await _settings.setOverlayAutomaticState(true);
    await _overlay()?.syncStateMapping();
    return const MenuActionResult.completed('已开启自动状态联动');
  }

  /// `appearance_prev` / `appearance_next`：在当前角色的可用素材里循环换图。
  ///
  /// 换图后进入**既有的** manual 锁定（`StateEngine.lockManual`），
  /// 这样下一次自动状态 tick 不会把用户刚选的图悄悄换回去。
  Future<MenuActionResult> _cycleAsset({required bool forward}) async {
    final CharacterModel? character = _snapshot.currentCharacter;
    if (character == null) {
      return const MenuActionResult.failed('尚未选择桌宠角色，请先在素材库中启用一个角色');
    }

    final List<EmotionAsset> assets =
        _stableOrder(await _listRenderableAssets(character.id));
    if (assets.isEmpty) {
      return const MenuActionResult.failed('当前角色没有可用素材');
    }
    if (assets.length == 1) {
      return const MenuActionResult.failed('当前角色只有一张素材');
    }

    final String? currentId = _snapshot.currentAsset?.id;
    final int currentIndex =
        currentId == null ? -1 : assets.indexWhere((EmotionAsset a) => a.id == currentId);
    final int nextIndex = currentIndex < 0
        ? 0 // 当前素材不在可用列表里（例如刚被禁用）：从第一张开始，行为可预期。
        : ((forward ? currentIndex + 1 : currentIndex - 1) + assets.length) % assets.length;
    final EmotionAsset target = assets[nextIndex];

    // 素材导入后文件仍可能被外部删除：这种情况必须**保持原图**并如实报错。
    if (!File(target.filePath).existsSync()) {
      return MenuActionResult.failed(
        '素材文件不存在，已保持当前素材：${target.emotionName}/${target.variantName}',
      );
    }

    try {
      await _stateEngine.lockManual(
        assetId: target.id,
        reason: forward ? '轮盘菜单：切换到下一张素材' : '轮盘菜单：切换到上一张素材',
      );
      await _settings.rememberSelection(
        characterId: character.id,
        state: SystemState.manual,
        assetId: target.id,
        manualAssetId: target.id,
      );
    } catch (e, st) {
      Loggers.app.warning('切换素材失败（保持当前素材）', e, st);
      return MenuActionResult.failed('切换素材失败，已保持当前素材：$e');
    }
    return MenuActionResult.completed(
      '已切换到 ${target.emotionName}/${target.variantName}',
    );
  }

  /// `appearance_auto`：解除 manual 锁定，恢复自动状态联动。
  Future<MenuActionResult> _releaseManualLock() async {
    final bool wasLocked =
        _snapshot.state == SystemState.manual || _snapshot.manualAssetId != null;
    await _stateEngine.releaseManual();
    // 持久化的 manual 素材也要清掉，否则下次冷启动会按它重新锁定（与"恢复自动"矛盾）。
    await _settings.clearManualAsset();
    return MenuActionResult.completed(
      wasLocked ? '已恢复自动状态联动' : '当前已是自动状态联动',
    );
  }

  /// `appearance_fav`：收藏 / 取消收藏**当前**素材。
  ///
  /// 收藏只影响回退链的先后，**不得改变当前正在显示的素材**：万一刷新后
  /// 解析结果变了（例如状态本身走的是"收藏素材"这一级），这里立刻把画面
  /// 锁回原来那张，保证用户点收藏时画面不动。
  Future<MenuActionResult> _toggleFavorite(Map<String, Object?> args) async {
    final CharacterModel? character = _snapshot.currentCharacter;
    final EmotionAsset? current = _snapshot.currentAsset;
    if (character == null || current == null) {
      return const MenuActionResult.failed('当前没有正在显示的素材');
    }
    final LibraryController? library = _library();
    if (library == null) {
      return const MenuActionResult.failed('素材库尚未就绪，请稍后重试');
    }

    final Object? rawFavorite = args['favorite'];
    final bool next = rawFavorite is bool
        ? rawFavorite
        : !(library
                .assetsFor(character.id)
                .firstWhere(
                  (EmotionAsset a) => a.id == current.id,
                  orElse: () => current,
                )
                .favorite);

    await library.setAssetFavorite(current.id, next);

    final String? activeAfter = _snapshot.currentAsset?.id;
    if (activeAfter != null && activeAfter != current.id) {
      // 收藏改变了回退结果：把画面锁回原来那张（这是"收藏不改画面"的兜底）。
      await _stateEngine.lockManual(
        assetId: current.id,
        reason: '收藏素材后保持当前素材不变',
      );
      await _settings.rememberSelection(
        characterId: character.id,
        state: SystemState.manual,
        assetId: current.id,
        manualAssetId: current.id,
      );
    }

    final String label = '${current.emotionName}/${current.variantName}';
    return MenuActionResult.completed(next ? '已收藏 $label' : '已取消收藏 $label');
  }

  /// `appearance_mapping`：打开**当前角色**的状态素材映射编辑器。
  Future<MenuActionResult> _openStateMapping() async {
    if (_currentCharacterId == null) {
      return const MenuActionResult.failed('尚未选择桌宠角色，无法编辑状态映射');
    }
    return _navigate(
      AppDestination.stateAssetMapping,
      successMessage: '已打开状态素材映射',
    );
  }

  // ---------------------------------------------------------------------------
  // records
  // ---------------------------------------------------------------------------

  /// `records_today`：今日使用时长。
  ///
  /// **与「使用统计（本机）」页完全同口径**：同一个服务
  /// （[UsageAnalyticsService]）、同一个窗口
  /// （`UsageAnalyticsService.windowFor(UsageRange.today)`）、同一个聚合字段
  /// （`UsageOverview.appActiveSeconds`，即页面上 Android 的「今日总使用时长」）。
  /// 刻意不读 `ActivityTracker.todayActiveSeconds`：那在 Android 上是另一条来源
  /// （Dart 采集器在 Android 不可用），会与统计页对不上。
  Future<MenuActionResult> _todayUsage() async {
    try {
      final UsageWindow window = UsageAnalyticsService.windowFor(UsageRange.today);
      final UsageSummary summary = await _usageAnalytics.summarize(window);
      return MenuActionResult.completed(
        '今日使用：${formatMenuDurationZh(summary.overview.appActiveSeconds)}',
      );
    } catch (e, st) {
      // 统计服务不可用 / 查询失败时如实报错，绝不把 0 当结果返回。
      Loggers.app.warning('读取今日使用时长失败', e, st);
      return MenuActionResult.failed('读取今日使用时长失败：$e');
    }
  }

  /// `records_track`：暂停 / 恢复记录（走设置页与统计页共用的那一个入口）。
  Future<MenuActionResult> _toggleTracking(Map<String, Object?> args) async {
    final TrackingSettings current = _trackingSettings();
    final Object? rawPaused = args['paused'];
    final bool next = rawPaused is bool ? rawPaused : !current.paused;
    await _saveTrackingSettings(current.copyWith(paused: next));
    return MenuActionResult.completed(next ? '已暂停记录' : '已恢复记录');
  }

  /// `records_sync`：手动同步。
  ///
  /// 走 `SyncEngine.syncNow(manual: true)` —— 引擎内部的单任务互斥保证
  /// "连续点两次不会真的跑两个同步"（既有实现，见 `sync_engine_test.dart`）。
  Future<MenuActionResult> _sync() async {
    if (!_isSignedIn()) {
      return const MenuActionResult.failed('尚未登录，请先在「账户与同步」页登录');
    }
    await _syncNow();
    return switch (_syncStatus()) {
      SyncStatus.success => const MenuActionResult.completed('同步成功'),
      SyncStatus.syncing => const MenuActionResult.completed('正在同步'),
      SyncStatus.waitingForNetwork =>
        const MenuActionResult.failed('离线，已保留待上传数据'),
      SyncStatus.needsReauthentication =>
        const MenuActionResult.failed('登录已失效，请重新登录'),
      SyncStatus.signedOut => const MenuActionResult.failed('尚未登录'),
      _ => MenuActionResult.failed('同步失败：${_syncLastError() ?? '未知原因'}'),
    };
  }

  /// `records_sync_state`：只读地把同步状态回报给用户。
  Future<MenuActionResult> _syncState() async {
    final StringBuffer buffer = StringBuffer()
      ..write('同步状态：${_syncStatus().labelZh}')
      ..write('，待上传 ${_syncPendingCount()} 条')
      ..write('，最近成功：${_syncSuccessLabel()}');
    final String? error = _syncLastError();
    if (error != null && error.isNotEmpty) {
      buffer.write('，最近错误：$error');
    }
    return MenuActionResult.completed(buffer.toString());
  }

  String _syncSuccessLabel() {
    final DateTime? at = _syncLastSuccessAt();
    if (at == null) return '从未成功';
    final DateTime local = at.toLocal();
    final DateTime now = _clock().toLocal();
    final String clock =
        '${_two(local.hour)}:${_two(local.minute)}';
    final bool sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    return sameDay ? clock : '${_two(local.month)}-${_two(local.day)} $clock';
  }

  // ---------------------------------------------------------------------------
  // settings
  // ---------------------------------------------------------------------------

  /// `settings_theme`：切换轮盘主题。
  ///
  /// 写入前**必须先回读**（`refreshMenuTheme`）才能续上原生单调递增的 revision，
  /// 否则会被原生的"旧配置不得覆盖新配置"守卫整份拒绝。
  Future<MenuActionResult> _selectTheme(Map<String, Object?> args) async {
    final OverlayPetController? overlay = _overlay();
    if (overlay == null) {
      return const MenuActionResult.failed('当前平台不支持系统级悬浮桌宠');
    }
    await overlay.refreshMenuTheme();

    String? themeId;
    final Object? rawThemeId = args['themeId'];
    if (rawThemeId is String && rawThemeId.isNotEmpty) {
      themeId = rawThemeId;
    } else {
      // 原生只给"切换"语义时，按内置预设顺序循环。
      final List<OverlayMenuThemePreset> presets = overlay.menuThemeState.presets;
      if (presets.isEmpty) {
        return const MenuActionResult.failed('原生未上报可用的轮盘主题');
      }
      final int index = presets.indexWhere(
        (OverlayMenuThemePreset p) => p.themeId == overlay.menuThemeState.themeId,
      );
      themeId = presets[(index + 1) % presets.length].themeId;
    }

    final Object? rawCustom = args['customPrimary'];
    final int? customPrimary = rawCustom is num ? rawCustom.toInt() : null;

    final bool accepted =
        await overlay.selectMenuTheme(themeId: themeId, customPrimary: customPrimary);
    if (!accepted) {
      return MenuActionResult.failed(overlay.lastError ?? '轮盘主题切换失败');
    }
    return MenuActionResult.completed('轮盘主题已切换为「${overlay.menuThemeState.displayName}」');
  }

  /// `settings_wheel_size` / `settings_button_size`：调整轮盘 / 按钮大小。
  ///
  /// 区间 50%~250%、步长 10%，默认 100% / 130%（沿用原生 `minScale`/`step`/
  /// `defaultScale` 与 `defaultButtonScale`），持久化仍走既有通道。
  Future<MenuActionResult> _setWheelSize({
    required bool button,
    required Map<String, Object?> args,
  }) async {
    final OverlayPetController? overlay = _overlay();
    if (overlay == null) {
      return const MenuActionResult.failed('当前平台不支持系统级悬浮桌宠');
    }
    // 与主题同理：先回读，续上原生的 revision。
    await overlay.refreshWheelLayout();
    final OverlayWheelLayoutSettings settings = overlay.wheelLayoutSettings;

    final double step = settings.step > 0 ? settings.step : 0.10;
    final double min = settings.minScale > 0 ? settings.minScale : 0.50;
    final double max = settings.maxScale > 0 ? settings.maxScale : 2.50;
    final double current = button ? settings.buttonVisualScale : settings.preferredScale;
    final double fallbackDefault = button ? settings.defaultButtonScale : settings.defaultScale;

    final double? target = _resolveScale(
      args,
      current: current,
      step: step,
      min: min,
      max: max,
      defaultValue: fallbackDefault,
    );
    if (target == null) {
      return const MenuActionResult.failed('参数无法识别，无法调整大小');
    }

    final bool accepted = button
        ? await overlay.setWheelScale(settings.preferredScale, buttonScale: target)
        : await overlay.setWheelScale(target, buttonScale: settings.buttonVisualScale);
    if (!accepted) {
      return MenuActionResult.failed(overlay.lastError ?? '保存大小设置失败');
    }
    final int percent = (target * 100).round();
    return MenuActionResult.completed('${button ? '按钮' : '轮盘'}大小已设为 $percent%');
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  Future<MenuActionResult> _navigate(
    AppDestination destination, {
    String? successMessage,
  }) async {
    // 只登记：外壳（或桌面控制面板）就绪后消费一次；未就绪时留在控制器里。
    _navigation.request(destination);
    return MenuActionResult.completed(successMessage);
  }

  /// 素材的**稳定排序**（情绪名 → 变体名 → ID），保证 prev/next 的顺序可复现。
  static List<EmotionAsset> _stableOrder(List<EmotionAsset> assets) {
    final List<EmotionAsset> ordered = List<EmotionAsset>.of(assets);
    ordered.sort((EmotionAsset a, EmotionAsset b) {
      final int byEmotion =
          a.emotionName.toLowerCase().compareTo(b.emotionName.toLowerCase());
      if (byEmotion != 0) return byEmotion;
      final int byVariant =
          a.variantName.toLowerCase().compareTo(b.variantName.toLowerCase());
      if (byVariant != 0) return byVariant;
      return a.id.compareTo(b.id);
    });
    return ordered;
  }

  /// 解析原生给的大小参数，返回对齐到 step 网格并夹紧到区间内的目标值。
  ///
  /// 兼容几种常见写法（原生侧尚未最终确定时都能工作）：
  /// * `scale` / `value` / `size` / `percent`：绝对值（>5 视为百分比）；
  /// * `delta` / `steps`：以步长为单位的增量；
  /// * `direction`：`up|increase|next` / `down|decrease|prev`；
  /// * `reset: true`：回到默认值；
  /// * 都没给 → 放大一档（菜单上只有一个"大小"按钮时最自然的语义）。
  double? _resolveScale(
    Map<String, Object?> args, {
    required double current,
    required double step,
    required double min,
    required double max,
    required double defaultValue,
  }) {
    double? target;
    final double? absolute = _number(args, <String>['scale', 'value', 'size', 'percent']);
    if (absolute != null) {
      target = absolute > 5 ? absolute / 100 : absolute;
    } else {
      final double? delta = _number(args, <String>['delta', 'steps', 'step']);
      if (delta != null) {
        target = current + delta * step;
      } else if (args['reset'] == true) {
        target = defaultValue;
      } else {
        final Object? rawDirection = args['direction'];
        if (rawDirection is String) {
          final String direction = rawDirection.toLowerCase();
          if (direction == 'up' || direction == 'increase' ||
              direction == 'next' || direction == 'larger') {
            target = current + step;
          } else if (direction == 'down' || direction == 'decrease' ||
              direction == 'prev' || direction == 'smaller') {
            target = current - step;
          } else {
            return null;
          }
        } else {
          target = current + step;
        }
      }
    }
    final double snapped = min + ((target - min) / step).round() * step;
    return double.parse(snapped.clamp(min, max).toStringAsFixed(2));
  }

  static double? _number(Map<String, Object?> args, List<String> keys) {
    for (final String key in keys) {
      final Object? value = args[key];
      if (value is num) return value.toDouble();
    }
    return null;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// 「已处理过的菜单请求」台账。
///
/// 幂等性要求：**每个 requestId 至多执行一次**，且要跨 Activity 重建与冷启动成立，
/// 因此必须落盘（内存集合不足够：Activity 重建会新建 State，
/// 冷启动更是全新的进程）。实现复用既有的 `local_settings` 表，
/// **不新建数据库、不新建表**。
abstract interface class MenuRequestLedger {
  /// 读取已处理过的 requestId。
  Future<Set<String>> loadSeen();

  /// 记住一个 requestId（写入后重启仍然有效）。
  Future<void> remember(String requestId);
}

/// 基于既有 `local_settings` 表的台账（同名 `AppDatabase`，不新增存储）。
class SqliteMenuRequestLedger implements MenuRequestLedger {
  SqliteMenuRequestLedger({required AppDatabase database, required String ownerId})
      : _dao = SettingsDao(database.raw),
        _ownerId = ownerId;

  /// 存储键（`local_settings` 里的一条普通配置，`AppSettings` 不读它，互不干扰）。
  static const String storageKey = 'overlay.menuSeenRequestIds';

  /// 最多保留的条数：只用于幂等去重，无需无限增长。
  static const int maxRemembered = 200;

  final SettingsDao _dao;
  final String _ownerId;

  @override
  Future<Set<String>> loadSeen() async {
    final String? raw = await _dao.get(_ownerId, storageKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return <String>{
        for (final Object? item in decoded)
          if (item is String && item.isNotEmpty) item,
      };
    } catch (e, st) {
      // 值被外力写坏时按"没有记录"处理：最坏结果是重复执行一次，
      // 而抛错会让菜单动作整批失效（更糟）。
      Loggers.app.warning('读取菜单请求台账失败，按空台账继续', e, st);
      return <String>{};
    }
  }

  @override
  Future<void> remember(String requestId) async {
    final List<String> ids = (await loadSeen()).toList(growable: true)
      ..remove(requestId)
      ..add(requestId);
    final List<String> capped = ids.length > maxRemembered
        ? ids.sublist(ids.length - maxRemembered)
        : ids;
    await _dao.set(_ownerId, storageKey, jsonEncode(capped), DateTime.now());
  }
}

/// 待处理菜单请求的消费者（Phase 4C-6B-2）。
///
/// 触发点：应用启动（`AppServices.bootstrap` 之后）与从后台回到前台。
/// 两条投递路径共用同一个台账，因此**同一个 requestId 只会被执行一次**：
/// * 原生主动 `menuRequest` 调用；
/// * 原生把请求排队，由 Dart 主动 `pullPendingMenuRequests` 拉取。
class OverlayMenuRequestConsumer with WidgetsBindingObserver {
  OverlayMenuRequestConsumer({
    required AndroidOverlayMenuBridge bridge,
    required OverlayMenuActionExecutor executor,
    required MenuRequestLedger ledger,
  })  : _bridge = bridge,
        _executor = executor,
        _ledger = ledger;

  final AndroidOverlayMenuBridge _bridge;
  final OverlayMenuActionExecutor _executor;
  final MenuRequestLedger _ledger;

  final Set<String> _seen = <String>{};

  bool _started = false;
  bool _seenLoaded = false;

  /// 重入保护：启动与 resume 可能几乎同时发生，避免同一批被拉两次。
  bool _pulling = false;

  /// 启动：注册原生 → Dart 处理器，并立刻拉取一次待处理请求。
  ///
  /// 幂等：重复调用不会注册第二个处理器。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _bridge.bindMenuRequestHandler(_onNativeRequest);
    unawaited(pump());
  }

  /// 应用回到前台：原生可能在后台排队了新请求。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(pump());
  }

  /// 释放（外壳 dispose）：注销通道处理器与生命周期监听。
  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _bridge.clearMenuRequestHandler();
  }

  /// 拉取待处理请求并逐个执行（每个 requestId 至多执行一次）。
  Future<void> pump() async {
    if (_pulling) return;
    _pulling = true;
    try {
      await _ensureSeenLoaded();
      final List<OverlayMenuRequest> requests = await _bridge.pullPendingMenuRequests();
      for (final OverlayMenuRequest request in requests) {
        await _handle(request);
      }
    } catch (e, st) {
      // 悬浮通道不可用（非 Android / 原生未注册）不该影响本地功能。
      Loggers.app.warning('拉取菜单待处理请求失败', e, st);
    } finally {
      _pulling = false;
    }
  }

  /// 原生主动投递：执行一次并返回 `{status, message}`。
  Future<Map<String, Object?>> _onNativeRequest(OverlayMenuRequest request) async {
    final MenuActionResult result = await _handle(request);
    return result.toMap();
  }

  Future<MenuActionResult> _handle(OverlayMenuRequest request) async {
    await _ensureSeenLoaded();

    // 已经在终态 / 已经执行过 → 只确认，绝不重复执行。
    if (request.status.isTerminal || _seen.contains(request.requestId)) {
      const MenuActionResult ack = MenuActionResult.completed('该请求已处理，未重复执行');
      await _acknowledge(request.requestId, ack);
      return ack;
    }

    MenuActionResult result;
    try {
      result = await _executor.execute(request.actionId, request.args);
    } catch (e, st) {
      Loggers.app.warning('执行菜单动作失败：${request.actionId}', e, st);
      result = MenuActionResult.failed('执行失败：$e');
    }
    // 先记账再回执：即使回执失败，也不会因为原生重投而执行第二次。
    await _remember(request.requestId);
    await _acknowledge(request.requestId, result);
    Loggers.app.info(
      'menu.complete requestId=${request.requestId} actionId=${request.actionId} '
      'status=${result.status.wireName}'
      '${result.message == null ? '' : '（${result.message}）'}',
    );
    return result;
  }

  Future<void> _acknowledge(String requestId, MenuActionResult result) async {
    try {
      await _bridge.completeMenuRequest(
        requestId: requestId,
        status: result.status,
        message: result.message,
      );
    } catch (e, st) {
      Loggers.app.warning('回执菜单请求失败：$requestId', e, st);
    }
  }

  Future<void> _remember(String requestId) async {
    _seen.add(requestId);
    try {
      await _ledger.remember(requestId);
    } catch (e, st) {
      Loggers.app.warning('写入菜单请求台账失败：$requestId', e, st);
    }
  }

  Future<void> _ensureSeenLoaded() async {
    if (_seenLoaded) return;
    try {
      _seen.addAll(await _ledger.loadSeen());
    } catch (e, st) {
      Loggers.app.warning('读取菜单请求台账失败', e, st);
    }
    _seenLoaded = true;
  }
}
