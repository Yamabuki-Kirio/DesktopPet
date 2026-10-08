import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'constants.dart';

/// 应用数据目录解析。
///
/// 目录布局（全部位于系统 AppData，绝不写入用户素材源目录）：
/// ```
/// <ApplicationSupport>/PetLife/
///   ├── petlife.db
///   ├── logs/petlife.log
///   ├── index/                 # 自动生成的素材索引导出（可选）
///   ├── assets/<ownerId>/<packSlug>/<characterSlug>/<file>
///   ├── credentials/           # 仅当退回 DPAPI 后端时存放加密后的凭据密文
///   └── tmp/                   # 导入临时解压目录
/// ```
class AppPaths {
  AppPaths._(this.root);

  final Directory root;

  static AppPaths? _instance;

  /// 已初始化的实例；使用前必须先调用 [initialize]。
  static AppPaths get instance {
    final AppPaths? i = _instance;
    if (i == null) {
      throw StateError('AppPaths 未初始化，请先 await AppPaths.initialize()');
    }
    return i;
  }

  static bool get isInitialized => _instance != null;

  /// 初始化（幂等）。
  static Future<AppPaths> initialize({Directory? overrideRoot}) async {
    final AppPaths? existing = _instance;
    if (existing != null) return existing;

    final Directory base =
        overrideRoot ?? Directory(p.join((await getApplicationSupportDirectory()).path, AppConstants.appDataFolder));
    final AppPaths paths = AppPaths._(base);
    await base.create(recursive: true);
    await paths.assetsRoot.create(recursive: true);
    await paths.logsDir.create(recursive: true);
    await paths.tmpDir.create(recursive: true);
    await paths.indexDir.create(recursive: true);
    // credentials 目录不主动创建：只有真的退回 DPAPI 后端时才需要它，
    // 没用到就不该在用户目录里留下一个空文件夹。
    _instance = paths;
    return paths;
  }

  /// 仅测试使用：重置单例。
  static void resetForTest() => _instance = null;

  File get databaseFile => File(p.join(root.path, AppConstants.databaseFileName));

  File get logFile => File(p.join(logsDir.path, AppConstants.logFileName));

  Directory get logsDir => Directory(p.join(root.path, 'logs'));

  Directory get assetsRoot => Directory(p.join(root.path, 'assets'));

  Directory get indexDir => Directory(p.join(root.path, 'index'));

  /// 凭据密文目录（仅在 DPAPI 回退后端下使用）。
  Directory get credentialsDir => Directory(p.join(root.path, 'credentials'));

  Directory get tmpDir => Directory(p.join(root.path, 'tmp'));

  /// 某个用户的素材根目录。
  Directory assetsRootFor(String ownerId) =>
      Directory(p.join(assetsRoot.path, _slug(ownerId)));

  /// 某个作品包的托管目录。
  ///
  /// 用户原始素材永远不会被写入，导入时复制到此处，删除也只删这里。
  Directory packDir(String ownerId, String packName) => Directory(
        p.join(assetsRootFor(ownerId).path, _slug(packName)),
      );

  /// 某个角色的托管目录。
  Directory characterDir(String ownerId, String packName, String characterName) => Directory(
        p.join(packDir(ownerId, packName).path, _slug(characterName)),
      );

  /// 把名称转成安全的目录片段：去掉路径分隔符与保留字符，避免路径穿越。
  static String _slug(String raw) {
    final String cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'^\.+'), '_')
        .trim();
    final String trimmed = cleaned.isEmpty ? 'unnamed' : cleaned;
    return trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
  }

  /// 对外暴露的 slug 规则（导入时需要用同一套逻辑保证幂等）。
  static String slug(String raw) => _slug(raw);
}
