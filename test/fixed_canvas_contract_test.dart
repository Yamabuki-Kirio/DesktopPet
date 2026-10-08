import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart' show PhysicalRect;

/// 固定画布 + Region 的**契约 / 协议 / 硬断言**单测（纯 Dart）。
void main() {
  group('方案开关（旧方案默认关闭且已标记 rejected）', () {
    test('旧"动态 setBounds"探针默认 OFF 且状态为 rejected', () {
      expect(PetWindowProbeFlags.dynamicSetBoundsProbeEnabled, isFalse);
      expect(
        PetWindowProbeApproach.dynamicSetBoundsRejected.wireName,
        'dynamic_set_bounds_rejected',
      );
    });

    test('当前生效路线为固定画布 + Region', () {
      expect(PetWindowProbeFlags.fixedCanvasRegionProbeEnabled, isTrue);
      expect(PetWindowProbeFlags.activeApproach,
          PetWindowProbeApproach.fixedCanvasRegion);
      expect(PetWindowProbeFlags.activeApproach.wireName, 'fixed_canvas_region');
    });
  });

  group('区域应用结果解析（宽容，绝不谎报成功）', () {
    test('成功：解析 success / rectCount / boundingBox', () {
      final RegionApplyResult r = RegionApplyResult.fromMap(<String, Object?>{
        'success': true,
        'rectCount': 2,
        'boundingBox': <String, Object?>{
          'left': 100,
          'top': 50,
          'right': 700,
          'bottom': 500,
        },
      });
      expect(r.success, isTrue);
      expect(r.rectCount, 2);
      expect(r.boundingBox, const PhysicalRect(100, 50, 700, 500));
    });

    test('缺键 / 坏类型 → 失败，不抛错', () {
      for (final Object? bad in <Object?>[
        null,
        'oops',
        <String, Object?>{},
        <String, Object?>{'success': 'yes'},
      ]) {
        expect(RegionApplyResult.fromMap(bad).success, isFalse, reason: '输入：$bad');
      }
    });

    test('boundingBox 缺键 → null，但整体仍成功', () {
      final RegionApplyResult r =
          RegionApplyResult.fromMap(<String, Object?>{'success': true});
      expect(r.success, isTrue);
      expect(r.boundingBox, isNull);
    });
  });

  group('探针诊断快照与复制文本', () {
    test('全部冻结键都出现在复制文本里，顺序固定', () {
      final FixedCanvasProbeDiagnostics d = FixedCanvasProbeDiagnostics(
        devicePixelRatio: 1.5,
        assertionFailures: const <String>['x'],
      );
      final List<String> lines = d.toCopyText().split('\n');
      // 第一行是头部，其余每个冻结键一行。
      expect(lines.first, 'fixed_canvas_probe=1');
      for (int i = 0; i < FixedCanvasProbeDiagnostics.frozenKeys.length; i++) {
        final String key = FixedCanvasProbeDiagnostics.frozenKeys[i];
        expect(lines[i + 1].startsWith('$key='), isTrue,
            reason: '第 $i 行应以 $key= 开头，实际：${lines[i + 1]}');
      }
      expect(d.dpi, 144);
      expect(d.passed, isFalse);
    });

    test('无断言失败 → passed = true', () {
      final FixedCanvasProbeDiagnostics d = FixedCanvasProbeDiagnostics();
      expect(d.passed, isTrue);
      expect(d.toCopyText(), contains('assertionFailures=none'));
      expect(d.toCopyText(), contains('gdiObjectCount=none'));
    });
  });

  group('硬断言（开合菜单期间窗口矩形不得变化）', () {
    const Rect win = Rect.fromLTWH(100, 100, 1352, 560);
    const Rect petScreen = Rect.fromLTWH(648, 252, 256, 256);

    test('窗口矩形完全一致 → 通过', () {
      final List<String> failures = FixedCanvasAssertions.evaluate(
        before: win,
        afterOpen: win,
        afterClose: win,
        petScreenBefore: petScreen,
        petScreenAfterOpen: petScreen,
        petScreenAfterClose: petScreen,
      );
      expect(failures, isEmpty);
    });

    test('打开后窗口矩形变化 → 失败', () {
      final List<String> failures = FixedCanvasAssertions.evaluate(
        before: win,
        afterOpen: win.translate(0, 4),
        afterClose: win,
        petScreenBefore: petScreen,
        petScreenAfterOpen: petScreen,
        petScreenAfterClose: petScreen,
      );
      expect(failures, isNotEmpty);
      expect(failures.join(), contains('windowRectBeforeOpen != windowRectAfterOpen'));
    });

    test('关闭后窗口矩形变化 → 失败', () {
      final List<String> failures = FixedCanvasAssertions.evaluate(
        before: win,
        afterOpen: win,
        afterClose: win.translate(2, 0),
        petScreenBefore: petScreen,
        petScreenAfterOpen: petScreen,
        petScreenAfterClose: petScreen,
      );
      expect(failures, isNotEmpty);
      expect(failures.join(), contains('windowRectBeforeOpen != windowRectAfterClose'));
    });

    test('桌宠屏幕矩形误差 > 1px → 失败；≤ 1px → 通过', () {
      final List<String> ok = FixedCanvasAssertions.evaluate(
        before: win,
        afterOpen: win,
        afterClose: win,
        petScreenBefore: petScreen,
        petScreenAfterOpen: petScreen.translate(0.5, 0.5),
        petScreenAfterClose: petScreen,
      );
      expect(ok, isEmpty);

      final List<String> bad = FixedCanvasAssertions.evaluate(
        before: win,
        afterOpen: win,
        afterClose: win,
        petScreenBefore: petScreen,
        petScreenAfterOpen: petScreen.translate(0, 3),
        petScreenAfterClose: petScreen,
      );
      expect(bad, isNotEmpty);
      expect(bad.join(), contains('桌宠屏幕矩形误差'));
    });

    test('窗口矩形缺失 → 失败（不可判定即判失败）', () {
      final List<String> failures = FixedCanvasAssertions.evaluate(
        before: null,
        afterOpen: win,
        afterClose: win,
        petScreenBefore: null,
        petScreenAfterOpen: null,
        petScreenAfterClose: null,
      );
      expect(failures, isNotEmpty);
    });
  });

  group('平台隔离（Android / 服务端不被触碰）', () {
    test('Windows Region 通道名不会出现在 Android 或 server 目录', () {
      final String root = Directory.current.path;
      final List<String> hits = <String>[];
      for (final String dir in <String>['lib/platform/android', 'android', 'server']) {
        final Directory d = Directory(p.join(root, dir));
        if (!d.existsSync()) continue;
        for (final FileSystemEntity e in d.listSync(recursive: true)) {
          if (e is! File) continue;
          final String lower = e.path.toLowerCase();
          if (lower.endsWith('.dart') ||
              lower.endsWith('.kt') ||
              lower.endsWith('.py') ||
              lower.endsWith('.xml') ||
              lower.endsWith('.kts')) {
            if (e.readAsStringSync().contains('windows_surface')) {
              hits.add(e.path);
            }
          }
        }
      }
      expect(hits, isEmpty, reason: 'Region 通道泄漏到 Android / 服务端：$hits');
    });
  });
}
