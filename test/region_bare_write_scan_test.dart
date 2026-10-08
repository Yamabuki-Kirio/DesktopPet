// F·静态扫描测试：Region 原生写入的“唯一所有者”约束。
//
// 背景：本轮把过去散落在业务层的三条 Window Region 原生写入
// （`applyInteractionRegion` / `restorePetOnlyRegion` / `clearInteractionRegion`）
// 全部收敛到 `RegionCoordinator`。为了防止后续增量（例如增量 B 的正式 P3P 轮盘）
// 又出现“绕过协调器直接写 Region”的裸写，这里用一个静态扫描测试把约束固化下来：
//
//   除白名单文件外，`lib/**/*.dart` 中不得再出现这三个原生写入方法的**调用**。
//
// 白名单（这三个文件分别是：契约定义、唯一协调器、唯一原生适配器）：
//   * lib/menu/fixed_canvas_contract.dart      —— RegionNativeOps 接口与常量定义
//   * lib/menu/region_coordinator.dart         —— 唯一调用者
//   * lib/platform/windows/windows_surface_channel.dart —— 唯一原生适配器
//
// 注意：探针层存在同名族方法 `restorePetOnlyRegionNow(...)`（注意结尾是 `Now`），
// 它内部走协调器、不是原生裸写，因此匹配必须使用「方法名 + 左括号」的调用形态，
// 而不能用裸子串匹配。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许直接出现三条原生写入方法名（作为定义或被协调器调用）的文件，
/// 路径相对于包根的 `lib/`，统一使用 `/` 分隔。
const Set<String> _allowedLibFiles = <String>{
  'menu/fixed_canvas_contract.dart',
  'menu/region_coordinator.dart',
  'platform/windows/windows_surface_channel.dart',
};

/// 三条原生写入方法。匹配时统一加上「左括号」，避免误伤 `restorePetOnlyRegionNow`。
const List<String> _nativeWriteMethods = <String>[
  'applyInteractionRegion',
  'restorePetOnlyRegion',
  'clearInteractionRegion',
];

void main() {
  group('Region 原生写入静态扫描（F）', () {
    test('lib/ 下除白名单外不得出现三条原生写入调用', () {
      final Directory libDir = _resolveLibDirectory();
      final List<String> violations = <String>[];

      final List<File> dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

      expect(dartFiles, isNotEmpty,
          reason: '未在 ${libDir.path} 下扫描到任何 .dart 文件，扫描路径可能不正确');

      for (final File file in dartFiles) {
        final String relative = _relativeToLib(file.path, libDir.path);
        if (_allowedLibFiles.contains(relative)) {
          continue;
        }
        final String code = _stripComments(file.readAsStringSync());
        for (final String method in _nativeWriteMethods) {
          final RegExp callPattern = RegExp('\\b$method\\s*\\(');
          if (callPattern.hasMatch(code)) {
            violations.add('$relative -> $method(');
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '以下文件绕过了 RegionCoordinator 直接写 Window Region：\n'
            '${violations.join('\n')}\n'
            '业务层必须经 RegionCoordinator 提交，见 lib/menu/region_coordinator.dart。',
      );
    });

    test('白名单文件确实承载了三条原生写入（避免白名单变成空壳）', () {
      final Directory libDir = _resolveLibDirectory();
      final Map<String, String> codes = <String, String>{
        for (final String rel in _allowedLibFiles)
          rel: _stripComments(
              File('${libDir.path}${Platform.pathSeparator}'
                      '${rel.replaceAll('/', Platform.pathSeparator)}')
                  .readAsStringSync()),
      };

      // 契约文件必须定义三条方法名。
      final String contract = codes['menu/fixed_canvas_contract.dart']!;
      for (final String method in _nativeWriteMethods) {
        expect(contract.contains(method), isTrue,
            reason: 'RegionNativeOps 契约缺少 $method');
      }

      // 协调器必须真正调用三条原生方法（而不是空转发）。
      final String coordinator = codes['menu/region_coordinator.dart']!;
      for (final String method in _nativeWriteMethods) {
        expect(RegExp('\\b$method\\s*\\(').hasMatch(coordinator), isTrue,
            reason: 'RegionCoordinator 没有调用 $method，收敛链可能被架空');
      }

      // 原生适配器必须实现三条方法。
      final String channel =
          codes['platform/windows/windows_surface_channel.dart']!;
      for (final String method in _nativeWriteMethods) {
        expect(RegExp('\\b$method\\s*\\(').hasMatch(channel), isTrue,
            reason: 'Windows 原生适配器没有实现 $method');
      }
    });

    test('业务层（lib/ui/**）不得出现三条原生写入', () {
      final Directory libDir = _resolveLibDirectory();
      final Directory uiDir =
          Directory('${libDir.path}${Platform.pathSeparator}ui');
      if (!uiDir.existsSync()) {
        return;
      }
      final List<String> violations = <String>[];
      for (final File file
          in uiDir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) {
          continue;
        }
        final String relative = _relativeToLib(file.path, libDir.path);
        final String code = _stripComments(file.readAsStringSync());
        for (final String method in _nativeWriteMethods) {
          if (RegExp('\\b$method\\s*\\(').hasMatch(code)) {
            violations.add('$relative -> $method(');
          }
        }
      }
      expect(violations, isEmpty,
          reason: 'lib/ui 下出现 Region 原生裸写：\n${violations.join('\n')}');
    });
  });
}

/// 定位包根下的 `lib/` 目录：从当前工作目录向上寻找 `pubspec.yaml`。
Directory _resolveLibDirectory() {
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final File pubspec =
        File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    final Directory lib = Directory('${dir.path}${Platform.pathSeparator}lib');
    if (pubspec.existsSync() && lib.existsSync()) {
      return lib;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  // 兜底：直接使用相对路径。
  return Directory('lib');
}

String _relativeToLib(String filePath, String libPath) {
  String normalized = filePath.replaceAll('\\', '/');
  final String normalizedLib = libPath.replaceAll('\\', '/');
  if (normalized.startsWith('$normalizedLib/')) {
    normalized = normalized.substring(normalizedLib.length + 1);
  }
  return normalized;
}

/// 去掉 `//` 行注释与 `/* */` 块注释，保留字符串字面量（避免误伤 `http://`）。
///
/// 这是一个轻量词法扫描，不追求完整的 Dart 语法覆盖，只保证：
/// 注释里的方法名不会被当成调用；字符串里的 `//` 不会被当成注释起点。
String _stripComments(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  bool inLineComment = false;
  bool inBlockComment = false;
  bool inString = false;
  String quote = '';
  while (i < source.length) {
    final String ch = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';
    if (inLineComment) {
      if (ch == '\n') {
        inLineComment = false;
        out.write(ch);
      }
      i++;
      continue;
    }
    if (inBlockComment) {
      if (ch == '*' && next == '/') {
        inBlockComment = false;
        i += 2;
        continue;
      }
      if (ch == '\n') {
        out.write(ch);
      }
      i++;
      continue;
    }
    if (inString) {
      out.write(ch);
      if (ch == '\\') {
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      } else if (ch == quote) {
        inString = false;
      }
      i++;
      continue;
    }
    if (ch == '/' && next == '/') {
      inLineComment = true;
      i += 2;
      continue;
    }
    if (ch == '/' && next == '*') {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (ch == "'" || ch == '"') {
      inString = true;
      quote = ch;
      out.write(ch);
      i++;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}
