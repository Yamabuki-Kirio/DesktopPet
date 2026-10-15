import '../../platform/overlay_pet.dart';
import '../../state_engine/state_snapshot.dart';
import '../../state_engine/system_state.dart';
import '../../sync/models/sync_models.dart';

/// 首页「当前桌宠状态卡」的**纯数据绑定层**。
///
/// 存在的理由（可测试性）：状态卡要展示的每一项都来自不同的既有服务 ——
/// 原生悬浮服务诊断、状态引擎快照、同步引擎 —— 如果把这些取值逻辑直接写在
/// Widget 里，就只能靠"pump 整个 AppServices"才能验证绑定是否正确，
/// 而整壳联调在 `flutter test` 里是不可行的（会启动定时器与数据库）。
///
/// 因此把「哪些字段、什么条件下显示什么文案」抽成纯函数：
/// * 页面只负责把服务里的值传进来；
/// * 测试可以直接构造各种组合（未运行 / 已隐藏 / 未登录 / 有待同步…）
///   断言绑定结果，**不需要任何 AppServices**。
class PetLifePetStatusView {
  const PetLifePetStatusView({
    required this.characterName,
    required this.emotionLabel,
    required this.foregroundAppLabel,
    required this.autoStateLabel,
    required this.autoStateEnabled,
    required this.serviceLabel,
    required this.serviceState,
    required this.syncLabel,
    required this.syncState,
  });

  /// 当前角色名（没有角色时为「还没有角色」）。
  final String characterName;

  /// 当前情绪 / 状态（优先当前素材的情绪名，回落到原生状态标签）。
  final String emotionLabel;

  /// 当前前台应用（Android 读原生共享快照，其它平台读采集器）。
  final String foregroundAppLabel;

  /// 「自动状态切换：已开启 / 已关闭」。
  final String autoStateLabel;
  final bool autoStateEnabled;

  /// 「悬浮服务：…」。
  final String serviceLabel;

  /// 悬浮服务的语义状态（用于选颜色）。
  final OverlayServiceState serviceState;

  /// 「同步：…」。
  final String syncLabel;
  final SyncVisualState syncState;

  /// 悬浮服务的语义状态。
  ///
  /// **不新增任何业务数据**：只是把已有的
  /// 「控制器是否存在 / 服务是否运行 / 是否隐藏」翻译成四种展示语义。
  static OverlayServiceState serviceStateOf({
    required bool supported,
    OverlayRuntimeState? runtime,
  }) {
    if (!supported) return OverlayServiceState.unsupported;
    if (runtime == null) return OverlayServiceState.unknown;
    if (!runtime.serviceRunning) return OverlayServiceState.stopped;
    if (runtime.hidden) return OverlayServiceState.hidden;
    return OverlayServiceState.running;
  }

  static String serviceLabelOf(OverlayServiceState state) => switch (state) {
        OverlayServiceState.unsupported => '悬浮服务：本平台不支持',
        OverlayServiceState.unknown => '悬浮服务：读取中…',
        OverlayServiceState.stopped => '悬浮服务：未运行',
        OverlayServiceState.hidden => '悬浮服务：运行中（已隐藏）',
        OverlayServiceState.running => '悬浮服务：运行中',
      };

  /// 同步一行的语义（成功 / 其它）。
  static SyncVisualState syncStateOf(SyncStatus status) =>
      status == SyncStatus.success
          ? SyncVisualState.success
          : SyncVisualState.neutral;

  /// 同步一行文案：有待同步记录时**必须**把条数带出来。
  static String syncLabelOf({
    required SyncStatus status,
    required int pendingCount,
  }) {
    final String label = status.labelZh;
    if (pendingCount > 0) return '同步：$label（待同步 $pendingCount 条）';
    return '同步：$label';
  }

  /// 自动状态切换文案。
  static String autoStateLabelOf(bool enabled) =>
      enabled ? '自动状态切换：已开启' : '自动状态切换：已关闭';

  /// 当前情绪 / 状态：优先「当前素材的情绪名」，其次原生状态标签，
  /// 最后回落到状态引擎的中文描述 —— 三者都是**已有**数据。
  static String emotionLabelOf({
    required StateSnapshot snapshot,
    String? nativeStateLabel,
  }) {
    final String? emotion = snapshot.currentAsset?.emotionName;
    if (emotion != null && emotion.isNotEmpty) return emotion;
    if (nativeStateLabel != null && nativeStateLabel.isNotEmpty) {
      return nativeStateLabel;
    }
    return snapshot.state.descriptionZh;
  }

  /// 由各个服务的**当前读数**构造展示模型（页面直接调用它）。
  factory PetLifePetStatusView.from({
    required StateSnapshot snapshot,
    required bool overlaySupported,
    required OverlayRuntimeState? overlayRuntime,
    required String? nativeStateLabel,
    required String foregroundAppLabel,
    required bool autoStateEnabled,
    required SyncStatus syncStatus,
    required int pendingCount,
  }) {
    final OverlayServiceState serviceState = serviceStateOf(
      supported: overlaySupported,
      runtime: overlayRuntime,
    );
    return PetLifePetStatusView(
      characterName: snapshot.currentCharacter?.displayName ?? '还没有角色',
      emotionLabel: emotionLabelOf(
        snapshot: snapshot,
        nativeStateLabel: nativeStateLabel,
      ),
      foregroundAppLabel: foregroundAppLabel,
      autoStateLabel: autoStateLabelOf(autoStateEnabled),
      autoStateEnabled: autoStateEnabled,
      serviceLabel: serviceLabelOf(serviceState),
      serviceState: serviceState,
      syncLabel: syncLabelOf(status: syncStatus, pendingCount: pendingCount),
      syncState: syncStateOf(syncStatus),
    );
  }
}

/// 悬浮服务的四种展示语义 + 未知 + 不支持。
enum OverlayServiceState { unsupported, unknown, stopped, hidden, running }

/// 同步一行的展示语义（用于选颜色）。
enum SyncVisualState { success, neutral }

/// 系统状态的展示文案（`wireName` + 中文描述），供首页 / 统计页共用。
String petLifeSystemStateLabel(SystemState state) =>
    '${state.descriptionZh}（${state.wireName}）';
