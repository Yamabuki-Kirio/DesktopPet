import '../core/constants.dart';
import '../menu/pet_position_resolver.dart' show WindowPositionSchema;
import '../menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import '../menu/wheel_theme.dart'
    show WheelMenuTheme, WheelMenuThemes, WheelThemeIds;
import '../state_engine/system_state.dart';

/// 应用设置（需求 9.5 / 六）。
///
/// 全部字段都是**可持久化**的：重启后必须恢复角色、图片、位置、缩放、透明度（验收第 18 项）。
class AppSettings {
  const AppSettings({
    this.alwaysOnTop = true,
    this.ignoreMouseEvents = false,
    this.lockPosition = false,
    this.scale = 2.0,
    this.smoothScaling = false,
    this.opacity = 1.0,
    this.crossFadeMs = RenderTimings.crossFadeDefaultMs,
    this.loopAnimation = true,
    this.defaultCharacterId,
    this.defaultAssetId,
    this.hideOnFullscreen = false,
    this.launchAtStartup = false,
    this.windowX,
    this.windowY,
    this.windowPositionSchema = WindowPositionSchema.none,
    this.lastCharacterId,
    this.lastState = SystemState.defaultState,
    this.lastAssetId,
    this.manualAssetId,
    this.usageStatsTab = usageStatsTabLocal,
    this.overlayAutomaticState = true,
    this.wheelThemeId = WheelThemeIds.p3pPink,
    this.wheelCustomPrimary = '',
    this.wheelScale = WheelMenuLayoutSettings.defaultScale,
    this.wheelButtonScale = WheelMenuLayoutSettings.defaultButtonScale,
    this.wheelMenuDistance = WheelMenuLayoutSettings.defaultDistance,
  });

  /// 「使用统计」页当前选中的子页：`local`（本机）或 `cloud`（云端）。
  ///
  /// 只是 UI 记忆，决定下次打开时停留在哪一页（需求：默认保持用户上次选择）。
  static const String usageStatsTabLocal = 'local';
  static const String usageStatsTabCloud = 'cloud';

  // --- 窗口 ---
  final bool alwaysOnTop;
  final bool ignoreMouseEvents;
  final bool lockPosition;

  /// 缩放倍数。需求要求支持 1×/2×/3×/4×，因此 UI 上只提供整数档。
  final double scale;

  /// false = 最近邻（像素画默认清晰），true = 平滑插值。
  final bool smoothScaling;

  /// 整体不透明度，0.2 ~ 1.0。
  final double opacity;

  /// 状态切换的淡入淡出时长（毫秒），约束在 150 ~ 300。
  final int crossFadeMs;

  /// 动态图是否循环播放。
  final bool loopAnimation;

  // --- 角色 ---
  final String? defaultCharacterId;

  /// 默认表情（素材 ID）。
  final String? defaultAssetId;

  // --- 行为 ---
  final bool hideOnFullscreen;

  /// 开机启动的**用户意图**。
  ///
  /// 真正的系统状态在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`；
  /// 设置页的开关渲染的是系统实况（见 `StartupRegistrationService.isRegistered`），
  /// 这个字段只用于"启动时按意图修复启动项路径"与诊断展示。
  final bool launchAtStartup;

  // --- 窗口位置记忆 ---

  /// 桌宠屏幕位置 X —— **语义由 [windowPositionSchema] 决定**。
  ///
  /// * [WindowPositionSchema.v2]（当前）：桌宠**可见区域左上角**
  ///   （`petScreenPosition`）。固定画布模式下保存/恢复都用这个口径；
  /// * [WindowPositionSchema.v1] / [WindowPositionSchema.none]：历史数据，
  ///   是**窗口左上角**，启动时由 `PetPositionResolver` 迁移，不可直接当
  ///   `petScreenPosition` 使用。
  final double? windowX;
  final double? windowY;

  /// 位置语义版本（见 [WindowPositionSchema]）。
  ///
  /// 默认 [WindowPositionSchema.none]（历史数据无版本）→ 启动时按"语义不确定"
  /// 处理（不猜测、回退默认位置、写回 v2）。
  final int windowPositionSchema;

  // --- 上次运行状态（重启恢复） ---
  final String? lastCharacterId;
  final SystemState lastState;
  final String? lastAssetId;

  /// manual 状态下临时锁定的图片。
  final String? manualAssetId;

  /// 「使用统计」页记忆的子页（`local` / `cloud`）。
  ///
  /// 纯 UI 记忆：决定下次打开统计页时停留在本机还是云端。
  final String usageStatsTab;

  /// Phase 4C-6A：「根据当前应用自动切换桌宠状态与素材」总开关。
  ///
  /// 默认开启。关闭后仍照常识别前台应用与采集使用时长，只是不再自动换素材。
  final bool overlayAutomaticState;

  // --- 轮盘（增量 B：与 Android `WheelMenuLayoutSettings` 同一语义）---

  /// 轮盘主题 id（`p3p-pink` / `blue` / `red` / `purple` / `green` / `custom`）。
  final String wheelThemeId;

  /// 自定义主题的主色（`#RRGGBB`）；空字符串 = 未设置（回退 P3P 粉同构）。
  final String wheelCustomPrimary;

  /// 轮盘大小：0.50 ~ 2.50，步进 0.10，默认 1.00。
  final double wheelScale;

  /// 按钮大小：0.50 ~ 2.50，步进 0.10，默认 1.30。
  final double wheelButtonScale;

  /// 菜单距离：0.05 ~ 0.30，默认 0.16（= 菜单中心相对桌宠**可见宽度**的偏移比例）。
  ///
  /// ⚠️ 这不是画布布局的 `FixedCanvasConfig.menuGap`（那是固定画布内部的几何常量）。
  final double wheelMenuDistance;

  AppSettings copyWith({
    bool? alwaysOnTop,
    bool? ignoreMouseEvents,
    bool? lockPosition,
    double? scale,
    bool? smoothScaling,
    double? opacity,
    int? crossFadeMs,
    bool? loopAnimation,
    String? defaultCharacterId,
    String? defaultAssetId,
    bool? hideOnFullscreen,
    bool? launchAtStartup,
    double? windowX,
    double? windowY,
    int? windowPositionSchema,
    String? lastCharacterId,
    SystemState? lastState,
    String? lastAssetId,
    String? manualAssetId,
    bool clearManualAssetId = false,
    String? usageStatsTab,
    bool? overlayAutomaticState,
    String? wheelThemeId,
    String? wheelCustomPrimary,
    double? wheelScale,
    double? wheelButtonScale,
    double? wheelMenuDistance,
  }) =>
      AppSettings(
        alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
        ignoreMouseEvents: ignoreMouseEvents ?? this.ignoreMouseEvents,
        lockPosition: lockPosition ?? this.lockPosition,
        scale: scale ?? this.scale,
        smoothScaling: smoothScaling ?? this.smoothScaling,
        opacity: opacity ?? this.opacity,
        crossFadeMs: crossFadeMs ?? this.crossFadeMs,
        loopAnimation: loopAnimation ?? this.loopAnimation,
        defaultCharacterId: defaultCharacterId ?? this.defaultCharacterId,
        defaultAssetId: defaultAssetId ?? this.defaultAssetId,
        hideOnFullscreen: hideOnFullscreen ?? this.hideOnFullscreen,
        launchAtStartup: launchAtStartup ?? this.launchAtStartup,
        windowX: windowX ?? this.windowX,
        windowY: windowY ?? this.windowY,
        windowPositionSchema: windowPositionSchema ?? this.windowPositionSchema,
        lastCharacterId: lastCharacterId ?? this.lastCharacterId,
        lastState: lastState ?? this.lastState,
        lastAssetId: lastAssetId ?? this.lastAssetId,
        manualAssetId: clearManualAssetId ? null : (manualAssetId ?? this.manualAssetId),
        usageStatsTab: usageStatsTab ?? this.usageStatsTab,
        overlayAutomaticState: overlayAutomaticState ?? this.overlayAutomaticState,
        wheelThemeId: wheelThemeId ?? this.wheelThemeId,
        wheelCustomPrimary: wheelCustomPrimary ?? this.wheelCustomPrimary,
        wheelScale: wheelScale ?? this.wheelScale,
        wheelButtonScale: wheelButtonScale ?? this.wheelButtonScale,
        wheelMenuDistance: wheelMenuDistance ?? this.wheelMenuDistance,
      );

  /// 约束到合法区间，避免手工改数据库或旧版本配置造成异常值。
  AppSettings normalized() {
    final double s = scale.clamp(1.0, 4.0).toDouble();
    return copyWith(
      // 只允许整数倍，避免像素画出现非整数缩放导致的模糊。
      scale: s.roundToDouble().clamp(1.0, 4.0).toDouble(),
      opacity: opacity.clamp(0.2, 1.0).toDouble(),
      crossFadeMs: crossFadeMs.clamp(
        RenderTimings.crossFadeMinMs,
        RenderTimings.crossFadeMaxMs,
      ),
      // 只接受两个已知取值，其它（旧配置 / 手改数据库）一律回到「本机」。
      usageStatsTab: usageStatsTab == usageStatsTabCloud
          ? usageStatsTabCloud
          : usageStatsTabLocal,
      // 轮盘：与 Android `WheelMenuLayoutSettings.normalized()` 同一口径
      // （大小 / 按钮吸附到 10% 步进，距离直接夹取）。
      wheelScale: WheelMenuLayoutSettings.quantizeScale(wheelScale),
      wheelButtonScale: WheelMenuLayoutSettings.quantizeButtonScale(wheelButtonScale),
      wheelMenuDistance: WheelMenuLayoutSettings.clampDistance(wheelMenuDistance),
      wheelThemeId: WheelMenuThemes.preset(wheelThemeId) != null ||
              wheelThemeId == WheelThemeIds.custom
          ? wheelThemeId
          : WheelThemeIds.p3pPink,
    );
  }

  /// 主题解析（把持久化的 id + 自定义主色还原成完整主题）。
  ///
  /// 自定义主色非法（空 / 解析失败）时 [WheelMenuTheme.fromWire] 会回退 P3P 粉同构配色。
  static WheelMenuThemeResolver get themeResolver => const WheelMenuThemeResolver._();

  /// 当前轮盘主题（由 `wheelThemeId` + `wheelCustomPrimary` 解析）。
  WheelMenuTheme get wheelTheme => themeResolver.resolve(
        themeId: wheelThemeId,
        customPrimary: wheelCustomPrimary,
      );

  /// 轮盘几何设置（直接喂给 `WheelMenuGeometry`）。
  WheelMenuLayoutSettings get wheelLayoutSettings => WheelMenuLayoutSettings(
        preferredScale: wheelScale,
        menuDistance: wheelMenuDistance,
        buttonVisualScale: wheelButtonScale,
      ).normalized();

  Map<String, String> toKeyValues() => <String, String>{
        'window.alwaysOnTop': alwaysOnTop ? '1' : '0',
        'window.ignoreMouseEvents': ignoreMouseEvents ? '1' : '0',
        'window.lockPosition': lockPosition ? '1' : '0',
        'window.scale': scale.toString(),
        'window.smoothScaling': smoothScaling ? '1' : '0',
        'window.opacity': opacity.toString(),
        'window.crossFadeMs': '$crossFadeMs',
        'window.loopAnimation': loopAnimation ? '1' : '0',
        'window.x': windowX?.toString() ?? '',
        'window.y': windowY?.toString() ?? '',
        'window.positionSchema': windowPositionSchema.toString(),
        'behavior.hideOnFullscreen': hideOnFullscreen ? '1' : '0',
        'behavior.launchAtStartup': launchAtStartup ? '1' : '0',
        'character.defaultCharacterId': defaultCharacterId ?? '',
        'character.defaultAssetId': defaultAssetId ?? '',
        'state.lastCharacterId': lastCharacterId ?? '',
        'state.lastState': lastState.wireName,
        'state.lastAssetId': lastAssetId ?? '',
        'state.manualAssetId': manualAssetId ?? '',
        'ui.usageStatsTab': usageStatsTab,
        'overlay.automaticState': overlayAutomaticState ? '1' : '0',
        'wheel.themeId': wheelThemeId,
        'wheel.customPrimary': wheelCustomPrimary,
        'wheel.scale': wheelScale.toString(),
        'wheel.buttonScale': wheelButtonScale.toString(),
        'wheel.menuDistance': wheelMenuDistance.toString(),
      };

  static AppSettings fromKeyValues(Map<String, String> kv) {
    final AppSettings base = const AppSettings();
    return AppSettings(
      alwaysOnTop: _bool(kv['window.alwaysOnTop'], base.alwaysOnTop),
      ignoreMouseEvents: _bool(kv['window.ignoreMouseEvents'], base.ignoreMouseEvents),
      lockPosition: _bool(kv['window.lockPosition'], base.lockPosition),
      scale: _double(kv['window.scale'], base.scale),
      smoothScaling: _bool(kv['window.smoothScaling'], base.smoothScaling),
      opacity: _double(kv['window.opacity'], base.opacity),
      crossFadeMs: _int(kv['window.crossFadeMs'], base.crossFadeMs),
      loopAnimation: _bool(kv['window.loopAnimation'], base.loopAnimation),
      windowX: _doubleOrNull(kv['window.x']),
      windowY: _doubleOrNull(kv['window.y']),
      windowPositionSchema: _int(kv['window.positionSchema'], WindowPositionSchema.none),
      hideOnFullscreen: _bool(kv['behavior.hideOnFullscreen'], base.hideOnFullscreen),
      launchAtStartup: _bool(kv['behavior.launchAtStartup'], base.launchAtStartup),
      defaultCharacterId: _stringOrNull(kv['character.defaultCharacterId']),
      defaultAssetId: _stringOrNull(kv['character.defaultAssetId']),
      lastCharacterId: _stringOrNull(kv['state.lastCharacterId']),
      lastState: kv['state.lastState'] == null
          ? SystemState.defaultState
          : SystemState.fromWire(kv['state.lastState']!),
      lastAssetId: _stringOrNull(kv['state.lastAssetId']),
      manualAssetId: _stringOrNull(kv['state.manualAssetId']),
      usageStatsTab: _stringOrNull(kv['ui.usageStatsTab']) ?? base.usageStatsTab,
      overlayAutomaticState:
          _bool(kv['overlay.automaticState'], base.overlayAutomaticState),
      wheelThemeId: _stringOrNull(kv['wheel.themeId']) ?? base.wheelThemeId,
      wheelCustomPrimary: kv['wheel.customPrimary'] ?? base.wheelCustomPrimary,
      wheelScale: _double(kv['wheel.scale'], base.wheelScale),
      wheelButtonScale: _double(kv['wheel.buttonScale'], base.wheelButtonScale),
      wheelMenuDistance: _double(kv['wheel.menuDistance'], base.wheelMenuDistance),
    ).normalized();
  }

  static bool _bool(String? raw, bool fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  static double _double(String? raw, double fallback) =>
      double.tryParse(raw ?? '') ?? fallback;

  static int _int(String? raw, int fallback) => int.tryParse(raw ?? '') ?? fallback;

  static double? _doubleOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  static String? _stringOrNull(String? raw) =>
      (raw == null || raw.isEmpty) ? null : raw;
}

/// 主题解析器（把持久化字段还原成 [WheelMenuTheme]）。
///
/// 单一入口，避免设置页 / 渲染器 / 诊断各自解析出不同结果。
class WheelMenuThemeResolver {
  const WheelMenuThemeResolver._();

  /// 由持久化的 `themeId` + 自定义主色文本还原完整主题。
  ///
  /// * `themeId` 为空 / 未命中预设 → 回退 P3P 粉（与 Android `fromWire` 同口径）；
  /// * 自定义主色解析失败（空 / 非法 hex）→ 用 P3P 主色派生，**不抛异常**。
  WheelMenuTheme resolve({
    required String themeId,
    String customPrimary = '',
  }) {
    final int primary =
        WheelMenuThemes.parseHex(customPrimary) ?? WheelMenuThemes.p3pPrimary;
    return WheelMenuTheme.fromWire(themeId, primary);
  }
}

/// 便于设置页直接拿到主题 id 列表（顺序与 Android 预设顺序一致）。
List<String> wheelThemePresetIds() =>
    <String>[for (final theme in WheelMenuThemes.presets) theme.themeId];
