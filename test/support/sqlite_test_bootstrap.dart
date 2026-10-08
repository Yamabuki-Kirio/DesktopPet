import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 让 `flutter test` 进程能加载到 sqlite3 原生库。
///
/// ## 为什么需要这个
///
/// `sqlite3` 3.6 走 native assets 的 `DynamicLoadingSystem`，
/// 运行期按**名字**加载库（Windows 下等价于 `LoadLibraryW("sqlite3.dll")`）。
/// 而 `pubspec.yaml` 里配置的是 `source: system`，表示「由系统提供」：
/// 打包后的应用之所以能用，是因为 `sqlite3_flutter_libs` 会把 `sqlite3.dll`
/// 放在 `petlife.exe` 同级目录，正好命中 DLL 搜索路径的第一顺位。
///
/// 但测试宿主 `flutter_tester.exe` 位于 Flutter SDK 缓存目录里，旁边没有这个 DLL，
/// 于是裸跑测试会直接失败：
///
/// ```
/// Failed to load dynamic library 'sqlite3.dll' (error code: 126)
/// ```
///
/// ## 对策
///
/// 1. 找一个可用的 sqlite3 原生库（构建产物优先，Windows 自带 `winsqlite3.dll` 兜底）；
/// 2. 统一**改名为 `sqlite3.dll`** 放进临时目录 —— 名字必须一致，
///    native assets 就是按这个名字加载的，`winsqlite3.dll` 原名加载不到；
/// 3. 用 `SetDllDirectoryW` 把该目录加进 DLL 搜索路径。
///
/// 全程不需要修改工程或 SDK 目录，可重复执行且幂等。
///
/// ## 暂存目录必须按进程隔离
///
/// `flutter test` 会**并发**跑多个测试文件，每个文件是独立的 `flutter_tester` 进程。
/// 若所有进程共用一个暂存目录，就会出现「A 已把 `sqlite3.dll` 拷好（并已加载），
/// B 再往同一个路径拷」的竞争，Windows 直接报错：
///
/// ```
/// PathExistsException: Cannot copy file to '...\petlife_test_sqlite3\sqlite3.dll'
///   (OS Error: 当文件已存在时，无法创建该文件。, errno = 183)
/// ```
///
/// 因此暂存目录名带上进程 ID + 时间戳，每个测试进程各用一份；
/// 目录内已经存在同名文件时直接跳过复制（本进程内保证幂等）。
class SqliteTestBootstrap {
  SqliteTestBootstrap._();

  static bool _initialized = false;
  static String? _resolvedSourcePath;

  /// 实际使用的原生库源文件路径（便于测试打印与排错）。
  static String? get resolvedLibraryPath => _resolvedSourcePath;

  /// 临时暂存目录（`sqlite3.dll` 就在这里）。
  static String? get stagingDirectory => _stagingDir?.path;
  static Directory? _stagingDir;

  /// 候选原生库，按优先级排列。
  static List<String> _candidates() {
    final List<String> candidates = <String>[];

    // 1) 显式指定优先，便于在别的机器/CI 上手工兜底。
    final String? fromEnv = Platform.environment['PETLIFE_SQLITE3_DLL'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      candidates.add(fromEnv.trim());
    }

    // 2) 本工程的 Release 构建产物（flutter build windows --release）。
    Directory dir = Directory.current;
    for (int i = 0; i < 5; i++) {
      candidates.add(
        p.join(dir.path, 'build', 'windows', 'x64', 'runner', 'Release', 'sqlite3.dll'),
      );
      dir = dir.parent;
    }

    // 3) 兜底：Windows 自带的 SQLite（导出标准 sqlite3_* 符号）。
    final String systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    candidates.add(p.join(systemRoot, 'System32', 'winsqlite3.dll'));

    return candidates;
  }

  /// 幂等地完成引导，返回所用原生库的路径。
  ///
  /// 失败时抛 [StateError] 并列出所有尝试过的候选路径 —— 不要静默跳过，
  /// 否则「数据库相关测试全部消失」会被误读成「全部通过」。
  static String ensureLoaded() {
    final String? done = _resolvedSourcePath;
    if (_initialized && done != null) return done;

    File? source;
    final List<String> tried = <String>[];
    for (final String candidate in _candidates()) {
      tried.add(candidate);
      final File f = File(candidate);
      if (f.existsSync()) {
        source = f;
        break;
      }
    }

    if (source == null) {
      throw StateError(
        '找不到 sqlite3 原生库，无法运行数据库测试。已尝试：\n'
        '${tried.map((String s) => '  - $s').join('\n')}\n'
        '请先执行 `flutter build windows --release`（会生成 sqlite3.dll），'
        '或用环境变量 PETLIFE_SQLITE3_DLL 指定库文件路径。',
      );
    }

    // 名字必须规范化成 sqlite3.dll，见类文档说明。
    // 目录名带 pid + 时间戳：flutter test 并发跑多个测试进程，不能共用一份暂存。
    final Directory staging = Directory(
      p.join(
        Directory.systemTemp.path,
        'petlife_test_sqlite3_${pid}_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    if (!staging.existsSync()) {
      staging.createSync(recursive: true);
    }
    final File staged = File(p.join(staging.path, 'sqlite3.dll'));
    // 同进程重复调用已在上面 return；这里的判断是防御性的。
    if (!staged.existsSync()) {
      source.copySync(staged.path);
    }

    _addToDllSearchPath(staging.path);

    // native assets 的解析是在首次真正用到符号时发生的，这里提前触发，
    // 让加载失败尽早暴露（而不是在某个断言中间炸出来）。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    _stagingDir = staging;
    _resolvedSourcePath = source.path;
    _initialized = true;
    return source.path;
  }

  static void _addToDllSearchPath(String directory) {
    final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
    final int Function(Pointer<Utf16>) setDllDirectory = kernel32
        .lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
      'SetDllDirectoryW',
    );

    final Pointer<Utf16> pathPtr = directory.toNativeUtf16();
    try {
      final int ok = setDllDirectory(pathPtr);
      if (ok == 0) {
        throw StateError('SetDllDirectoryW 调用失败，无法注册 DLL 搜索目录：$directory');
      }
    } finally {
      calloc.free(pathPtr);
    }
  }
}
