import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../authenticated_api.dart';
import '../credential_store.dart';
import 'proxy_models.dart';
import 'proxy_probe.dart';
import 'proxy_resolver.dart';
import 'system_proxy.dart';

/// 「网络连接」区域的控制器。
///
/// 职责：
/// * 持有当前 [ProxySettings] 与解析出的 [ProxyResolution]（UI 展示用）；
/// * 把"检测系统代理 / 测试代理 / 测试服务端 / 保存并重新连接"封装成语义化方法；
/// * 代理密码走 [CredentialStore]，**绝不落 SQLite、绝不写日志**。
///
/// 它不直接发同步请求——同步仍由 `SyncEngine` → `AuthenticatedApi` 负责，
/// 这里只改"走哪条网络路径"。
class ProxyController extends ChangeNotifier {
  ProxyController({
    required AuthenticatedApi api,
    required CredentialStore credentialStore,
    required ProxySettingsResolver resolver,
    required SystemProxyReader systemReader,
    ProxySettings? initialSettings,
  })  : _api = api,
        _credentials = credentialStore,
        _resolver = resolver,
        _systemReader = systemReader,
        _settings = initialSettings ?? ProxySettings.defaults;

  final AuthenticatedApi _api;
  final CredentialStore _credentials;
  final ProxySettingsResolver _resolver;
  final SystemProxyReader _systemReader;

  ProxySettings _settings;
  SystemProxyInfo? _detected;
  ProxyProbeResult? _lastProbe;
  bool _busy = false;
  String? _error;
  String? _notice;

  /// 代理密码在凭据存储里的条目名。
  static String get passwordReference =>
      '${SyncConfig.credentialTargetPrefix}${SyncConfig.credentialProxyKey}';

  ProxySettings get settings => _settings;

  /// 当前实际生效的决策（"当前实际使用：直连 / 代理 x.x.x.x:port"）。
  ProxyResolution get resolution => _api.proxyResolution;

  /// 最近一次"检测系统代理"的结果。
  SystemProxyInfo? get detected => _detected;

  /// 最近一次探测（测试代理 / 测试服务端）的结果。
  ProxyProbeResult? get lastProbe => _lastProbe;

  /// 最近一次"测试代理"还是"测试服务端"（用于标题文案）。
  bool get lastProbeIncludedHealth => _lastProbeIncludedHealth;
  bool _lastProbeIncludedHealth = true;

  bool get busy => _busy;
  String? get error => _error;
  String? get notice => _notice;

  /// 是否已保存过代理密码（UI 用它决定要不要显示"清除密码"）。
  bool get hasSavedPassword => _settings.hasSavedPassword;

  /// 启动时调用：读偏好 + 解析一次决策。
  Future<void> load() async {
    _settings = _resolver.settings;
    _detected = _resolver.lastDetected;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // 检测
  // ---------------------------------------------------------------------------

  /// 「检测系统代理」：只读取，不改配置。
  Future<void> detectSystemProxy() async {
    _setBusy(true);
    try {
      final SystemProxyInfo info = await _resolver.detectSystemProxy();
      _detected = info;
      _error = null;
      _notice = info.hasStaticProxy
          ? '已检测到系统代理：${info.proxyServer}（来源：${info.source}）'
          : (info.hasPac || info.autoDetect
              ? '检测到系统启用了 PAC/自动检测，PetLife 暂不支持；'
                  '请改用 Clash 的 System Proxy 或手动填写代理地址。'
              : '未检测到静态系统代理（Clash 的 System Proxy 可能未开启）。');
      Loggers.proxy.info('手动触发系统代理检测：来源=${info.source}，检测到=${info.hasStaticProxy}');
    } catch (e, st) {
      Loggers.proxy.warning('检测系统代理失败', e, st);
      _error = '检测系统代理失败：$e';
    } finally {
      _setBusy(false);
    }
  }

  // ---------------------------------------------------------------------------
  // 测试
  // ---------------------------------------------------------------------------

  /// 「测试代理」：TCP + CONNECT 隧道（不请求 /health）。
  Future<ProxyProbeResult> testProxy({
    required String baseUrl,
    required ProxySettings settings,
    String? password,
  }) =>
      _probe(baseUrl: baseUrl, settings: settings, password: password, includeHealthCheck: false);

  /// 「测试服务端」：TCP → CONNECT → TLS → `/health`。
  Future<ProxyProbeResult> testServer({
    required String baseUrl,
    required ProxySettings settings,
    String? password,
  }) =>
      _probe(baseUrl: baseUrl, settings: settings, password: password, includeHealthCheck: true);

  Future<ProxyProbeResult> _probe({
    required String baseUrl,
    required ProxySettings settings,
    required String? password,
    required bool includeHealthCheck,
  }) async {
    _setBusy(true);
    _lastProbeIncludedHealth = includeHealthCheck;
    try {
      final Uri? uri = Uri.tryParse(baseUrl.trim());
      if (uri == null || uri.host.isEmpty) {
        _lastProbe = _invalidTarget();
        _error = '服务端地址无效：$baseUrl';
        return _lastProbe!;
      }

      // 用**表单里的**配置解析，而不是已保存的配置：
      // 用户往往先测试再保存，测试结果必须反映表单里的值。
      final ProxySettingsResolver temp = ProxySettingsResolver(
        settings: settings,
        systemReader: _systemReader,
      );
      final ProxyResolution resolution = await temp.refresh();

      final ProxyProbe probe = ProxyProbe(
        proxyUsername: settings.username,
        proxyPassword: password,
      );
      final ProxyProbeResult result = await probe
          .probe(
            baseUri: uri,
            resolution: resolution,
            includeHealthCheck: includeHealthCheck,
          )
          .timeout(SyncConfig.proxyProbeTimeout);

      _lastProbe = result;
      _error = result.allOk ? null : result.summary;
      _notice = result.allOk ? '${result.summary}（${result.elapsed.inMilliseconds} ms）' : null;

      Loggers.proxy.info(
        '探测完成（${includeHealthCheck ? '测试服务端' : '测试代理'}）：'
        '走代理=${result.usedProxy}，'
        'TCP=${result.tcpOk}，CONNECT=${result.connectOk}，'
        'TLS=${result.tlsOk}，health=${result.healthOk}，'
        '失败=${result.failure?.name ?? '无'}',
      );
      return result;
    } on TimeoutException {
      _lastProbe = null;
      _error = '探测超时（超过 ${SyncConfig.proxyProbeTimeout.inSeconds} 秒）';
      return _invalidTarget(message: _error!, failure: ProxyProbeFailure.healthCheckFailed);
    } catch (e, st) {
      Loggers.proxy.warning('探测失败', e, st);
      _lastProbe = null;
      _error = '探测失败：$e';
      return _invalidTarget(message: _error!);
    } finally {
      _setBusy(false);
    }
  }

  static ProxyProbeResult _invalidTarget({
    String message = '服务端地址无效',
    ProxyProbeFailure failure = ProxyProbeFailure.invalidTarget,
  }) =>
      ProxyProbeResult(
        usedProxy: false,
        steps: <ProxyProbeStep>[
          ProxyProbeStep(label: '服务端地址', ok: false, detail: message),
        ],
        tcpOk: false,
        connectOk: false,
        tlsOk: false,
        healthOk: false,
        summary: message,
        failure: failure,
      );

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /// 「保存并重新连接」。
  ///
  /// [password] 语义：
  /// * `null`   → 不改动已保存的密码；
  /// * `''`     → 清除已保存的密码；
  /// * 非空字符串 → 覆盖保存。
  Future<void> save(ProxySettings next, {String? password}) async {
    _setBusy(true);
    try {
      ProxySettings target = next;

      if (password == null) {
        // 保持原引用不变
        target = next.copyWith(
          passwordCredentialReference: _settings.passwordCredentialReference,
          clearPasswordReference: _settings.passwordCredentialReference == null,
        );
      } else if (password.isEmpty) {
        await _deleteStoredPassword();
        target = next.copyWith(clearPasswordReference: true);
      } else {
        await _credentials.write(passwordReference, password);
        target = next.copyWith(passwordCredentialReference: passwordReference);
      }

      final ProxyResolution resolution = await _api.applyProxySettings(target);
      _settings = target;
      _detected = _resolver.lastDetected;
      _error = resolution.blockedReason;
      _notice = resolution.usesProxy
          ? '已保存并重新连接：经代理 ${resolution.authority}'
          : '已保存并重新连接：${resolution.kind.labelZh}'
              '${resolution.warning == null ? '' : '（${resolution.warning}）'}';
    } catch (e, st) {
      Loggers.proxy.warning('保存代理配置失败', e, st);
      _error = '保存代理配置失败：$e';
    } finally {
      _setBusy(false);
    }
  }

  /// 清除已保存的代理密码（退出登录不会动它，因此需要一个显式入口）。
  Future<void> clearStoredPassword() async {
    _setBusy(true);
    try {
      await _deleteStoredPassword();
      final ProxySettings target = _settings.copyWith(clearPasswordReference: true);
      await _api.applyProxySettings(target);
      _settings = target;
      _notice = '已清除保存的代理密码';
      _error = null;
    } catch (e, st) {
      Loggers.proxy.warning('清除代理密码失败', e, st);
      _error = '清除代理密码失败：$e';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _deleteStoredPassword() async {
    try {
      await _credentials.delete(passwordReference);
    } catch (e, st) {
      // 删除失败不该阻塞配置保存（条目可能本来就不存在）
      Loggers.credential.fine('删除代理密码失败', e, st);
    }
  }

  /// 重新解析并重建连接（用于"网络恢复了，重试一下"）。
  Future<void> reconnect() async {
    _setBusy(true);
    try {
      final ProxyResolution resolution = await _api.applyProxySettings(_settings);
      _error = resolution.blockedReason;
      _notice = resolution.usesProxy
          ? '已重新连接：经代理 ${resolution.authority}'
          : '已重新连接：${resolution.kind.labelZh}';
    } catch (e, st) {
      Loggers.proxy.warning('重新连接失败', e, st);
      _error = '重新连接失败：$e';
    } finally {
      _setBusy(false);
    }
  }

  void clearMessages() {
    _error = null;
    _notice = null;
    _notify();
  }

  /// 供 UI 组装表单：把当前生效的决策里的主机/端口作为手动模式的初值。
  String get suggestedHost => _settings.host.isEmpty
      ? (_detected?.parsed.preferredHttp?.host ?? SyncConfig.defaultProxyHost)
      : _settings.host;

  int get suggestedPort =>
      _settings.port > 0 ? _settings.port : SyncConfig.defaultProxyPort;

  void _setBusy(bool value) {
    _busy = value;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
