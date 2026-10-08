import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 本地假 **HTTP 代理**（Clash Mixed/HTTP 端口的最小可用替身）。
///
/// 为什么需要它：需求要求验证"所有请求统一走同一个代理""代理连接被拒绝"
/// "CONNECT 407""TLS 握手失败"，这些都必须在**真实 HTTP 栈**上验证，
/// mock 掉 `HttpClient` 就什么都证明不了。
///
/// 支持：
/// * **绝对形式转发**（明文 HTTP 经代理的标准做法）：
///   `GET http://host:port/path HTTP/1.1` → 重写为 origin-form 后转发给上游；
/// * **CONNECT 隧道**：回 `200 Connection established` 后双向透传；
/// * **可选认证**：没有/错误的 `Proxy-Authorization` 一律回 `407`；
/// * **模拟隧道故障**：`acceptConnectThenClose` 让 CONNECT 回 200 后立刻断开，
///   用于触发客户端的 **TLS 握手失败**（不需要自签证书）。
///
/// 只监听 127.0.0.1，不访问公网。
class FakeHttpProxy {
  FakeHttpProxy._(this._server, this.port);

  final ServerSocket _server;
  final int port;

  String get authority => '127.0.0.1:$port';

  // --- 可调行为 ---

  /// 是否要求代理认证。
  bool requireAuth = false;

  String username = 'clash-user';
  String password = 'hunter2-proxy-password';

  /// CONNECT 回 200 之后立刻断开（模拟"隧道建起来但 TLS 过不去"）。
  bool acceptConnectThenClose = false;

  // --- 观测 ---

  /// 收到的绝对形式目标（明文 HTTP 经代理时形如 `http://host:port/path`）。
  final List<String> forwardTargets = <String>[];

  /// 收到的 CONNECT 目标（形如 `host:port`）。
  final List<String> connectTargets = <String>[];

  /// 收到的请求方法（按到达顺序）。
  final List<String> methods = <String>[];

  /// 因缺少/错误凭据而回 407 的次数。
  int authChallenges = 0;

  /// 收到的 chunked 请求数（本替身不实现解码，会用 501 明确拒绝）。
  int chunkedRequests = 0;

  /// 通过认证的请求数。
  int authorizedRequests = 0;

  /// 是否有请求带着 `Proxy-Authorization` 头到达（**只记布尔，不记内容**）。
  bool sawProxyAuthorizationHeader = false;

  static Future<FakeHttpProxy> start() async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FakeHttpProxy proxy = FakeHttpProxy._(server, server.port);
    unawaited(proxy._listen());
    return proxy;
  }

  /// 停止监听（已建立的连接由客户端负责关闭）。
  Future<void> close() => _server.close();

  Future<void> _listen() async {
    await for (final Socket client in _server) {
      unawaited(_handle(client));
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(Socket client) async {
    final StreamIterator<Uint8List> reader = StreamIterator<Uint8List>(client);
    try {
      final _Head? head = await _readHead(reader);
      if (head == null) {
        client.destroy();
        return;
      }

      final List<String> lines = head.text.split('\r\n');
      final List<String> parts = lines.first.split(' ');
      if (parts.length < 2) {
        client.destroy();
        return;
      }
      final String method = parts[0].toUpperCase();
      final String target = parts[1];
      final Map<String, String> headers = _parseHeaders(lines.skip(1));
      methods.add(method);

      if (!_authorized(headers)) {
        authChallenges++;
        await _write(
          client,
          'HTTP/1.1 407 Proxy Authentication Required\r\n'
          'Proxy-Authenticate: Basic realm="petlife-test"\r\n'
          'Content-Length: 0\r\n'
          'Connection: close\r\n\r\n',
        );
        client.destroy();
        return;
      }
      authorizedRequests++;

      if (method == 'CONNECT') {
        await _handleConnect(client, target);
        return;
      }

      await _handleAbsoluteForm(client, reader, head, method, target, headers);
    } catch (_) {
      client.destroy();
    }
  }

  Future<void> _handleConnect(Socket client, String target) async {
    connectTargets.add(target);
    await _write(client, 'HTTP/1.1 200 Connection established\r\n\r\n');

    if (acceptConnectThenClose) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      client.destroy();
      return;
    }

    final Uri? upstreamUri = Uri.tryParse('http://$target');
    if (upstreamUri == null || upstreamUri.host.isEmpty) {
      client.destroy();
      return;
    }
    try {
      final Socket upstream = await Socket.connect(
        upstreamUri.host,
        upstreamUri.port,
        timeout: const Duration(seconds: 3),
      );
      _pipe(client, upstream);
    } catch (_) {
      client.destroy();
    }
  }

  Future<void> _handleAbsoluteForm(
    Socket client,
    StreamIterator<Uint8List> reader,
    _Head head,
    String method,
    String target,
    Map<String, String> headers,
  ) async {
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      await _write(
        client,
        'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
      );
      client.destroy();
      return;
    }

    // 本替身只处理"带 Content-Length 的定长请求体"。
    // 遇到 chunked 就**明确拒绝**：绝不能把 chunk 头当 body 原样转发，
    // 那样上游只会抛一个莫名其妙的 JSON 解析错误，排查起来极费时间。
    if ((headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked')) {
      chunkedRequests++;
      await _write(
        client,
        'HTTP/1.1 501 Not Implemented\r\n'
        'Content-Length: 0\r\n'
        'Connection: close\r\n\r\n',
      );
      client.destroy();
      return;
    }

    forwardTargets.add(target);
    final Uri absolute = Uri.parse(target);

    // 按 Content-Length 精确读满请求体（测试里的 body 都很小）
    final int? contentLength = int.tryParse(headers['content-length'] ?? '');
    final List<int> body = <int>[...head.leftover];
    while (contentLength != null &&
        body.length < contentLength &&
        await reader.moveNext()) {
      body.addAll(reader.current);
    }
    if (contentLength != null && body.length > contentLength) {
      body.removeRange(contentLength, body.length);
    }

    // 上游用独立 HttpClient 转发：请求行交给它按 absolute URI 生成 origin-form，
    // 不必手写 socket 拼接。
    // autoUncompress=false 保证"中继的字节"与"中继的响应头"始终一致。
    final HttpClient forwarder = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    final HttpClientRequest upstream = await forwarder.openUrl(
      method,
      absolute,
    );
    for (final MapEntry<String, String> e in headers.entries) {
      const Set<String> hopByHop = <String>{
        'proxy-authorization', // 代理凭据不能泄漏给上游
        'proxy-connection',
        'connection',
        'accept-encoding', // 避免压缩体，简化转发
        'host',
        'content-length', // 由 Dart 按实际写入的字节数重新生成
        'transfer-encoding', // 定长重打包，不再透传
      };
      if (hopByHop.contains(e.key)) continue;
      upstream.headers.set(e.key, e.value);
    }
    // 显式设定内容长度，保证请求帧与转发的字节数**完全一致**
    // （否则可能一边发 Content-Length 一边走 chunked，上游解析出半截 JSON）。
    upstream.contentLength = body.length;
    if (body.isNotEmpty) {
      upstream.add(body);
    }
    final HttpClientResponse response = await upstream.close();
    final List<int> responseBody = await response.fold<List<int>>(
      <int>[],
      (List<int> bytes, List<int> chunk) => bytes..addAll(chunk),
    );

    final StringBuffer responseHead = StringBuffer()
      ..write('HTTP/1.1 ${response.statusCode} ${response.reasonPhrase}\r\n');
    response.headers.forEach((String name, List<String> values) {
      const Set<String> hopByHop = <String>{
        'connection',
        'keep-alive',
        'proxy-authenticate',
        'proxy-authorization',
        'te',
        'trailer',
        'transfer-encoding',
        'upgrade',
        'content-length',
      };
      if (hopByHop.contains(name.toLowerCase())) return;
      for (final String value in values) {
        responseHead.write('$name: $value\r\n');
      }
    });
    responseHead
      ..write('Content-Length: ${responseBody.length}\r\n')
      ..write('Connection: close\r\n\r\n');
    client.add(utf8.encode(responseHead.toString()));
    if (responseBody.isNotEmpty) {
      client.add(responseBody);
    }
    await client.flush();
    client.destroy();
    forwarder.close(force: true);
  }

  // ---------------------------------------------------------------------------

  bool _authorized(Map<String, String> headers) {
    final String? auth = headers['proxy-authorization'];
    if (auth != null && auth.isNotEmpty) sawProxyAuthorizationHeader = true;
    if (!requireAuth) return true;
    if (auth == null) return false;
    final String expected =
        'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    return auth == expected;
  }

  static Map<String, String> _parseHeaders(Iterable<String> lines) {
    final Map<String, String> headers = <String, String>{};
    for (final String line in lines) {
      final int idx = line.indexOf(':');
      if (idx <= 0) continue;
      headers[line.substring(0, idx).trim().toLowerCase()] = line
          .substring(idx + 1)
          .trim();
    }
    return headers;
  }

  static Future<void> _write(Socket socket, String text) async {
    socket.write(text);
    await socket.flush();
  }

  static void _pipe(Socket a, Socket b) {
    a.listen(
      b.add,
      onError: (Object _) => b.destroy(),
      onDone: () => b.destroy(),
    );
    b.listen(
      a.add,
      onError: (Object _) => a.destroy(),
      onDone: () => a.destroy(),
    );
  }

  /// 读到 `\r\n\r\n` 为止；返回头部文本与"多读进来"的字节。
  static Future<_Head?> _readHead(StreamIterator<Uint8List> reader) async {
    final List<int> buffer = <int>[];
    while (await reader.moveNext()) {
      buffer.addAll(reader.current);
      final String text = utf8.decode(buffer, allowMalformed: true);
      final int idx = text.indexOf('\r\n\r\n');
      if (idx >= 0) {
        final int end = idx + 4;
        return _Head(text.substring(0, end), buffer.sublist(end));
      }
      if (buffer.length > 65536) return null;
    }
    return null;
  }
}

class _Head {
  const _Head(this.text, this.leftover);

  final String text;
  final List<int> leftover;
}
