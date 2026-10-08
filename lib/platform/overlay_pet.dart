/// Android 系统级悬浮桌宠的平台契约（Phase 4C）。
///
/// 为什么单独抽一个接口而不是直接调 MethodChannel：
/// * **Windows 不得加载 Android 专属逻辑** —— Windows/桩实现返回
///   [UnsupportedOverlayPet]，界面按 `isSupported()`/能力位隐藏整个分区；
/// * 悬浮桌宠的权限、生命周期、素材更新是"有状态 + 会失败"的操作，
///   需要一层可测试的模型（配置校验、状态解析）挡在通道之前。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../activity_tracking/android_usage_session.dart';
import '../activity_tracking/current_activity_provider.dart';
import 'overlay_state_mapping.dart';

/// 悬浮桌宠配置（Flutter ↔ 原生统一的传输模型）。
///
/// 只承载"原生渲染需要的最小信息"：素材文件、MIME、动画参数、缩放与吸附。
/// 不含任何账户 / 令牌 / 路径以外的隐私字段。
class OverlayPetConfig {
  const OverlayPetConfig({
    this.schemaVersion = 1,
    required this.characterId,
    required this.assetId,
    required this.filePath,
    required this.mimeType,
    this.isAnimated = false,
    this.frameCount = 0,
    this.animationDurationMs = 0,
    this.scale = 1.0,
    this.snapEnabled = true,
    this.fixedAssetMode = false,
  });

  /// 传输协议版本；原生端遇到未知版本会拒绝而不是猜。
  final int schemaVersion;

  final String characterId;
  final String assetId;
  final String filePath;
  final String mimeType;
  final bool isAnimated;
  final int frameCount;
  final int animationDurationMs;
  final double scale;

  /// 拖动松手后是否自动贴到最近的左/右边缘（默认开启）。
  final bool snapEnabled;
  final bool fixedAssetMode;

  /// 允许的悬浮窗缩放区间（与设置页滑块一致）。
  static const double minScale = 0.5;
  static const double maxScale = 2.0;

  /// 默认缩放（用户没调过大小时用它）。
  static const double defaultScale = 1.0;

  /// 设置页滑块的步长（与原生 `PetOverlayStore.MIN_SCALE/MAX_SCALE` 区间配合）。
  static const double scaleStep = 0.1;

  /// 允许的 MIME 白名单 —— 与 `ImageFormat` 支持集合一一对应。
  static const Set<String> allowedMimeTypes = <String>{
    'image/png',
    'image/webp',
    'image/jpeg',
    'image/gif',
  };

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'characterId': characterId,
        'assetId': assetId,
        'filePath': filePath,
        'mimeType': mimeType,
        'isAnimated': isAnimated,
        'frameCount': frameCount,
        'animationDurationMs': animationDurationMs,
        'scale': scale,
        'snapEnabled': snapEnabled,
        'fixedAssetMode': fixedAssetMode,
      };

  /// 严格解析（缺字段/类型不符直接抛错，不做"猜一个默认值"）。
  factory OverlayPetConfig.fromJson(Map<String, Object?> json) {
    final Object? rawScale = json['scale'];
    return OverlayPetConfig(
      schemaVersion: _int(json['schemaVersion'], 'schemaVersion'),
      characterId: _string(json['characterId'], 'characterId'),
      assetId: _string(json['assetId'], 'assetId'),
      filePath: _string(json['filePath'], 'filePath'),
      mimeType: _string(json['mimeType'], 'mimeType'),
      isAnimated: json['isAnimated'] == true,
      frameCount: _int(json['frameCount'], 'frameCount', fallback: 0),
      animationDurationMs:
          _int(json['animationDurationMs'], 'animationDurationMs', fallback: 0),
      scale: rawScale is num ? rawScale.toDouble() : 1.0,
      snapEnabled: json['snapEnabled'] != false,
      fixedAssetMode: json['fixedAssetMode'] == true,
    );
  }

  /// 复制并覆盖若干字段（相同素材去重时用得到）。
  OverlayPetConfig copyWith({
    bool? isAnimated,
    int? frameCount,
    int? animationDurationMs,
    double? scale,
    bool? snapEnabled,
    bool? fixedAssetMode,
  }) =>
      OverlayPetConfig(
        schemaVersion: schemaVersion,
        characterId: characterId,
        assetId: assetId,
        filePath: filePath,
        mimeType: mimeType,
        isAnimated: isAnimated ?? this.isAnimated,
        frameCount: frameCount ?? this.frameCount,
        animationDurationMs: animationDurationMs ?? this.animationDurationMs,
        scale: scale ?? this.scale,
        snapEnabled: snapEnabled ?? this.snapEnabled,
        fixedAssetMode: fixedAssetMode ?? this.fixedAssetMode,
      );

  /// 校验配置。**不合格就抛错**，绝不把坏配置送进原生层。
  ///
  /// [privateAssetsRoot] 是应用私有素材根目录（`AppPaths.instance.assetsRoot`），
  /// 显式传入而不是自己去读全局单例，这样这条安全规则可以被单独测试。
  void validate({required String privateAssetsRoot}) {
    if (characterId.trim().isEmpty) {
      throw const OverlayConfigException('empty_character_id', '缺少角色 ID');
    }
    if (assetId.trim().isEmpty) {
      throw const OverlayConfigException('empty_asset_id', '缺少素材 ID');
    }
    if (filePath.trim().isEmpty) {
      throw const OverlayConfigException('empty_file_path', '缺少素材文件路径');
    }
    if (scale < minScale || scale > maxScale) {
      throw OverlayConfigException(
        'scale_out_of_range',
        '缩放必须介于 $minScale ~ $maxScale（当前 $scale）',
      );
    }
    if (!allowedMimeTypes.contains(mimeType)) {
      throw OverlayConfigException('unsupported_mime', '不支持的素材类型：$mimeType');
    }
    if (frameCount < 0 || animationDurationMs < 0) {
      throw const OverlayConfigException('negative_animation_meta', '动画参数不能为负数');
    }
    if (schemaVersion != 1) {
      throw OverlayConfigException('unsupported_schema', '未知的配置版本：$schemaVersion');
    }

    final String normalizedFile = p.normalize(filePath);
    // 路径穿越：`..` 在任何一段里出现都直接拒绝（normalize 之后再查一次，
    // 防止 `a/../b` 这类伪装）。
    if (filePath.contains('..') || p.split(normalizedFile).contains('..')) {
      throw const OverlayConfigException('path_traversal', '素材路径不允许包含 ..');
    }
    final String normalizedRoot = p.normalize(privateAssetsRoot);
    if (!p.isWithin(normalizedRoot, normalizedFile)) {
      throw const OverlayConfigException(
        'outside_private_root',
        '素材必须位于应用私有目录内',
      );
    }
    if (!File(normalizedFile).existsSync()) {
      throw const OverlayConfigException('file_missing', '素材文件不存在');
    }
  }

  static String _string(Object? value, String field) {
    if (value is String && value.isNotEmpty) return value;
    throw OverlayConfigException('invalid_field', '字段 $field 缺失或类型不符');
  }

  static int _int(Object? value, String field, {int? fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (fallback != null) return fallback;
    throw OverlayConfigException('invalid_field', '字段 $field 缺失或类型不符');
  }
}

/// 悬浮窗外观/行为设置（设置页改动时下发）。
class OverlayPetSettings {
  const OverlayPetSettings({
    required this.scale,
    this.snapEnabled = true,
    this.touchThrough = false,
    this.hideOnLockScreen = true,
    this.fixedAssetMode = false,
    this.xRatio,
    this.yRatio,
  });

  final double scale;

  /// 拖动松手后是否自动贴边（需求 `overlay_snap_enabled`）。
  final bool snapEnabled;

  /// 触摸穿透：开启后必须能从通知栏或设置页恢复（否则用户再也点不到桌宠）。
  final bool touchThrough;
  final bool hideOnLockScreen;
  final bool fixedAssetMode;

  /// 相对位置（0~1）。为 null 表示"不改动当前位置"。
  ///
  /// 这两个值由**原生拖动**产生，界面一般只读不写；只有"重置位置"这类
  /// 显式操作才会下发，避免把用户拖出来的位置覆盖掉。
  final double? xRatio;
  final double? yRatio;

  Map<String, Object?> toJson() => <String, Object?>{
        'scale': scale,
        'snapEnabled': snapEnabled,
        'touchThrough': touchThrough,
        'hideOnLockScreen': hideOnLockScreen,
        'fixedAssetMode': fixedAssetMode,
        if (xRatio != null) 'xRatio': xRatio,
        if (yRatio != null) 'yRatio': yRatio,
      };

  void validate() {
    if (scale < OverlayPetConfig.minScale || scale > OverlayPetConfig.maxScale) {
      throw OverlayConfigException(
        'scale_out_of_range',
        '缩放必须介于 ${OverlayPetConfig.minScale} ~ ${OverlayPetConfig.maxScale}',
      );
    }
    for (final double? ratio in <double?>[xRatio, yRatio]) {
      if (ratio != null && (ratio < 0 || ratio > 1)) {
        throw const OverlayConfigException('ratio_out_of_range', '相对位置必须在 0 ~ 1');
      }
    }
  }
}

/// 授权状态。
class OverlayPermissionState {
  const OverlayPermissionState({
    required this.supported,
    required this.overlayGranted,
    required this.notificationsGranted,
    required this.notificationsRequired,
  });

  final bool supported;

  /// 是否已获得「显示在其他应用上层」权限 —— **唯一**决定能否显示悬浮桌宠的权限。
  final bool overlayGranted;

  final bool notificationsGranted;

  /// Android 13+ 才需要运行时申请通知权限。
  final bool notificationsRequired;

  factory OverlayPermissionState.fromMap(Map<String, Object?> map) =>
      OverlayPermissionState(
        supported: map['supported'] == true,
        overlayGranted: map['overlayGranted'] == true,
        notificationsGranted: map['notificationsGranted'] == true,
        notificationsRequired: map['notificationsRequired'] == true,
      );

  static const OverlayPermissionState unsupported = OverlayPermissionState(
    supported: false,
    overlayGranted: false,
    notificationsGranted: false,
    notificationsRequired: false,
  );
}

/// 开机自启状态（Phase 4D，Android）。
///
/// 与 [OverlayRuntimeState] 里的 `enabled` / `hidden` **是两回事**：
/// * `enabled` / `hidden` 描述"现在桌宠在不在显示"；
/// * [enabled] 只描述"重启后要不要把服务拉起来"。
/// 关闭开机自启不会停止当前桌宠；隐藏桌宠也不会关闭开机自启。
class OverlayAutostartStatus {
  const OverlayAutostartStatus({
    this.supported = false,
    this.enabled = false,
    this.overlayGranted = false,
    this.bootResultCode,
    this.bootResultAt,
    this.bootResultDetail,
  });

  final bool supported;

  /// 用户是否开启了"开机自动启动"（原生 SharedPreferences 里的权威值）。
  final bool enabled;

  /// 悬浮窗权限当前是否已授予（`system_blocked` 之外的另一个常见失败原因）。
  final bool overlayGranted;

  /// 最近一次开机自启结果码（null = 从未有过开机记录）。
  final String? bootResultCode;

  /// 最近一次开机结果的记录时间（null = 从未记录）。
  final DateTime? bootResultAt;

  /// 结果补充说明（诊断用；如异常类名）。
  final String? bootResultDetail;

  /// 开关状态的中文文案。
  String get switchLabelZh => enabled ? '已启用' : '已关闭';

  /// "最近一次开机结果"的中文文案（与原生 `BootAutostart` 的结果码逐字对应）。
  String? get bootResultLabelZh => switch (bootResultCode) {
        null => null,
        'disabled' => '已关闭，未随开机启动',
        'started' => '最近一次启动成功',
        'start_requested' => '正在启动…',
        'missing_overlay_permission' => '缺少悬浮窗权限',
        'system_blocked' => '系统限制后台启动',
        'already_running' => '服务已在运行',
        'duplicate_ignored' => '重复的开机信号（已忽略）',
        'start_failed' => '启动失败',
        'needs_user' => '需要用户打开应用完成恢复',
        _ => bootResultCode,
      };

  /// 是否需要**按需**给出"厂商后台/自启限制"的引导。
  ///
  /// 只有系统拒绝或需要用户介入时才提示 —— 不做"所有安卓都要去开发者设置里
  /// 开自启动"这种一刀切误导（不同厂商限制差异很大）。
  bool get needsVendorGuidance =>
      bootResultCode == 'system_blocked' || bootResultCode == 'needs_user';

  factory OverlayAutostartStatus.fromMap(Map<String, Object?> map) {
    final int at = map['bootResultAt'] is num
        ? (map['bootResultAt']! as num).toInt()
        : 0;
    return OverlayAutostartStatus(
      supported: map['supported'] == true,
      enabled: map['enabled'] == true,
      overlayGranted: map['overlayGranted'] == true,
      bootResultCode: map['bootResultCode'] as String?,
      bootResultAt:
          at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      bootResultDetail: map['bootResultDetail'] as String?,
    );
  }

  static const OverlayAutostartStatus unsupported =
      OverlayAutostartStatus(supported: false);
}

/// 「双窗口实现」开关状态（单窗口 → 双窗口迁移期的**临时回退开关**）。
///
/// 与「双窗口探针诊断」是两回事：
/// * 探针（[DualWindowProbeStatus]）是**只读诊断**，展示原生窗口布局的真值；
/// * 本开关是**可写**的：`true` = 走新的双窗口实现（默认），
///   `false` = 回退到旧的单窗口实现。
///
/// 原生把该标志持久化并**立即生效**（会重建悬浮窗）。非 Android 恒为
/// [unsupported]（[supported] = false），界面据此不渲染开关。
class DualWindowModeStatus {
  const DualWindowModeStatus({
    this.supported = false,
    this.dualWindowEnabled = true,
  });

  /// 当前平台是否支持该开关（非 Android 为 false）。
  final bool supported;

  /// `true` = 双窗口实现（默认）；`false` = 回退单窗口实现。
  final bool dualWindowEnabled;

  /// 当前模式的中文文案。
  String get modeLabelZh => dualWindowEnabled ? '双窗口（新实现）' : '单窗口（回退）';

  /// 解析原生 `getDualWindowMode` 的返回值（原生直接回 `bool`）。
  ///
  /// 宽容解析：只有明确的 `bool` 才采信；缺键 / 类型不符一律退化为安全默认
  /// `true`（默认走双窗口），**绝不抛错**。
  factory DualWindowModeStatus.fromValue(Object? value) => DualWindowModeStatus(
        supported: true,
        dualWindowEnabled: value is bool ? value : true,
      );

  static const DualWindowModeStatus unsupported =
      DualWindowModeStatus(supported: false, dualWindowEnabled: true);
}

/// 运行时状态。
enum OverlayPetStatus {
  /// 未运行。
  stopped,

  /// 运行中且窗口可见。
  running,

  /// 服务在运行、窗口已隐藏（隐藏 ≠ 停止）。
  hidden;

  String get labelZh => switch (this) {
        OverlayPetStatus.stopped => '已停止',
        OverlayPetStatus.running => '运行中',
        OverlayPetStatus.hidden => '已隐藏',
      };
}

class OverlayRuntimeState {
  const OverlayRuntimeState({
    required this.supported,
    required this.serviceRunning,
    required this.windowAttached,
    required this.enabled,
    required this.hidden,
    required this.overlayGranted,
    required this.notificationsGranted,
    this.characterId,
    this.assetId,
    this.mimeType,
    this.isAnimated = false,
    this.frameCount = 0,
    this.animationDurationMs = 0,
    this.scale = 1.0,
    this.snapEnabled = true,
    this.snapEdge = 'none',
    this.snapOrientation = 'unknown',
    this.touchThrough = false,
    this.hideOnLockScreen = true,
    this.fixedAssetMode = false,
    this.xRatio = 0.85,
    this.yRatio = 0.3,
    this.displayedAssetId,
    this.isPlaceholder = true,
    this.lastLoadError,
    this.lastUpdatedAt,
    this.animatedFirstFrameOnly = false,
    this.visualType = 'placeholder',
    this.animationFrameMode = 'not-applicable',
    this.animationSupported = false,
    this.animationPlaying = false,
    this.animationPausedReason,
    this.decodeCode,
    this.windowVisible = false,
    this.attachedToWindow = false,
    this.viewWidth = 0,
    this.viewHeight = 0,
    this.imageViewWidth = 0,
    this.imageViewHeight = 0,
    this.petWidth = 0,
    this.petHeight = 0,
    this.gestureState = 'IDLE',
    this.menuState = 'closed',
    this.menuButtonCount = 0,
    this.lastMenuAction,
    this.menuLevel = 'none',
    this.menuActiveIndex = 0,
    this.menuAnimation = 'idle',
    this.menuGestureOwner = 'none',
    this.menuThemeId = 'p3p-pink',
    this.menuPerformance = 'wheel perf=<none>',
    this.menuOpenDiagnostics = 'menuOpen=<none>',
    this.lastMenuActionPlaceholder = false,
    this.lastWindowError,
    this.lastWindowAction = 'none',
    this.visual = 'absent',
    this.debugOverlayMode = false,
  });

  /// 低版本（API 24~27）动态素材的**如实**口径（与原生 `ANIMATED_FIRST_FRAME_FALLBACK_NOTICE` 一致）。
  ///
  /// 4C-4 起 API 28+ 会真正播放动画，因此**不再**无条件显示"完整动画将在 4C-4 实现"。
  static const String animatedFirstFrameFallbackText =
      '当前 Android 版本不支持原生动态 WebP 播放，正在显示第一帧';

  /// 动态素材正在播放时的口径。
  static const String animatedPlayingText = '动态素材正在播放';

  final bool supported;
  final bool serviceRunning;
  final bool windowAttached;
  final bool enabled;
  final bool hidden;
  final bool overlayGranted;
  final bool notificationsGranted;

  /// 配置里**期望**显示的素材。
  final String? assetId;

  /// 原生层**实际显示中**的素材；null = 仍是占位内容。
  final String? displayedAssetId;

  /// 是否正在显示占位内容（没有任何素材成功加载）。
  final bool isPlaceholder;

  /// 最近一次素材加载/校验失败原因（`code: message`）。
  final String? lastLoadError;

  /// 最近一次素材成功显示的时间。
  final DateTime? lastUpdatedAt;

  /// 当前素材是动态的、且只显示第一帧（API 24~27 才会为 true）。
  final bool animatedFirstFrameOnly;

  /// Phase 4C-4：视觉类型 `static` / `animated` / `placeholder`。
  final String visualType;

  /// Phase 4C-4：帧模式 `full-animation` / `first-frame-fallback` / `not-applicable`。
  final String animationFrameMode;

  /// Phase 4C-4：当前系统是否支持完整动画（API 28+）。
  final bool animationSupported;

  /// Phase 4C-4：动画当前是否真的在播放。
  final bool animationPlaying;

  /// Phase 4C-4：最近一次"不允许播放"的原因（诊断）。
  final String? animationPausedReason;

  /// Phase 4C-4：最近一次解码错误码（成功后为空）。
  final String? decodeCode;

  /// 视觉类型的中文名（设置页显示用）。
  String get visualTypeLabelZh => switch (visualType) {
        'animated' => '动态 WebP',
        'static' => '静态图片',
        _ => '占位（无可显示素材）',
      };

  /// 播放状态的中文名（设置页显示用）。
  ///
  /// 取值口径（需求 §18）：解码失败 → 明确错误；低版本动态 → 仅第一帧；
  /// 动态且支持 → 正在播放/已暂停；静态 → 不显示动态提示。
  String get animationStateLabelZh {
    if (decodeCode != null || (lastLoadError != null && isPlaceholder)) {
      return '素材加载失败';
    }
    if (visualType != 'animated') {
      return visualType == 'static' ? '静态素材（无需播放）' : '等待素材';
    }
    if (animationFrameMode == 'first-frame-fallback') {
      return animatedFirstFrameFallbackText;
    }
    if (animationPlaying) return animatedPlayingText;
    return animationPausedReason == null ? '已暂停' : '已暂停（$animationPausedReason）';
  }

  /// 是否需要在设置页显示一行动态素材说明（静态素材不显示）。
  bool get showsAnimationHint => visualType == 'animated';

  /// 窗口是否可见（原生侧根 View 的可见性）。
  final bool windowVisible;

  /// 根 View 是否已附着到窗口（`addView` 真正生效的判据）。
  final bool attachedToWindow;

  /// 窗口**真实**像素尺寸（0 说明测量失败 —— 这正是"看不见"的直接证据）。
  final int viewWidth;
  final int viewHeight;

  /// ImageView 的真实像素尺寸。
  final int imageViewWidth;
  final int imageViewHeight;

  /// 最近一次 addView / updateViewLayout 失败原因。
  final String? lastWindowError;

  /// 最近一次窗口操作（**含成功**）——"show 之后有没有人 removeView"靠它追。
  final String lastWindowAction;

  /// 原生可见状态：`asset` / `loading` / `failure` / `empty` / `debug` / `absent`。
  final String visual;

  /// 诊断模式是否开启（固定洋红方块，不读素材）。
  final bool debugOverlayMode;

  final String? characterId;
  final String? mimeType;
  final bool isAnimated;
  final int frameCount;
  final int animationDurationMs;
  final double scale;

  /// 拖动松手后是否自动贴边。
  final bool snapEnabled;

  /// 当前吸附到的边：`left` / `right` / `none`。
  final String snapEdge;

  /// 保存位置时的屏幕方向（诊断用）。
  final String snapOrientation;

  final bool touchThrough;
  final bool hideOnLockScreen;
  final bool fixedAssetMode;

  /// 相对位置（0~1，相对**可用区域**而不是屏幕宽高）。
  final double xRatio;
  final double yRatio;

  /// Phase 4C-3A：窗口真实像素尺寸（按素材宽高比，不再是正方形）。
  final int petWidth;
  final int petHeight;

  /// 原生手势状态机当前状态名（IDLE / PRESSING / DRAGGING / SCALING / …）。
  final String gestureState;

  /// 圆盘菜单状态名（closed / opening / open / closing）—— 4C-3B。
  final String menuState;

  /// 当前菜单按钮数量（诊断）。
  final int menuButtonCount;

  /// 最近一次菜单按钮动作（占位按钮只会产生"功能尚未配置"）。
  final String? lastMenuAction;

  // --- Phase 4C-6B-1：P3P 风格分层轮盘（只读诊断）---

  /// 轮盘当前层级 ID（`root` / `pet` / `appearance` / `records` / `tools` / `settings`）。
  final String menuLevel;

  /// 轮盘当前高亮槽位下标。
  final int menuActiveIndex;

  /// 轮盘当前动画（`idle` / `open` / `close` / `selectionSwitch` / `enterLayer` / `exitLayer`）。
  final String menuAnimation;

  /// 轮盘手势归属（`none` / `pressing` / `swiping` / `pendingOutside`）。
  final String menuGestureOwner;

  /// 轮盘当前主题 ID。
  final String menuThemeId;

  /// 每帧耗时统计（需求 §15 的调试指标）。
  final String menuPerformance;

  /// 菜单打开链路的**可判定诊断**（Phase 4C-6B-1.1 真机回归）：
  /// `tap / req / addAttempt / addOk / attached / vis / bounds / types / err`。
  final String menuOpenDiagnostics;

  /// 最近一次轮盘动作是否只是**占位**（4C-6B-1 的业务项为 true，导航为 false）。
  final bool lastMenuActionPlaceholder;

  /// 菜单是否处于打开（或正在开/关）状态。
  bool get menuOccupiesWindow => menuState != 'closed';

  /// 菜单状态的人类可读名。
  String get menuStateLabelZh => switch (menuState) {
        'opening' => '展开中',
        'open' => '已展开',
        'closing' => '收起中',
        _ => '已关闭',
      };

  /// 轮盘层级的中文名（诊断区显示用）。
  String get menuLevelLabelZh => switch (menuLevel) {
        'root' => '根菜单',
        'pet' => '桌宠',
        'appearance' => '形象',
        'records' => '记录',
        'tools' => '工具',
        'settings' => '设置',
        'none' => '未打开',
        _ => menuLevel,
      };

  /// 缩放百分比（设置页显示用；四舍五入到整数）。
  int get scalePercent => (scale * 100).round();

  /// 设置页滑块的位置（0~1，把 50%~200% 映射到 slider）。
  double get scaleSliderValue =>
      (scale - OverlayPetConfig.minScale) /
      (OverlayPetConfig.maxScale - OverlayPetConfig.minScale);

  /// 吸附边的人类可读名。
  String get snapEdgeLabelZh => switch (snapEdge) {
        'left' => '左',
        'right' => '右',
        _ => '无',
      };

  OverlayPetStatus get status {
    if (!serviceRunning) return OverlayPetStatus.stopped;
    return hidden ? OverlayPetStatus.hidden : OverlayPetStatus.running;
  }

  /// 素材是否已经刷新成配置期望的那一张（用于设置页判断"是否还在加载"）。
  bool get showsExpectedAsset =>
      !isPlaceholder && assetId != null && displayedAssetId == assetId;

  /// **服务在运行，但窗口没有挂载** —— 必须显式告诉用户，不能让他干等。
  bool get windowMissing => serviceRunning && !hidden && !windowAttached;

  /// 窗口已挂载但根 View 还没附着到窗口（`addView` 尚未生效）。
  bool get windowNotAttached => windowAttached && !attachedToWindow;

  /// 窗口尺寸是否为 0（4C-2 真机缺陷的直接症状）。
  bool get hasZeroSizedWindow =>
      windowAttached && (viewWidth <= 0 || viewHeight <= 0);

  /// 一条能直接显示给用户的窗口诊断摘要。
  String get windowSummary {
    if (!serviceRunning) return '未运行';
    if (hidden) return '已隐藏';
    if (!windowAttached) return '未挂载';
    if (hasZeroSizedWindow) return '已挂载但尺寸为 0';
    return '已挂载 $viewWidth×$viewHeight';
  }

  factory OverlayRuntimeState.fromMap(Map<String, Object?> map) {
    final int updatedAt = _int(map['lastUpdatedAt']);
    return OverlayRuntimeState(
      supported: map['supported'] == true,
      serviceRunning: map['serviceRunning'] == true,
      windowAttached: map['windowAttached'] == true,
      enabled: map['enabled'] == true,
      hidden: map['hidden'] == true,
      overlayGranted: map['overlayGranted'] == true,
      notificationsGranted: map['notificationsGranted'] == true,
      characterId: map['characterId'] as String?,
      assetId: map['assetId'] as String?,
      mimeType: map['mimeType'] as String?,
      isAnimated: map['isAnimated'] == true,
      frameCount: _int(map['frameCount']),
      animationDurationMs: _int(map['animationDurationMs']),
      scale: _double(map['scale'], 1.0),
      snapEnabled: map['snapEnabled'] != false,
      snapEdge: (map['snapEdge'] as String?) ?? 'none',
      snapOrientation: (map['snapOrientation'] as String?) ?? 'unknown',
      touchThrough: map['touchThrough'] == true,
      hideOnLockScreen: map['hideOnLockScreen'] != false,
      fixedAssetMode: map['fixedAssetMode'] == true,
      xRatio: _double(map['xRatio'], 0.85),
      yRatio: _double(map['yRatio'], 0.3),
      displayedAssetId: map['displayedAssetId'] as String?,
      isPlaceholder: map['isPlaceholder'] != false,
      lastLoadError: map['lastLoadError'] as String?,
      lastUpdatedAt: updatedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(updatedAt)
          : null,
      // 4C-4：低版本回退标记由原生结构化字段推导（不再依赖一句话文案）。
      animatedFirstFrameOnly: (map['animationFrameMode'] as String?) ==
          'first-frame-fallback',
      visualType: (map['visualType'] as String?) ?? 'placeholder',
      animationFrameMode: (map['animationFrameMode'] as String?) ?? 'not-applicable',
      animationSupported: map['animationSupported'] == true,
      animationPlaying: map['animationPlaying'] == true,
      animationPausedReason: map['animationPausedReason'] as String?,
      decodeCode: map['decodeCode'] as String?,
      windowVisible: map['windowVisible'] == true,
      attachedToWindow: map['attachedToWindow'] == true,
      viewWidth: _int(map['viewWidth']),
      viewHeight: _int(map['viewHeight']),
      imageViewWidth: _int(map['imageViewWidth']),
      imageViewHeight: _int(map['imageViewHeight']),
      petWidth: _int(map['petWidth']),
      petHeight: _int(map['petHeight']),
      gestureState: (map['gestureState'] as String?) ?? 'IDLE',
      menuState: (map['menuState'] as String?) ?? 'closed',
      menuButtonCount: _int(map['menuButtonCount']),
      lastMenuAction: map['lastMenuAction'] as String?,
      menuLevel: (map['menuLevel'] as String?) ?? 'none',
      menuActiveIndex: _int(map['menuActiveIndex']),
      menuAnimation: (map['menuAnimation'] as String?) ?? 'idle',
      menuGestureOwner: (map['menuGestureOwner'] as String?) ?? 'none',
      menuThemeId: (map['menuThemeId'] as String?) ?? 'p3p-pink',
      menuPerformance: (map['menuPerformance'] as String?) ?? 'wheel perf=<none>',
      menuOpenDiagnostics: (map['menuOpenDiagnostics'] as String?) ?? 'menuOpen=<none>',
      lastMenuActionPlaceholder: map['lastMenuActionPlaceholder'] == true,
      lastWindowError: map['lastWindowError'] as String?,
      lastWindowAction: (map['lastWindowAction'] as String?) ?? 'none',
      visual: (map['visual'] as String?) ?? 'absent',
      debugOverlayMode: map['debugOverlayMode'] == true,
    );
  }

  static const OverlayRuntimeState unsupported = OverlayRuntimeState(
    supported: false,
    serviceRunning: false,
    windowAttached: false,
    enabled: false,
    hidden: false,
    overlayGranted: false,
    notificationsGranted: false,
  );

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  static double _double(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;
}

/// 状态联动的**只读诊断**（Phase 4C-5，需求 §19）。
///
/// 只用于设置页展示：**不由 Flutter 驱动任何状态切换**（切换在原生侧完成，
/// 且原生侧即使 Flutter 已退出也继续工作）。
///
/// 隐私：只有一个包名、一个可读应用标签、分类与状态 ID，
/// 不含屏幕内容 / 输入内容 / 通知 / 聊天 / 文件路径。
class OverlayStateDiagnostics {
  const OverlayStateDiagnostics({
    this.stateId = 'default',
    this.stateLabel = '默认',
    this.stateSource = 'unsupported',
    this.stateReason = '尚未检测',
    this.foregroundPackage,
    this.foregroundLabel,
    this.category,
    this.categorySource,
    this.candidateState,
    this.candidateCount = 0,
    this.manualOverride,
    this.usageAccessGranted = false,
    this.monitorRunning = false,
    this.mappingRevision = 0,
    this.stateAssetId,
    this.fallbackLevel = 0,
    this.lastChangedAt,
    this.stateErrorCode,
    this.detectionSource = 'unavailable',
    this.detectionReason,
    this.eventCount = 0,
    this.resumedEventCount = 0,
    this.usableEventCount = 0,
    this.statsCount = 0,
    this.lastRawPackage,
    this.appOpsAllowed = false,
    this.automaticStateEnabled = true,
    this.matchedRule,
    this.collectorRunning = false,
    this.resolvedTargetState,
    this.stableState,
    this.candidateSince,
    this.candidateElapsedMs = 0,
    this.categoryDetail,
    this.platformAppCategory,
    this.mappingReceivedAt,
    this.lastTransitionResult,
    this.lastTransitionReason,
    this.lastCommittedAt,
    this.displayMode = 'auto',
    this.previewState,
    this.previewExpiresAt,
  });

  /// 当前状态 ID（与 Dart `SystemState.wireName` 同一套命名）。
  final String stateId;

  /// 状态中文名（原生回报，避免两端各写一份翻译）。
  final String stateLabel;

  /// 来源：`manual-debug` / `foreground-app` / `idle` / `default` / `screen-off` / `unsupported`。
  final String stateSource;

  /// 判定原因（原生给出的人可读说明）。
  final String stateReason;

  final String? foregroundPackage;
  final String? foregroundLabel;

  /// 应用分类（`AppCategory.wireName`）。
  final String? category;

  /// 分类来源：`user-override` / `built-in-rule` / `fallback`。
  final String? categorySource;

  /// 尚未通过防抖的候选状态。
  final String? candidateState;
  final int candidateCount;

  /// 状态调试器的手动覆盖（null = 未覆盖）。
  final String? manualOverride;

  /// 是否已授予"使用情况访问"权限。
  final bool usageAccessGranted;

  /// 状态监听任务是否在运行。
  final bool monitorRunning;

  /// 原生当前生效的映射版本。
  final int mappingRevision;

  /// 当前状态实际选中的素材 ID（只给 ID，不给内部路径）。
  final String? stateAssetId;

  /// 命中回退链的级别：1 状态素材 / 2 角色默认 / 3 任一有效 / 4 占位。
  final int fallbackLevel;

  final DateTime? lastChangedAt;

  /// 最近一次状态联动错误码。
  final String? stateErrorCode;

  // --- Phase 4C-5 缺陷 C 修复：前台应用识别的诊断（需求 §6）---

  /// 检测来源：`activity-events` / `usage-stats-fallback` / `cache` / `unavailable`。
  final String detectionSource;

  /// 检测原因 / 失败原因（如 `last-event-is-self`、`usage-access-missing`）。
  final String? detectionReason;

  /// 查询窗口内事件总数。
  final int eventCount;

  /// 其中"应用来到前台"的事件数。
  final int resumedEventCount;

  /// 其中过滤后剩下的有效外部应用事件数。
  final int usableEventCount;

  /// 使用统计兜底返回的条目数。
  final int statsCount;

  /// 窗口内**未过滤**的最后一条前台事件包名（"最后一条到底是谁"）。
  final String? lastRawPackage;

  /// AppOps 是否明确允许（与"确实能读到数据"分开报告）。
  final bool appOpsAllowed;

  /// Phase 4C-6A：自动状态联动总开关在原生侧的实际取值。
  final bool automaticStateEnabled;

  /// Phase 4C-6A：最近一次命中的规则
  /// （`user-app` / `user-category` / `built-in` / `launcher` / `hold` / `manual` / `disabled` / `none`）。
  final String? matchedRule;

  // --- Phase 4C-6A 真机诊断：状态提交链路的每一步（全部来自原生服务）---

  /// 采集器（原生侧**唯一**的前台轮询任务）是否在运行。
  final bool collectorRunning;

  /// 原生**解析出来**的目标状态（`resolvedTargetState`）。
  ///
  /// 排查"状态不变"的关键：
  /// * 与 [stateId] 都为空 → 没走到规则解析（权限 / 快照不可用）；
  /// * 有值但 [stateId] 不变 → 卡在防抖提交（见 [lastTransitionResult]）。
  final String? resolvedTargetState;

  /// 原生已提交的稳定状态（`stableState`）；旧版原生不回报时为 null。
  final String? stableState;

  /// 界面用的稳定状态：原生没单独回报 `stableState` 时等同 [stateId]。
  String get stableStateId => stableState ?? stateId;

  /// 候选状态首次出现的时间（墙钟；null = 当前没有候选）。
  final DateTime? candidateSince;

  /// 候选已持续的毫秒数（原生用单调时钟计算）。
  final int candidateElapsedMs;

  /// 分类命中的具体依据（`exact:com.android.chrome` / `keyword:game` / `platform:0`）。
  final String? categoryDetail;

  /// 系统声明的分类值（`ApplicationInfo.category`，API 26+；null = 未声明或低版本）。
  final int? platformAppCategory;

  /// 最近一次**成功应用**状态映射快照的时间（null = 本次运行尚未收到）。
  final DateTime? mappingReceivedAt;

  /// 最近一次提交结果：`committed` / `candidate` / `suppressed` / `unchanged` /
  /// `hold` / `manual` / `disabled` / `unavailable`。
  final String? lastTransitionResult;

  /// 提交结果的人可读说明。
  final String? lastTransitionReason;

  /// 最近一次状态**真正提交**的时间。
  final DateTime? lastCommittedAt;

  // --- Phase 4C-6A.1：显示模式与临时预览（需求 §11.2 / §12）---

  /// 当前**显示模式**（原生给出，三者互不混淆）：
  /// * `preview` —— 临时预览某状态的素材（到期或手动结束即恢复）；
  /// * `manual` —— 状态调试器手动覆盖（一直生效直到解除）；
  /// * `auto` —— 跟随自动状态联动。
  final String displayMode;

  /// 预览中的状态 ID（非预览时为 null）。
  final String? previewState;

  /// 预览到期时间（到点后原生自动恢复真实状态；非预览时为 null）。
  final DateTime? previewExpiresAt;

  /// 显示模式的中文说明。
  String get displayModeZh => switch (displayMode) {
        'preview' => '临时预览（到期自动恢复）',
        'manual' => '手动覆盖',
        _ => '自动（跟随前台应用）',
      };

  /// 是否正在临时预览。
  bool get isPreviewing => displayMode == 'preview';

  /// 提交结果的中文说明。
  String? get transitionResultZh => switch (lastTransitionResult) {
        null => null,
        'committed' => '已提交（stableState 已更新）',
        'candidate' => '候选中（还在等稳定）',
        'suppressed' => '已稳定，但在快速切换抑制窗口内',
        'unchanged' => '目标与当前状态相同',
        'hold' => '系统界面：保持上一个稳定状态',
        'manual' => '手动覆盖生效',
        'disabled' => '自动联动已关闭',
        'unavailable' => '权限或前台数据不可用',
        _ => lastTransitionResult,
      };

  /// 命中规则的中文说明。
  String? get matchedRuleZh => switch (matchedRule) {
        null => null,
        'user-app' => '具体应用规则',
        'user-category' => '分类规则（用户设定）',
        'built-in' => '内置分类规则',
        'launcher' => '桌面 / 空闲',
        'hold' => '系统界面：保持上一个状态',
        'manual' => '手动覆盖',
        'disabled' => '自动联动已关闭',
        'none' => '未命中任何规则',
        _ => matchedRule,
      };

  /// 状态来源的中文说明。
  String get sourceLabelZh => switch (stateSource) {
        'manual-debug' => '手动覆盖',
        'foreground-app' => '前台应用',
        'idle' => '空闲判断',
        'screen-off' => '屏幕关闭',
        'unsupported' => '不可用',
        _ => '默认',
      };

  /// 前台应用显示名（拿不到标签时退回包名）。
  String? get foregroundAppLabel => foregroundLabel ?? foregroundPackage;

  /// 回退级别的中文说明（第 1 级为正常命中，不提示）。
  String? get fallbackLabelZh => switch (fallbackLevel) {
        2 => '状态未映射，使用角色默认素材',
        3 => '状态与默认素材都不可用，使用角色任一素材',
        4 => '没有可用素材，显示占位',
        _ => null,
      };

  /// "自动联动"一行的取值（需求 §19）。
  String get linkageLabelZh {
    if (!usageAccessGranted) return '不可用';
    return monitorRunning ? '运行中' : '未运行';
  }

  /// 不可用时的原因说明。
  String? get linkageHintZh =>
      usageAccessGranted ? null : '未授予使用情况访问权限，桌宠将保持默认状态';

  /// 前台应用检测来源的中文说明。
  String get detectionSourceLabelZh => switch (detectionSource) {
        'activity-events' => '前台事件',
        'usage-stats-fallback' => '使用统计兜底',
        'cache' => '最近有效外部应用',
        _ => '不可用',
      };

  /// 检测原因的中文说明（缺陷 C 的排查入口）。
  String? get detectionReasonZh => switch (detectionReason) {
        null => null,
        'usage-stats-fallback' => '前台事件为空，已按使用统计兜底（不是精确事件）',
        'no-event-in-window' => '查询窗口内没有前台事件',
        'last-event-is-self' => '最后一条事件是 PetLife 自己（分屏或返回设置页）',
        'last-event-is-system-noise' => '最后一条事件是系统界面或输入法',
        'no-usable-external-event' => '窗口内没有可用的外部应用事件',
        'cache-expired' => '最近有效外部应用已过期',
        'usage_access_missing' => '未授予使用情况访问权限',
        _ => detectionReason,
      };

  /// "事件数：总数 / 前台 / 可用（统计兜底 n）"。
  String get eventSummaryZh =>
      '$eventCount / $resumedEventCount / $usableEventCount（统计 $statsCount）';

  static OverlayStateDiagnostics fromMap(Map<String, Object?> map) {
    final int changed = _int(map['lastChangedAt']);
    final String stateId = (map['stateId'] as String?) ?? 'default';
    return OverlayStateDiagnostics(
      stateId: stateId,
      stateLabel: (map['stateLabel'] as String?) ?? '默认',
      stateSource: (map['stateSource'] as String?) ?? 'unsupported',
      stateReason: (map['stateReason'] as String?) ?? '尚未检测',
      foregroundPackage: map['foregroundPackage'] as String?,
      foregroundLabel: map['foregroundLabel'] as String?,
      category: map['category'] as String?,
      categorySource: map['categorySource'] as String?,
      candidateState: map['candidateState'] as String?,
      candidateCount: _int(map['candidateCount']),
      manualOverride: map['manualOverride'] as String?,
      usageAccessGranted: map['usageAccessGranted'] == true,
      monitorRunning: map['monitorRunning'] == true,
      mappingRevision: _int(map['mappingRevision']),
      stateAssetId: map['stateAssetId'] as String?,
      fallbackLevel: _int(map['fallbackLevel']),
      lastChangedAt:
          changed > 0 ? DateTime.fromMillisecondsSinceEpoch(changed) : null,
      stateErrorCode: map['stateErrorCode'] as String?,
      detectionSource: (map['foregroundDetectionSource'] as String?) ?? 'unavailable',
      detectionReason: map['foregroundDetectionReason'] as String?,
      eventCount: _int(map['foregroundEventCount']),
      resumedEventCount: _int(map['foregroundResumedEventCount']),
      usableEventCount: _int(map['foregroundUsableEventCount']),
      statsCount: _int(map['foregroundStatsCount']),
      lastRawPackage: map['foregroundLastRawPackage'] as String?,
      appOpsAllowed: map['foregroundAppOpsAllowed'] == true,
      automaticStateEnabled: map['automaticStateEnabled'] != false,
      matchedRule: map['matchedRule'] as String?,
      // --- Phase 4C-6A 真机诊断 ---
      collectorRunning: map['collectorRunning'] == true,
      resolvedTargetState: map['resolvedTargetState'] as String?,
      stableState: map['stableState'] as String?,
      candidateSince: _time(map['candidateSince']),
      candidateElapsedMs: _int(map['candidateElapsedMs']),
      categoryDetail: map['categoryDetail'] as String?,
      platformAppCategory: map['platformAppCategory'] is num
          ? (map['platformAppCategory'] as num).toInt()
          : null,
      mappingReceivedAt: _time(map['mappingReceivedAt']),
      lastTransitionResult: map['lastTransitionResult'] as String?,
      lastTransitionReason: map['lastTransitionReason'] as String?,
      lastCommittedAt: _time(map['lastCommittedAt']),
      displayMode: (map['displayMode'] as String?) ?? 'auto',
      previewState: map['previewState'] as String?,
      previewExpiresAt: _time(map['previewExpiresAt']),
    );
  }

  /// 毫秒时间戳 → DateTime（0 / 缺失 → null，绝不显示 1970 年）。
  static DateTime? _time(Object? value) {
    final int ms = _int(value);
    return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// 非 Android / 服务未运行时的安全默认。
  static const OverlayStateDiagnostics unavailable = OverlayStateDiagnostics();

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// 轮盘主题的色板（Phase 4C-6B-1）。
///
/// 颜色一律以 `#RRGGBB` 字符串在两端之间传递 —— 原生用的是 ARGB `Int`，
/// 字符串形式能避免"把无符号颜色读成负数"这类跨语言坑，也便于日志核对。
class OverlayMenuPalette {
  const OverlayMenuPalette({
    required this.primary,
    required this.secondary,
    required this.background,
    required this.highlight,
    required this.outline,
    required this.text,
    required this.disabled,
    this.gradientEnabled = true,
  });

  final String primary;
  final String secondary;
  final String background;
  final String highlight;
  final String outline;
  final String text;
  final String disabled;
  final bool gradientEnabled;

  factory OverlayMenuPalette.fromMap(Map<String, Object?> map) => OverlayMenuPalette(
        primary: _hex(map['primary']),
        secondary: _hex(map['secondary']),
        background: _hex(map['background']),
        highlight: _hex(map['highlight']),
        outline: _hex(map['outline']),
        text: _hex(map['text']),
        disabled: _hex(map['disabled']),
        gradientEnabled: map['gradientEnabled'] != false,
      );

  static String _hex(Object? value) =>
      value is String && value.isNotEmpty ? value : '#000000';
}

/// 一个内置轮盘主题预设。
class OverlayMenuThemePreset {
  const OverlayMenuThemePreset({
    required this.themeId,
    required this.displayName,
    required this.colors,
  });

  final String themeId;
  final String displayName;
  final OverlayMenuPalette colors;

  factory OverlayMenuThemePreset.fromMap(Map<String, Object?> map) =>
      OverlayMenuThemePreset(
        themeId: (map['themeId'] as String?) ?? '',
        displayName: (map['displayName'] as String?) ?? '',
        colors: OverlayMenuPalette.fromMap(
          (map['colors'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
              .cast<String, Object?>(),
        ),
      );
}

/// 轮盘主题的当前状态（原生是权威来源）。
class OverlayMenuThemeState {
  const OverlayMenuThemeState({
    required this.themeId,
    required this.displayName,
    required this.revision,
    required this.customPrimary,
    required this.legible,
    required this.contrast,
    required this.current,
    required this.presets,
    required this.menuDistanceRatio,
    required this.hapticsEnabled,
    required this.soundEnabled,
    required this.swipeEnabled,
    required this.swipeSensitivity,
  });

  final String themeId;
  final String displayName;

  /// 主题配置版本号（**下一次写入必须比它大**）。
  final int revision;

  /// 用户自选主色（`#RRGGBB`）。
  final String customPrimary;

  /// 文字对主色的对比度是否达标（需求 §13.3）。
  final bool legible;
  final double contrast;

  final OverlayMenuPalette current;
  final List<OverlayMenuThemePreset> presets;

  final double menuDistanceRatio;
  final bool hapticsEnabled;
  final bool soundEnabled;
  final bool swipeEnabled;
  final int swipeSensitivity;

  /// 自定义主题的固定 ID（与原生 `WheelMenuTheme.ID_CUSTOM` 一致）。
  static const String customThemeId = 'custom';

  static const OverlayMenuThemeState unsupported = OverlayMenuThemeState(
    themeId: 'p3p-pink',
    displayName: 'P3P 粉色',
    revision: 0,
    customPrimary: '#F24D96',
    legible: true,
    contrast: 3.4,
    current: OverlayMenuPalette(
      primary: '#F24D96',
      secondary: '#FF8ABA',
      background: '#FFD8E9',
      highlight: '#FFD42A',
      outline: '#111111',
      text: '#FFFFFF',
      disabled: '#8E7180',
    ),
    presets: <OverlayMenuThemePreset>[],
    menuDistanceRatio: 0.42,
    hapticsEnabled: true,
    soundEnabled: false,
    swipeEnabled: true,
    swipeSensitivity: 1,
  );

  factory OverlayMenuThemeState.fromMap(Map<String, Object?> map) {
    final Object? rawPresets = map['presets'];
    final List<OverlayMenuThemePreset> presets = rawPresets is List
        ? rawPresets
            .whereType<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> item) =>
                OverlayMenuThemePreset.fromMap(item.cast<String, Object?>()))
            .toList(growable: false)
        : const <OverlayMenuThemePreset>[];
    final Map<String, Object?> current =
        (map['current'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
            .cast<String, Object?>();
    return OverlayMenuThemeState(
      themeId: (map['themeId'] as String?) ?? customThemeId,
      displayName: (map['displayName'] as String?) ?? '轮盘主题',
      revision: map['revision'] is num ? (map['revision']! as num).toInt() : 0,
      customPrimary: OverlayMenuPalette._hex(map['customPrimary']),
      legible: map['legible'] != false,
      contrast: map['contrast'] is num ? (map['contrast']! as num).toDouble() : 0,
      current: OverlayMenuPalette.fromMap(current),
      presets: presets,
      menuDistanceRatio:
          map['menuDistanceRatio'] is num ? (map['menuDistanceRatio']! as num).toDouble() : 0.42,
      hapticsEnabled: map['hapticsEnabled'] != false,
      soundEnabled: map['soundEnabled'] == true,
      swipeEnabled: map['swipeEnabled'] != false,
      swipeSensitivity:
          map['swipeSensitivity'] is num ? (map['swipeSensitivity']! as num).toInt() : 1,
    );
  }
}

/// 写入主题的结果（可能被原生的 revision 守卫拒绝）。
class OverlayMenuThemeUpdate {
  const OverlayMenuThemeUpdate({
    required this.accepted,
    this.errorCode,
    this.state,
  });

  final bool accepted;
  final String? errorCode;
  final OverlayMenuThemeState? state;

  /// 被拒绝时的中文说明（诊断用）。
  String get errorLabelZh => switch (errorCode) {
        'stale_revision' => '已有一个更新的主题配置，本次修改被忽略',
        'unknown_theme' => '未知的主题',
        'invalid_color' => '颜色不合法',
        'invalid_arguments' => '参数不合法',
        'missing_revision' => '缺少版本号',
        _ => errorCode == null ? '' : '主题保存失败：$errorCode',
      };
}

/// 轮盘**布局**设置（Phase 4C-6B-1.1，需求 §5）。
///
/// 与 [OverlayMenuThemeState]（颜色）**分线**：两者各有独立的 revision 守卫。
class OverlayWheelLayoutSettings {
  const OverlayWheelLayoutSettings({
    required this.preferredScale,
    required this.compactMode,
    required this.revision,
    required this.minScale,
    required this.maxScale,
    required this.step,
    required this.defaultScale,
    required this.menuDistance,
    this.buttonVisualScale = 1.30,
    this.minButtonScale = 0.50,
    this.maxButtonScale = 2.50,
    this.defaultButtonScale = 1.30,
  });

  final double preferredScale;

  /// 按钮视觉缩放（**独立于轮盘大小**，需求 §4.3）。
  final double buttonVisualScale;
  final double minButtonScale;
  final double maxButtonScale;
  final double defaultButtonScale;
  final bool compactMode;
  final int revision;
  final double minScale;
  final double maxScale;
  final double step;
  final double defaultScale;
  final double menuDistance;

  /// 百分比文案（设置页显示用）。
  int get scalePercent => (preferredScale * 100).round();

  static const OverlayWheelLayoutSettings unsupported = OverlayWheelLayoutSettings(
    preferredScale: 1.00,
    compactMode: false,
    revision: 0,
    minScale: 0.50,
    maxScale: 2.50,
    step: 0.10,
    defaultScale: 1.00,
    menuDistance: 0.16,
    buttonVisualScale: 1.30,
    minButtonScale: 0.50,
    maxButtonScale: 2.50,
    defaultButtonScale: 1.30,
  );

  factory OverlayWheelLayoutSettings.fromMap(Map<String, Object?> map) {
    double num0(Object? value, double fallback) =>
        value is num && value.isFinite ? value.toDouble() : fallback;
    final double minScale = num0(map['minScale'], 0.50);
    final double maxScale = num0(map['maxScale'], 2.50);
    final double minButton = num0(map['minButtonScale'], 0.50);
    final double maxButton = num0(map['maxButtonScale'], 2.50);
    return OverlayWheelLayoutSettings(
      preferredScale: num0(map['preferredScale'], 1.00).clamp(minScale, maxScale),
      buttonVisualScale: num0(map['buttonVisualScale'], 1.30).clamp(minButton, maxButton),
      minButtonScale: minButton,
      maxButtonScale: maxButton,
      defaultButtonScale: num0(map['defaultButtonScale'], 1.30),
      compactMode: map['compactMode'] == true,
      revision: map['revision'] is num ? (map['revision']! as num).toInt() : 0,
      minScale: minScale,
      maxScale: maxScale,
      step: num0(map['step'], 0.10),
      defaultScale: num0(map['defaultScale'], 1.00),
      menuDistance: num0(map['menuDistance'], 0.16),
    );
  }
}

/// 写入轮盘布局设置的结果。
class OverlayWheelLayoutUpdate {
  const OverlayWheelLayoutUpdate({
    required this.accepted,
    this.errorCode,
    this.settings,
  });

  final bool accepted;
  final String? errorCode;
  final OverlayWheelLayoutSettings? settings;

  String get errorLabelZh => switch (errorCode) {
        'stale_revision' => '已有一个更新的轮盘设置，本次修改被忽略',
        'invalid_arguments' => '参数不合法',
        'missing_revision' => '缺少版本号',
        _ => errorCode == null ? '' : '轮盘设置保存失败：$errorCode',
      };
}

/// 双窗口探针的只读诊断快照（Frozen contract）。
///
/// 键与原生 `getDualWindowProbeStatus` 的返回**逐字对应**；只用于设置页展示，
/// **不由 Flutter 驱动任何窗口 / 探针行为**。原生在探针未运行时也会带回全部键
/// （`probeValid=false`，其余为 `none` / `0` / `false`），因此界面永远能画出完整一页。
///
/// 解析刻意**宽容**：缺键 / 类型不符一律退化为安全默认（bool → false、
/// 计数 → 0、文本 → null），界面把 null 显示为 `—`，绝不因一条坏数据抛异常。
class DualWindowProbeStatus {
  const DualWindowProbeStatus({
    this.supported = true,
    this.probeValid = false,
    this.productionWindowAttached = false,
    this.probeWindowCount = 0,
    this.expectedProbeWindowCount = 0,
    this.totalKnownOverlayWindowCount = 0,
    this.petAddCount = 0,
    this.menuAddCount = 0,
    this.petLastAddSequence = 0,
    this.menuLastAddSequence = 0,
    this.addSequence = 0,
    this.currentExpectedTopWindow,
    this.actualVisualTop,
    this.menuWasReaddedAfterPet = false,
    this.menuAttached = false,
    this.menuTouchable = false,
    this.menuAnchorPetRect,
    this.currentPetScreenRect,
    this.currentMenuWindowRect,
    this.anchorMatchesCurrentPet = false,
    this.menuDirection,
    this.verticalMode = false,
    this.clampedByScreen = false,
    this.lastWindowOperation,
    this.lastTouchReceiver,
    this.orientation,
    this.deviceModel,
    this.sdkInt = 0,
  });

  /// 当前平台是否支持该探针（Dart 侧附加字段，**不是**原生键）。
  ///
  /// 非 Android 为 false，界面据此显示"不支持"，而不是画一屏假 0。
  final bool supported;

  /// 探针是否处于有效运行状态（原生权威判据）。
  final bool probeValid;

  /// 生产窗口是否被附着（双窗口探针下应为 false，true 即失败）。
  final bool productionWindowAttached;

  final int probeWindowCount;
  final int expectedProbeWindowCount;
  final int totalKnownOverlayWindowCount;

  final int petAddCount;
  final int menuAddCount;

  final int petLastAddSequence;
  final int menuLastAddSequence;
  final int addSequence;

  /// 期望处于最顶层的窗口标识（文本）。
  final String? currentExpectedTopWindow;

  /// 实际视觉最顶层的窗口标识（文本）。
  final String? actualVisualTop;

  /// 菜单是否在桌宠之后被重新 add（true 即失败）。
  final bool menuWasReaddedAfterPet;

  final bool menuAttached;
  final bool menuTouchable;

  /// 菜单锚点矩形（`left,top w×h` 或 `none`）。
  final String? menuAnchorPetRect;

  /// 当前桌宠屏幕矩形（`left,top w×h` 或 `none`）。
  final String? currentPetScreenRect;

  /// 当前菜单窗口矩形（`left,top w×h` 或 `none`）。
  final String? currentMenuWindowRect;

  /// 菜单锚点是否与当前桌宠矩形一致（false 即失败）。
  final bool anchorMatchesCurrentPet;

  final String? menuDirection;
  final bool verticalMode;
  final bool clampedByScreen;

  final String? lastWindowOperation;
  final String? lastTouchReceiver;

  final String? orientation;
  final String? deviceModel;
  final int sdkInt;

  /// 全部冻结键（顺序固定）—— 复制文本与 UI 分组都依赖它。
  static const List<String> frozenKeys = <String>[
    'probeValid',
    'productionWindowAttached',
    'probeWindowCount',
    'expectedProbeWindowCount',
    'totalKnownOverlayWindowCount',
    'petAddCount',
    'menuAddCount',
    'petLastAddSequence',
    'menuLastAddSequence',
    'addSequence',
    'currentExpectedTopWindow',
    'actualVisualTop',
    'menuWasReaddedAfterPet',
    'menuAttached',
    'menuTouchable',
    'menuAnchorPetRect',
    'currentPetScreenRect',
    'currentMenuWindowRect',
    'anchorMatchesCurrentPet',
    'menuDirection',
    'verticalMode',
    'clampedByScreen',
    'lastWindowOperation',
    'lastTouchReceiver',
    'orientation',
    'deviceModel',
    'sdkInt',
  ];

  /// 键 → 原始值（bool / int / String?）。复制文本与界面共用同一份真值。
  Map<String, Object?> toMap() => <String, Object?>{
        'probeValid': probeValid,
        'productionWindowAttached': productionWindowAttached,
        'probeWindowCount': probeWindowCount,
        'expectedProbeWindowCount': expectedProbeWindowCount,
        'totalKnownOverlayWindowCount': totalKnownOverlayWindowCount,
        'petAddCount': petAddCount,
        'menuAddCount': menuAddCount,
        'petLastAddSequence': petLastAddSequence,
        'menuLastAddSequence': menuLastAddSequence,
        'addSequence': addSequence,
        'currentExpectedTopWindow': currentExpectedTopWindow,
        'actualVisualTop': actualVisualTop,
        'menuWasReaddedAfterPet': menuWasReaddedAfterPet,
        'menuAttached': menuAttached,
        'menuTouchable': menuTouchable,
        'menuAnchorPetRect': menuAnchorPetRect,
        'currentPetScreenRect': currentPetScreenRect,
        'currentMenuWindowRect': currentMenuWindowRect,
        'anchorMatchesCurrentPet': anchorMatchesCurrentPet,
        'menuDirection': menuDirection,
        'verticalMode': verticalMode,
        'clampedByScreen': clampedByScreen,
        'lastWindowOperation': lastWindowOperation,
        'lastTouchReceiver': lastTouchReceiver,
        'orientation': orientation,
        'deviceModel': deviceModel,
        'sdkInt': sdkInt,
      };

  /// 需要红色高亮的键（判据见需求；键名与复制文本一致）。
  ///
  /// * `probeValid=false` —— 探针没在跑 / 状态无效；
  /// * `productionWindowAttached=true` —— 生产窗口不该被附着；
  /// * `menuWasReaddedAfterPet=true` —— 菜单在桌宠之后被重新 add（时序异常）；
  /// * `anchorMatchesCurrentPet=false` —— 锚点与当前桌宠矩形不一致
  ///   （**仅在探针有效时判定**：探针没跑时该字段只是默认 false，不算失败）；
  /// * `menuTouchable=true` 且菜单未附着 —— 幽灵可触摸窗口会抢触摸。
  Set<String> get failureKeys {
    final Set<String> keys = <String>{};
    if (!probeValid) keys.add('probeValid');
    if (productionWindowAttached) keys.add('productionWindowAttached');
    if (menuWasReaddedAfterPet) keys.add('menuWasReaddedAfterPet');
    if (probeValid && !anchorMatchesCurrentPet) {
      keys.add('anchorMatchesCurrentPet');
    }
    if (menuTouchable && !menuAttached) keys.add('menuTouchable');
    return keys;
  }

  /// 某一行是否需要红色高亮。
  bool highlightsFailure(String key) => failureKeys.contains(key);

  /// 稳定的 `key=value` 文本块（每行一个键，顺序固定，便于 grep / 对账）。
  ///
  /// null（原生缺键或空串）统一写成 `none`，与原生契约里的 `none` 口径一致。
  String toCopyText() {
    final Map<String, Object?> map = toMap();
    return frozenKeys
        .map((String key) => '$key=${map[key] ?? 'none'}')
        .join('\n');
  }

  factory DualWindowProbeStatus.fromMap(Map<String, Object?> map) =>
      DualWindowProbeStatus(
        supported: true,
        probeValid: _bool(map['probeValid']),
        productionWindowAttached: _bool(map['productionWindowAttached']),
        probeWindowCount: _int(map['probeWindowCount']),
        expectedProbeWindowCount: _int(map['expectedProbeWindowCount']),
        totalKnownOverlayWindowCount: _int(map['totalKnownOverlayWindowCount']),
        petAddCount: _int(map['petAddCount']),
        menuAddCount: _int(map['menuAddCount']),
        petLastAddSequence: _int(map['petLastAddSequence']),
        menuLastAddSequence: _int(map['menuLastAddSequence']),
        addSequence: _int(map['addSequence']),
        currentExpectedTopWindow: _string(map['currentExpectedTopWindow']),
        actualVisualTop: _string(map['actualVisualTop']),
        menuWasReaddedAfterPet: _bool(map['menuWasReaddedAfterPet']),
        menuAttached: _bool(map['menuAttached']),
        menuTouchable: _bool(map['menuTouchable']),
        menuAnchorPetRect: _string(map['menuAnchorPetRect']),
        currentPetScreenRect: _string(map['currentPetScreenRect']),
        currentMenuWindowRect: _string(map['currentMenuWindowRect']),
        anchorMatchesCurrentPet: _bool(map['anchorMatchesCurrentPet']),
        menuDirection: _string(map['menuDirection']),
        verticalMode: _bool(map['verticalMode']),
        clampedByScreen: _bool(map['clampedByScreen']),
        lastWindowOperation: _string(map['lastWindowOperation']),
        lastTouchReceiver: _string(map['lastTouchReceiver']),
        orientation: _string(map['orientation']),
        deviceModel: _string(map['deviceModel']),
        sdkInt: _int(map['sdkInt']),
      );

  /// 非 Android / 通道缺失时的安全默认：全部键都在，但明确标记"不支持"。
  static const DualWindowProbeStatus unsupported =
      DualWindowProbeStatus(supported: false);

  /// 容错：非 bool 一律 false。
  static bool _bool(Object? value) => value is bool && value;

  /// 容错：非 num 一律 0。
  static int _int(Object? value) => value is num ? value.toInt() : 0;

  /// 容错：缺失 / 空串 / 非字符串 → null（界面显示 `—`）。
  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

/// 悬浮桌宠的平台接口。
abstract interface class AndroidOverlayPet {
  /// 当前平台/系统版本是否支持系统级悬浮窗。
  Future<bool> isSupported();

  /// 查询授权状态（**永远现场复查**，不使用缓存）。
  Future<OverlayPermissionState> permissionState();

  /// 打开系统授权页。返回的是**当前**状态：回到应用后必须再查一次。
  Future<OverlayPermissionState> requestOverlayPermission();

  /// 请求通知权限（Android 13+ 才需要）。等待系统回调后返回真实结果。
  Future<OverlayPermissionState> requestNotificationPermission();

  /// 启用并显示悬浮桌宠。
  ///
  /// [config] 为 null 时使用原生端**已保存**的配置（全新安装还没有任何素材
  /// 时也能显示占位图）；非 null 时必须先通过 [OverlayPetConfig.validate]。
  Future<OverlayRuntimeState> start([OverlayPetConfig? config]);

  Future<OverlayRuntimeState> show();

  /// 隐藏窗口（**不等于**停止服务）。
  Future<OverlayRuntimeState> hide();

  /// 停止服务并移除窗口。
  Future<OverlayRuntimeState> stop();

  /// 更新当前素材（自动/固定模式都走这里）。
  Future<OverlayRuntimeState> updatePet(OverlayPetConfig config);

  /// 更新外观/行为设置。
  Future<OverlayRuntimeState> updateSettings(OverlayPetSettings settings);

  /// 诊断模式：固定洋红方块，**不读取任何素材**（真机排障专用，见 docs/35 §6）。
  Future<OverlayRuntimeState> setDebugOverlay(bool enabled);

  Future<OverlayRuntimeState> getState();

  /// 打开系统电池优化设置（只打开列表，**不**自动申请白名单）。
  Future<void> openBatterySettings();

  /// 打开应用详情页（厂商后台限制提示用）。
  Future<void> openAppDetails();

  // ---------------------------------------------------------------------------
  // Phase 4C-5：状态联动
  // ---------------------------------------------------------------------------

  /// 下发状态 → 素材快照（原生据此在 Flutter 退出后继续联动）。
  ///
  /// 原生只接受**不旧于**当前版本的 [OverlayStateMapping.revision]，
  /// 更新映射**不会**重建窗口或重启服务。
  Future<OverlayRuntimeState> updateStateMapping(OverlayStateMapping mapping);

  /// 状态调试器手动覆盖到某个状态（null = 恢复自动）。立即生效，不等防抖。
  Future<OverlayRuntimeState> setManualState(String? stateId);

  /// 临时预览某状态的映射素材（Phase 4C-6A.1，需求 §11）。
  ///
  /// 与手动覆盖、编辑映射都不同：**不修改 stableState、不写手动覆盖**，
  /// 约 10 秒后自动恢复真实状态，且**不持久化**（服务重启后不恢复）。
  Future<OverlayRuntimeState> previewState(String stateId);

  /// 立刻结束临时预览，回到真实状态。
  Future<OverlayRuntimeState> clearPreview();

  /// 读取状态联动的只读诊断（需求 §19）。
  Future<OverlayStateDiagnostics> stateDiagnostics();

  // ---------------------------------------------------------------------------
  // 双窗口探针：只读诊断
  // ---------------------------------------------------------------------------

  /// 读取**双窗口探针**的只读诊断（无参数）。
  ///
  /// 通道方法固定为 `getDualWindowProbeStatus`（Frozen contract）。探针未运行时
  /// 原生也会带回全部键（`probeValid=false`）。非 Android 返回
  /// [DualWindowProbeStatus.unsupported]，**不抛错**——这是纯只读展示。
  Future<DualWindowProbeStatus> dualWindowProbeStatus();

  // ---------------------------------------------------------------------------
  // 双窗口实现开关（单窗口 → 双窗口迁移期的临时回退开关）
  // ---------------------------------------------------------------------------

  /// 读取「双窗口实现」开关（Frozen contract：`getDualWindowMode`，无参数）。
  ///
  /// `true` = 新的双窗口实现（默认）；`false` = 回退单窗口实现。
  /// 非 Android 返回 [DualWindowModeStatus.unsupported]（`supported = false`），
  /// **不抛错** —— 这是纯读操作。
  Future<DualWindowModeStatus> dualWindowMode();

  /// 设置「双窗口实现」开关（Frozen contract：`setDualWindowMode(enabled)`）。
  ///
  /// 返回原生是否接受（`true` = 已接受、持久化并立即生效）。
  /// 调用方**必须回读** [dualWindowMode] 确认真实值，不得假设写入一定成功。
  Future<bool> setDualWindowMode(bool enabled);

  // ---------------------------------------------------------------------------
  // Phase 4C-6B-1：P3P 风格分层轮盘的主题
  // ---------------------------------------------------------------------------

  /// 读取轮盘主题（当前色板 + 预设列表 + 持久化开关）。
  ///
  /// 返回的 `revision` 必须**续接**到下一次写入里，否则原生会按
  /// "旧配置不得覆盖新配置"把改动挡掉。
  Future<OverlayMenuThemeState> menuTheme();

  /// 选择轮盘主题。`themeId = 'custom'` 时使用 [customPrimary]（`#RRGGBB`）。
  ///
  /// [revision] 必须**大于**上一次读到的值（`getMenuTheme().revision + 1`）。
  Future<OverlayMenuThemeUpdate> setMenuTheme({
    required String themeId,
    int? customPrimary,
    required int revision,
  });

  // ---------------------------------------------------------------------------
  // Phase 4C-6B-1.1：轮盘布局（尺寸 / 紧凑）
  // ---------------------------------------------------------------------------

  /// 读取轮盘布局设置（设置页「轮盘大小」）。
  Future<OverlayWheelLayoutSettings> wheelLayout();

  /// 写入轮盘布局设置；[revision] 必须比读到的值大。
  Future<OverlayWheelLayoutUpdate> setWheelLayout({
    required double preferredScale,
    double? buttonVisualScale,
    required bool compactMode,
    required int revision,
  });

  // ---------------------------------------------------------------------------
  // Phase 4D：开机自启
  // ---------------------------------------------------------------------------

  /// 读取"开机自动启动"开关与最近一次开机结果。
  ///
  /// 原生是权威来源：开关存在原生 SharedPreferences，`BOOT_COMPLETED` 接收器
  /// 读的就是这一份（因此不依赖 Flutter 是否启动过）。
  Future<OverlayAutostartStatus> autostartStatus();

  /// 设置"开机自动启动"并**写透**到原生 SharedPreferences。
  ///
  /// 只改这一个标志：不动 `enabled` / `hidden`（显示/隐藏是另一份状态），
  /// 也不会立即启动或停止服务 —— 它只影响**下一次重启**。
  Future<OverlayAutostartStatus> setAutostart(bool enabled);

  /// 读取**共享的**当前前台应用快照（Phase 4C-5.1A）。
  ///
  /// 设置页与使用统计页都读它，因此两个页面不可能显示不同的应用；
  /// 界面刷新也**不会**触发新的 `UsageStatsManager` 查询
  /// （原生只在快照过期时补一次检测）。
  Future<CurrentActivity> currentActivity();

  /// 打开系统"使用情况访问"设置页（**只打开**，不反复弹窗催授权）。
  Future<void> openUsageAccessSettings();

  // ---------------------------------------------------------------------------
  // Phase 4C-5.1B：原生使用会话采集（journal → 幂等导入）
  // ---------------------------------------------------------------------------

  /// 读取原生采集器与 journal 的状态（设置页诊断区用）。
  ///
  /// 非 Android 返回 [UsageCollectorState.unsupported]。
  Future<UsageCollectorState> usageCollectorState();

  /// 读取待导入的已结束会话。
  ///
  /// **只读**：不会删除或修改 journal；[limit] 用于避免一次传输过大。
  Future<List<AndroidUsageSession>> readPendingUsageSessions({int limit});

  /// 按 `session_id` 确认（删除）已成功导入的记录，返回真正删除的条数。
  ///
  /// 调用方必须**先确保本地事务已提交**；桥接异常绝不删除 journal。
  Future<int> acknowledgeUsageSessions(List<String> sessionIds);

  /// 切换采集暂停。原生会**立即结束**当前会话，之后不再新建（需求 §9）。
  Future<void> setUsageCollectionPaused(bool paused);

  /// 下发本机稳定设备标识（原生把它写进 journal 记录，便于自描述与排查）。
  ///
  /// 注意：这是**本地统计口径**的标识，与服务端注册设备 ID 不是同一个东西。
  Future<void> updateUsageIdentity(String deviceLocalId);
}

/// 配置不合格。
class OverlayConfigException implements Exception {
  const OverlayConfigException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OverlayConfigException($code): $message';
}

/// 原生端返回了错误（服务创建失败、窗口被系统拒绝等）。
class OverlayPlatformException implements Exception {
  const OverlayPlatformException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OverlayPlatformException($code): $message';
}

/// 当前平台没有系统级悬浮桌宠能力（Windows / 桩实现）。
///
/// 写操作**抛错而不是静默成功** —— 否则一旦界面忘记按能力位隐藏，
/// Windows 上会呈现"点了没反应但看起来像成功"的假象。
class OverlayUnsupportedException implements Exception {
  const OverlayUnsupportedException([this.message = '当前平台不支持系统级悬浮桌宠']);

  final String message;

  @override
  String toString() => 'OverlayUnsupportedException: $message';
}

/// 非 Android 平台（Windows、Web 桩、测试）的实现。
///
/// 读操作返回"不支持"的事实（界面据此隐藏分区），写操作抛
/// [OverlayUnsupportedException] 暴露调用方的疏忽。
class UnsupportedOverlayPet implements AndroidOverlayPet {
  const UnsupportedOverlayPet();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<OverlayPermissionState> permissionState() async =>
      OverlayPermissionState.unsupported;

  @override
  Future<OverlayRuntimeState> getState() async => OverlayRuntimeState.unsupported;

  @override
  Future<OverlayPermissionState> requestOverlayPermission() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayPermissionState> requestNotificationPermission() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> start([OverlayPetConfig? config]) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> show() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> hide() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> stop() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> updatePet(OverlayPetConfig config) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> updateSettings(OverlayPetSettings settings) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> setDebugOverlay(bool enabled) async =>
      throw const OverlayUnsupportedException();

  // --- Phase 4C-5：状态联动 ---
  // 读操作返回"不可用"的安全默认（界面直接隐藏/降级展示），写操作抛错。

  @override
  Future<OverlayStateDiagnostics> stateDiagnostics() async =>
      OverlayStateDiagnostics.unavailable;

  // --- 双窗口探针：只读诊断 ---
  // 非 Android 明确返回"不支持"的事实（读操作不抛错），界面据此不画一屏假 0。

  @override
  Future<DualWindowProbeStatus> dualWindowProbeStatus() async =>
      DualWindowProbeStatus.unsupported;

  // --- 双窗口实现开关：非 Android 返回"不支持"的安全默认（读写均不抛错，Frozen contract）。---

  @override
  Future<DualWindowModeStatus> dualWindowMode() async =>
      DualWindowModeStatus.unsupported;

  @override
  Future<bool> setDualWindowMode(bool enabled) async => false;

  @override
  Future<CurrentActivity> currentActivity() async => const CurrentActivity(
        available: false,
        failureReason: 'unsupported-platform-provider',
      );

  @override
  Future<OverlayRuntimeState> updateStateMapping(OverlayStateMapping mapping) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> setManualState(String? stateId) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> previewState(String stateId) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<OverlayRuntimeState> clearPreview() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<void> openUsageAccessSettings() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<void> openBatterySettings() async =>
      throw const OverlayUnsupportedException();

  @override
  Future<void> openAppDetails() async =>
      throw const OverlayUnsupportedException();

  // --- Phase 4C-6B-1：轮盘主题 ---
  // 读操作返回内置默认色板（界面仍能画出预览），写操作抛错。

  @override
  Future<OverlayMenuThemeState> menuTheme() async => OverlayMenuThemeState.unsupported;

  @override
  Future<OverlayMenuThemeUpdate> setMenuTheme({
    required String themeId,
    int? customPrimary,
    required int revision,
  }) async =>
      throw const OverlayUnsupportedException();

  // --- Phase 4C-6B-1.1：轮盘布局 ---

  @override
  Future<OverlayWheelLayoutSettings> wheelLayout() async =>
      OverlayWheelLayoutSettings.unsupported;

  @override
  Future<OverlayWheelLayoutUpdate> setWheelLayout({
    required double preferredScale,
    double? buttonVisualScale,
    required bool compactMode,
    required int revision,
  }) async =>
      throw const OverlayUnsupportedException();

  // --- Phase 4D：开机自启 ---
  // 读操作返回"不支持"的事实（界面据此不渲染该分区），写操作抛错暴露调用方疏忽。

  @override
  Future<OverlayAutostartStatus> autostartStatus() async =>
      OverlayAutostartStatus.unsupported;

  @override
  Future<OverlayAutostartStatus> setAutostart(bool enabled) async =>
      throw const OverlayUnsupportedException();

  // --- Phase 4C-5.1B：原生使用会话采集 ---
  // 读操作返回"不支持"的事实；写操作抛错（调用方只会在 Android 装配里拿到导入器）。

  @override
  Future<UsageCollectorState> usageCollectorState() async =>
      UsageCollectorState.unsupported;

  @override
  Future<List<AndroidUsageSession>> readPendingUsageSessions({int limit = 200}) async =>
      const <AndroidUsageSession>[];

  @override
  Future<int> acknowledgeUsageSessions(List<String> sessionIds) async => 0;

  @override
  Future<void> setUsageCollectionPaused(bool paused) async =>
      throw const OverlayUnsupportedException();

  @override
  Future<void> updateUsageIdentity(String deviceLocalId) async =>
      throw const OverlayUnsupportedException();
}
