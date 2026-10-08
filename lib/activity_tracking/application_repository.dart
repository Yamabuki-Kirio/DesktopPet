import '../core/logger.dart';
import '../database/dao/application_dao.dart';
import 'app_keys.dart';
import 'application_classifier.dart';
import 'local_change_sink.dart';
import 'models/activity_enums.dart';
import 'models/activity_sample.dart';

/// 应用库：`applications` 表的内存视图 + 分类裁决。
///
/// 为什么全部载入内存：应用数量级只有几十到几百条，
/// 而采样每 2 秒就要判断一次「这个应用分类是什么、是否被排除」。
/// 全表查询会造成持续的无谓 IO（需求「十七、性能要求」明确禁止），
/// 因此启动时载入一次，之后只操作内存 + 定期回写。
class ApplicationRepository {
  ApplicationRepository({
    required ApplicationDao dao,
    ApplicationClassifier classifier = const ApplicationClassifier(),
    LocalChangeSink changeSink = const NoopLocalChangeSink(),
  })  : _dao = dao,
        _classifier = classifier,
        _changeSink = changeSink;

  final ApplicationDao _dao;
  final ApplicationClassifier _classifier;

  /// Phase 2：应用记录变更 → 待同步队列。
  final LocalChangeSink _changeSink;

  final Map<String, TrackedApplication> _byKey = <String, TrackedApplication>{};

  /// 待回写 `last_seen_at` 的应用键（避免每次采样都写库）。
  final Set<String> _pendingLastSeen = <String>{};

  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<TrackedApplication> get all {
    final List<TrackedApplication> list = _byKey.values.toList()
      ..sort((TrackedApplication a, TrackedApplication b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return list;
  }

  TrackedApplication? find(String appKey) => _byKey[appKey];

  bool isExcluded(String appKey) =>
      _byKey[appKey]?.excluded ?? isBuiltInExcluded(appKey);

  /// 从数据库载入全部应用（启动时调用一次）。
  Future<void> load() async {
    final List<TrackedApplication> rows = await _dao.listAll();
    _byKey
      ..clear()
      ..addEntries(rows.map(
        (TrackedApplication a) => MapEntry<String, TrackedApplication>(a.appKey, a),
      ));
    _pendingLastSeen.clear();
    _loaded = true;
    Loggers.activity.info('应用库已载入：${_byKey.length} 个应用'
        '（其中排除 ${_byKey.values.where((TrackedApplication a) => a.excluded).length} 个）');
  }

  /// 记录「看到了这个应用」。
  ///
  /// 首次见到才会写库（插入一行）；之后只在内存更新 `lastSeenAt`，
  /// 由 [flush] 统一回写，采样路径上没有写操作。
  Future<TrackedApplication> ensureSeen({
    required String appKey,
    String? processName,
    String? executablePath,
    required DateTime at,
  }) async {
    final TrackedApplication? existing = _byKey[appKey];
    if (existing != null) {
      // 补齐之前没拿到的路径 / 进程名（例如第一次因权限不足只拿到进程名）。
      final String? betterPath =
          (existing.executablePath == null || existing.executablePath!.isEmpty) &&
                  executablePath != null &&
                  executablePath.isNotEmpty
              ? executablePath
              : null;
      if (betterPath != null) {
        final TrackedApplication updated = existing.copyWith(
          executablePath: betterPath,
          lastSeenAt: at,
        );
        _byKey[appKey] = updated;
        _pendingLastSeen.add(appKey);
        await _dao.upsert(updated);
        await _notifyApp(appKey);
        return updated;
      }
      _byKey[appKey] = existing.copyWith(lastSeenAt: at);
      _pendingLastSeen.add(appKey);
      return existing;
    }

    // 新应用：记录分类（人工设定优先，此时必然没有人工设定）。
    final ClassificationResult result = _classifier.classify(
      appKey: appKey,
      executablePath: executablePath,
    );
    final String displayName = executablePath != null && executablePath.isNotEmpty
        ? displayNameFromExecutable(executablePath)
        : (processName != null && processName.isNotEmpty
            ? displayNameFromExecutable(processName)
            : appKey);

    final TrackedApplication created = TrackedApplication(
      appKey: appKey,
      displayName: displayName,
      processName: processName,
      executablePath: executablePath,
      category: result.category,
      userOverridden: false,
      excluded: isBuiltInExcluded(appKey),
      firstSeenAt: at,
      lastSeenAt: at,
    );
    _byKey[appKey] = created;
    await _dao.upsert(created);
    Loggers.activity.info(
      '发现新应用 ${created.displayName}（app_key=$appKey，分类=${result.category.wireName}'
      '，来源=${result.source.labelZh}）',
    );
    await _notifyApp(appKey);
    return created;
  }

  /// 登记来自**原生层**的应用（Android 使用会话导入路径，Phase 4C-5.1B）。
  ///
  /// 与 [ensureSeen] 的区别：显示名与分类**由原生直接给出**
  /// （Android 用应用标签 + 原生分类规则），不走 Windows 的可执行文件名分类器。
  ///
  /// 优先级不变式：**用户手工改过的分类 / 显示名永远优先**，原生数据不得覆盖它 ——
  /// 否则用户在统计页改过的分类会被下一次导入悄悄改回去。
  ///
  /// 返回是否发生了需要写库的变化（false = 只是更新了 last_seen）。
  Future<bool> ensureSeenFromPlatform({
    required String appKey,
    String? displayName,
    AppCategory? category,
    required DateTime at,
  }) async {
    final TrackedApplication? existing = _byKey[appKey];
    final String resolvedName = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName.trim()
        : (existing?.displayName ?? appKey);
    final AppCategory resolvedCategory = category ?? existing?.category ?? AppCategory.other;

    if (existing != null) {
      _pendingLastSeen.add(appKey);
      final bool nameChanged = !existing.userOverridden && existing.displayName != resolvedName;
      final bool categoryChanged = !existing.userOverridden && existing.category != resolvedCategory;
      if (!nameChanged && !categoryChanged) {
        _byKey[appKey] = existing.copyWith(lastSeenAt: at);
        return false;
      }
      final TrackedApplication updated = existing.copyWith(
        displayName: resolvedName,
        category: resolvedCategory,
        lastSeenAt: at,
      );
      _byKey[appKey] = updated;
      await _dao.upsert(updated);
      await _notifyApp(appKey);
      return true;
    }

    final TrackedApplication created = TrackedApplication(
      appKey: appKey,
      displayName: resolvedName,
      processName: null,
      executablePath: null,
      category: resolvedCategory,
      userOverridden: false,
      excluded: isBuiltInExcluded(appKey),
      firstSeenAt: at,
      lastSeenAt: at,
    );
    _byKey[appKey] = created;
    await _dao.upsert(created);
    Loggers.activity.info(
      '登记原生使用记录中的新应用 ${created.displayName}（app_key=$appKey，'
      '分类=${created.category.wireName}）',
    );
    await _notifyApp(appKey);
    return true;
  }

  /// 回写 `last_seen_at`（在每个检查点周期调用，不是每次采样）。
  Future<void> flush() async {
    if (_pendingLastSeen.isEmpty) return;
    final Set<String> keys = Set<String>.from(_pendingLastSeen);
    _pendingLastSeen.clear();
    final DateTime now = DateTime.now();
    for (final String key in keys) {
      try {
        await _dao.touchLastSeen(key, now);
      } catch (e, st) {
        // 回写失败不影响采集；下次检查点会重试。
        Loggers.activity.fine('回写 last_seen_at 失败: $key', e, st);
      }
    }
  }

  /// 用户修改分类（人工设定，永久优先于内置规则）。
  Future<void> setCategory(String appKey, AppCategory category) async {
    final TrackedApplication? existing = _byKey[appKey];
    if (existing == null) return;
    await _dao.updateUserSettings(appKey, category: category);
    _byKey[appKey] = existing.copyWith(category: category, userOverridden: true);
    Loggers.activity.info('应用 $appKey 分类被用户改为 ${category.wireName}');
    await _notifyApp(appKey);
  }

  /// 用户修改显示名。
  Future<void> setDisplayName(String appKey, String displayName) async {
    final TrackedApplication? existing = _byKey[appKey];
    if (existing == null || displayName.trim().isEmpty) return;
    final String name = displayName.trim();
    await _dao.updateUserSettings(appKey, displayName: name);
    _byKey[appKey] = existing.copyWith(displayName: name);
    await _notifyApp(appKey);
  }

  /// 排除 / 恢复记录。
  Future<void> setExcluded(String appKey, bool excluded) async {
    final TrackedApplication? existing = _byKey[appKey];
    if (existing == null) return;
    await _dao.updateUserSettings(appKey, excluded: excluded);
    _byKey[appKey] = existing.copyWith(excluded: excluded);
    Loggers.activity.info('应用 $appKey ${excluded ? '已排除' : '已恢复'}记录');
    // 注意：excluded 是本机隐私偏好，**不上传**给服务端；
    // 但显示名/分类仍可能需要上传，这里统一声明一次变更。
    await _notifyApp(appKey);
  }

  /// 声明应用记录变更（写 outbox）。
  ///
  /// 失败只记日志：入队异常绝不能影响采集。
  Future<void> _notifyApp(String appKey) async {
    try {
      await _changeSink.onApplicationChanged(appKey);
    } catch (e, st) {
      Loggers.sync.fine('应用记录入队失败（不影响采集）: $appKey', e, st);
    }
  }
}
