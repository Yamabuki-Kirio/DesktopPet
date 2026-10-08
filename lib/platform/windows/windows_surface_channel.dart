/// Windows 窗口 Region 原生桥 + 固定画布窗口操作（本轮新方向）。
///
/// 这个文件是 `platform/windows/**` 的一部分，允许 import 桌面专属库
/// （`window_manager` / `display_topology`）。
///
/// 原生侧（`windows/runner/flutter_window.cpp`）实现了三条可调用方法：
/// * `applyInteractionRegion(rects)`：`CreateRectRgn` + `CombineRgn(RGN_OR)` +
///   `SetWindowRgn`；
/// * `clearInteractionRegion()`：`SetWindowRgn(hwnd, NULL, TRUE)`；
/// * `restorePetOnlyRegion(rects)`：与 apply 同实现（单个桌宠矩形）。
/// 另有 `gdiObjectCount` / `regionBoundingBox` 两条只读诊断。
///
/// **本文件是原生 Region 的唯一适配器**：它实现 `RegionNativeOps`，而 `RegionNativeOps`
/// 的唯一调用者是 `RegionCoordinator`。业务层（`ui/**`）禁止直接使用本类。
///
/// **HRGN 所有权（GDI 泄漏铁律）**：Dart 侧只传"矩形列表"，从不持有 HRGN，
/// 因此不存在 Dart 侧泄漏；HRGN 的释放完全由原生侧按规则处理 ——
/// `SetWindowRgn` 成功时由系统接管（不得再 `DeleteObject`），
/// 失败时由原生 `DeleteObject`（必须释放）。详见 C++ 注释。
library;

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/logger.dart';
import '../../menu/fixed_canvas_contract.dart';
import '../../menu/fixed_canvas_geometry.dart';
import '../../menu/wheel_geometry.dart' show WheelDisplayArea;
import '../../menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import '../../menu/windows_surface_mode.dart';
import 'display_topology.dart';

/// 原生 Region 桥（生产实现，`RegionNativeOps` 的唯一落地）。
class WindowsSurfaceBridge implements RegionNativeOps {
  WindowsSurfaceBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(windowsSurfaceChannelName);

  final MethodChannel _channel;

  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) =>
      _invokeRegion(
        windowsSurfaceApplyRegion,
        logicalRects,
        devicePixelRatio: devicePixelRatio,
      );

  @override
  Future<RegionApplyResult> restorePetOnlyRegion(
    Rect logicalPetRect, {
    required double devicePixelRatio,
  }) =>
      _invokeRegion(
        windowsSurfaceRestorePetOnly,
        <Rect>[logicalPetRect],
        devicePixelRatio: devicePixelRatio,
      );

  Future<RegionApplyResult> _invokeRegion(
    String method,
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    final List<PhysicalRect> rects =
        FixedCanvasDpi.rectsToPhysical(logicalRects, devicePixelRatio);
    if (rects.isEmpty) {
      return const RegionApplyResult.failure('没有可用的非空矩形');
    }
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(
        method,
        <String, Object?>{
          'rects': rects.map((PhysicalRect r) => r.toMap()).toList(),
        },
      );
      return RegionApplyResult.fromMap(raw);
    } on MissingPluginException catch (e) {
      // 原生通道缺失（例如非 Windows / 旧构建）：返回失败，触发小窗口回退。
      return RegionApplyResult.failure('原生 Region 通道不可用：$e');
    } on PlatformException catch (e) {
      return RegionApplyResult.failure('原生 Region 应用失败：${e.code} ${e.message}');
    } catch (e) {
      return RegionApplyResult.failure('原生 Region 应用异常：$e');
    }
  }

  @override
  Future<bool> clearInteractionRegion() async {
    try {
      final Object? raw =
          await _channel.invokeMethod<Object?>(windowsSurfaceClearRegion);
      if (raw is bool) return raw;
      if (raw is Map) return raw['success'] == true;
      return false;
    } on MissingPluginException {
      return false;
    } catch (e, st) {
      Loggers.window.warning('清除窗口 Region 失败', e, st);
      return false;
    }
  }

  @override
  Future<int?> gdiObjectCount() async {
    try {
      final Object? raw =
          await _channel.invokeMethod<Object?>(windowsSurfaceGdiObjectCount);
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PhysicalRect?> regionBoundingBox() async {
    try {
      final Object? raw = await _channel
          .invokeMethod<Object?>(windowsSurfaceRegionBoundingBox);
      return PhysicalRect.fromMap(raw);
    } catch (_) {
      return null;
    }
  }
}

/// 固定画布窗口几何操作：`commitBounds` 是**唯一**的矩形提交点。
///
/// 与 `WindowsWheelWindowOps` 并列，但用途不同：这里服务于"固定画布"模式，
/// 提交的是**画布矩形**（一次 `SetWindowPos`），打开 / 关闭菜单期间绝不调用。
class WindowsFixedCanvasWindowOps implements FixedCanvasWindowOps {
  const WindowsFixedCanvasWindowOps();

  @override
  Future<Rect> currentBounds() => windowManager.getBounds();

  @override
  Future<void> commitBounds(Rect bounds) {
    // 模式守卫：面板**稳定态**下禁止任何"固定画布"矩形提交
    // （面板几何由面板流程自己写入；旧探针 / 桌宠回调必须被丢弃，
    // 绝不能把 1180×760 的面板缩回画布尺寸）。
    if (windowsSurfaceSession.mode == WindowsSurfaceMode.panel) {
      wheelGeometryJournal.record(
        'geometry.size.write.dropped',
        fields: <String, Object?>{
          'source': 'WindowsFixedCanvasWindowOps.commitBounds',
          'reason': 'surface_panel',
          'requested': WheelGeometryJournal.formatRect(bounds),
        },
      );
      return Future<void>.value();
    }
    return windowManager.setBounds(bounds);
  }

  @override
  Future<void> setVisible(bool visible) async {
    // 只服务于**固定画布重建事务**：重建期间先隐藏、回读校验通过后再显示。
    // 打开 / 关闭菜单期间不会调用（由探针的事务纪律保证）。
    if (visible) {
      await windowManager.show();
    } else {
      await windowManager.hide();
    }
  }

  @override
  double devicePixelRatio() {
    try {
      return windowManager.getDevicePixelRatio();
    } catch (e, st) {
      Loggers.window.warning('读取 devicePixelRatio 失败，退化为 1.0', e, st);
      return 1.0;
    }
  }

  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async {
    final List<WheelDisplayArea> all = await displays();
    if (all.isEmpty) return null;
    for (final WheelDisplayArea display in all) {
      if (display.containsPoint(point)) return display;
    }
    // 未命中任何显示器 → 主显示器（启动位置解析的兜底口径）。
    return all.firstWhere(
      (WheelDisplayArea d) => d.isPrimary,
      orElse: () => all.first,
    );
  }

  @override
  Future<List<WheelDisplayArea>> displays() async {
    final DisplayTopology topology = await DisplayTopology.load();
    return <WheelDisplayArea>[
      for (final DisplayBounds d in topology.displays) _areaOf(d),
    ];
  }

  static WheelDisplayArea _areaOf(DisplayBounds d) => WheelDisplayArea(
        id: d.id,
        left: d.left,
        top: d.top,
        width: d.width,
        height: d.height,
        isPrimary: d.isPrimary,
      );
}
