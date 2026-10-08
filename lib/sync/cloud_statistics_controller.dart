import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import 'cloud_statistics_cache.dart';
import 'cloud_statistics_repository.dart';
import 'models/cloud_statistics_models.dart';

/// 云端统计页面状态。
enum CloudStatsStatus {
  /// 还没有发起过任何请求。
  idle,

  /// 首次加载（本地无缓存可展示）。
  loading,

  /// 已有数据，正在后台刷新。
  refreshing,

  /// 展示的是服务端刚返回的数据。
  loaded,

  /// 展示的是本地缓存（网络不可用或刷新失败）。
  offlineCache,

  /// 请求成功但该范围内没有任何数据。
  empty,

  /// 出错且没有可用缓存。
  error,
}

/// 云端统计的页面级控制器。
///
/// 职责（每条都对应需求里的一个硬要求）：
/// * **状态机**：idle / loading / refreshing / loaded / offlineCache / empty / error；
/// * **缓存优先**：先展示缓存 → 后台请求 → 成功后覆盖缓存；失败则保留缓存并标记离线；
/// * **请求去重**：同一查询键只允许一个在途请求（`_inFlight`）；
/// * **防串页**：快速切换日期/设备时，旧响应不会覆盖新查询（`_epoch` 守卫）；
/// * **只读**：本控制器只调用仓库的读方法，任何数据都不会写进本机采集表或 outbox。
class CloudStatisticsController extends ChangeNotifier {
  CloudStatisticsController({
    required CloudStatisticsRepository repository,
    required CloudStatisticsCache cache,
    required String? Function() currentAccountUserId,
    DateTime Function()? clock,
  })  : _repository = repository,
        _cache = cache,
        _account = currentAccountUserId,
        _clock = clock ?? DateTime.now;

  final CloudStatisticsRepository _repository;
  final CloudStatisticsCache _cache;
  final String? Function() _account;
  final DateTime Function() _clock;

  /// 回到前台后超过这个时长才自动刷新（避免频繁切页时反复请求）。
  static const Duration foregroundRefreshThreshold = Duration(minutes: 2);

  CloudStatsStatus _status = CloudStatsStatus.idle;
  List<CloudDevice> _devices = const <CloudDevice>[];
  DateTime? _date;
  String? _deviceId;
  String? _appId;
  int _timezoneOffsetMinutes = 0;
  String _timezone = 'UTC+00:00';

  CloudUsageSummary? _summary;
  List<CloudTimelineEntry> _timeline = const <CloudTimelineEntry>[];
  final Map<String, List<CloudUsageSession>> _sessionsByApp =
      <String, List<CloudUsageSession>>{};
  final Map<String, String?> _sessionCursors = <String, String?>{};
  final Set<String> _loadingApps = <String>{};

  String? _errorMessage;
  bool _isOfflineData = false;
  DateTime? _fetchedAt;
  DateTime? _lastRefreshedAt;

  /// 查询代次：任何查询条件变化都会 +1，旧代次的响应直接丢弃。
  int _epoch = 0;
  int _sessionEpoch = 0;

  /// 在途请求（按"代次 + 查询键"去重）。
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// 强制刷新的序号：让"再点一次刷新"永远能真正发起请求（不受在途去重影响）。
  int _manualSeq = 0;

  /// 上一次加载所用的账户；账户变了必须先作废旧数据（换号不得看到上一个账户的记录）。
  String? _loadedAccount;

  bool _disposed = false;

  // --- 只读视图 ---

  CloudStatsStatus get status => _status;

  List<CloudDevice> get devices => _devices;

  /// null = 全部设备。
  String? get deviceId => _deviceId;

  String get deviceKey => _deviceId ?? kCloudDeviceAll;

  DateTime? get date => _date;

  String? get appId => _appId;

  int get timezoneOffsetMinutes => _timezoneOffsetMinutes;

  String get timezone => _timezone;

  CloudUsageSummary? get summary => _summary;

  List<CloudTimelineEntry> get timeline => _timeline;

  String? get errorMessage => _errorMessage;

  /// true = 当前展示的是离线缓存（界面需要显示"离线数据"）。
  bool get isOfflineData => _isOfflineData;

  /// 这份数据的时间（服务端返回时间 / 缓存写入时间）。
  DateTime? get fetchedAt => _fetchedAt;

  /// 最近一次成功刷新时间。
  DateTime? get lastRefreshedAt => _lastRefreshedAt;

  bool get hasData => _summary != null || _timeline.isNotEmpty;

  List<CloudUsageSession> sessionsOf(String appId) =>
      _sessionsByApp[appId] ?? const <CloudUsageSession>[];

  bool isLoadingSessions(String appId) => _loadingApps.contains(appId);

  bool hasMoreSessions(String appId) {
    final String? cursor = _sessionCursors[appId];
    return cursor != null && cursor.isNotEmpty;
  }

  CloudDevice? get selectedDevice {
    final String? id = _deviceId;
    if (id == null) return null;
    for (final CloudDevice d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  CloudUsageQuery get query => CloudUsageQuery(
        date: _date ?? _todayLocal(),
        deviceId: _deviceId,
        timezone: _timezone,
        timezoneOffsetMinutes: _timezoneOffsetMinutes,
        appId: _appId,
      );

  // --- 生命周期 ---

  /// 首次（或重新）打开云端统计：先展示缓存，再后台刷新。
  ///
  /// 幂等：重复调用只会再走一次"缓存 → 刷新"，不会清掉已展示的数据
  /// （只有**账户发生变化**时才会先 `reset()`）。
  Future<void> initialize() async {
    final String? account = _account();
    // 账户变了（退出重登 / 换号）→ 旧数据必须先清掉，绝不能带到新账户。
    if (_loadedAccount != account) {
      _loadedAccount = account;
      reset();
    }

    final DateTime now = _clock();
    _date ??= _todayLocal();
    _timezoneOffsetMinutes = now.timeZoneOffset.inMinutes;
    _timezone = timezoneKeyForOffset(_timezoneOffsetMinutes);

    if (account == null) {
      _status = CloudStatsStatus.error;
      _errorMessage = '登录后即可查看云端统计';
      _notify();
      return;
    }

    // 1) 缓存优先：有缓存就先渲染出来。
    final bool fromCache = await _loadFromCache(account);
    if (fromCache) {
      _status = CloudStatsStatus.offlineCache;
      _isOfflineData = true;
      _notify();
    } else {
      _status = CloudStatsStatus.loading;
      _notify();
    }

    // 2) 后台刷新（失败时保留缓存，不清空界面）。
    await refresh();
  }

  /// 从缓存读取当前查询的数据；返回是否命中。
  Future<bool> _loadFromCache(String account) async {
    final CloudUsageQuery q = query;
    try {
      final List<CloudDevice>? devices = await _cache.readDevices(account);
      if (devices != null) _devices = devices;

      final CloudUsageSummary? summary = await _cache.readSummary(account, q);
      final List<CloudTimelineEntry>? timeline = await _cache.readTimeline(account, q);
      final DateTime? fetchedAt = await _cache.lastFetchedAt(account);
      _fetchedAt = fetchedAt;

      if (summary == null && timeline == null) return false;
      _summary = summary;
      _timeline = timeline ?? const <CloudTimelineEntry>[];
      _applySummaryState();
      return true;
    } catch (e, st) {
      Loggers.sync.warning('读取云端统计缓存失败', e, st);
      return false;
    }
  }

  void _applySummaryState() {
    final CloudUsageSummary? summary = _summary;
    final bool empty = (summary == null || summary.totalDuration.inSeconds == 0) &&
        _timeline.isEmpty;
    _status = empty ? CloudStatsStatus.empty : _status;
  }

  /// 刷新当前查询。
  ///
  /// [manual] 为 true 表示用户**主动**点「刷新」/下拉刷新：
  /// * **强制重新拉取设备列表**（新注册的设备立刻可见，验收第 1 条）；
  /// * **不受"同键在途去重"限制**——上一次请求还没回来时再点一次，仍然会真的
  ///   向服务器发一次新请求（否则按钮看起来"点了没反应"）。
  ///
  /// 无论是否 manual，刷新都会**绕过缓存直接请求服务器**；缓存只用于
  /// [initialize] 的首屏兜底与请求失败时的离线展示。
  Future<void> refresh({bool manual = false}) async {
    if (_disposed) return;

    // 1) 账户变化必须先作废旧数据：换号后不得看到上一个账户的统计（验收第 8 条）。
    final String? account = _account();
    if (_loadedAccount != account) {
      _loadedAccount = account;
      reset();
    }
    if (account == null) {
      _status = CloudStatsStatus.error;
      _errorMessage = '登录后即可查看云端统计';
      _notify();
      return;
    }

    // 2) 每次刷新都按"当前时刻"重算时区与今日 —— 否则跨时区/跨夏令时后会一直用旧偏移。
    final DateTime now = _clock();
    _date ??= _todayLocal();
    _timezoneOffsetMinutes = now.timeZoneOffset.inMinutes;
    _timezone = timezoneKeyForOffset(_timezoneOffsetMinutes);

    final CloudUsageQuery q = query;
    // 代次进键：切设备/切日期后即使旧请求仍在途，也必须为新查询真正发起请求。
    final String base = '$_epoch|${q.baseCacheKey}';
    final String key = manual ? 'manual#${++_manualSeq}|$base' : base;

    // 请求去重：同一代次、同一查询键只允许一个在途请求。
    final Future<void>? running = _inFlight[key];
    if (running != null) return running;

    final Future<void> task = _runRefresh(account: account, query: q, manual: manual);
    _inFlight[key] = task;
    try {
      await task;
    } finally {
      // `remove` 的返回值是"被移除的 Future"，这里只是清理表项，不需要等待它。
      _inFlight.remove(key)?.ignore();
    }
  }

  Future<void> _runRefresh({
    required String account,
    required CloudUsageQuery query,
    bool manual = false,
  }) async {
    final int epoch = _epoch;
    _errorMessage = null;
    if (!hasData) {
      _status = CloudStatsStatus.loading;
    } else {
      _status = CloudStatsStatus.refreshing;
    }
    _notify();

    try {
      // 设备列表与统计**并发**拉取：
      // * 串行拉会白白多一个网络往返（刷新变慢）；
      // * [_refreshDevices] 自己吞掉异常，因此它失败也不会让统计失败。
      final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
        _refreshDevices(account: account, epoch: epoch, force: manual),
        _repository.getSummary(query),
        _repository.getTimeline(query),
      ]);
      if (_isStale(epoch)) return;

      final CloudUsageSummary summary = results[1]! as CloudUsageSummary;
      final List<CloudTimelineEntry> timeline = results[2]! as List<CloudTimelineEntry>;

      _summary = summary;
      _timeline = timeline;
      _isOfflineData = false;
      _fetchedAt = _clock();
      _lastRefreshedAt = _fetchedAt;

      // 成功后覆盖缓存（先读后写，任何失败都不影响已展示的数据）。
      await _cache.saveSummary(
        accountUserId: account,
        query: query,
        summary: summary,
      );
      await _cache.saveTimeline(
        accountUserId: account,
        query: query,
        entries: timeline,
      );

      _status = (summary.totalDuration.inSeconds == 0 && timeline.isEmpty)
          ? CloudStatsStatus.empty
          : CloudStatsStatus.loaded;
    } on CloudStatisticsException catch (e) {
      if (_isStale(epoch)) return;
      _errorMessage = e.message;
      if (e.isNetwork && hasData) {
        // 离线：保留缓存内容并明确标记。
        _status = CloudStatsStatus.offlineCache;
        _isOfflineData = true;
      } else if (e.isNetwork) {
        _status = CloudStatsStatus.error;
      } else {
        // 登录失效 / 服务端错误 / 结构异常：保留已有数据但显示错误，便于重试。
        _status = hasData ? CloudStatsStatus.offlineCache : CloudStatsStatus.error;
        _isOfflineData = hasData;
      }
      Loggers.sync.warning('云端统计刷新失败: ${e.message}');
    } catch (e, st) {
      if (_isStale(epoch)) return;
      Loggers.sync.warning('云端统计刷新异常', e, st);
      _errorMessage = '云端统计刷新失败：$e';
      _status = hasData ? CloudStatsStatus.offlineCache : CloudStatsStatus.error;
      _isOfflineData = hasData;
    } finally {
      _notify();
    }
  }

  /// 拉取设备列表。
  ///
  /// 三条约定：
  /// * **每次刷新都拉**：设备列表此前只在"为空时"拉一次，导致新注册的设备
  ///   直到重启应用才会出现（验收第 1 条要求两端设备列表一致）；
  /// * **失败只记日志**：设备列表拉取失败绝不能拖垮整个统计刷新 —— 沿用上一次的列表；
  /// * **内容没变就不写缓存**：否则每次刷新（含切日期）都会多一次真实写盘，
  ///   既无意义又会拖慢刷新。
  Future<void> _refreshDevices({
    required String account,
    required int epoch,
    required bool force,
  }) async {
    try {
      final List<CloudDevice> devices = await _repository.listDevices();
      if (_isStale(epoch)) return;
      if (devices.isEmpty && !force) return;
      final bool changed = !_sameDevices(_devices, devices);
      _devices = devices;
      if (changed) {
        await _cache.saveDevices(accountUserId: account, devices: devices);
      }
    } catch (e, st) {
      Loggers.sync.warning('刷新设备列表失败（沿用上一次列表）', e, st);
    }
  }

  /// 两份设备列表在"界面能看到的信息"上是否等价。
  static bool _sameDevices(List<CloudDevice> a, List<CloudDevice> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final CloudDevice x = a[i];
      final CloudDevice y = b[i];
      if (x.id != y.id ||
          x.name != y.name ||
          x.platform != y.platform ||
          x.modelName != y.modelName ||
          x.revoked != y.revoked ||
          x.isCurrent != y.isCurrent ||
          x.lastSeenAt != y.lastSeenAt) {
        return false;
      }
    }
    return true;
  }

  bool _isStale(int epoch) {
    if (_disposed) return true;
    return epoch != _epoch;
  }

  // --- 查询条件变化（都会作废旧响应） ---

  Future<void> setDate(DateTime date) async {
    final DateTime normalized = DateTime(date.year, date.month, date.day);
    if (_date != null && _sameDay(_date!, normalized)) return;
    _date = normalized;
    _invalidate();
    await refresh();
  }

  Future<void> shiftDay(int days) async {
    final DateTime base = _date ?? _todayLocal();
    await setDate(base.add(Duration(days: days)));
  }

  Future<void> goToToday() => setDate(_todayLocal());

  Future<void> setDevice(String? deviceId) async {
    if (_deviceId == deviceId) return;
    _deviceId = deviceId;
    _invalidate();
    await refresh();
  }

  Future<void> setAppFilter(String? appId) async {
    if (_appId == appId) return;
    _appId = appId;
    _invalidate();
    await refresh();
  }

  /// 作废旧响应，并**一起清掉已展示的数据**。
  ///
  /// 为什么必须清数据（验收第 6 条「切换设备不会显示前一个设备的缓存」）：
  /// 页面标题取自 `selectedDevice`，而数字取自 `_summary`。若只递增代次而不清数据，
  /// 切换设备的瞬间就会出现"**新设备的标题 + 旧设备的数字**"；若新请求失败，
  /// 还会变成"新设备名 + 旧数字 + 离线横幅"，看起来就像"这台设备有数据"。
  void _invalidate() {
    _epoch += 1;
    _sessionEpoch += 1;
    _sessionsByApp.clear();
    _sessionCursors.clear();
    _loadingApps.clear();
    _summary = null;
    _timeline = const <CloudTimelineEntry>[];
    _fetchedAt = null;
    _errorMessage = null;
    _isOfflineData = false;
  }

  /// 从后台回到前台：距上次刷新超过阈值才刷新。
  Future<void> onAppResumed() async {
    final DateTime? last = _lastRefreshedAt;
    if (last != null && _clock().difference(last) < foregroundRefreshThreshold) {
      return;
    }
    await refresh();
  }

  /// 本机上传成功后触发（需求：本机同步成功后刷新云端统计）。
  Future<void> onLocalSyncSucceeded() => refresh();

  /// 网络恢复后触发。
  Future<void> onNetworkRestored() => refresh();

  // --- 展开应用的时间段（分页） ---

  Future<void> expandApp(String appId) async {
    if (_sessionsByApp.containsKey(appId) && !hasMoreSessions(appId)) return;
    await loadSessions(appId);
  }

  Future<void> loadMoreSessions(String appId) async {
    if (!hasMoreSessions(appId)) return;
    await loadSessions(appId, append: true);
  }

  Future<void> loadSessions(String appId, {bool append = false}) async {
    if (_disposed || _loadingApps.contains(appId)) return;
    final String? account = _account();
    if (account == null) return;

    final int epoch = _sessionEpoch;
    _loadingApps.add(appId);
    _notify();

    final CloudUsageQuery q = query.copyWith(
      appId: appId,
      cursor: append ? _sessionCursors[appId] : null,
      clearCursor: !append,
      limit: 200,
    );

    try {
      final CloudSessionPage page = await _repository.getSessions(q);
      if (_disposed || epoch != _sessionEpoch) return;
      _sessionsByApp[appId] = append
          ? <CloudUsageSession>[...?_sessionsByApp[appId], ...page.items]
          : page.items;
      _sessionCursors[appId] = page.nextCursor;
      if (!append) {
        await _cache.saveSessions(accountUserId: account, query: q, page: page);
      }
    } on CloudStatisticsException catch (e) {
      if (epoch == _sessionEpoch) _errorMessage = e.message;
    } catch (e, st) {
      Loggers.sync.warning('加载云端使用时间段失败', e, st);
    } finally {
      _loadingApps.remove(appId);
      _notify();
    }
  }

  // --- 账户切换 / 退出 ---

  /// 退出账号：清理该账户的云端缓存并重置状态。
  ///
  /// **只清缓存**：本机采集数据、素材库与 outbox 一律不动。
  Future<void> onSignedOut() async {
    final String? account = _account();
    if (account != null) {
      try {
        final int removed = await _cache.clearAccount(account);
        Loggers.sync.info('已清理账户 $account 的云端统计缓存（$removed 条）');
      } catch (e, st) {
        Loggers.sync.warning('清理云端统计缓存失败', e, st);
      }
    }
    reset();
  }

  void reset() {
    _devices = const <CloudDevice>[];
    _summary = null;
    _timeline = const <CloudTimelineEntry>[];
    _sessionsByApp.clear();
    _sessionCursors.clear();
    _loadingApps.clear();
    _errorMessage = null;
    _isOfflineData = false;
    _fetchedAt = null;
    _lastRefreshedAt = null;
    _deviceId = null;
    _appId = null;
    _date = null;
    _invalidate();
    _status = CloudStatsStatus.idle;
    _notify();
  }

  // --- 内部 ---

  DateTime _todayLocal() {
    final DateTime now = _clock();
    return DateTime(now.year, now.month, now.day);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
