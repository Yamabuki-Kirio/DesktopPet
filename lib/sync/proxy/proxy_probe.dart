import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/constants.dart';
import '../../core/logger.dart';
import 'proxy_http_client.dart';
import 'proxy_models.dart';
import 'proxy_resolver.dart';

/// 探测失败的具体阶段原因（需求「五」要求区分，而不是只报"握手失败"）。
enum ProxyProbeFailure {
  /// 连不上代理（连接被拒绝 / 超时）。
  proxyConnectionRefused('连不上代理（连接被拒绝或超时）'),

  /// 代理返回 407，需要认证。
  proxyAuthenticationRequired('代理要求认证（HTTP 407）'),

  /// 代理拒绝建立 CONNECT 隧道（非 200 且非 407）。
  proxyConnectRejected('代理拒绝建立 CONNECT 隧道'),

  /// TLS 握手失败（含证书校验失败；**不会**被绕过）。
  tlsHandshakeFailed('TLS 握手失败'),

  /// 服务端不可达（直连失败）。
  serverUnreachable('服务端不可达'),

  /// `/health` 返回非 200 或响应异常。
  healthCheckFailed('/health 检查失败'),

  /// 服务端地址本身无效。
  invalidTarget('服务端地址无效');

  const ProxyProbeFailure(this.labelZh);

  final String labelZh;
}

/// 探测的单个阶段结果。
class ProxyProbeStep {
  const ProxyProbeStep({required this.label, required this.ok, required this.detail});

  final String label;
  final bool ok;
  final String detail;

  @override
  String toString() => '${ok ? 'OK' : 'FAIL'} $label：$detail';
}

/// 探测总结果。
class ProxyProbeResult {
  const ProxyProbeResult({
    required this.usedProxy,
    required this.steps,
    required this.tcpOk,
    required this.connectOk,
    required this.tlsOk,
    required this.healthOk,
    required this.summary,
    this.failure,
    this.proxyStatusCode,
    this.healthStatusCode,
    this.elapsed = Duration.zero,
  });

  /// 本次探测是否使用了代理。
  final bool usedProxy;

  final List<ProxyProbeStep> steps;

  /// 四个阶段各自的通过情况（`connectOk` 在直连模式下等于 `tcpOk`）。
  final bool tcpOk;
  final bool connectOk;
  final bool tlsOk;
  final bool healthOk;

  /// 一句话结论（可读、不含敏感信息）。
  final String summary;

  /// 第一个失败的原因；全部通过时为 null。
  final ProxyProbeFailure? failure;

  /// CONNECT 阶段代理返回的状态码（例如 407）。
  final int? proxyStatusCode;

  /// `/health` 的状态码。
  final int? healthStatusCode;

  final Duration elapsed;

  bool get allOk => failure == null && tcpOk && connectOk && tlsOk && healthOk;
}

/// 分阶段网络探测：TCP → CONNECT 隧道 → TLS 握手 → `/health`。
///
/// 为什么不用 `HttpClient` 一路到底：需求要求把失败原因**分阶段**呈现
/// （连接被拒 / 需要认证 / 隧道被拒 / TLS 失败 / 服务端不可达）。
/// `HttpClient` 只会抛一个笼统异常，拿不到 CONNECT 的状态码。
///
/// 因此：
/// * **CONNECT 阶段**用裸 socket 手工发请求，才能读到 `407` / 非 200 的状态行；
/// * **TLS + /health 阶段**交给 `HttpClient`（内部仍会走 CONNECT 隧道），
///   好处是**证书校验保持 Dart 默认行为**——本类绝不设置
///   `badCertificateCallback`，也不给 `SecureSocket` 传 `onBadCertificate`。
class ProxyProbe {
  const ProxyProbe({this.proxyUsername, this.proxyPassword});

  /// 手动代理用户名（来自 [ProxySettings]）。
  final String? proxyUsername;

  /// 手动代理密码（来自 `CredentialStore`，**绝不写日志**）。
  final String? proxyPassword;

  /// 执行探测。
  ///
  /// [includeHealthCheck] = false 时只做「TCP + CONNECT 隧道」，
  /// 对应界面上的「测试代理」；true 时一路做到 `/health`，对应「测试服务端」。
  Future<ProxyProbeResult> probe({
    required Uri baseUri,
    required ProxyResolution resolution,
    bool includeHealthCheck = true,
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    final List<ProxyProbeStep> steps = <ProxyProbeStep>[];

    final String targetHost = baseUri.host;
    if (targetHost.isEmpty || (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
      steps.add(const ProxyProbeStep(
        label: '服务端地址',
        ok: false,
        detail: '无法解析出主机名，请检查服务端地址',
      ));
      return ProxyProbeResult(
        usedProxy: resolution.usesProxy,
        steps: steps,
        tcpOk: false,
        connectOk: false,
        tlsOk: false,
        healthOk: false,
        summary: ProxyProbeFailure.invalidTarget.labelZh,
        failure: ProxyProbeFailure.invalidTarget,
      );
    }

    final int targetPort =
        baseUri.hasPort ? baseUri.port : (baseUri.scheme == 'https' ? 443 : 80);
    final bool useProxy = resolution.usesProxy;
    final String dialHost = useProxy ? (resolution.host ?? targetHost) : targetHost;
    final int dialPort = useProxy ? (resolution.port ?? targetPort) : targetPort;

    // --- 1) TCP ---
    Socket? socket;
    try {
      socket = await Socket.connect(
        dialHost,
        dialPort,
        timeout: SyncConfig.proxyStageTimeout,
      );
      steps.add(ProxyProbeStep(
        label: useProxy ? 'TCP 连接代理' : 'TCP 连接服务端',
        ok: true,
        detail: '$dialHost:$dialPort',
      ));
    } on SocketException catch (e) {
      final ProxyProbeFailure failure = useProxy
          ? ProxyProbeFailure.proxyConnectionRefused
          : ProxyProbeFailure.serverUnreachable;
      steps.add(ProxyProbeStep(
        label: useProxy ? 'TCP 连接代理' : 'TCP 连接服务端',
        ok: false,
        detail: '$dialHost:$dialPort（${_socketMessage(e)}）',
      ));
      watch.stop();
      return _failed(
        steps: steps,
        failure: failure,
        usedProxy: useProxy,
        elapsed: watch.elapsed,
      );
    } on TimeoutException {
      final ProxyProbeFailure failure = useProxy
          ? ProxyProbeFailure.proxyConnectionRefused
          : ProxyProbeFailure.serverUnreachable;
      steps.add(ProxyProbeStep(
        label: useProxy ? 'TCP 连接代理' : 'TCP 连接服务端',
        ok: false,
        detail: '$dialHost:$dialPort（连接超时）',
      ));
      watch.stop();
      return _failed(
        steps: steps,
        failure: failure,
        usedProxy: useProxy,
        elapsed: watch.elapsed,
      );
    }

    // --- 2) CONNECT 隧道（仅代理模式） ---
    // 走到这里 socket 一定是非空的：上面所有失败分支都已经 return。
    int? proxyStatus;
    if (useProxy) {
      try {
        final String? authHeader = _basicProxyAuthorization();
        final StringBuffer request = StringBuffer()
          ..write('CONNECT $targetHost:$targetPort HTTP/1.1\r\n')
          ..write('Host: $targetHost:$targetPort\r\n')
          ..write('Proxy-Connection: keep-alive\r\n');
        // 认证头只写进 socket，绝不写日志
        if (authHeader != null) {
          request.write('Proxy-Authorization: $authHeader\r\n');
        }
        request.write('\r\n');

        socket.write(request.toString());
        await socket.flush();

        final String head = await _readHead(socket);
        proxyStatus = _statusCode(head);

        if (proxyStatus == 200) {
          steps.add(const ProxyProbeStep(
            label: 'CONNECT 隧道',
            ok: true,
            detail: '200 Connection established',
          ));
        } else if (proxyStatus == 407) {
          steps.add(const ProxyProbeStep(
            label: 'CONNECT 隧道',
            ok: false,
            detail: '407 代理要求认证',
          ));
          _destroy(socket);
          watch.stop();
          return _failed(
            steps: steps,
            failure: ProxyProbeFailure.proxyAuthenticationRequired,
            usedProxy: useProxy,
            tcpOk: true,
            proxyStatusCode: proxyStatus,
            elapsed: watch.elapsed,
          );
        } else {
          steps.add(ProxyProbeStep(
            label: 'CONNECT 隧道',
            ok: false,
            detail: '代理返回 ${proxyStatus ?? '未知状态'}'
                '${_firstLine(head).isEmpty ? '' : '：${_firstLine(head)}'}',
          ));
          _destroy(socket);
          watch.stop();
          return _failed(
            steps: steps,
            failure: ProxyProbeFailure.proxyConnectRejected,
            usedProxy: useProxy,
            tcpOk: true,
            proxyStatusCode: proxyStatus,
            elapsed: watch.elapsed,
          );
        }
      } on Exception catch (e) {
        steps.add(ProxyProbeStep(
          label: 'CONNECT 隧道',
          ok: false,
          detail: '与代理通信失败（${e.runtimeType}）',
        ));
        _destroy(socket);
        watch.stop();
        return _failed(
          steps: steps,
          failure: ProxyProbeFailure.proxyConnectRejected,
          usedProxy: useProxy,
          tcpOk: true,
          elapsed: watch.elapsed,
        );
      }
      _destroy(socket);
    }

    if (!includeHealthCheck) {
      steps.add(ProxyProbeStep(
        label: 'TLS 握手',
        ok: true,
        detail: '未检查（本次只测代理连通性）',
      ));
      steps.add(const ProxyProbeStep(
        label: '/health',
        ok: true,
        detail: '未检查',
      ));
      watch.stop();
      return ProxyProbeResult(
        usedProxy: useProxy,
        steps: steps,
        tcpOk: true,
        connectOk: true,
        tlsOk: true,
        healthOk: true,
        summary: useProxy ? '代理可用（TCP 与 CONNECT 均通过）' : '服务端 TCP 可达',
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    }

    // --- 3) TLS 握手 + 4) /health（交给 HttpClient，证书校验走 Dart 默认行为） ---
    final String basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    final Uri healthUri =
        baseUri.replace(path: '$basePath/health', query: null, fragment: null);

    final HttpClient client = buildProxyAwareHttpClient(
      resolver: FixedProxyResolver(resolution),
      proxyUsername: proxyUsername ?? resolution.settings.username,
      proxyPassword: proxyPassword,
      userAgent: 'PetLife/${AppConstants.appVersion}',
    );

    try {
      final HttpClientRequest request =
          await client.getUrl(healthUri).timeout(SyncConfig.proxyStageTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse response =
          await request.close().timeout(SyncConfig.proxyStageTimeout);
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(SyncConfig.proxyStageTimeout);

      final bool isHttps = baseUri.scheme == 'https';
      steps.add(ProxyProbeStep(
        label: 'TLS 握手',
        ok: true,
        detail: isHttps ? '证书校验通过（${baseUri.host}）' : '明文 HTTP，跳过',
      ));

      final bool healthOk = response.statusCode == 200;
      steps.add(ProxyProbeStep(
        label: '/health',
        ok: healthOk,
        detail: 'HTTP ${response.statusCode}'
            '${healthOk ? '' : '：${_shorten(body)}'}',
      ));

      watch.stop();
      if (healthOk) {
        return ProxyProbeResult(
          usedProxy: useProxy,
          steps: steps,
          tcpOk: true,
          connectOk: true,
          tlsOk: true,
          healthOk: true,
          summary: useProxy ? '全部通过：经代理可正常访问服务端' : '全部通过：直连可正常访问服务端',
          proxyStatusCode: proxyStatus,
          healthStatusCode: response.statusCode,
          elapsed: watch.elapsed,
        );
      }
      return ProxyProbeResult(
        usedProxy: useProxy,
        steps: steps,
        tcpOk: true,
        connectOk: true,
        tlsOk: true,
        healthOk: false,
        summary: '/health 返回 HTTP ${response.statusCode}',
        failure: ProxyProbeFailure.healthCheckFailed,
        proxyStatusCode: proxyStatus,
        healthStatusCode: response.statusCode,
        elapsed: watch.elapsed,
      );
    } on TlsException catch (e) {
      // HandshakeException / CertificateException 都归到这里：
      // 证书校验失败**不会**被绕过，所以它就是"必须修好"的 TLS 问题。
      steps.add(ProxyProbeStep(
        label: 'TLS 握手',
        ok: false,
        detail: '证书校验或握手失败（${e.message}）',
      ));
      return _failed(
        steps: steps,
        failure: ProxyProbeFailure.tlsHandshakeFailed,
        usedProxy: useProxy,
        tcpOk: true,
        connectOk: true,
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    } on SocketException catch (e) {
      // 已经成功建立 CONNECT 隧道，此时 socket 层失败基本都发生在 TLS 阶段
      // （代理把隧道接过去之后立刻断开、或目标端口不是 TLS 等）。
      final bool tlsLikely = useProxy || baseUri.scheme == 'https';
      steps.add(ProxyProbeStep(
        label: tlsLikely ? 'TLS 握手' : '连接服务端',
        ok: false,
        detail: _socketMessage(e),
      ));
      return _failed(
        steps: steps,
        failure:
            tlsLikely ? ProxyProbeFailure.tlsHandshakeFailed : ProxyProbeFailure.serverUnreachable,
        usedProxy: useProxy,
        tcpOk: true,
        connectOk: true,
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    } on TimeoutException {
      steps.add(const ProxyProbeStep(
        label: 'TLS 握手',
        ok: false,
        detail: '握手或响应超时',
      ));
      return _failed(
        steps: steps,
        failure: ProxyProbeFailure.tlsHandshakeFailed,
        usedProxy: useProxy,
        tcpOk: true,
        connectOk: true,
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    } on HttpException catch (e) {
      // 隧道已经在 CONNECT 阶段拿到 200，说明"代理"这一环是通的；
      // 之后报 HttpException 时，问题更可能出在 TLS/目标服务而不是代理本身。
      final bool tlsLikely = useProxy && baseUri.scheme == 'https';
      steps.add(ProxyProbeStep(
        label: tlsLikely ? 'TLS 握手' : '连接服务端',
        ok: false,
        detail: e.message,
      ));
      return _failed(
        steps: steps,
        failure: tlsLikely
            ? ProxyProbeFailure.tlsHandshakeFailed
            : (useProxy
                ? ProxyProbeFailure.proxyConnectRejected
                : ProxyProbeFailure.serverUnreachable),
        usedProxy: useProxy,
        tcpOk: true,
        connectOk: true,
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    } catch (e, st) {
      Loggers.proxy.fine('代理探测出现未预期错误', e, st);
      steps.add(ProxyProbeStep(
        label: '探测',
        ok: false,
        detail: '未预期错误（${e.runtimeType}）',
      ));
      return _failed(
        steps: steps,
        failure: ProxyProbeFailure.healthCheckFailed,
        usedProxy: useProxy,
        tcpOk: true,
        connectOk: true,
        proxyStatusCode: proxyStatus,
        elapsed: watch.elapsed,
      );
    } finally {
      client.close(force: true);
    }
  }

  ProxyProbeResult _failed({
    required List<ProxyProbeStep> steps,
    required ProxyProbeFailure failure,
    required bool usedProxy,
    required Duration elapsed,
    bool tcpOk = false,
    bool connectOk = false,
    bool tlsOk = false,
    int? proxyStatusCode,
    int? healthStatusCode,
  }) =>
      ProxyProbeResult(
        usedProxy: usedProxy,
        steps: steps,
        tcpOk: tcpOk,
        connectOk: connectOk,
        tlsOk: tlsOk,
        healthOk: false,
        summary: failure.labelZh,
        failure: failure,
        proxyStatusCode: proxyStatusCode,
        healthStatusCode: healthStatusCode,
        elapsed: elapsed,
      );

  // ---------------------------------------------------------------------------

  /// `Proxy-Authorization: Basic ...`。**只用于写入 socket**。
  String? _basicProxyAuthorization() {
    final String? user = proxyUsername?.trim();
    final String? password = proxyPassword;
    if (user == null || user.isEmpty) return null;
    final String raw = '$user:${password ?? ''}';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  static void _destroy(Socket socket) {
    try {
      socket.destroy();
    } catch (_) {
      // 忽略
    }
  }

  static Future<String> _readHead(Socket socket) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    final Completer<String> done = Completer<String>();
    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (Uint8List chunk) {
        builder.add(chunk);
        final String text = utf8.decode(builder.toBytes(), allowMalformed: true);
        if (text.contains('\r\n\r\n') || builder.length > 65536) {
          if (!done.isCompleted) done.complete(text);
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(utf8.decode(builder.toBytes(), allowMalformed: true));
        }
      },
      cancelOnError: true,
    );
    try {
      return await done.future.timeout(SyncConfig.proxyStageTimeout);
    } finally {
      await sub.cancel();
    }
  }

  static int? _statusCode(String head) {
    final String first = _firstLine(head);
    final List<String> parts = first.split(' ');
    if (parts.length < 2) return null;
    return int.tryParse(parts[1]);
  }

  static String _firstLine(String head) {
    final int idx = head.indexOf('\r\n');
    final String line = idx < 0 ? head : head.substring(0, idx);
    return line.trim();
  }

  static String _shorten(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 120 ? oneLine : '${oneLine.substring(0, 120)}…';
  }

  static String _socketMessage(SocketException e) =>
      e.osError?.message ?? e.message;
}
