import 'proxy_models.dart';

/// Windows 当前用户代理配置的读取结果。
class SystemProxyInfo {
  const SystemProxyInfo({
    required this.source,
    required this.available,
    this.enabled = false,
    this.autoDetect = false,
    this.autoConfigUrl,
    this.proxyServer,
    this.proxyBypass,
    this.error,
  });

  /// 检测来源（`WinHTTP` / `注册表` / `不可用`），用于 UI 与诊断展示。
  final String source;

  /// 检测是否真的执行成功（false = 读不到，不代表"没有代理"）。
  final bool available;

  /// 静态代理开关（注册表 `ProxyEnable`）。
  final bool enabled;

  /// 是否开启了自动检测（WPAD）。
  final bool autoDetect;

  /// PAC 地址（`AutoConfigURL`）。
  final String? autoConfigUrl;

  /// 原始 `ProxyServer` 字符串，例如 `127.0.0.1:7877` 或
  /// `http=127.0.0.1:7877;https=127.0.0.1:7877`。
  final String? proxyServer;

  /// 原始 `ProxyOverride` 字符串，例如 `<local>;*.corp.example.com`。
  final String? proxyBypass;

  /// 检测失败原因（可读）。
  final String? error;

  /// 是否配置了 PAC。
  bool get hasPac => autoConfigUrl != null && autoConfigUrl!.trim().isNotEmpty;

  /// 是否配置了静态代理字符串。
  bool get hasStaticProxy => proxyServer != null && proxyServer!.trim().isNotEmpty;

  /// `<local>` 是否出现在绕过列表里（Windows 的"跳过本地地址"）。
  bool get bypassLocalByDefault {
    final String? raw = proxyBypass;
    if (raw == null) return false;
    return raw
        .split(RegExp(r'[;,<>\s]'))
        .any((String s) => s.trim().toLowerCase() == 'local');
  }

  ProxyServerParse get parsed => ProxyServerParse.parseProxyServer(proxyServer);

  static const SystemProxyInfo unavailable = SystemProxyInfo(
    source: '不可用',
    available: false,
  );

  @override
  String toString() => 'SystemProxyInfo($source, available=$available, enabled=$enabled, '
      'autoDetect=$autoDetect, pac=${hasPac ? 'yes' : 'no'}, '
      'proxy=${hasStaticProxy ? 'yes' : 'no'})';
}

/// 系统代理读取器（抽象出来是为了测试能注入固定结果，不去碰真实注册表）。
abstract interface class SystemProxyReader {
  SystemProxyInfo read();
}

/// 固定结果的读取器（测试用；也可用于"强制指定"场景）。
class StaticSystemProxyReader implements SystemProxyReader {
  const StaticSystemProxyReader(this.info);

  final SystemProxyInfo info;

  @override
  SystemProxyInfo read() => info;
}

/// 不可用实现：非 Windows 平台（Android）使用。
///
/// 语义与 Windows 上的"读不到代理配置"一致：**不做任何探测**，
/// 让上层按"未检测到系统代理"处理，而不是抛异常或返回伪结果。
class UnavailableSystemProxyReader implements SystemProxyReader {
  const UnavailableSystemProxyReader();

  @override
  SystemProxyInfo read() => SystemProxyInfo(
    source: '不可用',
    available: false,
    error: '当前平台不支持读取系统代理（Android 使用应用内代理设置）',
  );
}

