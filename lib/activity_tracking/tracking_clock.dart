/// 采集用的时钟抽象。
///
/// 需求「五、时间准确性」要求持续时间**不能完全依赖系统墙上时间**：
/// - 墙上时间用于写库（带时区语义）；
/// - 单调时钟用于计算持续时长，不受系统时间调整影响。
///
/// 两者都抽象出来，测试可以完全控制时间推进，不依赖真实等待。
library;

/// 单调时钟（只增不减）。
abstract interface class MonotonicClock {
  /// 自某个固定起点的毫秒数。
  int nowMs();
}

/// 墙上时钟。
abstract interface class WallClock {
  /// 当前本地时间。
  DateTime now();
}

/// 基于 [Stopwatch] 的单调时钟实现。
class StopwatchMonotonicClock implements MonotonicClock {
  StopwatchMonotonicClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();

  @override
  int nowMs() => _stopwatch.elapsedMilliseconds;
}

/// 系统墙上时钟实现。
class SystemWallClock implements WallClock {
  const SystemWallClock();

  @override
  DateTime now() => DateTime.now();
}

/// 测试用：可任意推进的单调时钟。
class FakeMonotonicClock implements MonotonicClock {
  FakeMonotonicClock([this._nowMs = 0]);

  int _nowMs;

  /// 前进（也可传负数模拟时钟异常，用于验证不产生负数记录）。
  void advance(int ms) => _nowMs += ms;

  void set(int ms) => _nowMs = ms;

  @override
  int nowMs() => _nowMs;
}

/// 测试用：可任意推进的墙上时钟。
class FakeWallClock implements WallClock {
  FakeWallClock(this._now);

  DateTime _now;

  /// 前进指定时长。
  void advance(Duration d) => _now = _now.add(d);

  /// 直接设定（用于模拟系统时间被改动）。
  void set(DateTime t) => _now = t;

  @override
  DateTime now() => _now;
}
