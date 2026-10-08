import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../core/logger.dart';
import '../startup_registrar.dart';

/// Windows 开机自启：当前用户的 `Run` 项。
///
/// 位置与名称
/// ----------
/// * 注册表路径：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
///   —— 用 **HKCU 而不是 HKLM**：不需要管理员权限，也只影响当前用户；
/// * 值名称：`PetLife`（固定，见 [defaultValueName]）。
///
/// 启动命令
/// --------
/// 值内容 = **当前正在运行的可执行文件的绝对路径**（由调用方传入，
/// 生产代码是 `Platform.resolvedExecutable`），并**始终用双引号包裹**：
/// `"C:\Program Files\PetLife\petlife.exe"`。
/// 路径含空格时 Windows 会按第一个空格切分命令行，不加引号会导致启动失败；
/// 无空格时加引号也完全合法，因此统一加，避免"有的机器行有的机器不行"。
///
/// 为什么不用 `win32` 包
/// --------------------
/// 本工程既有做法是**手写 FFI 绑定**（`win32_credential_native.dart`、
/// `win32_process_stats.dart`、`winhttp_system_proxy.dart` 都是），
/// 这里沿用同一风格，避免为一个功能引入新依赖。
///
/// 用的是 Vista 起就有的便捷 API（`RegSetKeyValueW` / `RegDeleteKeyValueW`），
/// 可以直接用预定义句柄 `HKEY_CURRENT_USER` 读写子键下的值，
/// 不需要 `RegOpenKeyEx` / `RegCloseKey` 成对管理句柄，减少句柄泄漏面。
class WindowsStartupRegistrar implements StartupRegistrar {
  const WindowsStartupRegistrar({this.valueName = defaultValueName});

  /// 启动项在 `Run` 下的固定名称。
  static const String defaultValueName = 'PetLife';

  /// `Run` 子键路径。
  static const String runKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  /// 值名称。保留成参数只是为了**测试**能用独立名称做真实注册表往返，
  /// 生产代码一律使用 [defaultValueName]。
  final String valueName;

  /// Windows 绝对路径：`C:\...` 或 UNC `\\server\share\...`。
  static final RegExp _absoluteWindowsPath = RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)');

  @override
  bool get isSupported => _Advapi32.instance != null;

  @override
  String? registeredCommand() {
    final _Advapi32? native = _Advapi32.instance;
    if (native == null) {
      throw const StartupRegistrationException(
        'advapi32.dll 不可用，无法读取开机自启状态',
      );
    }
    return native.readString(runKeyPath, valueName);
  }

  @override
  void enable(String executablePath) {
    final _Advapi32? native = _Advapi32.instance;
    if (native == null) {
      throw const StartupRegistrationException(
        'advapi32.dll 不可用，无法注册开机自启',
      );
    }

    final String command = buildCommand(executablePath);
    native.writeString(runKeyPath, valueName, command);
    Loggers.settings.info('开机自启已注册：$valueName = $command');
  }

  @override
  void disable() {
    final _Advapi32? native = _Advapi32.instance;
    if (native == null) {
      throw const StartupRegistrationException(
        'advapi32.dll 不可用，无法删除开机自启',
      );
    }
    native.deleteValue(runKeyPath, valueName);
    Loggers.settings.info('开机自启已移除：$valueName');
  }

  /// 生成写入 `Run` 项的启动命令。
  ///
  /// * 路径两端**始终加双引号**（处理空格 / 中文 / 括号等）；
  /// * 必须是绝对路径 —— 相对路径写进 `Run` 项在登录时的工作目录不确定，
  ///   会导致"注册成功但启动不了"，这里直接拒绝并给出明确原因；
  /// * 入参已经带引号时先剥掉再重新包一层，保证**幂等**，不会变成 `""C:\...""`。
  static String buildCommand(String executablePath) {
    String path = executablePath.trim();
    if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
      path = path.substring(1, path.length - 1).trim();
    }
    if (path.isEmpty) {
      throw const StartupRegistrationException('可执行文件路径为空，无法注册开机自启');
    }
    if (!_absoluteWindowsPath.hasMatch(path)) {
      throw StartupRegistrationException(
        '可执行文件路径不是绝对路径，拒绝写入启动项：$path',
      );
    }
    return '"$path"';
  }
}

/// `advapi32.dll` 的注册表读写封装（只做调用，不吞异常）。
class _Advapi32 {
  _Advapi32._(this._advapi32);

  final DynamicLibrary _advapi32;

  static _Advapi32? _instance;
  static bool _initialized = false;

  static _Advapi32? get instance {
    if (!_initialized) {
      _initialized = true;
      _instance = _tryCreate();
    }
    return _instance;
  }

  static _Advapi32? _tryCreate() {
    try {
      return _Advapi32._(DynamicLibrary.open('advapi32.dll'));
    } catch (e, st) {
      Loggers.settings.fine('advapi32.dll 不可用（无法操作开机自启注册表项）', e, st);
      return null;
    }
  }

  late final _RegSetKeyValueDart _regSetKeyValue =
      _advapi32.lookupFunction<_RegSetKeyValueNative, _RegSetKeyValueDart>(
    'RegSetKeyValueW',
  );

  late final _RegDeleteKeyValueDart _regDeleteKeyValue =
      _advapi32.lookupFunction<_RegDeleteKeyValueNative, _RegDeleteKeyValueDart>(
    'RegDeleteKeyValueW',
  );

  late final _RegGetValueDart _regGetValue =
      _advapi32.lookupFunction<_RegGetValueNative, _RegGetValueDart>(
    'RegGetValueW',
  );

  String? readString(String subKey, String name) {
    final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    final Pointer<Uint32> sizePtr = calloc<Uint32>();
    try {
      // 两段式：先问长度（此时不会写入数据），再按长度分配缓冲区。
      sizePtr.value = 0;
      final int probe = _regGetValue(
        _hkeyCurrentUser,
        subKeyPtr,
        namePtr,
        _rrfRtRegSz,
        nullptr,
        nullptr,
        sizePtr,
      );
      if (probe == _errorFileNotFound || probe == _errorPathNotFound) return null;
      if (probe != _errorSuccess) {
        throw StartupRegistrationException(
          '读取开机自启注册表项失败（Win32 错误码 $probe）',
        );
      }
      if (sizePtr.value == 0) return null;

      final Pointer<Uint8> buffer = calloc<Uint8>(sizePtr.value);
      try {
        final int ok = _regGetValue(
          _hkeyCurrentUser,
          subKeyPtr,
          namePtr,
          _rrfRtRegSz,
          nullptr,
          buffer.cast<Void>(),
          sizePtr,
        );
        if (ok != _errorSuccess) {
          throw StartupRegistrationException(
            '读取开机自启注册表项失败（Win32 错误码 $ok）',
          );
        }
        // REG_SZ 带结尾 NUL，toDartString 会在 NUL 处截断。
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

  void writeString(String subKey, String name, String value) {
    final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    final Pointer<Utf16> valuePtr = value.toNativeUtf16();
    try {
      // cbData 必须是**含结尾 NUL 的字节数**：Dart 的 String 以 UTF-16 码元计数，
      // 因此 (length + 1) * 2 对中文路径同样正确。
      final int byteLength = (value.length + 1) * 2;
      final int status = _regSetKeyValue(
        _hkeyCurrentUser,
        subKeyPtr,
        namePtr,
        _regSz,
        valuePtr.cast<Void>(),
        byteLength,
      );
      if (status != _errorSuccess) {
        throw StartupRegistrationException(
          '写入开机自启注册表项失败（Win32 错误码 $status）：$value',
        );
      }
    } finally {
      calloc
        ..free(valuePtr)
        ..free(namePtr)
        ..free(subKeyPtr);
    }
  }

  void deleteValue(String subKey, String name) {
    final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    try {
      final int status = _regDeleteKeyValue(_hkeyCurrentUser, subKeyPtr, namePtr);
      // 条目（或子键）本来就不存在时也算删除成功：删除必须是幂等的。
      if (status == _errorSuccess ||
          status == _errorFileNotFound ||
          status == _errorPathNotFound) {
        return;
      }
      throw StartupRegistrationException(
        '删除开机自启注册表项失败（Win32 错误码 $status）',
      );
    } finally {
      calloc
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

const int _errorSuccess = 0;

/// `ERROR_FILE_NOT_FOUND`（值不存在）。
const int _errorFileNotFound = 2;

/// `ERROR_PATH_NOT_FOUND`（子键不存在）。
const int _errorPathNotFound = 3;

/// `REG_SZ`。
const int _regSz = 1;

/// `RRF_RT_REG_SZ`。
const int _rrfRtRegSz = 0x00000002;

/// `LSTATUS RegSetKeyValueW(HKEY, LPCWSTR, LPCWSTR, DWORD, LPCVOID, DWORD)`
typedef _RegSetKeyValueNative = Int32 Function(
    IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Void>, Uint32);
typedef _RegSetKeyValueDart = int Function(
    int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int);

/// `LSTATUS RegDeleteKeyValueW(HKEY, LPCWSTR, LPCWSTR)`
typedef _RegDeleteKeyValueNative = Int32 Function(
    IntPtr, Pointer<Utf16>, Pointer<Utf16>);
typedef _RegDeleteKeyValueDart = int Function(
    int, Pointer<Utf16>, Pointer<Utf16>);

/// `LSTATUS RegGetValueW(HKEY, LPCWSTR, LPCWSTR, DWORD, DWORD*, LPVOID, DWORD*)`
typedef _RegGetValueNative = Int32 Function(IntPtr, Pointer<Utf16>,
    Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>);
typedef _RegGetValueDart = int Function(int, Pointer<Utf16>, Pointer<Utf16>,
    int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>);
