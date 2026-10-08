/// 本地数据变更 → 待同步队列的桥接点（Phase 2）。
///
/// 为什么用接口而不是让采集层直接依赖 `OutboxProducer`：
/// * 阶段 1 的采集逻辑与测试完全不关心同步，不该被迫引入网络相关依赖；
/// * 测试可以注入 `NoopLocalChangeSink`，也可以注入记录调用的替身来断言"确实入队了"；
/// * 采集层只负责**声明"这条本地数据变了"**，具体怎么排队由 sync 层决定。
///
/// 调用约定：所有回调都必须**吞掉异常**——写 outbox 失败绝不能让采集或渲染出问题。
library;

abstract interface class LocalChangeSink {
  /// 活动段发生变化（开段 / 关段 / 检查点更新）。
  Future<void> onSegmentChanged(String segmentId);

  /// 每日用量快照发生变化。
  Future<void> onDailyUsageChanged({
    required String deviceLocalId,
    required String dayKey,
  });

  /// 应用记录发生变化（新发现 / 用户改分类、显示名、排除标记）。
  Future<void> onApplicationChanged(String appKey);
}

/// 什么都不做的实现：阶段 1 的既有测试与未登录状态都用它。
class NoopLocalChangeSink implements LocalChangeSink {
  const NoopLocalChangeSink();

  @override
  Future<void> onSegmentChanged(String segmentId) async {}

  @override
  Future<void> onDailyUsageChanged({
    required String deviceLocalId,
    required String dayKey,
  }) async {}

  @override
  Future<void> onApplicationChanged(String appKey) async {}
}
