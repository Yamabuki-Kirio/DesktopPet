import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import '../menu/pet_position_resolver.dart' show WindowPositionSchema;
import '../menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import '../menu/wheel_theme.dart' show WheelThemeIds;
import '../state_engine/system_state.dart';
import 'app_settings.dart';
import 'settings_repository.dart';

/// 设置的内存视图 + 持久化协调者。
///
/// UI 只与它交互；它负责写入 [SettingsRepository]，并在每次变更后通知监听者
/// （窗口控制器据此实时应用置顶 / 透明度等）。
class SettingsController extends ChangeNotifier {
  SettingsController({required SettingsRepository repository, required String ownerId})
      : _repository = repository,
        _ownerId = ownerId;

  final SettingsRepository _repository;
  final String _ownerId;

  AppSettings _settings = const AppSettings();
  bool _loaded = false;

  AppSettings get settings => _settings;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    _settings = (await _repository.load(_ownerId)).normalized();
    _loaded = true;
    Loggers.settings.info(
      '设置加载完成: 置顶=${_settings.alwaysOnTop} 穿透=${_settings.ignoreMouseEvents} '
      '锁定=${_settings.lockPosition} 缩放=${_settings.scale}x '
      '平滑=${_settings.smoothScaling} 透明度=${_settings.opacity} '
      '淡入淡出=${_settings.crossFadeMs}ms 循环=${_settings.loopAnimation} '
      '位置=(${_settings.windowX}, ${_settings.windowY})',
    );
    notifyListeners();
  }

  /// 原子更新：传入一个变更函数，自动持久化并通知。
  Future<void> update(AppSettings Function(AppSettings current) mutate) async {
    final AppSettings next = mutate(_settings).normalized();
    if (mapEquals(next.toKeyValues(), _settings.toKeyValues())) return;
    _settings = next;
    notifyListeners();
    await _repository.patch(_ownerId, next.toKeyValues());
  }

  Future<void> setAlwaysOnTop(bool value) =>
      update((AppSettings s) => s.copyWith(alwaysOnTop: value));

  Future<void> setIgnoreMouseEvents(bool value) =>
      update((AppSettings s) => s.copyWith(ignoreMouseEvents: value));

  Future<void> setLockPosition(bool value) =>
      update((AppSettings s) => s.copyWith(lockPosition: value));

  Future<void> setScale(double value) => update((AppSettings s) => s.copyWith(scale: value));

  Future<void> setSmoothScaling(bool value) =>
      update((AppSettings s) => s.copyWith(smoothScaling: value));

  Future<void> setOpacity(double value) => update((AppSettings s) => s.copyWith(opacity: value));

  Future<void> setCrossFadeMs(int value) =>
      update((AppSettings s) => s.copyWith(crossFadeMs: value));

  Future<void> setLoopAnimation(bool value) =>
      update((AppSettings s) => s.copyWith(loopAnimation: value));

  Future<void> setDefaultCharacter(String? characterId) =>
      update((AppSettings s) => s.copyWith(defaultCharacterId: characterId));

  Future<void> setDefaultAsset(String? assetId) =>
      update((AppSettings s) => s.copyWith(defaultAssetId: assetId));

  Future<void> setHideOnFullscreen(bool value) =>
      update((AppSettings s) => s.copyWith(hideOnFullscreen: value));

  Future<void> setLaunchAtStartup(bool value) =>
      update((AppSettings s) => s.copyWith(launchAtStartup: value));

  /// 记住「使用统计」页停留的子页（本机 / 云端）。
  Future<void> setUsageStatsTab(String value) => update(
        (AppSettings s) => s.copyWith(
          usageStatsTab: value == AppSettings.usageStatsTabCloud
              ? AppSettings.usageStatsTabCloud
              : AppSettings.usageStatsTabLocal,
        ),
      );

  /// Phase 4C-6A：「根据当前应用自动切换桌宠状态」总开关。
  ///
  /// 只影响**自动换素材**；前台识别与使用时长采集不受影响（需求 §9）。
  Future<void> setOverlayAutomaticState(bool value) =>
      update((AppSettings s) => s.copyWith(overlayAutomaticState: value));

  // --- 轮盘（增量 B：字段语义与 Android `WheelMenuLayoutSettings` 一致）---

  /// 轮盘主题（`p3p-pink` / `blue` / `red` / `purple` / `green` / `custom`）。
  ///
  /// 未知 id 会被 [AppSettings.normalized] 拉回 P3P 粉。
  Future<void> setWheelThemeId(String themeId) =>
      update((AppSettings s) => s.copyWith(wheelThemeId: themeId));

  /// 自定义主题主色（`#RRGGBB`；空字符串 = 未设置）。
  ///
  /// 只存主色，其余颜色由 [WheelMenuThemes.custom] 派生 —— 与 Android 同口径。
  Future<void> setWheelCustomPrimary(String hex) =>
      update((AppSettings s) => s.copyWith(wheelCustomPrimary: hex));

  /// 轮盘大小：夹取到 0.50 ~ 2.50 并吸附 0.10 步进。
  Future<void> setWheelScale(double value) =>
      update((AppSettings s) => s.copyWith(wheelScale: value));

  /// 按钮大小：夹取到 0.50 ~ 2.50 并吸附 0.10 步进。
  Future<void> setWheelButtonScale(double value) =>
      update((AppSettings s) => s.copyWith(wheelButtonScale: value));

  /// 菜单距离：夹取到 0.05 ~ 0.30（**不量化**，Android 原样夹取）。
  Future<void> setWheelMenuDistance(double value) =>
      update((AppSettings s) => s.copyWith(wheelMenuDistance: value));

  /// 轮盘设置恢复默认（主题 P3P 粉 / 大小 1.00 / 按钮 1.30 / 距离 0.16）。
  Future<void> resetWheelSettings() => update(
        (AppSettings s) => s.copyWith(
          wheelThemeId: WheelThemeIds.p3pPink,
          wheelCustomPrimary: '',
          wheelScale: WheelMenuLayoutSettings.defaultScale,
          wheelButtonScale: WheelMenuLayoutSettings.defaultButtonScale,
          wheelMenuDistance: WheelMenuLayoutSettings.defaultDistance,
        ),
      );

  /// 记忆**桌宠屏幕位置**（`petScreenPosition` = 人物可见区域左上角）。
  ///
  /// 真机回归修复后，`windowX/Y` 的语义**唯一**是 `petScreenPosition`
  /// （见 `WindowPositionSchema.v2`），因此这里**总是**写 v2 版本号 ——
  /// 否则下次启动会被判为"语义不确定的旧数据"而回退默认位置。
  ///
  /// 调用方必须传"人物屏幕位置"，**禁止**传：
  /// * 固定画布左上角（= `petScreen − petAnchor`）；
  /// * 控制面板左上角；
  /// * Region 包围盒左上角。
  Future<void> rememberWindowPosition(double x, double y) =>
      rememberWindowPositionWithSchema(x, y, schemaVersion: WindowPositionSchema.current);

  /// 带**显式语义版本**的位置写入（启动迁移 / 修正用）。
  Future<void> rememberWindowPositionWithSchema(
    double x,
    double y, {
    required int schemaVersion,
  }) =>
      update(
        (AppSettings s) => s.copyWith(
          windowX: x,
          windowY: y,
          windowPositionSchema: schemaVersion,
        ),
      );

  /// 记忆当前角色与表情，供下次启动恢复。
  Future<void> rememberSelection({
    String? characterId,
    SystemState? state,
    String? assetId,
    String? manualAssetId,
  }) =>
      update((AppSettings s) => s.copyWith(
            lastCharacterId: characterId,
            lastState: state,
            lastAssetId: assetId,
            manualAssetId: manualAssetId,
          ));

  /// 清掉持久化的 manual 锁定素材（`appearance_auto` 解除锁定时用）。
  ///
  /// 必须显式清除：启动时会按 `manualAssetId` 重新锁定，若只调
  /// `rememberSelection(manualAssetId: null)`（`copyWith` 的 null 表示"不改动"），
  /// 下次冷启动又会把图锁回去 —— 与"恢复自动状态联动"直接矛盾。
  Future<void> clearManualAsset() =>
      update((AppSettings s) => s.copyWith(clearManualAssetId: true));

  Future<void> resetToDefaults() async {
    await _repository.reset(_ownerId);
    _settings = const AppSettings();
    notifyListeners();
    Loggers.settings.info('设置已恢复默认');
  }
}
