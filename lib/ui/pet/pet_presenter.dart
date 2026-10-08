import 'dart:async';

import '../../character/pet_renderer.dart';
import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../settings/settings_controller.dart';
import '../../state_engine/state_engine.dart';
import '../../state_engine/state_snapshot.dart';

/// 把「状态引擎决定的状态」翻译成「渲染器要画的素材」。
///
/// 这一层存在的意义是把两条容易混淆的规则隔离开：
/// - **防抖**（什么时候允许换状态）属于 StateEngine；
/// - **等待动画播完一轮**（换素材的时机）属于这里，因为它需要知道渲染器当前
///   播放到哪一帧——这是渲染层的信息，引擎不该关心。
class PetPresenter {
  PetPresenter({
    required StateEngine engine,
    required PetRenderer renderer,
    required SettingsController settings,
  })  : _engine = engine,
        _renderer = renderer,
        _settings = settings;

  final StateEngine _engine;
  final PetRenderer _renderer;
  final SettingsController _settings;

  StreamSubscription<StateChangeEvent>? _eventSub;
  Timer? _pendingDisplayTimer;

  String? _lastShownAssetId;
  bool _disposed = false;

  /// 最近一次展示是否因为等待动画而延迟（诊断页展示）。
  int lastDeferralMs = 0;

  Future<void> start() async {
    _settings.addListener(_applySettings);
    _applySettings();

    _eventSub = _engine.events.listen(_onStateChanged);

    // 只监听事件是不够的：**切换角色**时系统状态并没有变化
    // （DefaultStateEngine 只在 previousState != _state 时才发事件），
    // 于是"设为当前桌宠角色"之后桌宠仍显示旧角色的素材，
    // 直到重启应用（start() 里的首帧 _render）才更新。
    // 这里再监听快照本身，覆盖角色 / 素材 / 映射 / 默认图片等一切变化。
    _engine.snapshots.addListener(_onSnapshotChanged);

    // 先渲染当前快照，让窗口在启动瞬间就有内容。
    await _render(_engine.snapshot, immediate: true);
    Loggers.state.info('桌宠展示层已就绪');
  }

  /// 快照变化时按需重渲染。
  ///
  /// [_render] 内部按 `currentAsset.id` 去重，因此同一张图的重复通知
  /// 既不会重复解码，也不会把正在播放的动画重新起播。
  void _onSnapshotChanged() {
    if (_disposed) return;
    unawaited(_render(_engine.snapshot, immediate: false));
  }

  void _applySettings() {
    _renderer
      ..setCrossFadeMs(_settings.settings.crossFadeMs)
      ..setLoop(_settings.settings.loopAnimation);
  }

  void _onStateChanged(StateChangeEvent event) {
    if (_disposed) return;

    // 普通状态切换：尽量等当前动画播完一轮，避免把动画拦腰截断。
    // 紧急状态（error / manual）或调试器要求立即生效时直接切换。
    if (event.waitForAnimationCycle) {
      final int remaining = _renderer.remainingMsInCycle;
      if (remaining > 0 && remaining <= RenderTimings.waitAnimationCycleTimeoutMs) {
        lastDeferralMs = remaining;
        Loggers.state.fine('等待当前动画播完一轮（还需 ${remaining}ms）后切换素材');
        _pendingDisplayTimer?.cancel();
        _pendingDisplayTimer = Timer(Duration(milliseconds: remaining), () {
          unawaited(_render(_engine.snapshot, immediate: false));
        });
        return;
      }
    }

    lastDeferralMs = 0;
    _pendingDisplayTimer?.cancel();
    unawaited(_render(_engine.snapshot, immediate: event.to.isUrgent));
  }

  Future<void> _render(StateSnapshot snapshot, {required bool immediate}) async {
    if (_disposed) return;
    final String? assetId = snapshot.currentAsset?.id;
    if (assetId == _lastShownAssetId && !immediate) {
      return; // 同一张图，不重复加载、不重启动画。
    }
    _lastShownAssetId = assetId;

    await _renderer.display(snapshot.currentAsset, immediate: immediate);
    if (_disposed) return;

    if (snapshot.currentAsset == null) {
      Loggers.state.info(
        '当前状态 ${snapshot.state.wireName} 使用内置占位图'
        '（回退级别：${snapshot.fallbackLevel.label}，原因：${snapshot.resolution.reason}）',
      );
    }
  }

  /// 用户切换角色或修改映射后，强制重渲染。
  Future<void> forceRefresh() async {
    _lastShownAssetId = null;
    await _renderer.clear();
    await _render(_engine.snapshot, immediate: true);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pendingDisplayTimer?.cancel();
    _engine.snapshots.removeListener(_onSnapshotChanged);
    _settings.removeListener(_applySettings);
    await _eventSub?.cancel();
    await _renderer.clear();
  }
}

/// 本地 unawaited（避免为一个函数额外引入 dart:async 的命名冲突）。
void unawaited(Future<void> future) {
  future.catchError((Object e, StackTrace st) {
    Loggers.state.warning('异步渲染失败', e, st);
  });
}
