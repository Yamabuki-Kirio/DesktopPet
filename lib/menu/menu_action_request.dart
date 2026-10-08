/// **菜单动作幂等账本**（增量 C1，需求 §八）。
///
/// 问题：桌宠的确认是"左键松开"，用户很容易在动画还没落位时连点两下；
/// 若不做去重，同一个动作会执行两次（收藏被切两下 = 没变；同步被触发两次 =
/// 重复请求）。Android 侧靠原生请求队列 + 落盘账本解决。
///
/// 这里用**明确的可判定机制**而不是延时：
/// * 每个动作携带 `requestId`；
/// * 同一个 `requestId` 只允许 `begin` 成功一次；
/// * 执行完成（成功或失败）后 `finish`，允许**下一个** requestId 执行；
/// * 因此"同一动作连点"仍然可以再次执行（用户确实想再点），
///   但"同一次确认被派发两次"（重入 / 事件重复投递）**只会执行一次**。
///
/// 纯 Dart，可单测。
library;

/// 一次动作请求的凭据。
class MenuActionRequest {
  const MenuActionRequest({
    required this.requestId,
    required this.actionId,
    required this.levelId,
  });

  /// 单调递增的请求号（同一次确认内唯一）。
  final int requestId;

  /// 稳定动作 id。
  final String actionId;

  /// 发起时所在的层级 id（用于判断"晚到结果是否已过期"）。
  final String levelId;

  String get key => '$actionId#$requestId';
}

/// 幂等账本。
class MenuActionLedger {
  MenuActionLedger({this.capacity = 64});

  /// 最多记住多少个"已开始 / 已完成"的请求。
  final int capacity;

  final List<String> _order = <String>[];
  final Set<String> _started = <String>{};
  final Set<String> _finished = <String>{};

  /// 是否已经见过这个 key（用于诊断）。
  bool hasSeen(String key) => _started.contains(key);

  /// 尝试开始一个请求。返回 false = 已经处理过（重入 / 重复投递），调用方必须放弃。
  bool begin(String key) {
    if (_started.contains(key)) return false;
    _started.add(key);
    _order.add(key);
    _evictIfNeeded();
    return true;
  }

  /// 标记请求结束（结束**不**移除 started 记录，否则重复投递又能进来）。
  void finish(String key) => _finished.add(key);

  /// 正在执行中的请求数（诊断 / 测试）。
  int get inFlightCount => _started.length - _finished.length;

  /// 测试 / 复位用。
  void reset() {
    _order.clear();
    _started.clear();
    _finished.clear();
  }

  void _evictIfNeeded() {
    while (_order.length > capacity) {
      final String oldest = _order.removeAt(0);
      _started.remove(oldest);
      _finished.remove(oldest);
    }
  }
}
