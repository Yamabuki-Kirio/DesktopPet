import '../../core/logger.dart';
import 'proxy_models.dart';
import 'system_proxy.dart';

/// 代理决策器。
///
/// 之所以要有独立一层：`HttpClient.findProxy` 是**同步**回调，
/// 而"读系统代理"这类动作希望只在配置/环境变化时做一次。
/// 因此这里把结果缓存成 [current]，`findProxy` 只读缓存。
///
/// 约定：本层**绝不抛出**。任何失败都表达为
/// [ProxyResolution.blockedReason] + 直连回退，保证桌宠与本地采集不受影响。
abstract interface class ProxyResolver {
  /// 当前生效的决策（同步读取，给 `HttpClient.findProxy` 用）。
  ProxyResolution get current;

  /// 重新计算决策（配置变化、点"检测系统代理"、启动时调用）。
  Future<ProxyResolution> refresh();

  /// 更新普通代理配置；调用方随后通过 [refresh] 重新计算路由。
  void updateSettings(ProxySettings settings);

  /// `HttpClient.findProxy` 的实现。
  String findProxyFor(Uri uri);
}

/// 永远直连（未配置代理时的安全默认）。
class AlwaysDirectProxyResolver implements ProxyResolver {
  AlwaysDirectProxyResolver({ProxySettings? settings})
    : _settings = settings ?? ProxySettings.defaults;

  ProxySettings _settings;

  @override
  void updateSettings(ProxySettings settings) {
    _settings = settings.copyWith(mode: ProxyMode.direct);
  }

  @override
  ProxyResolution get current =>
      ProxyResolution.direct(settings: _settings, sourceLabel: '未启用代理');

  @override
  Future<ProxyResolution> refresh() async => current;

  @override
  String findProxyFor(Uri uri) => 'DIRECT';
}

/// 固定返回某个决策（探测"测试当前配置"时用，避免探测过程被并发改配置影响）。
class FixedProxyResolver implements ProxyResolver {
  const FixedProxyResolver(this._resolution);

  final ProxyResolution _resolution;

  @override
  ProxyResolution get current => _resolution;

  @override
  Future<ProxyResolution> refresh() async => _resolution;

  @override
  void updateSettings(ProxySettings settings) {
    // 固定决策只用于一次探测或测试，不接受运行期改写。
  }

  @override
  String findProxyFor(Uri uri) => _resolution.findProxyFor(uri);
}

/// 基于 [ProxySettings] + 系统代理检测的默认实现。
class ProxySettingsResolver implements ProxyResolver {
  ProxySettingsResolver({
    ProxySettings settings = ProxySettings.defaults,
    SystemProxyReader? systemReader,
  }) : _settings = settings,
       // 默认用"不可用"实现：桌面装配层会注入 WinHTTP 读取器，
       // 移动端（Android）则保持不可用（用应用内代理设置）。
       _systemReader = systemReader ?? const UnavailableSystemProxyReader() {
    // 先给一个安全默认（直连），避免 refresh 之前的请求走错路。
    _current = ProxyResolution.direct(settings: _settings, sourceLabel: '尚未检测');
  }

  ProxySettings _settings;
  final SystemProxyReader _systemReader;

  late ProxyResolution _current;
  SystemProxyInfo? _lastDetected;

  ProxySettings get settings => _settings;

  /// 最近一次系统代理检测结果（UI 展示"检测到的代理地址"）。
  SystemProxyInfo? get lastDetected => _lastDetected;

  @override
  ProxyResolution get current => _current;

  /// 更新配置（不自动 refresh，由调用方决定何时重算）。
  @override
  void updateSettings(ProxySettings next) {
    _settings = next;
  }

  @override
  String findProxyFor(Uri uri) => _current.findProxyFor(uri);

  /// 只做系统代理检测，不改变当前决策（"检测系统代理"按钮用）。
  Future<SystemProxyInfo> detectSystemProxy() async {
    final SystemProxyInfo info = _systemReader.read();
    _lastDetected = info;
    Loggers.proxy.info(
      '系统代理检测：来源=${info.source}，可用=${info.available}，'
      '启用=${info.enabled}，PAC=${info.hasPac}，静态代理=${info.hasStaticProxy}',
    );
    return info;
  }

  @override
  Future<ProxyResolution> refresh() async {
    final ProxySettings s = _settings;
    switch (s.mode) {
      case ProxyMode.direct:
        _current = ProxyResolution.direct(
          settings: s,
          sourceLabel: '手动选择「直接连接」',
        );
        return _current;

      case ProxyMode.manualHttp:
        _current = _resolveManual(s);
        return _current;

      case ProxyMode.system:
        _current = await _resolveSystem(s, allowDirectFallback: false);
        return _current;

      case ProxyMode.automatic:
        _current = await _resolveSystem(s, allowDirectFallback: true);
        return _current;
    }
  }

  // ---------------------------------------------------------------------------
  // 各模式
  // ---------------------------------------------------------------------------

  ProxyResolution _resolveManual(ProxySettings s) {
    final String host = s.host.trim();
    if (host.isEmpty || s.port <= 0 || s.port > 65535) {
      return ProxyResolution.direct(
        settings: s,
        sourceLabel: '手动 HTTP 代理（配置不完整）',
        blockedReason:
            '手动代理配置不完整：请填写地址与端口（例如 127.0.0.1:7877）。'
            '当前已退回直连。',
      );
    }
    return ProxyResolution.proxy(
      settings: s,
      host: host,
      port: s.port,
      sourceLabel: '手动 HTTP 代理',
    );
  }

  Future<ProxyResolution> _resolveSystem(
    ProxySettings s, {
    required bool allowDirectFallback,
  }) async {
    final SystemProxyInfo info = await detectSystemProxy();
    final ProxySettings effective = info.bypassLocalByDefault
        ? s.copyWith(bypassLocalhost: true)
        : s;

    if (!info.available) {
      return ProxyResolution.direct(
        settings: effective,
        sourceLabel: '读取系统代理失败',
        blockedReason: allowDirectFallback
            ? null
            : '读不到 Windows 代理设置（${info.error ?? '未知原因'}）。'
                  '请改用手动 HTTP 代理。',
        warning: allowDirectFallback ? '读不到系统代理设置，已退回直连。' : null,
      );
    }

    // WinHTTP 只在"启用了静态代理"时才返回 lpszProxy；
    // 注册表路径则由 ProxyEnable 决定。两条路径都已经折算进 [info.enabled]。
    final ProxyServerEntry? entry = info.parsed.preferredHttp;
    if (info.enabled && entry != null) {
      return ProxyResolution.proxy(
        settings: effective,
        host: entry.host,
        port: entry.port,
        sourceLabel: 'Windows 系统代理（${info.source}）',
        detectedFromSystem: true,
        warning: info.parsed.note,
      );
    }

    // 走到这里说明没有可用的静态 HTTP 代理。
    final String? pacNote = _pacNote(info);
    if (allowDirectFallback) {
      return ProxyResolution.direct(
        settings: effective,
        sourceLabel: '自动检测：未发现系统代理',
        warning: pacNote ?? (info.parsed.note ?? '未检测到系统代理，已退回直连。'),
      );
    }

    final String reason;
    if (pacNote != null) {
      reason = pacNote;
    } else if (info.parsed.hasSocksOnly) {
      reason =
          '系统代理只配置了 SOCKS 端口，不能直接作为 HTTP 代理使用。'
          '请在 Clash 中开启 System Proxy，或把 Mixed Port 填到手动 HTTP 代理里。';
    } else {
      reason =
          '未检测到 Windows 系统代理。请确认 Clash 已开启 "System Proxy"，'
          '或改为「手动 HTTP 代理」并填写 127.0.0.1:7877。';
    }
    return ProxyResolution.direct(
      settings: effective,
      sourceLabel: '跟随系统代理（未检测到）',
      blockedReason: reason,
    );
  }

  /// PAC / WPAD 的说明文本（本轮不支持，必须显式告知而不是静默误判）。
  String? _pacNote(SystemProxyInfo info) {
    if (info.hasPac) {
      return '检测到 PAC 自动配置脚本（${info.autoConfigUrl}），'
          'PetLife 暂不支持 PAC，已退回直连；'
          '请改用 Clash 的 System Proxy（静态 HTTP 代理）或手动填写代理地址。';
    }
    if (info.autoDetect) {
      return '检测到 Windows 启用了自动检测（WPAD），'
          'PetLife 暂不支持 PAC/WPAD，已退回直连；'
          '请改用 Clash 的 System Proxy（静态 HTTP 代理）或手动填写代理地址。';
    }
    return null;
  }
}
