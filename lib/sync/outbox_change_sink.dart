import '../activity_tracking/local_change_sink.dart';
import '../core/logger.dart';
import 'outbox_producer.dart';

/// 把「本地数据变了」翻译成「往 outbox 写一条待同步记录」。
///
/// 两点刻意的设计：
/// 1. **不触发同步**。需求规定的同步触发时机是登录 / 启动 / 每 5 分钟 /
///    手动 / 网络恢复 / 退出前，不包括"每次本地变更"。在采集路径上发起网络请求
///    会把采集与网络耦合在一起，一旦网络慢就会拖累采集与渲染。
/// 2. **只刷新待同步计数**，让界面上的数字实时反映队列长度；
///    真正的同步由引擎的定时器与手动触发负责。
class OutboxChangeSink implements LocalChangeSink {
  OutboxChangeSink({required OutboxProducer producer, void Function()? onChanged})
      : _producer = producer,
        _onChanged = onChanged;

  final OutboxProducer _producer;

  /// 引擎创建晚于采集层（引擎依赖 producer），因此这里用可写回调打破构造顺序环。
  void Function()? _onChanged;

  set onChanged(void Function()? value) => _onChanged = value;

  @override
  Future<void> onSegmentChanged(String segmentId) async {
    await _producer.enqueueSegment(segmentId);
    _notify();
  }

  @override
  Future<void> onDailyUsageChanged({
    required String deviceLocalId,
    required String dayKey,
  }) async {
    await _producer.enqueueDailyUsage(deviceLocalId: deviceLocalId, dayKey: dayKey);
    _notify();
  }

  @override
  Future<void> onApplicationChanged(String appKey) async {
    await _producer.enqueueApplication(appKey);
    _notify();
  }

  void _notify() {
    try {
      _onChanged?.call();
    } catch (e, st) {
      Loggers.sync.fine('刷新待同步计数失败', e, st);
    }
  }
}
