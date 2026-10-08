import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../character/models/character_model.dart';
import '../character/models/emotion_asset.dart';
import '../core/logger.dart';
import '../platform/overlay_pet.dart';
import '../platform/overlay_state_mapping.dart';
import '../state_engine/state_snapshot.dart';
import '../state_engine/system_state.dart';

/// 读取"当前角色 → 状态 → 素材"快照的回调（Phase 4C-5）。
///
/// [revision] 由控制器统一分配并保证单调递增：原生侧只接受不旧于当前的版本。
typedef OverlayStateMappingLoader = Future<OverlayStateMapping?> Function(
  StateSnapshot snapshot,
  int revision,
);

/// 悬浮桌宠的 Flutter 侧协调器（Phase 4C-2）。
///
/// 职责：把「状态引擎当前决定了哪个角色 / 哪张素材」翻译成 [OverlayPetConfig]
/// 并下发给原生层，同时把原生的加载结果（实际显示的是哪张、有没有失败）
/// 变成设置页可以显示的状态。
///
/// Phase 4C-5 起还负责两件事：
/// * 把「状态 → 素材」整份快照推给原生（原生在 **Flutter 退出后**继续按它联动）；
/// * 转发状态调试器的手动覆盖（手动覆盖必须在**原生**侧生效，
///   因为用户看到的是原生悬浮窗而不是 Flutter 里的桌宠）。
///
/// 四条硬规则：
/// * **只有关键字段变化才下发**（characterId / assetId / filePath / mimeType /
///   isAnimated）—— 相同素材不得重复解码；
/// * **不发送非法配置**：素材为空、路径越界、文件已被删除等情况一律本地拦下，
///   只把原因记下来给用户看；
/// * **一次失败不改变已显示的素材**：失败只记录原因，不动原生当前的画面；
/// * **状态映射的 revision 单调递增**，且首次同步时从原生"已生效版本"续上，
///   避免应用重启后用一个更小的 revision 被原生拒绝。
class OverlayPetController extends ChangeNotifier {
  OverlayPetController({
    required AndroidOverlayPet overlay,
    required ValueListenable<StateSnapshot> snapshots,
    required String Function() privateAssetsRoot,
    Future<void> Function(Duration)? delay,
    OverlayStateMappingLoader? stateMappingLoader,
  })  : _overlay = overlay,
        _snapshots = snapshots,
        _privateAssetsRoot = privateAssetsRoot,
        _delay = delay ?? Future<void>.delayed,
        _stateMappingLoader = stateMappingLoader;

  final AndroidOverlayPet _overlay;
  final ValueListenable<StateSnapshot> _snapshots;
  final String Function() _privateAssetsRoot;
  final Future<void> Function(Duration) _delay;
  final OverlayStateMappingLoader? _stateMappingLoader;

  /// 最近一次从原生读到的运行时状态。
  OverlayRuntimeState? _state;

  /// 最近一次读到的授权状态。
  OverlayPermissionState? _permissions;

  /// 最近一次成功下发的素材签名（用于去重）。
  String? _pushedSignature;

  /// 最近一次成功下发的状态映射签名（用于去重）。
  String? _pushedMappingSignature;

  /// 状态映射的 revision 计数器（单调递增；首次同步时从原生续上）。
  int _mappingRevision = 0;

  /// 最近一次读到的状态联动诊断（Phase 4C-5，需求 §19）。
  OverlayStateDiagnostics _stateDiagnostics =
      OverlayStateDiagnostics.unavailable;

  /// 最近一次读到的双窗口探针诊断（只读展示，不驱动任何行为）。
  DualWindowProbeStatus _dualWindowProbeStatus =
      DualWindowProbeStatus.unsupported;

  /// 界面要显示的错误 / 提示（原样保留最近一次）。
  String? _lastError;
  String? _lastNotice;

  /// 最近一次原生快照发布的结果（Phase 4C-6A.1 诊断，需求 §15）。
  String? _lastPublishResult;
  String? _lastPublishError;
  DateTime? _lastPublishAt;
  int _lastPublishedRevision = 0;

  /// 轮盘主题（Phase 4C-6B-1；原生是权威来源）。
  OverlayMenuThemeState _menuTheme = OverlayMenuThemeState.unsupported;
  int _menuThemeRevision = 0;

  /// 轮盘布局（Phase 4C-6B-1.1：尺寸 / 紧凑）。
  OverlayWheelLayoutSettings _wheelLayout = OverlayWheelLayoutSettings.unsupported;
  int _wheelLayoutRevision = 0;

  /// 开机自启状态（Phase 4D；原生是权威来源）。
  OverlayAutostartStatus _autostart = OverlayAutostartStatus.unsupported;

  /// 「双窗口实现」开关（迁移期临时回退；原生是权威来源）。
  DualWindowModeStatus _dualWindowMode = DualWindowModeStatus.unsupported;

  bool _attached = false;
  bool _disposed = false;

  OverlayRuntimeState? get state => _state;

  /// 状态联动的只读诊断（Phase 4C-5）。
  OverlayStateDiagnostics get stateDiagnostics => _stateDiagnostics;

  /// 双窗口探针的只读诊断（原生权威；未读取或非 Android 时为不支持的安全默认）。
  DualWindowProbeStatus get dualWindowProbeStatus => _dualWindowProbeStatus;

  /// 当前是否已被状态调试器手动覆盖。
  bool get hasManualStateOverride =>
      _stateDiagnostics.manualOverride != null;

  /// 最近一次发布结果的原始码（`succeeded` / `skipped-*` / `failed`）。
  String? get lastPublishResult => _lastPublishResult;

  /// 最近一次发布失败的原因（成功时为 null）。
  String? get lastPublishError => _lastPublishError;

  /// 最近一次成功下发的时间。
  DateTime? get lastPublishAt => _lastPublishAt;

  /// 最近一次成功下发的 revision。
  int get lastPublishedRevision => _lastPublishedRevision;

  /// 发布结果的中文说明（映射编辑器直接显示）。
  String get publishResultZh => switch (_lastPublishResult) {
        null => '尚未发布',
        'succeeded' => '已下发原生（rev $_lastPublishedRevision）',
        'skipped-unchanged' => '内容未变化，无需重复下发',
        'skipped-service-not-running' => '悬浮服务未运行：已保存，启动后自动下发',
        'failed' => '下发失败（原生保留旧配置）',
        _ => _lastPublishResult!,
      };

  OverlayPermissionState? get permissions => _permissions;

  String? get lastError => _lastError;

  String? get lastNotice => _lastNotice;

  /// 是否处于"配置已下发但原生还没显示出来"的中间态。
  bool get isAwaitingDisplay {
    final OverlayRuntimeState? s = _state;
    if (s == null || !s.serviceRunning || s.hidden) return false;
    return !s.isPlaceholder && !s.showsExpectedAsset;
  }

  /// 设置页显示的"当前悬浮素材：角色 / 情绪 / 变体"。
  String? get currentAssetLabel {
    final StateSnapshot snapshot = _snapshots.value;
    final CharacterModel? character = snapshot.currentCharacter;
    final EmotionAsset? asset = snapshot.currentAsset;
    if (character == null || asset == null) return null;
    return '${character.displayName} / ${asset.emotionName} / ${asset.variantName}';
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 状态诊断的轮询间隔（Phase 4C-6A 真机诊断）。
  ///
  /// 设置页要看"边切应用边变化"的原生真值，使用统计页也要显示**原生**的
  /// 当前状态，因此这里由控制器统一驱动一次只读轮询 ——
  /// 页面只负责读 [stateDiagnostics]，不再各自起计时器（也避免漏刷新）。
  ///
  /// 代价明确：这是一个**只读**通道调用，且原生侧不会因此发起
  /// `UsageStatsManager` 查询（共享快照未过期时直接返回缓存）。
  static const Duration stateDiagnosticsInterval = Duration(seconds: 2);

  Timer? _diagnosticsTimer;

  /// 开始监听状态引擎，并立刻同步一次（覆盖"应用启动后恢复"）。
  void attach() {
    if (_attached) return;
    _attached = true;
    _snapshots.addListener(_onSnapshotChanged);
    unawaited(_initialSync());
    _diagnosticsTimer ??= Timer.periodic(
      stateDiagnosticsInterval,
      (Timer _) => unawaited(refreshStateDiagnostics()),
    );
  }

  /// 只读一次状态诊断（不查权限、不查窗口状态）。
  ///
  /// 服务没在运行时**不发通道调用** —— 此时界面显示的值来自上一次成功读取，
  /// 不会因为"服务已停止"而把它清成假值。
  Future<void> refreshStateDiagnostics() async {
    if (_disposed) return;
    if (!(_state?.serviceRunning ?? false)) return;
    try {
      _stateDiagnostics = await _overlay.stateDiagnostics();
      _notify();
    } catch (e, st) {
      Loggers.app.warning('读取状态诊断失败', e, st);
    }
  }

  /// 只读一次双窗口探针诊断（Frozen contract 的 `getDualWindowProbeStatus`）。
  ///
  /// 与状态诊断不同：探针**不依赖悬浮服务是否在跑**（未跑时原生也会带回
  /// `probeValid=false`），因此这里不做 `serviceRunning` 前置判断。
  ///
  /// 失败（通道缺失 / 原生未实现）时**保留上一次的值**并返回它——纯只读展示，
  /// 绝不因此抛错或清空界面。非 Android 恒为 [DualWindowProbeStatus.unsupported]。
  Future<DualWindowProbeStatus> refreshDualWindowProbeStatus() async {
    if (_disposed) return _dualWindowProbeStatus;
    try {
      _dualWindowProbeStatus = await _overlay.dualWindowProbeStatus();
      _notify();
    } catch (e, st) {
      Loggers.app.warning('读取双窗口探针诊断失败', e, st);
    }
    return _dualWindowProbeStatus;
  }

  /// 先读一次原生状态，再决定要不要下发素材与映射。
  ///
  /// 顺序很关键：`syncNow` / `syncStateMapping` 需要先知道"服务是不是在运行"，
  /// 否则应用重启后（悬浮服务仍在跑）会漏掉第一次同步；而映射的 revision
  /// 也必须先由 [refresh] 从原生"已生效版本"续上。
  Future<void> _initialSync() async {
    await refresh();
    if (_disposed) return;
    await syncStateMapping();
    if (_disposed) return;
    await syncNow();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _snapshots.removeListener(_onSnapshotChanged);
  }

  @override
  void dispose() {
    _disposed = true;
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = null;
    detach();
    super.dispose();
  }

  void _onSnapshotChanged() {
    unawaited(syncStateMapping());
    unawaited(syncNow());
  }

  // ---------------------------------------------------------------------------
  // 读取状态
  // ---------------------------------------------------------------------------

  Future<void> refresh() async {
    try {
      final OverlayPermissionState permissions = await _overlay.permissionState();
      final OverlayRuntimeState state = await _overlay.getState();
      final OverlayStateDiagnostics diagnostics = await _overlay.stateDiagnostics();
      // 从原生"已生效的映射版本"续上计数器：应用重启后计数器从 0 开始，
      // 若不续上就会被原生当成"旧 revision"整份拒绝（需求 §9）。
      _mappingRevision = math.max(_mappingRevision, diagnostics.mappingRevision);
      _stateDiagnostics = diagnostics;
      _applyState(state, permissions: permissions);
    } catch (e, st) {
      Loggers.app.warning('读取悬浮桌宠状态失败', e, st);
      _setError(_describe(e));
    }
  }

  /// 素材解码在原生侧是异步的：下发后等一小会儿再读一次，让界面收敛到真实状态。
  Future<void> refreshAfterLoad({
    Duration delay = const Duration(milliseconds: 400),
  }) async {
    await _delay(delay);
    if (_disposed) return;
    await refresh();
  }

  // ---------------------------------------------------------------------------
  // 素材同步（核心）
  // ---------------------------------------------------------------------------

  /// 按当前状态引擎快照同步素材到原生层。
  ///
  /// 服务没在运行时**只记录不发送**：等用户点「显示悬浮桌宠」时随 `start` 一起带过去。
  Future<void> syncNow() async {
    if (_disposed) return;

    final OverlayPetConfig? config = _desiredConfig();
    // 素材为空 / 配置非法：本地拦下，绝不把非法路径送给原生。
    if (config == null) return;

    final String signature = _signatureOf(config);
    if (signature == _pushedSignature) return;
    if (!(_state?.serviceRunning ?? false)) return;

    try {
      final OverlayRuntimeState next = await _overlay.updatePet(config);
      _pushedSignature = signature;
      _applyState(next);
      await refreshAfterLoad();
    } catch (e, st) {
      Loggers.app.warning('同步悬浮桌宠素材失败', e, st);
      _setError(_describe(e));
    }
  }

  /// 当前快照对应的配置；素材为空或校验不过时返回 null（并记录原因）。
  OverlayPetConfig? _desiredConfig() {
    final StateSnapshot snapshot = _snapshots.value;
    final CharacterModel? character = snapshot.currentCharacter;
    final EmotionAsset? asset = snapshot.currentAsset;
    if (character == null || asset == null) return null;

    final OverlayRuntimeState? current = _state;
    final OverlayPetConfig config = OverlayPetConfig(
      characterId: character.id,
      assetId: asset.id,
      filePath: asset.filePath,
      mimeType: asset.mimeType,
      isAnimated: asset.isAnimated,
      frameCount: asset.frameCount,
      animationDurationMs: asset.animationDurationMs,
      // 缩放 / 吸附沿用**原生当前的设置**，避免"同步素材"顺手把用户调过的大小重置。
      scale: current?.scale ?? OverlayPetConfig.defaultScale,
      snapEnabled: current?.snapEnabled ?? true,
    );

    try {
      config.validate(privateAssetsRoot: _privateAssetsRoot());
    } on OverlayConfigException catch (e) {
      Loggers.app.warning('悬浮桌宠素材配置不合格：${e.code} ${e.message}');
      _setError('${e.message}（${e.code}）');
      return null;
    }
    return config;
  }

  /// 去重签名：只包含需求规定的五个关键字段。
  static String _signatureOf(OverlayPetConfig config) => <String>[
        config.characterId,
        config.assetId,
        config.filePath,
        config.mimeType,
        config.isAnimated.toString(),
      ].join('|');

  // ---------------------------------------------------------------------------
  // 状态映射同步（Phase 4C-5）
  // ---------------------------------------------------------------------------

  /// 把「状态 → 素材」整份快照推给原生。
  ///
  /// 只有内容变化才下发（按 [OverlayStateMapping.signature] 去重）；
  /// 服务没在运行时只记录，等用户点「显示悬浮桌宠」时随 start 一起带过去。
  ///
  /// Phase 4C-6A.1：整个过程产出结构化日志与可读的发布结果
  /// （`lastPublishResult` / `lastPublishError`），映射编辑器据此告诉用户
  /// "这次保存有没有真的下发成功"，而不是让他对着一个没反应的界面猜。
  Future<void> syncStateMapping() async {
    if (_disposed) return;
    final OverlayStateMappingLoader? loader = _stateMappingLoader;
    if (loader == null) return;
    if (!(_state?.serviceRunning ?? false)) {
      // 服务没跑 ≠ 保存失败：数据库已经写好了，下次启动服务时会带上最新快照。
      _setPublishResult('skipped-service-not-running', null);
      return;
    }

    try {
      // 先自增再请求：即使这次请求在通道层失败，下次也用**更大的** revision，
      // 不会被原生当成"旧版本"跳过。
      final int revision = _mappingRevision + 1;
      final OverlayStateMapping? mapping =
          await loader(_snapshots.value, revision);
      if (mapping == null || _disposed) return;
      if (mapping.characterId.isEmpty) return;
      if (mapping.signature == _pushedMappingSignature) {
        _setPublishResult('skipped-unchanged', null);
        return;
      }

      Loggers.app.info(
        'state_mapping_publish_started revision=$revision '
        'character=${mapping.characterId} states=${mapping.states.length}',
      );
      final OverlayRuntimeState next = await _overlay.updateStateMapping(mapping);
      _mappingRevision = revision;
      _pushedMappingSignature = mapping.signature;
      _lastPublishAt = DateTime.now();
      _lastPublishedRevision = revision;
      Loggers.app.info('state_mapping_publish_succeeded revision=$revision');
      _applyState(next);
      _setPublishResult('succeeded', null);
    } catch (e, st) {
      // 原生拒绝 / 通道异常：**保留旧配置**（原生侧自己保证），这里只如实记录。
      Loggers.app.warning('state_mapping_publish_failed', e, st);
      _setPublishResult('failed', '$e');
    }
  }

  /// 记录最近一次发布结果；**只有真的变化时**才通知界面（避免无谓重建）。
  void _setPublishResult(String result, String? error) {
    if (_lastPublishResult == result && _lastPublishError == error) return;
    _lastPublishResult = result;
    _lastPublishError = error;
    _notify();
  }

  /// 状态调试器手动覆盖（需求 §16）：立即生效、不等防抖。
  Future<OverlayRuntimeState> setManualState(String? stateId) async {
    final OverlayRuntimeState next = await _run(
      () => _overlay.setManualState(stateId),
    );
    _lastNotice = stateId == null
        ? '已恢复自动状态联动'
        : '已手动覆盖为「${SystemState.fromWire(stateId).descriptionZh}」，'
            '期间不响应前台应用自动切换';
    _notify();
    return next;
  }

  /// 临时预览某状态的映射素材（需求 §11）。
  ///
  /// 与另外两件事的区别（UI 文案不得混用）：
  /// * **编辑映射**：改的是「状态 → 素材」，自动模式照常；
  /// * **手动覆盖**：`displayMode=manual`，一直忽略自动状态直到解除；
  /// * **临时预览**：`displayMode=preview`，约 10 秒后自动回到真实状态。
  Future<OverlayRuntimeState> previewState(String stateId) =>
      _run(() => _overlay.previewState(stateId));

  /// 立刻结束临时预览。
  Future<OverlayRuntimeState> clearPreview() =>
      _run(() => _overlay.clearPreview());

  /// 打开系统"使用情况访问"设置页（**只打开**，不反复催授权）。
  Future<void> openUsageAccessSettings() => _overlay.openUsageAccessSettings();

  // ---------------------------------------------------------------------------
  // 轮盘主题（Phase 4C-6B-1）
  // ---------------------------------------------------------------------------

  /// 最近一次读到的轮盘主题（原生权威）。
  OverlayMenuThemeState get menuThemeState => _menuTheme;

  /// 下一次写入必须用的 revision（**续接**原生计数，否则会被"旧配置"挡掉）。
  int get menuThemeNextRevision => _menuThemeRevision + 1;

  /// 读取轮盘主题（设置页进入 / 主题切换后回读）。
  Future<OverlayMenuThemeState> refreshMenuTheme() async {
    try {
      final OverlayMenuThemeState next = await _overlay.menuTheme();
      _menuTheme = next;
      _menuThemeRevision = next.revision;
      _notify();
      return next;
    } catch (e, st) {
      Loggers.app.warning('读取轮盘主题失败', e, st);
      _setError(_describe(e));
      return _menuTheme;
    }
  }

  /// 选择轮盘主题（预设 ID，或 `custom` + 自选主色）。
  ///
  /// 返回原生是否接受；被拒绝时在 [lastNotice] 里给出中文原因，
  /// **绝不谎报成功**（需求 §13.3 的 revision 守卫就是为了这个）。
  Future<bool> selectMenuTheme({
    required String themeId,
    int? customPrimary,
  }) async {
    try {
      final OverlayMenuThemeUpdate update = await _overlay.setMenuTheme(
        themeId: themeId,
        customPrimary: customPrimary,
        revision: _menuThemeRevision + 1,
      );
      if (update.accepted) {
        final OverlayMenuThemeState? state = update.state;
        if (state != null) {
          _menuTheme = state;
          _menuThemeRevision = state.revision;
        } else {
          await refreshMenuTheme();
        }
        _lastNotice = '轮盘主题已更新为「${_menuTheme.displayName}」';
        _notify();
        return true;
      }
      _lastError = update.errorLabelZh;
      await refreshMenuTheme();
      return false;
    } catch (e, st) {
      Loggers.app.warning('切换轮盘主题失败', e, st);
      _setError(_describe(e));
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 轮盘布局（Phase 4C-6B-1.1：轮盘大小）
  // ---------------------------------------------------------------------------

  /// 最近一次读到的轮盘布局设置（原生权威）。
  OverlayWheelLayoutSettings get wheelLayoutSettings => _wheelLayout;

  /// 最近一次读到的开机自启状态（原生权威）。
  OverlayAutostartStatus get autostartState => _autostart;

  /// 最近一次读到的「双窗口实现」开关（原生权威；未读取或非 Android 时为不支持的安全默认）。
  DualWindowModeStatus get dualWindowModeState => _dualWindowMode;

  /// 下一次写入必须用的 revision。
  int get wheelLayoutNextRevision => _wheelLayoutRevision + 1;

  /// 读取轮盘布局设置。
  Future<OverlayWheelLayoutSettings> refreshWheelLayout() async {
    try {
      final OverlayWheelLayoutSettings next = await _overlay.wheelLayout();
      _wheelLayout = next;
      _wheelLayoutRevision = next.revision;
      _notify();
      return next;
    } catch (e, st) {
      Loggers.app.warning('读取轮盘布局设置失败', e, st);
      return _wheelLayout;
    }
  }

  /// 设置轮盘大小（0.50~2.50，10% 步进）与/或按钮大小（0.50~2.50）。
  ///
  /// 返回原生是否接受；被拒绝时给出中文原因，绝不谎报成功。
  Future<bool> setWheelScale(
    double scale, {
    double? buttonScale,
    bool? compactMode,
  }) async {
    try {
      final OverlayWheelLayoutUpdate update = await _overlay.setWheelLayout(
        preferredScale: scale,
        buttonVisualScale: buttonScale ?? _wheelLayout.buttonVisualScale,
        compactMode: compactMode ?? _wheelLayout.compactMode,
        revision: _wheelLayoutRevision + 1,
      );
      if (update.accepted) {
        final OverlayWheelLayoutSettings? settings = update.settings;
        if (settings != null) {
          _wheelLayout = settings;
          _wheelLayoutRevision = settings.revision;
        } else {
          await refreshWheelLayout();
        }
        _lastNotice = '轮盘 ${_wheelLayout.scalePercent}% · '
            '按钮 ${(_wheelLayout.buttonVisualScale * 100).round()}%';
        _notify();
        return true;
      }
      _lastError = update.errorLabelZh;
      await refreshWheelLayout();
      return false;
    } catch (e, st) {
      Loggers.app.warning('设置轮盘大小失败', e, st);
      _setError(_describe(e));
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 开机自启（Phase 4D）
  // ---------------------------------------------------------------------------

  /// 读取"开机自动启动"开关与最近一次开机结果（原生权威）。
  Future<OverlayAutostartStatus> refreshAutostart() async {
    try {
      final OverlayAutostartStatus next = await _overlay.autostartStatus();
      _autostart = next;
      _notify();
      return next;
    } catch (e, st) {
      Loggers.app.warning('读取开机自启状态失败', e, st);
      return _autostart;
    }
  }

  /// 设置"开机自动启动"（写透到原生 SharedPreferences，供 BOOT_COMPLETED 接收器读取）。
  ///
  /// **只改这一个开关**：不启动/停止当前服务，也不改显示或隐藏状态。
  Future<OverlayAutostartStatus> setAutostart(bool enabled) async {
    final OverlayAutostartStatus next = await _overlay.setAutostart(enabled);
    _autostart = next;
    _lastNotice = enabled ? '开机自动启动已开启' : '开机自动启动已关闭';
    _notify();
    return next;
  }

  // ---------------------------------------------------------------------------
  // 双窗口实现开关（迁移期临时回退）
  // ---------------------------------------------------------------------------

  /// 读取「双窗口实现」开关（只读；原生权威；非 Android 为不支持的安全默认）。
  ///
  /// 失败（通道缺失 / 原生未实现）时**保留上一次的值**并返回它 —— 纯读展示，
  /// 绝不因此抛错或清空界面。
  Future<DualWindowModeStatus> refreshDualWindowMode() async {
    if (_disposed) return _dualWindowMode;
    try {
      _dualWindowMode = await _overlay.dualWindowMode();
      _notify();
    } catch (e, st) {
      Loggers.app.warning('读取双窗口实现开关失败', e, st);
    }
    return _dualWindowMode;
  }

  /// 设置「双窗口实现」开关（写透到原生并立即生效）。
  ///
  /// **写后一律回读原生真值**：不假设成功、也不假设立刻生效。被拒绝时回读到的
  /// 仍是旧值，界面据此自动回退，绝不谎报成功；写入抛错时由调用方（UI）
  /// 捕获、回退显示并提示。
  Future<DualWindowModeStatus> setDualWindowMode(bool enabled) async {
    final bool accepted = await _overlay.setDualWindowMode(enabled);
    final DualWindowModeStatus next = await refreshDualWindowMode();
    if (!accepted) {
      _lastNotice = '原生未接受切换（当前保持：${next.modeLabelZh}）';
      _notify();
    }
    return next;
  }

  // ---------------------------------------------------------------------------
  // 动作（设置页调用）
  // ---------------------------------------------------------------------------

  /// 显示悬浮桌宠：把**当前素材**一起带过去（没有素材时显示占位内容）。
  ///
  /// Phase 4C-5：服务起来后**立刻补一次状态映射**——全新安装时原生手里
  /// 还没有任何映射，必须由这次推送把"状态 → 素材"补上。
  Future<OverlayRuntimeState> show() async {
    try {
      final OverlayPetConfig? config = _desiredConfig();
      final OverlayRuntimeState next =
          config == null ? await _overlay.start() : await _overlay.start(config);
      if (config != null) _pushedSignature = _signatureOf(config);
      _applyState(next);
      await syncStateMapping();
      await refreshAfterLoad();
      return next;
    } catch (e, st) {
      Loggers.app.warning('显示悬浮桌宠失败', e, st);
      _setError(_describe(e));
      rethrow;
    }
  }

  Future<OverlayRuntimeState> hide() => _run(_overlay.hide);

  Future<OverlayRuntimeState> stop() async {
    // 停止后原生会清掉运行态；这里也把两个去重签名清空，
    // 保证"停止 → 再显示"时一定会重新下发素材与状态映射。
    _pushedSignature = null;
    _pushedMappingSignature = null;
    return _run(_overlay.stop);
  }

  Future<OverlayPermissionState> requestOverlayPermission() async {
    final OverlayPermissionState permissions =
        await _overlay.requestOverlayPermission();
    _permissions = permissions;
    _lastNotice = permissions.overlayGranted
        ? '悬浮窗权限已授权'
        : '请在系统页面里允许「显示在其他应用的上层」，然后返回本页';
    _notify();
    return permissions;
  }

  Future<OverlayPermissionState> requestNotificationPermission() async {
    final OverlayPermissionState permissions =
        await _overlay.requestNotificationPermission();
    _permissions = permissions;
    _lastNotice = permissions.notificationsGranted
        ? '通知权限已授权'
        : '未授予通知权限：悬浮桌宠仍可运行，但通知栏不会显示控制入口';
    _notify();
    return permissions;
  }

  Future<OverlayRuntimeState> updateSettings(OverlayPetSettings settings) =>
      _run(() => _overlay.updateSettings(settings));

  /// 调整悬浮桌宠大小（Phase 4C-3A 设置页滑块）。
  ///
  /// 只改**大小**：其余开关按原生当前回报值原样回传，避免顺手把用户
  /// 调过的选项重置；位置由原生拖动/吸附负责，界面不下发坐标。
  Future<OverlayRuntimeState> setScale(double scale) {
    final OverlayRuntimeState? current = _state;
    return updateSettings(
      OverlayPetSettings(
        scale: scale,
        snapEnabled: current?.snapEnabled ?? true,
        touchThrough: current?.touchThrough ?? false,
        hideOnLockScreen: current?.hideOnLockScreen ?? true,
        fixedAssetMode: current?.fixedAssetMode ?? false,
      ),
    );
  }

  /// 恢复默认大小（100%）。
  Future<OverlayRuntimeState> resetScale() =>
      setScale(OverlayPetConfig.defaultScale);

  /// 滑块**实时预览**：失败只记日志、不弹错。
  ///
  /// 拖动滑块的中间态不该反复打扰用户；真正的失败会在松开后的
  /// [refresh] 里以 `lastError` 的形式呈现。
  Future<void> previewScale(double scale) async {
    try {
      await setScale(scale);
    } catch (e, st) {
      Loggers.app.warning('预览悬浮桌宠大小失败', e, st);
    }
  }

  /// 诊断模式开关（固定洋红方块，不读素材）。真机排障用，见 docs/35 §6。
  Future<OverlayRuntimeState> setDebugOverlay(bool enabled) =>
      _run(() => _overlay.setDebugOverlay(enabled));

  Future<void> openBatterySettings() => _overlay.openBatterySettings();

  Future<void> openAppDetails() => _overlay.openAppDetails();

  /// 清掉界面上的错误 / 提示。
  void clearMessages() {
    if (_lastError == null && _lastNotice == null) return;
    _lastError = null;
    _lastNotice = null;
    _notify();
  }

  // ---------------------------------------------------------------------------

  Future<OverlayRuntimeState> _run(
    Future<OverlayRuntimeState> Function() action,
  ) async {
    try {
      final OverlayRuntimeState next = await action();
      _applyState(next);
      await refreshAfterLoad();
      return next;
    } catch (e, st) {
      Loggers.app.warning('悬浮桌宠操作失败', e, st);
      _setError(_describe(e));
      rethrow;
    }
  }

  void _applyState(OverlayRuntimeState state, {OverlayPermissionState? permissions}) {
    if (_disposed) return;
    _state = state;
    _permissions = permissions ??
        OverlayPermissionState(
          supported: state.supported,
          overlayGranted: state.overlayGranted,
          notificationsGranted: state.notificationsGranted,
          notificationsRequired: _permissions?.notificationsRequired ?? false,
        );
    // 原生报上来的加载/校验失败也要让用户看见。
    if (state.lastLoadError != null && state.lastLoadError!.isNotEmpty) {
      _lastError = state.lastLoadError;
    }
    _notify();
  }

  void _setError(String message) {
    if (_disposed) return;
    _lastError = message;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  static String _describe(Object error) {
    if (error is OverlayPlatformException) return error.message;
    if (error is OverlayConfigException) return error.message;
    if (error is OverlayUnsupportedException) return error.message;
    return '操作失败：$error';
  }
}
