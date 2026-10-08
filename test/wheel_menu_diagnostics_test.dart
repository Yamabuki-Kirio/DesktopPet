import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_menu_diagnostics.dart';

/// 增量 A：轮盘菜单几何诊断用例（纯 Dart）。
void main() {
  Rect pet() => const Rect.fromLTWH(600, 400, 256, 192);
  Rect expanded() => const Rect.fromLTWH(600, 336, 588, 320);

  WheelMenuDiagnostics openOnce(WheelMenuDiagnostics diag) {
    diag.recordOpen(
      displayId: '\\\\.\\DISPLAY1',
      devicePixelRatio: 1.25,
      oldWindowRect: pet(),
      targetWindowRect: expanded(),
      actualWindowRect: expanded(),
      petLocalOffset: const Offset(0, 64),
      commitDurationMs: 3.5,
      petScreenErrorPx: 0,
      menuOnRight: true,
      clampedByDisplay: false,
    );
    return diag;
  }

  test('打开记录包含全部冻结键，复制文本可 grep', () {
    final WheelMenuDiagnostics diag = openOnce(WheelMenuDiagnostics());
    final WheelMenuDiagnosticSample sample = diag.latest!;
    final Map<String, Object?> map = sample.toMap();

    expect(map['event'], 'open');
    expect(map['display_id'], '\\\\.\\DISPLAY1');
    expect(map['device_pixel_ratio'], 1.25);
    expect(map['dpi'], 120);
    expect(map['commit_method'], 'setBounds');
    expect(map['pet_screen_error_px'], 0);
    expect(map['menu_on_right'], true);

    final String text = sample.toCopyText();
    expect(text.split('\n').length, WheelMenuDiagnosticSample.frozenKeys.length);
    for (final String key in WheelMenuDiagnosticSample.frozenKeys) {
      expect(text, contains('$key='), reason: key);
    }
    expect(text, contains('commit_method=setBounds'));
    expect(text, contains('old_window_rect=600,400 256×192'));
  });

  test('复制文本幂等；表头带 sample_count', () {
    final WheelMenuDiagnostics diag = openOnce(WheelMenuDiagnostics());
    expect(diag.toCopyText(), diag.toCopyText());
    expect(diag.toCopyText(), contains('diagnostic_mode=false'));
    expect(diag.toCopyText(), contains('sample_count=1'));
  });

  test('缺值统一写 none', () {
    final WheelMenuDiagnostics diag = WheelMenuDiagnostics();
    diag.recordRejected(note: '鼠标穿透已开启，未打开轮盘菜单');
    final String text = diag.latest!.toCopyText();
    expect(text, contains('old_window_rect=none'));
    expect(text, contains('pet_screen_error_px=none'));
    expect(text, contains('note=鼠标穿透已开启，未打开轮盘菜单'));
  });

  test('逐帧几何仅在诊断模式、且最多 12 帧', () {
    final WheelMenuDiagnostics diag = openOnce(WheelMenuDiagnostics());

    // 默认关闭：不记录。
    for (int i = 0; i < 20; i++) {
      diag.logFrame(i, 'window=...');
    }
    expect(diag.latest!.frames, isEmpty);

    // 打开诊断模式后最多 12 帧。
    diag.diagnosticMode = true;
    for (int i = 0; i < 20; i++) {
      diag.logFrame(i, 'window=...');
    }
    expect(diag.latest!.frames.length, WheelMenuDiagnostics.maxFrameLogs);
  });

  test('关闭记录 restored / transparentRegionBlocksClicks', () {
    final WheelMenuDiagnostics diag = openOnce(WheelMenuDiagnostics());
    diag.recordClose(
      oldWindowRect: expanded(),
      targetWindowRect: pet(),
      actualWindowRect: pet(),
      restoredAfterClose: true,
      transparentRegionBlocksClicks: false,
      commitDurationMs: 2.0,
      petScreenErrorPx: 0,
    );
    final WheelMenuDiagnosticSample close = diag.latest!;
    expect(close.event, 'close');
    expect(close.restoredAfterClose, isTrue);
    expect(close.transparentRegionBlocksClicks, isFalse);
    // 最新在前。
    expect(diag.samples.first.event, 'close');
    expect(diag.samples.length, 2);
  });

  test('样本数量有上限', () {
    final WheelMenuDiagnostics diag = WheelMenuDiagnostics();
    for (int i = 0; i < WheelMenuDiagnostics.maxSamples + 5; i++) {
      diag.recordRejected(note: 'n$i');
    }
    expect(diag.samples.length, WheelMenuDiagnostics.maxSamples);
  });

  test('clear 清空', () {
    final WheelMenuDiagnostics diag = openOnce(WheelMenuDiagnostics());
    expect(diag.hasSamples, isTrue);
    diag.clear();
    expect(diag.hasSamples, isFalse);
    expect(diag.latest, isNull);
  });

  test('formatRect / formatOffset', () {
    expect(WheelMenuDiagnosticSample.formatRect(null), 'none');
    expect(
      WheelMenuDiagnosticSample.formatRect(const Rect.fromLTWH(1.5, 2, 10, 20)),
      '1.5,2 10×20',
    );
    expect(WheelMenuDiagnosticSample.formatOffset(null), 'none');
    expect(
      WheelMenuDiagnosticSample.formatOffset(const Offset(3, 4.25)),
      '3,4.3',
    );
  });
}
