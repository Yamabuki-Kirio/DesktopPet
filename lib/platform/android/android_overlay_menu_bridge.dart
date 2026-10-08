import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../overlay_pet.dart';
import 'android_overlay_pet.dart' show androidOverlayChannelName;

/// 轮盘菜单请求的状态（原生与 Dart 共用的取值）。
enum MenuRequestStatus {
  /// 待处理。
  pending,

  /// 已执行成功（终态）。
  completed,

  /// 执行失败（终态）。
  failed,

  /// 已过期（终态）。
  expired;

  String get wireName => name;

  /// 是否为终态（终态一律不再执行，只做幂等确认）。
  bool get isTerminal =>
      this == MenuRequestStatus.completed ||
      this == MenuRequestStatus.failed ||
      this == MenuRequestStatus.expired;

  static MenuRequestStatus fromWire(String? raw) {
    if (raw == null) return MenuRequestStatus.pending;
    for (final MenuRequestStatus status in MenuRequestStatus.values) {
      if (status.name == raw) return status;
    }
    // 未知取值按"待处理"处理：宁可执行一次（有幂等台账兜底），也不要静默丢掉请求。
    return MenuRequestStatus.pending;
  }
}

/// 一条菜单请求（原生 → Dart）。
///
/// 字段与冻结契约一一对应：`{requestId, actionId, args, createdAt, status}`。
class OverlayMenuRequest {
  const OverlayMenuRequest({
    required this.requestId,
    required this.actionId,
    this.args = const <String, Object?>{},
    this.createdAt = 0,
    this.status = MenuRequestStatus.pending,
  });

  final String requestId;

  /// 原生侧的动作 ID（`pet_auto` / `appearance_next` / …）。
  final String actionId;

  final Map<String, Object?> args;

  /// 原生记录的时间戳（毫秒）；仅用于日志与诊断。
  final int createdAt;

  final MenuRequestStatus status;

  /// 严格解析：缺少 `requestId` 或 `actionId` 时返回 null（不猜、不伪造）。
  static OverlayMenuRequest? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final Object? id = map['requestId'];
    final Object? action = map['actionId'];
    if (id is! String || id.isEmpty) return null;
    if (action is! String || action.isEmpty) return null;
    final Object? rawArgs = map['args'];
    final Object? rawCreatedAt = map['createdAt'];
    return OverlayMenuRequest(
      requestId: id,
      actionId: action,
      args: rawArgs is Map
          ? rawArgs.map<String, Object?>(
              (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
            )
          : const <String, Object?>{},
      createdAt: rawCreatedAt is num ? rawCreatedAt.toInt() : 0,
      status: MenuRequestStatus.fromWire(map['status'] as String?),
    );
  }

  @override
  String toString() => 'OverlayMenuRequest($requestId, $actionId, ${status.name})';
}

/// 轮盘菜单动作通道（原生 ↔ Dart，Phase 4C-6B-2）。
///
/// **刻意复用** `PetOverlayBridge.CHANNEL_NAME`（`asia.akechi.petlife/overlay`）：
/// * Dart → 原生：`pullPendingMenuRequests` / `completeMenuRequest`（本类）；
/// * 原生 → Dart：`menuRequest`（本类注册处理器）。
///
/// 关于"同一个通道名再建一个 `MethodChannel` 实例"是否安全：
/// `MethodChannel` 的处理器注册表按 **(binaryMessenger, 通道名)** 索引，
/// 与实例无关。因此这里注册 `setMethodCallHandler` 不会影响
/// `AndroidOverlayPetBridge` 用另一个实例发起的 `invokeMethod` 调用
/// （两者走同一个通道名，互不覆盖）。仓库内已确认此前**没有任何**
/// `setMethodCallHandler`（本类是唯一处理器注册点）。
///
/// 错误翻译与 `android_overlay_pet.dart` 保持一致：
/// 通道不存在 → [OverlayUnsupportedException]；原生报错 → [OverlayPlatformException]。
class AndroidOverlayMenuBridge {
  AndroidOverlayMenuBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(androidOverlayChannelName);

  /// 原生 → Dart：投递一条菜单请求，期望返回 `{status, message}`。
  static const String methodMenuRequest = 'menuRequest';

  /// Dart → 原生：拉取待处理请求。
  static const String methodPullPending = 'pullPendingMenuRequests';

  /// Dart → 原生：回执（`completed` / `failed` / `expired`）。
  static const String methodComplete = 'completeMenuRequest';

  final MethodChannel _channel;

  /// 拉取待处理请求（原生是权威来源；异常一律抛出，由调用方决定是否记录）。
  Future<List<OverlayMenuRequest>> pullPendingMenuRequests() async {
    final Map<String, Object?> map = _asMap(await _invoke(methodPullPending));
    final Object? raw = map['requests'];
    if (raw is! List) return const <OverlayMenuRequest>[];
    final List<OverlayMenuRequest> requests = <OverlayMenuRequest>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final OverlayMenuRequest? request = OverlayMenuRequest.fromMap(
        item.map<String, Object?>(
          (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
        ),
      );
      // 单条坏数据只跳过（记日志），绝不因为一条脏记录中断整批。
      if (request == null) {
        Loggers.app.warning('原生返回了一条无法解析的菜单请求，已跳过');
        continue;
      }
      requests.add(request);
    }
    return requests;
  }

  /// 回执一条请求。返回原生是否确认（`ok`）。
  ///
  /// [status] 必须是终态（`completed` / `failed` / `expired`）——
  /// 契约里不存在"把已处理的请求再标回 pending"的用法。
  Future<bool> completeMenuRequest({
    required String requestId,
    required MenuRequestStatus status,
    String? message,
  }) async {
    final Map<String, Object?> map = _asMap(
      await _invoke(methodComplete, <String, Object?>{
        'requestId': requestId,
        'status': status.wireName,
        if (message != null) 'message': message,
      }),
    );
    return map['ok'] == true;
  }

  /// 注册原生 → Dart 的 `menuRequest` 处理器。
  ///
  /// [handler] 的返回值会原样作为通道答复（`{status, message}`）。
  void bindMenuRequestHandler(
    Future<Map<String, Object?>> Function(OverlayMenuRequest request) handler,
  ) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != methodMenuRequest) {
        // 该通道只约定了一个原生 → Dart 方法；未知方法如实记录并返回 null，
        // 不抛异常（抛错会让原生侧看到 PlatformException 而不是"不支持"）。
        Loggers.app.warning('悬浮桌宠通道收到未知的原生调用：${call.method}');
        return null;
      }
      final Object? raw = call.arguments;
      final OverlayMenuRequest? request = OverlayMenuRequest.fromMap(
        raw is Map
            ? raw.map<String, Object?>(
                (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
              )
            : null,
      );
      if (request == null) {
        return <String, Object?>{'status': 'failed', 'message': '菜单请求参数不完整'};
      }
      return handler(request);
    });
  }

  /// 注销处理器（外壳销毁时调用，避免持有已释放的 State）。
  void clearMenuRequestHandler() => _channel.setMethodCallHandler(null);

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const OverlayUnsupportedException('原生端未注册悬浮桌宠通道');
    } on PlatformException catch (e) {
      throw OverlayPlatformException(e.code, e.message ?? '悬浮窗操作失败');
    }
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? v) => MapEntry<String, Object?>('$key', v),
      );
    }
    throw const OverlayPlatformException('bad_response', '原生端返回了非预期的结果');
  }
}
