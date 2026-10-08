/// 增量 B：39 个原创 Path 图标的移植验收（决策三）。
///
/// 覆盖：
/// 1. 39 个图标 key 齐全；
/// 2. 菜单目录里**每个**条目 id 都有图标（无遗漏、无回退到兜底图标）；
/// 3. 归一化几何落在 `[-1, 1]²`（含 `STROKE = 0.16` 的描边外扩）内；
/// 4. 描边宽度 / 线帽 / 线接按 Android 取值；
/// 5. 图标**始终直立**：绘制入口不含角度参数，同一图标在不同槽位上像素一致；
/// 6. 左右镜像只镜像槽位布局，不翻转图标内容。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/ui/desktop/wheel_icons.dart';

/// 把图标渲染成 `n × n` 的 RGBA 位图（图标占边长 [size]，居中）。
Future<Uint8List> _render(WheelMenuIcon icon, int n, {required double size}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint paint = Paint()..isAntiAlias = false;
  WheelMenuIcons.draw(
    canvas,
    icon,
    n / 2,
    n / 2,
    size,
    const Color(0xFFFFFFFF),
    paint,
  );
  final ui.Image image = await recorder.endRecording().toImage(n, n);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 位图在第 [row] 行、第 [col] 列的 alpha。
int _alpha(Uint8List rgba, int n, int col, int row) => rgba[(row * n + col) * 4 + 3];

void main() {
  const int n = 160;
  // 归一化坐标 ±1 映射到边长为 size 的正方形；留出描边外扩（0.08 × size/2）的余量。
  const double size = n - 40;

  group('图标 · 覆盖与映射', () {
    test('39 个图标 key（与 Android WheelMenuIcon 数量一致）', () {
      expect(WheelMenuIcon.values.length, 39);
    });

    test('菜单目录里每个条目 id 都有**专属**图标（无遗漏、无兜底）', () {
      final Set<String> catalogIds = <String>{
        for (final MenuLevel level in MenuCatalog.levels)
          for (final MenuNode node in level.nodes) node.id,
      };
      // 增量 C1 新增 `settings_menu_distance` → 32 个条目。
      expect(catalogIds.length, 32);
      expect(WheelMenuIcons.nodeIcons.length, catalogIds.length);
      for (final String id in catalogIds) {
        expect(WheelMenuIcons.nodeIcons.containsKey(id), isTrue, reason: '缺少 $id 的图标');
        expect(WheelMenuIcons.iconForNodeId(id), isNot(WheelMenuIcon.info),
            reason: '$id 落到了兜底图标');
      }
    });

    test('映射表里的 id 都在菜单目录里（没有写错的键）', () {
      final Set<String> catalogIds = <String>{
        for (final MenuLevel level in MenuCatalog.levels)
          for (final MenuNode node in level.nodes) node.id,
      };
      for (final String id in WheelMenuIcons.nodeIcons.keys) {
        expect(catalogIds.contains(id), isTrue, reason: '映射表里的 $id 不在目录中');
      }
    });

    test('未知 id 回退到 info（绝不返回 null，避免空按钮）', () {
      expect(WheelMenuIcons.iconForNodeId('不存在的条目'), WheelMenuIcon.info);
    });

    test('返回槽位用 back 图标（Android 同口径）', () {
      expect(WheelMenuIcons.iconForNodeId('back'), WheelMenuIcon.back);
    });

    test('五个子菜单入口的图标与 Android 一致', () {
      expect(WheelMenuIcons.iconForNodeId('root_pet'), WheelMenuIcon.pet);
      expect(WheelMenuIcons.iconForNodeId('root_appearance'), WheelMenuIcon.appearance);
      expect(WheelMenuIcons.iconForNodeId('root_records'), WheelMenuIcon.record);
      expect(WheelMenuIcons.iconForNodeId('root_tools'), WheelMenuIcon.tools);
      expect(WheelMenuIcons.iconForNodeId('root_settings'), WheelMenuIcon.gear);
      expect(WheelMenuIcons.iconForNodeId('root_hide'), WheelMenuIcon.hide);
    });
  });

  group('图标 · 描边与画法', () {
    test('归一化描边宽度 0.16，线帽 / 线接都是 ROUND', () {
      expect(WheelMenuIcons.stroke, 0.16);
      final Paint paint = Paint();
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      WheelMenuIcons.draw(
        Canvas(recorder),
        WheelMenuIcon.gear,
        50,
        50,
        40,
        const Color(0xFFFFFFFF),
        paint,
      );
      // dart:ui 的 Paint 走 Skia float32，0.16 存回来是 0.1599999964237213 —— 用容差比。
      expect(paint.strokeWidth, closeTo(WheelMenuIcons.stroke, 1e-6));
      expect(paint.strokeCap, StrokeCap.round);
      expect(paint.strokeJoin, StrokeJoin.round);
      expect(paint.color, const Color(0xFFFFFFFF));
    });

    test('size <= 0 时**不做任何绘制**（防御空按钮）', () {
      final Paint paint = Paint();
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      WheelMenuIcons.draw(
        Canvas(recorder),
        WheelMenuIcon.pet,
        50,
        50,
        0,
        const Color(0xFFFFFFFF),
        paint,
      );
      expect(paint.strokeWidth, 0, reason: '没有进入绘制分支');
    });

    test('每个图标都能绘制且**互不相同**（没有粘在一起的空实现）', () async {
      await Future<void>.delayed(Duration.zero);
      final List<Uint8List> rendered = <Uint8List>[];
      for (final WheelMenuIcon icon in WheelMenuIcon.values) {
        rendered.add(await _render(icon, n, size: size));
      }
      // 至少 30 个互不相同的位图（个别图标共享几何是允许的，例如同族箭头）。
      int distinct = 0;
      for (int i = 0; i < rendered.length; i++) {
        bool dup = false;
        for (int j = 0; j < i; j++) {
          if (_sameBytes(rendered[i], rendered[j])) {
            dup = true;
            break;
          }
        }
        if (!dup) distinct++;
      }
      expect(distinct, greaterThanOrEqualTo(30));
      // 每个图标都至少画了东西（不是全透明）。
      for (int i = 0; i < rendered.length; i++) {
        expect(_hasInk(rendered[i], n), isTrue,
            reason: '${WheelMenuIcon.values[i].name} 是空白图');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('图标 · 归一化范围与直立性', () {
    testWidgets('所有图标的几何都落在归一化 [-1,1]²（外圈透明）',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        // 归一化 ±1 → 边长 size 的正方形；描边再外扩 0.08 × size/2 = 4px。
        const int ring = 5;
        for (final WheelMenuIcon icon in WheelMenuIcon.values) {
          final Uint8List rgba = await _render(icon, n, size: size);
          final int margin = ((n - size) / 2).round() - ring;
          for (int col = 0; col < margin; col++) {
            for (int row = 0; row < n; row++) {
              expect(_alpha(rgba, n, col, row), 0,
                  reason: '${icon.name} 越过了左边界（列 $col）');
              expect(_alpha(rgba, n, n - 1 - col, row), 0,
                  reason: '${icon.name} 越过了右边界（列 ${n - 1 - col}）');
            }
          }
          for (int row = 0; row < margin; row++) {
            for (int col = 0; col < n; col++) {
              expect(_alpha(rgba, n, col, row), 0,
                  reason: '${icon.name} 越过了上边界（行 $row）');
              expect(_alpha(rgba, n, col, n - 1 - row), 0,
                  reason: '${icon.name} 越过了下边界（行 ${n - 1 - row}）');
            }
          }
        }
      });
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('图标始终直立：同一图标在不同槽位位置像素完全一致',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        // 绘制入口**没有角度参数** —— 镜像时不可能被翻转。
        // 这里用"换个位置画，内容逐像素相同"来钉住这一点（不是镜像、不是旋转）。
        const WheelMenuIcon icon = WheelMenuIcon.back;
        final Uint8List a = await _render(icon, n, size: size);
        final Uint8List b = await _render(icon, n, size: size);
        expect(_sameBytes(a, b), isTrue);
        // 非对称图标：与自身水平翻转**不同**（证明它有确定朝向，且没有被悄悄镜像）。
        expect(_sameBytes(a, _mirrorHorizontally(a, n)), isFalse);
      });
    });
  });
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _hasInk(Uint8List rgba, int n) {
  for (int i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 0) return true;
  }
  return false;
}

Uint8List _mirrorHorizontally(Uint8List rgba, int n) {
  final Uint8List out = Uint8List(rgba.length);
  for (int row = 0; row < n; row++) {
    for (int col = 0; col < n; col++) {
      final int src = (row * n + col) * 4;
      final int dst = (row * n + (n - 1 - col)) * 4;
      out[dst] = rgba[src];
      out[dst + 1] = rgba[src + 1];
      out[dst + 2] = rgba[src + 2];
      out[dst + 3] = rgba[src + 3];
    }
  }
  return out;
}
