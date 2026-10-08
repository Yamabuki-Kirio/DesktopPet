import '../../core/constants.dart';

/// 代理支持（Phase 2 补充）的领域模型与纯函数解析。
///
/// 设计原则
/// --------
/// * **不修改服务端协议**：代理只影响本地 `HttpClient` 怎么建连；
/// * **不绕过 TLS 校验**：绝不设置 `badCertificateCallback`；
/// * **密码不落 SQLite**：只保存一个 [ProxySettings.passwordCredentialReference]，
///   真正的密码放在 `CredentialStore` 里；
/// * **PAC/WPAD 明确不支持**：检测到 PAC 时给出明确提示，而不是静默误判成直连。
/// 连接方式。
enum ProxyMode {
  /// 自动检测系统代理；检测不到就直连。
  automatic('automatic', '自动检测（推荐）'),

  /// 强制使用 Windows 系统代理；检测不到就**报错**而不是偷偷直连。
  system('system', '跟随 Windows 系统代理'),

  /// 手动指定 HTTP/HTTPS CONNECT 代理。
  manualHttp('manual_http', '手动 HTTP 代理'),

  /// 强制直连（忽略任何系统代理设置）。
  direct('direct', '直接连接');

  const ProxyMode(this.wireName, this.labelZh);

  /// 持久化用的稳定字符串（**不要**依赖 `index`，否则重排枚举会读错旧配置）。
  final String wireName;

  final String labelZh;

  static ProxyMode fromWire(String? value) {
    for (final ProxyMode m in ProxyMode.values) {
      if (m.wireName == value) return m;
    }
    return ProxyMode.automatic;
  }
}

/// 代理配置（普通字段，可安全落 SQLite）。
///
/// ⚠️ 这里**没有** `password` 字段：
/// 密码只以 [passwordCredentialReference]（凭据条目名）的形式出现。
class ProxySettings {
  const ProxySettings({
    this.mode = ProxyMode.automatic,
    this.host = SyncConfig.defaultProxyHost,
    this.port = SyncConfig.defaultProxyPort,
    this.username,
    this.passwordCredentialReference,
    this.bypassLocalhost = true,
  });

  /// 默认：自动检测 + 预填 Clash 常见端口（仅在手动脉式下使用）。
  static const ProxySettings defaults = ProxySettings();

  final ProxyMode mode;

  /// 手动代理主机（默认 `127.0.0.1`）。
  final String host;

  /// 手动代理端口（Clash Mixed Port 默认示例 `7877`）。
  final int port;

  /// 可选用户名；为空表示代理不需要认证。
  final String? username;

  /// 密码在 `CredentialStore` 里的条目名；为 null 表示没有保存密码。
  ///
  /// 注意这是一个**引用**，不是密码本身。
  final String? passwordCredentialReference;

  /// 是否绕过本地地址（`<local>` 语义：回环 + 无点主机名）。
  final bool bypassLocalhost;

  bool get hasUsername => username != null && username!.trim().isNotEmpty;

  bool get hasSavedPassword =>
      passwordCredentialReference != null &&
      passwordCredentialReference!.trim().isNotEmpty;

  ProxySettings copyWith({
    ProxyMode? mode,
    String? host,
    int? port,
    String? username,
    bool clearUsername = false,
    String? passwordCredentialReference,
    bool clearPasswordReference = false,
    bool? bypassLocalhost,
  }) => ProxySettings(
    mode: mode ?? this.mode,
    host: host ?? this.host,
    port: port ?? this.port,
    username: clearUsername ? null : (username ?? this.username),
    passwordCredentialReference: clearPasswordReference
        ? null
        : (passwordCredentialReference ?? this.passwordCredentialReference),
    bypassLocalhost: bypassLocalhost ?? this.bypassLocalhost,
  );

  /// 人类可读描述（**绝不包含密码**）。
  String describe() => switch (mode) {
    ProxyMode.direct => '直接连接',
    ProxyMode.manualHttp =>
      '手动 HTTP 代理 $host:$port'
          '${hasUsername ? '（用户 ${username!.trim()}）' : ''}',
    ProxyMode.system => '跟随 Windows 系统代理',
    ProxyMode.automatic => '自动检测系统代理',
  };

  /// SQLite 存储形式（全部字符串，见 `04-桌宠窗口与配置持久化.md` 的 key-value 约定）。
  ///
  /// 键名带 `sync.proxy` 前缀，避免与其它模块撞车。
  Map<String, String> toStorageMap() => <String, String>{
    'sync.proxyMode': mode.wireName,
    'sync.proxyHost': host,
    'sync.proxyPort': '$port',
    if (hasUsername) 'sync.proxyUsername': username!.trim(),
    if (hasSavedPassword)
      'sync.proxyPasswordReference': passwordCredentialReference!.trim(),
    'sync.proxyBypassLocalhost': bypassLocalhost ? '1' : '0',
  };

  static ProxySettings fromStorageMap(Map<String, String> map) {
    final String? host = _nonEmpty(map['sync.proxyHost']);
    final int? port = int.tryParse(map['sync.proxyPort'] ?? '');
    return ProxySettings(
      mode: ProxyMode.fromWire(map['sync.proxyMode']),
      host: host ?? SyncConfig.defaultProxyHost,
      port: (port != null && port > 0 && port <= 65535)
          ? port
          : SyncConfig.defaultProxyPort,
      username: _nonEmpty(map['sync.proxyUsername']),
      passwordCredentialReference: _nonEmpty(
        map['sync.proxyPasswordReference'],
      ),
      bypassLocalhost: (map['sync.proxyBypassLocalhost'] ?? '1') != '0',
    );
  }

  static String? _nonEmpty(String? v) {
    final String? t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  @override
  String toString() =>
      'ProxySettings(${mode.wireName}, $host:$port, user=${hasUsername ? 'yes' : 'no'}, '
      'pwdRef=${hasSavedPassword ? 'yes' : 'no'}, bypassLocalhost=$bypassLocalhost)';
}

/// 一条 `ProxyServer` 条目，例如 `http=127.0.0.1:7877`。
class ProxyServerEntry {
  const ProxyServerEntry({
    required this.scheme,
    required this.host,
    required this.port,
  });

  /// `http` / `https` / `socks` / `socks5`。
  final String scheme;

  final String host;
  final int port;

  bool get isSocks => scheme.startsWith('socks');

  bool get isHttpLike => scheme == 'http' || scheme == 'https';

  String get authority => '$host:$port';

  @override
  String toString() => '$scheme=$authority';
}

/// `ProxyServer` 字符串的解析结果。
class ProxyServerParse {
  const ProxyServerParse({required this.entries, this.note});

  final List<ProxyServerEntry> entries;

  /// 给用户看的说明（例如"SOCKS 端口不能直接当 HTTP 代理用"）。
  final String? note;

  bool get isEmpty => entries.isEmpty;

  /// 取一个可用于 HTTP/HTTPS CONNECT 的条目：优先 `http`，其次 `https`。
  ProxyServerEntry? get preferredHttp {
    for (final ProxyServerEntry e in entries) {
      if (e.scheme == 'http') return e;
    }
    for (final ProxyServerEntry e in entries) {
      if (e.scheme == 'https') return e;
    }
    return null;
  }

  bool get hasSocksOnly =>
      entries.isNotEmpty && entries.every((ProxyServerEntry e) => e.isSocks);

  /// 解析 Windows `ProxyServer` 值。
  ///
  /// 支持两种真实存在的形式：
  /// * 单条目：`127.0.0.1:7877`
  /// * 分协议：`http=127.0.0.1:7877;https=127.0.0.1:7877`
  ///
  /// 也容忍用户在界面里输入 `http://127.0.0.1:7877` 这种带 scheme 的写法。
  /// SOCKS 条目会被解析出来但**不会**被选用（会通过 [note] 说明原因）。
  static ProxyServerParse parseProxyServer(String? raw) {
    final String? text = raw?.trim();
    if (text == null || text.isEmpty) {
      return const ProxyServerParse(entries: <ProxyServerEntry>[]);
    }

    final List<ProxyServerEntry> entries = <ProxyServerEntry>[];
    for (final String chunk in text.split(RegExp(r'[;,]'))) {
      final String item = chunk.trim();
      if (item.isEmpty) continue;

      String scheme = 'http';
      String authority = item;

      final int eq = item.indexOf('=');
      if (eq > 0) {
        scheme = item.substring(0, eq).trim().toLowerCase();
        authority = item.substring(eq + 1).trim();
      } else if (item.contains('://')) {
        // 形如 http://127.0.0.1:7877（部分工具会这样写）
        final int sep = item.indexOf('://');
        scheme = item.substring(0, sep).trim().toLowerCase();
        authority = item.substring(sep + 3).trim();
      }

      // 去掉可能存在的路径（Clash 的 ProxyServer 不带路径，但防御一下）
      final int slash = authority.indexOf('/');
      if (slash >= 0) authority = authority.substring(0, slash);

      final ProxyServerEntry? entry = _parseAuthority(scheme, authority);
      if (entry != null) entries.add(entry);
    }

    String? note;
    if (entries.isNotEmpty &&
        entries.every((ProxyServerEntry e) => e.isSocks)) {
      note =
          '系统代理只配置了 SOCKS 端口，不能直接当 HTTP 代理使用；'
          '请在 Clash 中改用 Mixed Port（或手动填写 HTTP 端口）。';
    }

    return ProxyServerParse(entries: entries, note: note);
  }

  static ProxyServerEntry? _parseAuthority(String scheme, String authority) {
    if (authority.isEmpty) return null;

    String host;
    String portText = '';

    if (authority.startsWith('[')) {
      // IPv6 字面量：[::1]:7877
      final int close = authority.indexOf(']');
      if (close < 0) return null;
      host = authority.substring(1, close);
      final String rest = authority.substring(close + 1);
      if (rest.startsWith(':')) portText = rest.substring(1);
    } else {
      final int colon = authority.lastIndexOf(':');
      if (colon < 0) {
        host = authority;
      } else {
        host = authority.substring(0, colon);
        portText = authority.substring(colon + 1);
      }
    }

    host = host.trim();
    if (host.isEmpty) return null;

    final int? port = int.tryParse(portText.trim());
    if (port == null || port <= 0 || port > 65535) return null;

    return ProxyServerEntry(scheme: scheme, host: host, port: port);
  }
}

/// 最终生效的路由方式。
enum ProxyRouteKind {
  /// 直连（不经过代理）。
  direct('直连'),

  /// 经过 HTTP/HTTPS CONNECT 代理。
  httpProxy('代理');

  const ProxyRouteKind(this.labelZh);

  final String labelZh;
}

/// 一次代理决策的**结果快照**（给 UI 展示 + 给 `HttpClient.findProxy` 同步读取）。
class ProxyResolution {
  const ProxyResolution({
    required this.kind,
    required this.settings,
    required this.sourceLabel,
    this.host,
    this.port,
    this.warning,
    this.blockedReason,
    this.detectedFromSystem = false,
  });

  /// 直连结果。
  factory ProxyResolution.direct({
    required ProxySettings settings,
    required String sourceLabel,
    String? warning,
    String? blockedReason,
  }) => ProxyResolution(
    kind: ProxyRouteKind.direct,
    settings: settings,
    sourceLabel: sourceLabel,
    warning: warning,
    blockedReason: blockedReason,
  );

  /// 走代理结果。
  factory ProxyResolution.proxy({
    required ProxySettings settings,
    required String host,
    required int port,
    required String sourceLabel,
    bool detectedFromSystem = false,
    String? warning,
  }) => ProxyResolution(
    kind: ProxyRouteKind.httpProxy,
    settings: settings,
    host: host,
    port: port,
    sourceLabel: sourceLabel,
    detectedFromSystem: detectedFromSystem,
    warning: warning,
  );

  final ProxyRouteKind kind;
  final ProxySettings settings;

  /// 人类可读的"这个决定是怎么来的"。
  final String sourceLabel;

  final String? host;
  final int? port;

  /// 需要让用户知道但**不影响使用**的提示（例如 PAC 不支持）。
  final String? warning;

  /// 明确失败的原因（`system` 模式检测不到代理时用）。
  ///
  /// 非 null 表示这是"无法按用户要求建立连接"，UI 必须显式展示，
  /// 而不是假装一切正常。
  final String? blockedReason;

  /// 是否来自系统代理检测（决定 UI 上要不要提示"检测到的代理"）。
  final bool detectedFromSystem;

  bool get usesProxy => kind == ProxyRouteKind.httpProxy;

  String get authority => (host == null || port == null) ? '' : '$host:$port';

  /// 给 `HttpClient.findProxy` 用的返回值。
  ///
  /// Dart 只认 `DIRECT` / `PROXY host:port` / `SOCKS host:port` 这几种形式。
  String findProxyFor(Uri uri) {
    if (kind == ProxyRouteKind.direct) return 'DIRECT';
    if (settings.bypassLocalhost && isBypassedHost(uri.host)) return 'DIRECT';
    return 'PROXY $authority';
  }

  /// 是否属于"本地地址"（`<local>` 语义）。
  ///
  /// 判定：回环地址，或**不含点**的主机名（Windows 的 `<local>` 就是这个含义，
  /// 覆盖 `localhost`、`my-pc` 这类内网短名）。
  static bool isBypassedHost(String host) {
    if (host.isEmpty) return false;
    final String h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
    if (h.startsWith('127.')) return true;
    // 单标签主机名（没有点，且不是 IPv6）→ 视为本地/内网名字
    if (!h.contains('.') && !h.contains(':')) return true;
    return false;
  }

  @override
  String toString() =>
      'ProxyResolution(${kind.name}, ${usesProxy ? authority : '<direct>'}, '
      'source=$sourceLabel'
      '${blockedReason == null ? '' : ', blocked=$blockedReason'})';
}
