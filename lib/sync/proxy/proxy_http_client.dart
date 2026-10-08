import 'dart:io';

import '../../core/constants.dart';
import '../../core/logger.dart';
import 'proxy_resolver.dart';

/// 按代理决策创建一个 `HttpClient`。
///
/// 这是**唯一**创建带代理的 `HttpClient` 的地方，避免出现
/// "登录走代理、同步直连"这种不一致。
///
/// 硬约束（需求「四、API 客户端接入」）：
/// * **绝不**设置 `badCertificateCallback` —— 不做任何 TLS 绕过；
/// * 代理密码只用于 `addProxyCredentials`，**不进日志、不进异常**；
/// * `findProxy` 每次请求都向 [resolver] 取当前决策，
///   因此配置变化后**必须重建 HttpClient**（旧连接池里可能还有走老路的连接）。
HttpClient buildProxyAwareHttpClient({
  required ProxyResolver resolver,
  String? proxyUsername,
  String? proxyPassword,
  Duration? connectionTimeout,
  String? userAgent,
}) {
  final HttpClient client = HttpClient();
  client.connectionTimeout = connectionTimeout ?? SyncConfig.connectTimeout;
  if (userAgent != null) client.userAgent = userAgent;

  client.findProxy = resolver.findProxyFor;

  final String? user = _nonEmpty(proxyUsername);
  final String? password = proxyPassword;
  if (user != null) {
    // 代理要求认证时（407）由这里补凭据。Dart 会自动重放请求。
    client.authenticateProxy =
        (String host, int port, String scheme, String? realm) async {
          try {
            client.addProxyCredentials(
              host,
              port,
              realm ?? '',
              HttpClientBasicCredentials(user, password ?? ''),
            );
            // 只记"提供了凭据"，绝不记凭据内容。
            Loggers.proxy.info('代理要求认证，已提供手动配置的凭据（host=$host:$port）');
            return true;
          } catch (e, st) {
            Loggers.proxy.fine('设置代理凭据失败', e, st);
            return false;
          }
        };
  }

  return client;
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
