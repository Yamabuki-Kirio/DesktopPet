import 'package:flutter/services.dart';

import '../../activity_tracking/android_usage_session.dart';
import '../../activity_tracking/current_activity_provider.dart';
import '../overlay_pet.dart';
import '../overlay_state_mapping.dart';

/// 与原生 `PetOverlayBridge.CHANNEL_NAME` 必须完全一致。
const String androidOverlayChannelName = 'asia.akechi.petlife/overlay';

/// Android 系统级悬浮桌宠（MethodChannel 实现，Phase 4C）。
///
/// 只被 [AndroidPlatformServices] 创建；Windows 一律使用 [UnsupportedOverlayPet]，
/// 因此 Windows 构建不会加载任何悬浮窗逻辑。
///
/// 错误翻译原则（与 `android_keystore_credential_store.dart` 一致）：
/// * 通道不存在 → [OverlayUnsupportedException]（构建配置错误，不是用户错误）；
/// * 原生返回 `PlatformException` → [OverlayPlatformException]，
///   消息原样透传（原生侧写的就是给用户看的中文）。
class AndroidOverlayPetBridge implements AndroidOverlayPet {
  AndroidOverlayPetBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(androidOverlayChannelName);

  final MethodChannel _channel;

  @override
  Future<bool> isSupported() async => await _invoke('isSupported') == true;

  @override
  Future<OverlayPermissionState> permissionState() async =>
      OverlayPermissionState.fromMap(_asMap(await _invoke('getPermissionStatus')));

  @override
  Future<OverlayPermissionState> requestOverlayPermission() async =>
      OverlayPermissionState.fromMap(
        _asMap(await _invoke('requestOverlayPermission')),
      );

  @override
  Future<OverlayPermissionState> requestNotificationPermission() async =>
      OverlayPermissionState.fromMap(
        _asMap(await _invoke('requestNotificationPermission')),
      );

  @override
  Future<OverlayRuntimeState> start([OverlayPetConfig? config]) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('start', config?.toJson())),
      );

  @override
  Future<OverlayRuntimeState> show() async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('show')));

  @override
  Future<OverlayRuntimeState> hide() async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('hide')));

  @override
  Future<OverlayRuntimeState> stop() async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('stop')));

  @override
  Future<OverlayRuntimeState> updatePet(OverlayPetConfig config) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('updatePet', config.toJson())),
      );

  @override
  Future<OverlayRuntimeState> updateSettings(OverlayPetSettings settings) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('updateSettings', settings.toJson())),
      );

  @override
  Future<OverlayRuntimeState> setDebugOverlay(bool enabled) async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('setDebugOverlay', enabled)));

  @override
  Future<OverlayRuntimeState> getState() async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('getState')));

  @override
  Future<void> openBatterySettings() async => _invoke('openBatterySettings');

  @override
  Future<void> openAppDetails() async => _invoke('openAppDetails');

  // ---------------------------------------------------------------------------
  // Phase 4C-5：状态联动
  // ---------------------------------------------------------------------------

  @override
  Future<OverlayRuntimeState> updateStateMapping(OverlayStateMapping mapping) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('updateStateMapping', mapping.toJson())),
      );

  @override
  Future<OverlayRuntimeState> setManualState(String? stateId) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('setManualState', stateId)),
      );

  @override
  Future<OverlayRuntimeState> previewState(String stateId) async =>
      OverlayRuntimeState.fromMap(
        _asMap(await _invoke('previewState', stateId)),
      );

  @override
  Future<OverlayRuntimeState> clearPreview() async =>
      OverlayRuntimeState.fromMap(_asMap(await _invoke('clearPreview')));

  @override
  Future<OverlayStateDiagnostics> stateDiagnostics() async =>
      OverlayStateDiagnostics.fromMap(
        _asMap(await _invoke('getStateDiagnostics')),
      );

  // ---------------------------------------------------------------------------
  // 双窗口探针：只读诊断（Frozen contract：getDualWindowProbeStatus，无参数）
  // ---------------------------------------------------------------------------

  @override
  Future<DualWindowProbeStatus> dualWindowProbeStatus() async =>
      DualWindowProbeStatus.fromMap(
        _asMap(await _invoke('getDualWindowProbeStatus')),
      );

  // ---------------------------------------------------------------------------
  // 双窗口实现开关：迁移期临时回退（Frozen contract：get/setDualWindowMode）
  // ---------------------------------------------------------------------------

  @override
  Future<DualWindowModeStatus> dualWindowMode() async =>
      DualWindowModeStatus.fromValue(await _invoke('getDualWindowMode'));

  @override
  Future<bool> setDualWindowMode(bool enabled) async =>
      await _invoke('setDualWindowMode', enabled) == true;

  @override
  Future<CurrentActivity> currentActivity() async =>
      CurrentActivity.fromMap(
        _asMap(await _invoke('getCurrentForegroundApp')),
      );

  @override
  Future<void> openUsageAccessSettings() async =>
      _invoke('openUsageAccessSettings');

  // ---------------------------------------------------------------------------
  // Phase 4C-6B-1：轮盘主题
  // ---------------------------------------------------------------------------

  @override
  Future<OverlayMenuThemeState> menuTheme() async =>
      OverlayMenuThemeState.fromMap(_asMap(await _invoke('getMenuTheme')));

  @override
  Future<OverlayMenuThemeUpdate> setMenuTheme({
    required String themeId,
    int? customPrimary,
    required int revision,
  }) async {
    final Map<String, Object?> map = _asMap(await _invoke('setMenuTheme', <String, Object?>{
      'themeId': themeId,
      if (customPrimary != null) 'customPrimary': customPrimary,
      'revision': revision,
    }));
    final bool accepted = map['accepted'] == true;
    return OverlayMenuThemeUpdate(
      accepted: accepted,
      errorCode: map['errorCode'] as String?,
      // 只有被接受时原生才会回完整状态；被拒绝时保留调用方手里的旧状态。
      state: accepted ? OverlayMenuThemeState.fromMap(map) : null,
    );
  }

  @override
  Future<OverlayWheelLayoutSettings> wheelLayout() async =>
      OverlayWheelLayoutSettings.fromMap(_asMap(await _invoke('getMenuLayout')));

  @override
  Future<OverlayWheelLayoutUpdate> setWheelLayout({
    required double preferredScale,
    double? buttonVisualScale,
    required bool compactMode,
    required int revision,
  }) async {
    final Map<String, Object?> map = _asMap(
      await _invoke('setMenuLayout', <String, Object?>{
        'preferredScale': preferredScale,
        if (buttonVisualScale != null) 'buttonVisualScale': buttonVisualScale,
        'compactMode': compactMode,
        'revision': revision,
      }),
    );
    final bool accepted = map['accepted'] == true;
    return OverlayWheelLayoutUpdate(
      accepted: accepted,
      errorCode: map['errorCode'] as String?,
      settings: accepted ? OverlayWheelLayoutSettings.fromMap(map) : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Phase 4D：开机自启
  // ---------------------------------------------------------------------------

  @override
  Future<OverlayAutostartStatus> autostartStatus() async =>
      OverlayAutostartStatus.fromMap(_asMap(await _invoke('getAutostartStatus')));

  @override
  Future<OverlayAutostartStatus> setAutostart(bool enabled) async =>
      OverlayAutostartStatus.fromMap(_asMap(await _invoke('setAutostart', enabled)));

  // ---------------------------------------------------------------------------
  // Phase 4C-5.1B：原生使用会话采集
  // ---------------------------------------------------------------------------

  @override
  Future<UsageCollectorState> usageCollectorState() async =>
      UsageCollectorState.fromMap(_asMap(await _invoke('getUsageCollectorState')));

  @override
  Future<List<AndroidUsageSession>> readPendingUsageSessions({int limit = 200}) async {
    final Object? raw = await _invoke('readPendingUsageSessions', limit);
    if (raw is! List) {
      throw const OverlayPlatformException('bad_response', '原生端返回了非预期的结果');
    }
    final List<AndroidUsageSession> sessions = <AndroidUsageSession>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      // 解析不了的单条直接跳过（由导入器计数上报），绝不因为一条坏数据中断整批。
      final AndroidUsageSession? session = AndroidUsageSession.fromMap(
        item.map<String, Object?>(
          (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
        ),
      );
      if (session != null) sessions.add(session);
    }
    return sessions;
  }

  @override
  Future<int> acknowledgeUsageSessions(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return 0;
    final Object? raw = await _invoke('acknowledgeUsageSessions', sessionIds);
    return raw is num ? raw.toInt() : 0;
  }

  @override
  Future<void> setUsageCollectionPaused(bool paused) async =>
      _invoke('setUsageCollectionPaused', paused);

  @override
  Future<void> updateUsageIdentity(String deviceLocalId) async =>
      _invoke('updateUsageIdentity', deviceLocalId);

  // ---------------------------------------------------------------------------

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const OverlayUnsupportedException('原生端未注册悬浮桌宠通道');
    } on PlatformException catch (e) {
      throw OverlayPlatformException(e.code, e.message ?? '悬浮窗操作失败');
    }
  }

  /// 原生返回的必须是 Map；返回 null/其它类型说明协议被破坏，直接报错而不是猜。
  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? v) => MapEntry<String, Object?>('$key', v),
      );
    }
    throw const OverlayPlatformException('bad_response', '原生端返回了非预期的结果');
  }
}
