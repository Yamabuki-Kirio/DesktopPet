import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/logger.dart';
import '../../sync/credential_store.dart';
import 'win32_credential_native.dart';

/// DPAPI 文件后端（Windows Credential Manager 不可用时的回退）。
///
/// 做法：把凭据用 **DPAPI（用户范围）** 加密后写入
/// `<AppData>/PetLife/credentials/<key>.bin`。
///
/// 为什么用户范围就够：`CryptProtectData` 默认使用当前登录用户的凭据作为密钥，
/// **只有同一台机器上的同一个 Windows 用户**才能解密。别的用户、
/// 或者把文件拷到别的机器，都解不开。
///
/// 为什么不用 SQLite 存密文：这样本地数据库里连"一段可疑的密文"都不会有，
/// 数据库可以随意备份/导出去排查使用统计问题，不必担心夹带凭据。
class DpapiFileCredentialStore implements CredentialStore {
  DpapiFileCredentialStore({required this.directory});

  final Directory directory;

  @override
  String get backendName => 'DPAPI（用户范围，文件密文）';

  Win32CredentialNative? get _native => Win32CredentialNative.instance;

  @override
  bool get isAvailable => _native != null;

  File _fileFor(String key) => File(p.join(directory.path, '${_safeName(key)}.bin'));

  /// 凭据条目名是固定的几个常量，这里仍做一次转义以防未来出现路径穿越。
  static String _safeName(String key) =>
      key.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  @override
  Future<void> write(String key, String secret) async {
    final Win32CredentialNative? native = _native;
    if (native == null) {
      throw const CredentialStoreException('DPAPI 不可用（crypt32.dll 加载失败）');
    }
    final Uint8List? cipher =
        native.protect(Uint8List.fromList(utf8.encode(secret)));
    if (cipher == null) {
      throw CredentialStoreException('DPAPI 加密失败（key=$key）');
    }
    await directory.create(recursive: true);
    await _fileFor(key).writeAsBytes(cipher, flush: true);
    Loggers.credential.info('凭据已用 DPAPI 加密写入本地文件: ${_fileFor(key).path}');
  }

  @override
  Future<String?> read(String key) async {
    final Win32CredentialNative? native = _native;
    if (native == null) return null;
    final File file = _fileFor(key);
    if (!await file.exists()) return null;
    try {
      final Uint8List cipher = await file.readAsBytes();
      final Uint8List? plain = native.unprotect(cipher);
      if (plain == null) {
        // 换了 Windows 用户 / 文件损坏：当作没有凭据，并清掉这个不可用文件
        Loggers.credential.warning('DPAPI 解密失败，将清理无效凭据文件（需要重新登录）');
        await delete(key);
        return null;
      }
      return utf8.decode(plain, allowMalformed: true);
    } catch (e, st) {
      Loggers.credential.warning('读取 DPAPI 凭据文件失败', e, st);
      return null;
    }
  }

  @override
  Future<void> delete(String key) async {
    final File file = _fileFor(key);
    try {
      if (await file.exists()) {
        // 先覆盖再删除，降低被文件系统恢复软件捞回的概率
        final int length = await file.length();
        await file.writeAsBytes(Uint8List(length), flush: true);
        await file.delete();
      }
      Loggers.credential.info('DPAPI 凭据文件已删除');
    } catch (e, st) {
      Loggers.credential.warning('删除 DPAPI 凭据文件失败', e, st);
    }
  }
}
