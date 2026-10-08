import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/logger.dart';
import '../../sync/credential_store.dart';

/// Windows 原生凭据能力（Dart FFI 直连）。
///
/// 两种后端：
///
/// | 后端 | API | 用途 |
/// |---|---|---|
/// | Windows Credential Manager | `CredWriteW` / `CredReadW` / `CredDeleteW` | **首选**，凭据由系统保管 |
/// | DPAPI | `CryptProtectData` / `CryptUnprotectData` | 回退，密文绑定当前 Windows 用户 |
///
/// 为什么优先 Credential Manager：凭据内容不出现在应用的任何文件里，
/// 用户在「凭据管理器」里可以直接看到并删除这条目，撤销路径最清晰。
///
/// **本类只做原生调用**，所有失败都返回 null / false，绝不抛出。
class Win32CredentialNative {
  Win32CredentialNative._(this._advapi32, this._crypt32, this._kernel32);

  final DynamicLibrary _advapi32;
  final DynamicLibrary _crypt32;
  final DynamicLibrary _kernel32;

  static Win32CredentialNative? _instance;
  static bool _initialized = false;

  static Win32CredentialNative? get instance {
    if (!_initialized) {
      _initialized = true;
      _instance = _tryCreate();
    }
    return _instance;
  }

  static Win32CredentialNative? _tryCreate() {
    try {
      return Win32CredentialNative._(
        DynamicLibrary.open('advapi32.dll'),
        DynamicLibrary.open('crypt32.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );
    } catch (e, st) {
      Loggers.credential.fine('Windows 凭据 API 不可用（将退化为文件后端）', e, st);
      return null;
    }
  }

  // --- Credential Manager ---

  late final _CredWriteDart _credWrite =
      _advapi32.lookupFunction<_CredWriteNative, _CredWriteDart>('CredWriteW');

  late final _CredReadDart _credRead =
      _advapi32.lookupFunction<_CredReadNative, _CredReadDart>('CredReadW');

  late final _CredDeleteDart _credDelete =
      _advapi32.lookupFunction<_CredDeleteNative, _CredDeleteDart>('CredDeleteW');

  late final _CredFreeDart _credFree =
      _advapi32.lookupFunction<_CredFreeNative, _CredFreeDart>('CredFree');

  // --- DPAPI ---

  late final _CryptProtectDart _cryptProtect = _crypt32
      .lookupFunction<_CryptProtectNative, _CryptProtectDart>('CryptProtectData');

  late final _CryptUnprotectDart _cryptUnprotect = _crypt32
      .lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>('CryptUnprotectData');

  late final _LocalFreeDart _localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  /// 写入一条通用凭据。
  bool writeGeneric(String target, String secret, {String userName = 'petlife'}) {
    try {
      final Uint8List blobBytes = Uint8List.fromList(utf8.encode(secret));
      if (blobBytes.isEmpty || blobBytes.length > _maxBlobBytes) {
        Loggers.credential.warning(
          '凭据长度超出 Windows 上限（${blobBytes.length} > $_maxBlobBytes），'
          '将退化为文件后端',
        );
        return false;
      }

      final Pointer<Utf16> targetPtr = target.toNativeUtf16();
      final Pointer<Utf16> userPtr = userName.toNativeUtf16();
      final Pointer<Uint8> blobPtr = calloc<Uint8>(blobBytes.length);
      final Pointer<_CredentialW> cred = calloc<_CredentialW>();
      try {
        blobPtr.asTypedList(blobBytes.length).setAll(0, blobBytes);

        cred.ref
          ..flags = 0
          ..type = _credTypeGeneric
          ..targetName = targetPtr.address
          ..comment = nullptr.address
          ..lastWritten = 0
          ..credentialBlobSize = blobBytes.length
          ..credentialBlob = blobPtr.address
          ..persist = _credPersistLocalMachine
          ..attributeCount = 0
          ..attributes = nullptr.address
          ..targetAlias = nullptr.address
          ..userName = userPtr.address;

        final int ok = _credWrite(cred, 0);
        if (ok == 0) {
          Loggers.credential.fine('CredWriteW 失败（GetLastError=${_lastError()}）');
          return false;
        }
        return true;
      } finally {
        calloc
          ..free(cred)
          ..free(blobPtr)
          ..free(targetPtr)
          ..free(userPtr);
      }
    } catch (e, st) {
      Loggers.credential.fine('写入 Windows 凭据失败: $target', e, st);
      return false;
    }
  }

  /// 读取一条通用凭据；不存在或失败时返回 null。
  String? readGeneric(String target) {
    try {
      final Pointer<Utf16> targetPtr = target.toNativeUtf16();
      final Pointer<Pointer<_CredentialW>> outPtr = calloc<Pointer<_CredentialW>>();
      try {
        final int ok = _credRead(targetPtr, _credTypeGeneric, 0, outPtr);
        if (ok == 0 || outPtr.value == nullptr) return null;

        final Pointer<_CredentialW> cred = outPtr.value;
        try {
          final int size = cred.ref.credentialBlobSize;
          final int blobAddr = cred.ref.credentialBlob;
          if (size <= 0 || blobAddr == 0) return null;
          final Pointer<Uint8> blobPtr = Pointer<Uint8>.fromAddress(blobAddr);
          final Uint8List bytes = blobPtr.asTypedList(size);
          return utf8.decode(bytes, allowMalformed: true);
        } finally {
          _credFree(cred);
        }
      } finally {
        calloc
          ..free(outPtr)
          ..free(targetPtr);
      }
    } catch (e, st) {
      Loggers.credential.fine('读取 Windows 凭据失败: $target', e, st);
      return null;
    }
  }

  /// 删除一条通用凭据。返回 true 表示删除成功或本来就不存在。
  bool deleteGeneric(String target) {
    try {
      final Pointer<Utf16> targetPtr = target.toNativeUtf16();
      try {
        final int ok = _credDelete(targetPtr, _credTypeGeneric, 0);
        if (ok != 0) return true;
        // ERROR_NOT_FOUND(1168)：本来就没有，视为成功（删除应当幂等）
        return _lastError() == 1168;
      } finally {
        calloc.free(targetPtr);
      }
    } catch (e, st) {
      Loggers.credential.fine('删除 Windows 凭据失败: $target', e, st);
      return false;
    }
  }

  /// DPAPI 加密（用户范围，绑定当前 Windows 用户）。
  Uint8List? protect(Uint8List plain) => _dpapi(plain, encrypt: true);

  /// DPAPI 解密。
  Uint8List? unprotect(Uint8List cipher) => _dpapi(cipher, encrypt: false);

  Uint8List? _dpapi(Uint8List input, {required bool encrypt}) {
    if (input.isEmpty) return null;
    try {
      final Pointer<Uint8> inBytes = calloc<Uint8>(input.length);
      final Pointer<_DataBlob> inBlob = calloc<_DataBlob>();
      final Pointer<_DataBlob> outBlob = calloc<_DataBlob>();
      try {
        inBytes.asTypedList(input.length).setAll(0, input);
        inBlob.ref
          ..cbData = input.length
          ..pbData = inBytes.address;

        final int ok = encrypt
            ? _cryptProtect(
                inBlob,
                nullptr,
                nullptr,
                nullptr,
                nullptr,
                _cryptprotectUiForbidden,
                outBlob,
              )
            : _cryptUnprotect(
                inBlob,
                nullptr,
                nullptr,
                nullptr,
                nullptr,
                _cryptprotectUiForbidden,
                outBlob,
              );
        if (ok == 0) {
          Loggers.credential.fine(
            'DPAPI ${encrypt ? '加密' : '解密'}失败（GetLastError=${_lastError()}）',
          );
          return null;
        }

        final int size = outBlob.ref.cbData;
        final int addr = outBlob.ref.pbData;
        if (size <= 0 || addr == 0) return null;
        final Uint8List result =
            Uint8List.fromList(Pointer<Uint8>.fromAddress(addr).asTypedList(size));
        _localFree(addr);
        return result;
      } finally {
        calloc
          ..free(outBlob)
          ..free(inBlob)
          ..free(inBytes);
      }
    } catch (e, st) {
      Loggers.credential.fine('DPAPI 调用失败', e, st);
      return null;
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

/// Windows Credential Manager 后端。
class WindowsCredentialManagerStore implements CredentialStore {
  const WindowsCredentialManagerStore();

  @override
  String get backendName => 'Windows Credential Manager';

  Win32CredentialNative? get _native => Win32CredentialNative.instance;

  @override
  bool get isAvailable => _native != null;

  @override
  Future<void> write(String key, String secret) async {
    final Win32CredentialNative? native = _native;
    if (native == null) {
      throw CredentialStoreException('Windows 凭据 API 不可用');
    }
    if (!native.writeGeneric(key, secret)) {
      // 不把 secret 放进异常信息
      throw CredentialStoreException('写入 Windows 凭据失败（key=$key）');
    }
    Loggers.credential.info('凭据已写入 Windows Credential Manager: $key');
  }

  @override
  Future<String?> read(String key) async => _native?.readGeneric(key);

  @override
  Future<void> delete(String key) async {
    _native?.deleteGeneric(key);
    Loggers.credential.info('凭据已从 Windows Credential Manager 删除: $key');
  }
}

// -----------------------------------------------------------------------------
// FFI 绑定
// -----------------------------------------------------------------------------

const int _credTypeGeneric = 1;
const int _credPersistLocalMachine = 2;
const int _cryptprotectUiForbidden = 0x1;

/// CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512
const int _maxBlobBytes = 2560;

/// `CREDENTIALW`（x64 布局）。
final class _CredentialW extends Struct {
  @Uint32()
  external int flags;

  @Uint32()
  external int type;

  @IntPtr()
  external int targetName;

  @IntPtr()
  external int comment;

  /// FILETIME：两个 DWORD 合成 8 字节。
  @Uint64()
  external int lastWritten;

  @Uint32()
  external int credentialBlobSize;

  @IntPtr()
  external int credentialBlob;

  @Uint32()
  external int persist;

  @Uint32()
  external int attributeCount;

  @IntPtr()
  external int attributes;

  @IntPtr()
  external int targetAlias;

  @IntPtr()
  external int userName;
}

/// `DATA_BLOB`。
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  @IntPtr()
  external int pbData;
}

typedef _CredWriteNative = Int32 Function(Pointer<_CredentialW>, Uint32);
typedef _CredWriteDart = int Function(Pointer<_CredentialW>, int);

typedef _CredReadNative = Int32 Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Pointer<_CredentialW>>);
typedef _CredReadDart = int Function(
    Pointer<Utf16>, int, int, Pointer<Pointer<_CredentialW>>);

typedef _CredDeleteNative = Int32 Function(Pointer<Utf16>, Uint32, Uint32);
typedef _CredDeleteDart = int Function(Pointer<Utf16>, int, int);

typedef _CredFreeNative = Void Function(Pointer<_CredentialW>);
typedef _CredFreeDart = void Function(Pointer<_CredentialW>);

typedef _CryptProtectNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptProtectDart = int Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);

typedef _CryptUnprotectNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<IntPtr>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptUnprotectDart = int Function(
    Pointer<_DataBlob>,
    Pointer<IntPtr>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);

typedef _LocalFreeNative = IntPtr Function(IntPtr);
typedef _LocalFreeDart = int Function(int);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
