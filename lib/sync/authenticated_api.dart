import 'dart:async';

import '../core/constants.dart';
import '../core/logger.dart';
import '../database/dao/account_session_dao.dart';
import 'api_client.dart';
import 'credential_store.dart';
import 'device_identity.dart';
import 'models/api_key_models.dart';
import 'models/sync_models.dart';
import 'proxy/proxy_models.dart';
import 'proxy/proxy_resolver.dart';
import 'sync_preferences.dart';

/// 会话所有者：负责「我是谁 / 令牌放哪 / 过期了怎么换」。
///
/// 这一层是**唯一**接触令牌的地方：
/// * 令牌只存在于内存与 [CredentialStore] 之间；
/// * 落库的只有 [AccountSession]（非敏感信息 + 凭据条目名）；
/// * 日志里只出现用户、设备、状态，绝不出现令牌。
///
/// 401 处理策略（需求「四、API 客户端」）：
/// `ensureAccessToken` 提前刷新 → 收到 401 时**只重试一次** → 仍失败则清令牌并进入
/// `needsReauthentication`。重试深度由方法签名里的 `allowRetry` 在编译期固定，
/// 因此**结构上不可能出现无限刷新循环**。
///
/// 认证失效的**唯一责任边界**
/// -----------------------------
/// 只有这一层可以清令牌、只有这一层可以置 `needsReauthentication`，
/// 并且这两件事都要求「这个错误确实属于**当前**会话」，判据是 [authGeneration]
/// 与令牌标识（见 [_isCurrentSession]）。
///
/// 为什么必须有它：重新登录的那一刻，上一个会话可能还有在途的 push / pull /
/// refresh。它们随后返回 401；如果无条件清理，就会把**刚登录得到的新令牌**删掉，
/// 界面立刻又跳回「需要重新登录」，再点任何操作都报「尚未登录」。
/// 这不是"要忽略 401"，而是要让**旧会话的 401 只能影响旧会话**。
class AuthenticatedApi {
  AuthenticatedApi({
    required CredentialStore credentialStore,
    required AccountSessionDao accountSessionDao,
    required DeviceIdentity deviceIdentity,
    required SyncPreferences preferences,
    ProxyResolver? proxyResolver,
  })  : _credentials = credentialStore,
        _sessionDao = accountSessionDao,
        _deviceIdentity = deviceIdentity,
        _preferences = preferences,
        _proxyResolver = proxyResolver ?? AlwaysDirectProxyResolver();

  final CredentialStore _credentials;
  final AccountSessionDao _sessionDao;
  final DeviceIdentity _deviceIdentity;
  final SyncPreferences _preferences;
  final ProxyResolver _proxyResolver;

  ApiClient? _client;
  String? _clientBaseUrl;

  /// 代理已解析过（避免每次建 client 都读一次系统代理）。
  bool _proxyResolved = false;

  /// 代理凭据（内存副本，绝不落库、绝不写日志）。
  String? _proxyUsername;
  String? _proxyPassword;

  /// 网络客户端重建次数（代理配置变化时必须 +1）。
  ///
  /// 暴露出来的原因：**行为测试证明不了"连接池没有复用"**——
  /// 只要 `findProxy` 读了新决策，旧连接也能走到新代理去。
  /// 因此需要一个显式信号，让测试能断言"旧 HttpClient 确实被关掉重建了"；
  /// 诊断页也用它来确认重配是否生效。
  int get networkGeneration => _networkGeneration;

  int _networkGeneration = 0;

  AccountSession? _session;
  TokenPair? _tokens;

  /// 单飞刷新：多个并发请求同时发现令牌过期时，只发起一次刷新。
  Future<TokenPair?>? _refreshInFlight;

  /// 上面那次刷新登记时的 [authGeneration]。
  ///
  /// 会话换掉之后，旧的那次刷新就不该再被复用、其结果也不该再被采纳。
  int? _refreshInFlightGeneration;

  /// 认证 epoch：每次**开始登录**、**登录成功**、**退出登录**都会 +1。
  ///
  /// 它回答的问题是："这次请求发起时的会话，还是现在这个会话吗？"
  /// 只有答案仍为"是"时，这条请求的认证失败才允许清理令牌。
  int get authGeneration => _authGeneration;

  int _authGeneration = 0;

  /// 是否已被判定为「需要重新登录」。
  bool _needsReauthentication = false;

  /// 刷新提前量：距离过期不足这个时长就提前换新，避免请求正好卡在过期瞬间。
  static const Duration _refreshSkew = Duration(seconds: 60);

  // ---------------------------------------------------------------------------
  // 只读状态
  // ---------------------------------------------------------------------------

  /// 当前是否处于已登录且令牌可用的状态。
  bool get isSignedIn => _session != null && _tokens != null;

  /// 上次登录过的账户信息（即使令牌已失效也会保留，便于 UI 预填与提示）。
  AccountSession? get lastAccount => _session;

  bool get needsReauthentication => _needsReauthentication;

  String get baseUrl => _session?.serverBaseUrl ?? SyncConfig.defaultServerBaseUrl;

  String? get deviceServerId => _session?.deviceServerId;

  String get credentialBackendName => _credentials.backendName;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动时恢复上次会话（读库里的账户信息 + 凭据存储里的令牌）。
  Future<void> load() async {
    await _resolveProxy(force: true);

    _session = await _sessionDao.load();
    final AccountSession? session = _session;
    if (session == null) return;

    final String? raw = await _credentials.read(session.credentialReference);
    _tokens = TokenPair.decode(raw);
    if (_tokens == null) {
      // 有账户信息但没有可用凭据（例如换了 Windows 用户 / 被清理过）
      _needsReauthentication = true;
      Loggers.sync.info('发现账户信息但凭据不可用，需要重新登录');
    } else {
      Loggers.sync.info('已恢复登录状态：${session.email}（后端=${_credentials.backendName}）');
    }
  }

  // ---------------------------------------------------------------------------
  // 代理
  // ---------------------------------------------------------------------------

  /// 解析代理决策并把代理凭据读进内存。
  ///
  /// 从 [CredentialStore] 读密码而不是从 SQLite 读，保证密码永远不落库。
  Future<void> _resolveProxy({bool force = false}) async {
    if (_proxyResolved && !force) return;
    _proxyResolved = true;

    final ProxySettings settings = await _preferences.proxySettings();
    _proxyResolver.updateSettings(settings);
    _proxyUsername = settings.username;

    final String? reference = settings.passwordCredentialReference;
    if (reference == null) {
      _proxyPassword = null;
    } else {
      try {
        _proxyPassword = await _credentials.read(reference);
      } catch (e, st) {
        Loggers.proxy.fine('读取代理密码失败（将按无密码处理）', e, st);
        _proxyPassword = null;
      }
    }

    final ProxyResolution resolution = await _proxyResolver.refresh();
    Loggers.proxy.info(
      '代理决策：${resolution.kind.labelZh}'
      '${resolution.usesProxy ? '（${resolution.authority}）' : ''}'
      '，来源=${resolution.sourceLabel}'
      '${resolution.blockedReason == null ? '' : '，问题=${resolution.blockedReason}'}',
    );
  }

  /// 当前生效的代理决策（UI 展示"当前实际使用"）。
  ProxyResolution get proxyResolution => _proxyResolver.current;

  /// 应用新的代理配置（界面上的「保存并重新连接」）。
  ///
  /// 顺序：写偏好 → 刷新决策 → 关闭旧 HttpClient 并重建。
  /// **不重启应用、不影响本地采集**。
  Future<ProxyResolution> applyProxySettings(ProxySettings settings) async {
    await _preferences.setProxySettings(settings);
    await _resolveProxy(force: true);
    reconfigureNetwork();
    Loggers.proxy.info('代理配置已更新：${settings.describe()}');
    return _proxyResolver.current;
  }

  /// 关闭缓存的 HttpClient，使下一次请求按新配置重建连接池。
  void reconfigureNetwork() {
    _client?.close();
    _client = null;
    _clientBaseUrl = null;
    _networkGeneration += 1;
  }

  /// 登录或注册。
  ///
  /// 顺序严格按需求：登录 → **注册设备** → 保存会话。
  /// 只有设备注册成功后才算完成登录（否则后续同步必被 403）。
  Future<AuthResult> signIn({
    required String baseUrl,
    required String email,
    required String password,
    required bool registerInsteadOfLogin,
    String? modelName,
  }) async {
    // **开始登录**：立刻（同步地）推进 generation，让上一个会话的所有在途请求失效。
    // 放在任何 await 之前，因此不存在"登录已经开始了、旧请求却仍被当作当前会话"的窗口。
    _advanceAuthGeneration();

    final String normalized = _normalizeBaseUrl(baseUrl);
    await _preferences.setServerBaseUrl(normalized);

    final DeviceRegistration registration = await buildDeviceRegistration(modelName: modelName);
    final ApiClient client = await _clientFor(normalized);
    final AuthResult auth = registerInsteadOfLogin
        ? await client.register(
            email: email,
            password: password,
            displayName: _displayNameFromEmail(email),
            device: registration,
          )
        : await client.login(email: email, password: password, device: registration);

    // 显式绑定设备：登录信封里已带上设备信息（服务端会顺带绑定），
    // 这里再调一次 register 是**幂等**的，同时能把 device_name / model_name 更新到最新，
    // 并确保我们拿到权威的 device_id。
    final RemoteDevice device = await client.registerDevice(
      accessToken: auth.tokens.accessToken,
      device: registration,
    );

    final AccountSession session = AccountSession(
      serverBaseUrl: normalized,
      userId: auth.user.id,
      email: auth.user.email,
      displayName: auth.user.displayName,
      deviceServerId: device.id,
      credentialReference: _credentialReference,
      accessTokenExpiresAt: auth.tokens.accessTokenExpiresAt,
      updatedAt: DateTime.now(),
    );
    _session = session;
    _tokens = auth.tokens;
    _needsReauthentication = false;

    // **登录成功**：再次推进 generation。
    // 覆盖"登录过程中发起、用的还是旧令牌"的那些请求——它们已经不是当前会话了。
    _advanceAuthGeneration();

    await _credentials.write(_credentialReference, auth.tokens.encode());
    await _sessionDao.save(session);

    Loggers.sync.info(
      '${registerInsteadOfLogin ? '注册' : '登录'}成功：${auth.user.email}'
      '（设备=${device.deviceName}，凭据后端=${_credentials.backendName}）',
    );
    return AuthResult(tokens: auth.tokens, user: auth.user, deviceId: device.id);
  }

  /// 退出登录。
  ///
  /// * 尽力通知服务端注销当前会话（失败也继续）；
  /// * **删除本地令牌**；
  /// * 清掉账户信息；
  /// * **保留**本地使用记录、素材与未同步队列（需求明确要求）。
  Future<void> signOut() async {
    // 退出同样推进 generation：在途请求的 401 不得再影响任何会话状态。
    _advanceAuthGeneration();

    final TokenPair? tokens = _tokens;
    final String? deviceId = _session?.deviceServerId;
    try {
      if (tokens != null) {
        await _client?.logout(refreshToken: tokens.refreshToken, deviceId: deviceId);
      }
    } catch (e, st) {
      // 服务端不可达也要允许本地退出
      Loggers.sync.fine('通知服务端注销失败（本地仍会清理令牌）', e, st);
    }

    await _clearTokens();
    await _sessionDao.clear();
    _session = null;
    _client?.close();
    _client = null;
    _clientBaseUrl = null;
    Loggers.sync.info('已退出登录：本地令牌与账户信息已清除，使用记录与素材保留');
  }

  // ---------------------------------------------------------------------------
  // 认证请求封装
  // ---------------------------------------------------------------------------

  /// 确保拿到一个可用的 Access Token（必要时刷新）。
  Future<String> ensureAccessToken({bool allowRefresh = true}) async {
    final int generation = _authGeneration;
    final TokenPair? tokens = _tokens;
    if (tokens == null) {
      throw const ApiException(
        kind: SyncFailureKind.refreshFailed,
        message: '尚未登录',
      );
    }
    final DateTime? expiresAt = tokens.accessTokenExpiresAt;
    final bool expiringSoon = expiresAt != null &&
        DateTime.now().add(_refreshSkew).isAfter(expiresAt);
    if (!expiringSoon) return tokens.accessToken;

    final TokenPair? refreshed = await _refresh(allowRefresh: allowRefresh);
    if (generation != _authGeneration) {
      // 刷新期间会话被替换（重新登录 / 退出登录）：一律**以新会话为准**，
      // 不能用旧刷新的结论去推翻它。
      final TokenPair? current = _tokens;
      if (current != null) return current.accessToken;
      throw const ApiException(
        kind: SyncFailureKind.refreshFailed,
        message: '尚未登录',
      );
    }
    if (refreshed == null) {
      throw const ApiException(
        kind: SyncFailureKind.refreshFailed,
        message: '登录凭据已失效，请重新登录',
      );
    }
    return refreshed.accessToken;
  }

  /// 带认证地执行一次请求；401 时刷新并**只重试一次**。
  ///
  /// 认证失败的处理带**会话校验**：只有"发起这次请求的会话仍是当前会话"时，
  /// 才允许刷新、才允许清理令牌（见 [_isCurrentSession]）。
  Future<T> send<T>(
    Future<T> Function(String accessToken, String deviceId) action, {
    bool allowRetry = true,
  }) async {
    final int generation = _authGeneration;
    final String deviceId = await ensureDeviceId();
    final String token = await ensureAccessToken();
    try {
      return await action(token, deviceId);
    } on ApiException catch (e) {
      if (e.kind == SyncFailureKind.unauthorized) {
        if (!allowRetry) {
          // 已经重试过一次仍然 401：只有确认该请求属于当前会话才清理令牌。
          await _enterNeedsReauthenticationIfCurrent(generation, token, e.message);
          rethrow;
        }
        if (generation != _authGeneration) {
          // 这是**上一个会话**遗留的在途请求：不刷新、更不清令牌。
          // 原样交回调用方；新会话的状态不受任何影响。
          Loggers.sync.info('忽略不属于当前会话的 401（不刷新、不清理令牌）');
          rethrow;
        }
        // 令牌过期：刷新后重试一次（allowRetry 已置 false，不可能再进这个分支）
        final TokenPair? refreshed = await _refresh(allowRefresh: true);
        if (refreshed == null) {
          await _enterNeedsReauthenticationIfCurrent(generation, token, e.message);
          rethrow;
        }
        return send(
          action,
          allowRetry: false,
        );
      }
      if (e.kind.needsReauth) {
        // 设备被撤销 / 404 这类"当前会话确定不可用"的错误同样要过会话校验
        await _enterNeedsReauthenticationIfCurrent(generation, token, e.message);
      }
      rethrow;
    }
  }

  /// 确保有服务端设备 ID（缺设备 ID 时补一次注册）。
  Future<String> ensureDeviceId() async {
    final String? existing = _session?.deviceServerId;
    if (existing != null && existing.isNotEmpty) return existing;

    final AccountSession? session = _session;
    final TokenPair? tokens = _tokens;
    if (session == null || tokens == null) {
      throw const ApiException(
        kind: SyncFailureKind.refreshFailed,
        message: '尚未登录',
      );
    }
    final ApiClient client = await _clientFor(session.serverBaseUrl);
    final RemoteDevice device = await client.registerDevice(
      accessToken: tokens.accessToken,
      device: await buildDeviceRegistration(),
    );
    await _sessionDao.update(deviceServerId: device.id);
    _session = session.copyWith(deviceServerId: device.id, updatedAt: DateTime.now());
    Loggers.sync.info('已补齐设备绑定：${device.id}');
    return device.id;
  }

  // ---------------------------------------------------------------------------
  // 业务封装（UI / 引擎都用这些，不直接碰 ApiClient）
  // ---------------------------------------------------------------------------

  Future<List<RemoteDevice>> listDevices() =>
      send((String token, String deviceId) async =>
          (await _clientFor(baseUrl)).listDevices(
            accessToken: token,
            deviceId: deviceId,
          ));

  Future<RemoteDevice> updateDevice({
    required String deviceId,
    String? deviceName,
    String? modelName,
  }) =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).updateDevice(
            accessToken: token,
            deviceId: deviceId,
            deviceName: deviceName,
            modelName: modelName,
          ));

  Future<RemoteDevice> revokeDevice(String deviceId) =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).revokeDevice(
            accessToken: token,
            deviceId: deviceId,
          ));

  // --- AI 数据访问密钥（Phase 3）---
  //
  // 全部走 [send]，因此自动获得：Access Token 自动刷新（401 重试一次）、
  // 当前代理配置、以及统一的 [ApiException] 分级。
  // 明文密钥不会写进日志；撤销后服务端立即拒绝该密钥。

  /// 生成一把只读统计密钥。明文只在返回值里出现一次，**不落库**。
  Future<ApiKeyCreated> createApiKey(String name) =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).createApiKey(accessToken: token, name: name));

  Future<List<ApiKeySummary>> listApiKeys() =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).listApiKeys(accessToken: token));

  Future<ApiKeySummary> revokeApiKey(String keyId) =>
      send((String token, String _) async => (await _clientFor(baseUrl))
          .revokeApiKey(accessToken: token, keyId: keyId));

  Future<RemoteUser> updateDisplayName(String displayName) =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).updateMe(
            accessToken: token,
            displayName: displayName,
          ));

  Future<Map<String, Object?>> stats({
    required String endpoint,
    String period = 'today',
  }) =>
      send((String token, String _) async =>
          (await _clientFor(baseUrl)).stats(
            accessToken: token,
            endpoint: endpoint,
            period: period,
          ));

  /// Phase 4B：云端统计的只读 GET。
  ///
  /// **复用 [send]**，因此自动获得：设备 ID 注入、访问令牌注入、
  /// 401 → 刷新令牌 → **只重试一次**、代理与超时策略。
  /// 云端统计因此不需要任何第二套鉴权逻辑。
  Future<Map<String, Object?>> cloudStatisticsJson(
    String path,
    Map<String, String> query,
  ) =>
      send((String token, String deviceId) async =>
          (await _clientFor(baseUrl)).getJson(
            path: path,
            accessToken: token,
            deviceId: deviceId,
            query: query,
          ));

  /// 批量上传（供引擎使用；token 由 [send] 注入并负责 401 重试一次）。
  Future<PushOutcome> push({
    required String accessToken,
    required String deviceId,
    required Map<SyncEntityType, List<Map<String, Object?>>> records,
    String? batchId,
  }) async =>
      (await _clientFor(baseUrl)).push(
        accessToken: accessToken,
        deviceId: deviceId,
        records: records,
        batchId: batchId,
      );

  /// 增量拉取（供引擎使用）。
  Future<PullOutcome> pullRaw({
    required String accessToken,
    required String deviceId,
    required int cursor,
    int? limit,
  }) async =>
      (await _clientFor(baseUrl)).pull(
        accessToken: accessToken,
        deviceId: deviceId,
        cursor: cursor,
        limit: limit,
      );

  /// 构建当前设备的注册信息（供登录与引擎复用）。
  Future<DeviceRegistration> buildDeviceRegistration({String? modelName}) async {
    final String localId = await _deviceIdentity.ensureDeviceLocalId();
    return DeviceRegistration(
      deviceLocalId: localId,
      deviceName: DeviceIdentity.defaultDeviceName(),
      platform: DeviceIdentity.platform(),
      architecture: DeviceIdentity.architecture(),
      osVersion: DeviceIdentity.osVersion(),
      appVersion: DeviceIdentity.appVersion(),
      // Android 上报机型；Windows 上一般为 null（与阶段 2 行为一致）。
      modelName: modelName ?? DeviceIdentity.modelName(),
    );
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  String get _credentialReference =>
      '${SyncConfig.credentialTargetPrefix}${SyncConfig.credentialAccountKey}';

  static String _normalizeBaseUrl(String raw) {
    String value = raw.trim();
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }

  static String _displayNameFromEmail(String email) {
    final int at = email.indexOf('@');
    final String name = at > 0 ? email.substring(0, at) : email;
    return name.isEmpty ? 'PetLife 用户' : name;
  }

  /// 取（必要时创建）指向 [baseUrl] 的客户端。
  ///
  /// 代理配置是**全局唯一**的：这里创建的所有客户端都挂同一个
  /// [ProxyResolver]，因此 health / 登录 / 刷新 / 设备 / push / pull / 统计
  /// 全部走同一套代理设置。
  Future<ApiClient> _clientFor(String baseUrl) async {
    await _resolveProxy();
    final String normalized = _normalizeBaseUrl(baseUrl);
    final ApiClient? existing = _client;
    if (existing != null && _clientBaseUrl == normalized) return existing;

    // 地址或代理配置变了：关掉旧的（含连接池）再建新的。
    existing?.close();
    final ApiClient created = ApiClient(
      baseUrl: normalized,
      proxyResolver: _proxyResolver,
      proxyUsername: _proxyUsername,
      proxyPassword: _proxyPassword,
    );
    _client = created;
    _clientBaseUrl = normalized;
    return created;
  }

  /// 单飞刷新。返回 null 表示刷新失败（或结果已因会话更换而作废）。
  ///
  /// 单飞只在**同一个 generation** 内生效：会话换掉之后，旧的那次刷新
  /// 既不该被复用，其结果也不该被采纳。
  Future<TokenPair?> _refresh({required bool allowRefresh}) {
    if (!allowRefresh) return Future<TokenPair?>.value(null);
    final int generation = _authGeneration;
    final Future<TokenPair?>? inFlight = _refreshInFlight;
    if (inFlight != null && _refreshInFlightGeneration == generation) {
      return inFlight;
    }

    final Future<TokenPair?> future = _doRefresh();
    _refreshInFlight = future;
    _refreshInFlightGeneration = generation;
    return future.whenComplete(() {
      // 只有"登记的还是自己"时才清空，否则会把后来者的登记抹掉
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
        _refreshInFlightGeneration = null;
      }
    });
  }

  Future<TokenPair?> _doRefresh() async {
    final int generation = _authGeneration;
    final TokenPair? tokens = _tokens;
    final AccountSession? session = _session;
    if (tokens == null || session == null) return null;
    final String refreshToken = tokens.refreshToken;

    try {
      final AuthResult result = await (await _clientFor(session.serverBaseUrl)).refresh(
        refreshToken,
        deviceLocalId: await _deviceIdentity.ensureDeviceLocalId(),
      );
      if (!_isCurrentSession(generation, refreshToken)) {
        // 刷新期间会话已被替换：**不得**用旧结果覆盖新登录得到的令牌
        Loggers.sync.info('刷新结果属于已被替换的会话，已丢弃（不覆盖当前令牌）');
        return null;
      }
      _tokens = result.tokens;
      _needsReauthentication = false;
      await _credentials.write(_credentialReference, result.tokens.encode());
      await _sessionDao.update(
        accessTokenExpiresAt: result.tokens.accessTokenExpiresAt,
        updatedAt: DateTime.now(),
      );
      _session = _session?.copyWith(
        accessTokenExpiresAt: result.tokens.accessTokenExpiresAt,
        updatedAt: DateTime.now(),
      );
      Loggers.sync.fine('Access Token 已刷新（Refresh Token 已轮换）');
      return result.tokens;
    } on ApiException catch (e) {
      if (!_isCurrentSession(generation, refreshToken)) {
        // 旧 Refresh 请求失败：**不得**把新登录的会话标记为失效
        Loggers.sync.info('刷新失败属于已被替换的会话，已忽略：${e.message}');
        return null;
      }
      if (e.kind.needsReauth || e.kind == SyncFailureKind.unauthorized) {
        await _enterNeedsReauthentication(e.message);
      } else {
        Loggers.sync.fine('刷新令牌失败（可重试）：${e.message}');
      }
      return null;
    } catch (e, st) {
      Loggers.sync.fine('刷新令牌异常', e, st);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 会话校验
  // ---------------------------------------------------------------------------

  /// 推进认证 epoch（开始登录 / 登录成功 / 退出登录）。
  void _advanceAuthGeneration() {
    _authGeneration += 1;
  }

  /// 这次请求是否仍属于**当前会话**。
  ///
  /// 两个条件必须同时成立：
  /// * generation 未变 —— 没有发生重新登录 / 退出登录；
  /// * 当前令牌仍是该请求使用的那一个 —— 没有被刷新或整体替换。
  ///
  /// 任一条件不成立，就说明"这个 401 讲的是另一个会话的事"，
  /// 此时**绝不允许**清理令牌（否则会删掉后来登录得到的新令牌）。
  bool _isCurrentSession(int generation, String token) {
    if (_authGeneration != generation) return false;
    final TokenPair? current = _tokens;
    if (current == null) return false;
    return current.accessToken == token || current.refreshToken == token;
  }

  /// 只有"错误确实属于当前会话"时才进入需要重新登录。
  Future<void> _enterNeedsReauthenticationIfCurrent(
    int generation,
    String token,
    String reason,
  ) async {
    if (!_isCurrentSession(generation, token)) {
      Loggers.sync.info('认证失败发生在已被替换的会话上，不清理当前令牌：$reason');
      return;
    }
    await _enterNeedsReauthentication(reason);
  }

  /// 进入「需要重新登录」：清理令牌，但保留账户信息供 UI 提示。
  ///
  /// ⚠️ 这是**唯一**清理令牌的地方；调用方必须先通过 [_isCurrentSession] 校验。
  Future<void> _enterNeedsReauthentication(String reason) async {
    if (_needsReauthentication && _tokens == null) return;
    _needsReauthentication = true;
    await _clearTokens();
    Loggers.sync.warning('需要重新登录：$reason');
  }

  /// 删除凭据存储里的令牌（本地采集与素材完全不受影响）。
  Future<void> _clearTokens() async {
    _tokens = null;
    try {
      await _credentials.delete(_credentialReference);
    } catch (e, st) {
      Loggers.credential.warning('删除凭据失败', e, st);
    }
  }

  /// 释放网络资源。
  void dispose() {
    _client?.close();
    _client = null;
    _clientBaseUrl = null;
  }
}
