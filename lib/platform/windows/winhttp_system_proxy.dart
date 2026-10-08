import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../core/logger.dart';
// 本文件既要使用这些类型（import），也要把它们转出去给原来的调用方（export）。
import '../../sync/proxy/system_proxy.dart';

export '../../sync/proxy/system_proxy.dart';

/// 读取 Windows 当前用户代理配置。
///
/// 优先级：
/// 1. **WinHTTP** `WinHttpGetIEProxyConfigForCurrentUser`（一次拿到
///    `fAutoDetect` / `AutoConfigURL` / `ProxyServer` / `ProxyBypass`，
///    这正是 Clash 勾选 "System Proxy" 时写入的那份配置）；
/// 2. 失败时回退到**注册表** `HKCU\...\Internet Settings`
///    的 `ProxyEnable` / `ProxyServer` / `ProxyOverride` / `AutoConfigURL`。
///
/// 两条路径都只读、不改动任何系统设置。
class WinHttpSystemProxyReader implements SystemProxyReader {
  const WinHttpSystemProxyReader();

  @override
  SystemProxyInfo read() {
    final SystemProxyInfo? viaWinHttp = _WinHttpNative.instance?.readCurrentUserIeProxy();
    if (viaWinHttp != null && viaWinHttp.available) return viaWinHttp;

    final SystemProxyInfo? viaRegistry = _RegistryNative.instance?.readIeProxySettings();
    if (viaRegistry != null && viaRegistry.available) return viaRegistry;

    return SystemProxyInfo(
      source: '不可用',
      available: false,
      error: viaWinHttp?.error ?? viaRegistry?.error ?? '读取 Windows 代理设置失败',
    );
  }
}

/// `WinHttpGetIEProxyConfigForCurrentUser` 的 Dart 侧封装。
///
/// 只做原生调用，失败返回带 [SystemProxyInfo.error] 的结果，绝不抛出。
class _WinHttpNative {
  _WinHttpNative._(this._winhttp, this._kernel32);

  final DynamicLibrary _winhttp;
  final DynamicLibrary _kernel32;

  static _WinHttpNative? _instance;
  static bool _initialized = false;

  static _WinHttpNative? get instance {
    if (!_initialized) {
      _initialized = true;
      _instance = _tryCreate();
    }
    return _instance;
  }

  static _WinHttpNative? _tryCreate() {
    try {
      return _WinHttpNative._(
        DynamicLibrary.open('winhttp.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );
    } catch (e, st) {
      Loggers.proxy.fine('winhttp.dll 不可用（将回退读取注册表）', e, st);
      return null;
    }
  }

  late final _GetIeProxyConfigDart _getIeProxyConfig = _winhttp.lookupFunction<
      _GetIeProxyConfigNative, _GetIeProxyConfigDart>(
    'WinHttpGetIEProxyConfigForCurrentUser',
  );

  /// WinHTTP 返回的字符串由系统分配，**必须用 GlobalFree 释放**。
  late final _GlobalFreeDart _globalFree =
      _kernel32.lookupFunction<_GlobalFreeNative, _GlobalFreeDart>('GlobalFree');

  SystemProxyInfo readCurrentUserIeProxy() {
    final Pointer<_WinHttpIeProxyConfig> config = calloc<_WinHttpIeProxyConfig>();
    try {
      final int ok = _getIeProxyConfig(config);
      if (ok == 0) {
        return SystemProxyInfo(
          source: 'WinHTTP',
          available: false,
          error: 'WinHttpGetIEProxyConfigForCurrentUser 返回失败（GetLastError=${_lastError()}）',
        );
      }

      final String? pac = _takeString(config.ref.autoConfigUrl);
      final String? proxy = _takeString(config.ref.proxy);
      final String? bypass = _takeString(config.ref.proxyBypass);
      final bool autoDetect = config.ref.autoDetect != 0;

      // WinHTTP 的 lpszProxy 只有在"启用了静态代理"时才有值，
      // 因此 hasStaticProxy 本身就等价于 ProxyEnable=1。
      return SystemProxyInfo(
        source: 'WinHTTP',
        available: true,
        enabled: proxy != null && proxy.isNotEmpty,
        autoDetect: autoDetect,
        autoConfigUrl: pac,
        proxyServer: proxy,
        proxyBypass: bypass,
      );
    } catch (e, st) {
      Loggers.proxy.fine('WinHTTP 读取代理配置失败', e, st);
      return SystemProxyInfo(source: 'WinHTTP', available: false, error: '$e');
    } finally {
      calloc.free(config);
    }
  }

  /// 把 LPWSTR 复制成 Dart 字符串并立刻 `GlobalFree`。
  String? _takeString(int address) {
    if (address == 0) return null;
    try {
      final String value = Pointer<Utf16>.fromAddress(address).toDartString();
      final String trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    } finally {
      _globalFree(address);
    }
  }

  int _lastError() {
    try {
      return _getLastError();
    } catch (_) {
      return 0;
    }
  }

  late final _GetLastErrorDart _getLastError =
      _kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
}

/// 注册表回退读取（`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`）。
class _RegistryNative {
  _RegistryNative._(this._advapi32);

  final DynamicLibrary _advapi32;

  static _RegistryNative? _instance;
  static bool _initialized = false;

  static _RegistryNative? get instance {
    if (!_initialized) {
      _initialized = true;
      _instance = _tryCreate();
    }
    return _instance;
  }

  static _RegistryNative? _tryCreate() {
    try {
      return _RegistryNative._(DynamicLibrary.open('advapi32.dll'));
    } catch (e, st) {
      Loggers.proxy.fine('advapi32.dll 不可用（无法读取注册表代理设置）', e, st);
      return null;
    }
  }

  static const String _subKey =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  late final _RegGetValueDart _regGetValue =
      _advapi32.lookupFunction<_RegGetValueNative, _RegGetValueDart>('RegGetValueW');

  SystemProxyInfo readIeProxySettings() {
    try {
      final int enable = _getDword('ProxyEnable') ?? 0;
      final String? proxy = _getString('ProxyServer');
      final String? bypass = _getString('ProxyOverride');
      final String? pac = _getString('AutoConfigURL');

      return SystemProxyInfo(
        source: '注册表',
        available: true,
        enabled: enable != 0,
        autoDetect: false,
        autoConfigUrl: pac,
        proxyServer: proxy,
        proxyBypass: bypass,
      );
    } catch (e, st) {
      Loggers.proxy.fine('读取注册表代理设置失败', e, st);
      return SystemProxyInfo(source: '注册表', available: false, error: '$e');
    }
  }

  String? _getString(String name) {
    // 两段式调用：先问长度，再分配缓冲区。
    final Pointer<Utf16> subKeyPtr = _subKey.toNativeUtf16();
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    final Pointer<Uint32> sizePtr = calloc<Uint32>();
    try {
      sizePtr.value = 0;
      final int probe = _regGetValue(
        _hkeyCurrentUser,
        subKeyPtr.address,
        namePtr.address,
        _rrfRtRegSz,
        nullptr,
        nullptr,
        sizePtr,
      );
      if (probe != 0 || sizePtr.value == 0) return null;

      final int byteLength = sizePtr.value;
      final Pointer<Uint8> buffer = calloc<Uint8>(byteLength);
      try {
        final int ok = _regGetValue(
          _hkeyCurrentUser,
          subKeyPtr.address,
          namePtr.address,
          _rrfRtRegSz,
          nullptr,
          buffer.cast<Void>(),
          sizePtr,
        );
        if (ok != 0) return null;
        final String value = buffer.cast<Utf16>().toDartString().trim();
        return value.isEmpty ? null : value;
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc
        ..free(sizePtr)
        ..free(namePtr)
        ..free(subKeyPtr);
    }
  }

  int? _getDword(String name) {
    final Pointer<Utf16> subKeyPtr = _subKey.toNativeUtf16();
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    final Pointer<Uint32> out = calloc<Uint32>();
    final Pointer<Uint32> sizePtr = calloc<Uint32>();
    try {
      sizePtr.value = 4;
      final int ok = _regGetValue(
        _hkeyCurrentUser,
        subKeyPtr.address,
        namePtr.address,
        _rrfRtRegDword,
        nullptr,
        out.cast<Void>(),
        sizePtr,
      );
      return ok == 0 ? out.value : null;
    } finally {
      calloc
        ..free(sizePtr)
        ..free(out)
        ..free(namePtr)
        ..free(subKeyPtr);
    }
  }
}

// -----------------------------------------------------------------------------
// FFI 绑定
// -----------------------------------------------------------------------------

/// `HKEY_CURRENT_USER` 的固定句柄值。
const int _hkeyCurrentUser = 0x80000001;

/// `RRF_RT_REG_SZ`。
const int _rrfRtRegSz = 0x00000002;

/// `RRF_RT_REG_DWORD`。
const int _rrfRtRegDword = 0x00000010;

/// `WINHTTP_CURRENT_USER_IE_PROXY_CONFIG`。
final class _WinHttpIeProxyConfig extends Struct {
  /// BOOL
  @Int32()
  external int autoDetect;

  /// LPWSTR（此 4 字节后的对齐填充由 Dart FFI 自动处理）
  @IntPtr()
  external int autoConfigUrl;

  @IntPtr()
  external int proxy;

  @IntPtr()
  external int proxyBypass;
}

typedef _GetIeProxyConfigNative = Int32 Function(Pointer<_WinHttpIeProxyConfig>);
typedef _GetIeProxyConfigDart = int Function(Pointer<_WinHttpIeProxyConfig>);

typedef _GlobalFreeNative = IntPtr Function(IntPtr);
typedef _GlobalFreeDart = int Function(int);

typedef _RegGetValueNative = Int32 Function(
    IntPtr, IntPtr, IntPtr, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>);
typedef _RegGetValueDart = int Function(
    int, int, int, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
