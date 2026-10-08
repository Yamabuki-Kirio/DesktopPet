/// 桌宠 ↔ 控制面板 的**窗口形态事务**（显式模式机驱动）。
///
/// 这是回归修复的核心：切面板不再是"改几个布尔量"，而是一条**顺序固定、可校验、
/// 可回滚**的事务。任何一步的后续步骤在执行前都要同时校验
/// `WindowsSurfaceSession` 的**代际**与**模式**；过期即丢弃。
///
/// 真正的副作用（窗口 API / Region API / widget 切换）由 [SurfaceTransactionHost]
/// 提供，因此本文件可以在 `flutter_tester` 里用假宿主完整单测。
library;

import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

import '../../menu/fixed_canvas_geometry.dart' show PhysicalRect;
import '../../menu/wheel_geometry_ownership.dart' show wheelGeometryJournal;
import '../../menu/windows_surface_mode.dart';

/// 一次形态切换的结果。
@immutable
class SurfaceTransitionResult {
  const SurfaceTransitionResult({
    required this.success,
    required this.mode,
    required this.generation,
    this.error,
  });

  final bool success;
  final WindowsSurfaceMode mode;
  final int generation;
  final String? error;

  @override
  String toString() =>
      'SurfaceTransitionResult(ok=$success mode=${mode.wireName} gen=$generation'
      '${error == null ? '' : ' error=$error'})';
}

/// 面板事务需要的全部副作用（真实实现 = `DesktopShell`；测试注入假实现）。
abstract interface class SurfaceTransactionHost {
  /// 收起旧轮盘几何探针（默认关闭，但必须显式收）。
  Future<void> closeWheelMenu();

  /// dismiss 右键 PopupRoute 并**等待其真正关闭**。
  Future<void> dismissContextMenuAndWait();

  /// 禁用固定画布：切换几何所有权到 panel、清除 `petAnchor`、停用探针。
  Future<void> suspendFixedCanvas();

  /// 使 contextMenu / wheel 等**所有**旧 Region 事务立即失效（面板切换第 2 步）。
  Future<void> invalidateAllRegionTransactions(String reason);

  /// 清除窗口 Region，并由 `panelTransition` **独占**。返回是否成功。
  Future<bool> clearRegionForPanel();

  /// 读取当前 Region 包围盒（清除后应为 null）。
  Future<PhysicalRect?> readRegionBoundingBox();

  Future<void> setWindowVisible(bool visible);

  /// 恢复普通面板窗口属性：非穿透、可缩放、矩形命中。
  Future<void> restorePanelWindowAttributes();

  /// 提交**一次**面板 bounds（已按桌宠所在显示器 workArea 居中），返回实际请求的矩形。
  Future<Rect> commitPanelBounds();

  /// 校验给定物理矩形是否**完整落在**它所在显示器的可用工作区内
  /// （面板不应压到任务栏 / 跑到屏幕外）。
  Future<bool> isBoundsFullyVisible(Rect bounds);

  /// 切到 `ControlPanel` widget 并等待一帧布局完成。
  Future<void> showPanelWidgetAndSettle();

  Future<Rect> readWindowBounds();

  Future<void> showWindowAndFocus();

  /// 用保存的桌宠屏幕位置 + petAnchor 算出画布矩形并**提交一次**，返回该矩形。
  Future<Rect> commitFixedCanvasBounds();

  /// 切回桌宠 widget 并等待布局完成。
  Future<void> showPetWidgetAndSettle();

  /// 采用已提交的画布矩形，应用"仅桌宠" Region。返回是否成功。
  Future<bool> applyPetOnlyRegion();

  /// 当前桌宠屏幕矩形（用于回读校验）。
  Future<Rect> readPetScreenRect();

  /// 回滚到普通矩形小窗口（清 Region + 缩回桌宠尺寸），绝不留下大透明块。
  Future<void> rollbackToRectangularPet(String reason);

  /// 面向上层给出显式错误（桌宠模式下的瞬时提示）。
  Future<void> showStatusMessage(String message);

  /// 当前桌宠逻辑尺寸。
  Size get petLogicalSize;

  /// 固定画布尺寸（用于判定"不再是画布尺寸"）。
  Size get fixedCanvasSize;
}

/// 形态事务执行器。
class SurfaceModeController {
  SurfaceModeController(this._host);

  final SurfaceTransactionHost _host;

  bool _inFlight = false;

  WindowsSurfaceMode get mode => windowsSurfaceSession.mode;

  /// 面板尺寸容差（像素）：DPI 取整可能带来 ±1px。
  static const double sizeTolerance = 2.0;

  bool _alive(int generation, WindowsSurfaceMode expected) =>
      windowsSurfaceSession.isCurrent(generation, mode: expected);

  /// 进入控制面板。返回是否成功（失败时已回滚到桌宠小窗口）。
  Future<SurfaceTransitionResult> enterPanel({required Size panelSize}) async {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) {
      // 已在面板 / 过渡中：快速双击只允许**一次**事务。
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: 'already_transitioning_or_panel',
      );
    }
    if (_inFlight) {
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: 'in_flight',
      );
    }
    _inFlight = true;

    // 1) 立即切到过渡态：阻断一切新的单击 / 双击 / 拖动 / 菜单请求。
    final int gen = windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.transitioningToPanel,
      source: 'controller.enterPanel',
    );
    wheelGeometryJournal.record(
      'panel.transition.start',
      fields: <String, Object?>{'direction': 'to_panel', 'generation': gen},
    );

    try {
      // 2a) 面板侧**独占** Region：让 contextMenu / wheel 的旧事务全部失效 ——
      //     即使它们的 `finally` 迟到，也会被 RegionCoordinator 判为 dropped_stale。
      await _host.invalidateAllRegionTransactions('panel.enterPanel');

      // 2b) 收起旧轮盘探针（含固定画布模式的左键轮盘）。
      await _host.closeWheelMenu();
      if (!_alive(gen, WindowsSurfaceMode.transitioningToPanel)) {
        return _dropped(gen);
      }

      // 3) dismiss 右键 PopupRoute 并等待其关闭（必须在清 Region 之前）。
      await _host.dismissContextMenuAndWait();
      if (!_alive(gen, WindowsSurfaceMode.transitioningToPanel)) {
        return _dropped(gen);
      }
      wheelGeometryJournal.record(
        'panel.popup_dismissed',
        fields: <String, Object?>{'generation': gen},
      );

      // 4) 切到 panel 过渡 + 7) 禁用固定画布（owner / petAnchor / 探针）。
      await _host.suspendFixedCanvas();
      if (!_alive(gen, WindowsSurfaceMode.transitioningToPanel)) {
        return _dropped(gen);
      }

      // 5) 清除 Region（owner = panelTransition）。
      final bool cleared = await _host.clearRegionForPanel();
      wheelGeometryJournal.record(
        'panel.region_cleared',
        fields: <String, Object?>{'success': cleared, 'generation': gen},
      );

      // 6) 确认 Region 已是 none（清除后应为 null）。
      final PhysicalRect? box = await _host.readRegionBoundingBox();
      if (box != null) {
        await _host.rollbackToRectangularPet('region_not_cleared:${box.width}x${box.height}');
        wheelGeometryJournal.record(
          'panel.transition.rollback',
          fields: <String, Object?>{'reason': 'region_not_cleared', 'generation': gen},
        );
        windowsSurfaceSession.changeTo(
          WindowsSurfaceMode.petFixedCanvas,
          source: 'controller.enterPanel.rollback',
        );
        return SurfaceTransitionResult(
          success: false,
          mode: windowsSurfaceSession.mode,
          generation: windowsSurfaceSession.generation,
          error: 'region_not_cleared',
        );
      }

      // 8) 隐藏窗口：用户不应看到中间态。
      await _host.setWindowVisible(false);

      // 9) 恢复普通面板窗口属性。
      await _host.restorePanelWindowAttributes();
      if (!_alive(gen, WindowsSurfaceMode.transitioningToPanel)) {
        return _dropped(gen);
      }

      // 10) 提交一次面板 bounds（已夹取到可见区）。
      final Rect requested = await _host.commitPanelBounds();
      wheelGeometryJournal.record(
        'panel.bounds.requested',
        fields: <String, Object?>{
          'left': requested.left,
          'top': requested.top,
          'width': requested.width,
          'height': requested.height,
          'generation': gen,
        },
      );

      // 11) 切到 ControlPanel widget。
      await _host.showPanelWidgetAndSettle();
      wheelGeometryJournal.record(
        'panel.widget_ready',
        fields: <String, Object?>{'generation': gen},
      );

      // 12) 等一帧后回读实际窗口矩形。
      final Rect actual = await _host.readWindowBounds();
      wheelGeometryJournal.record(
        'panel.bounds.actual',
        fields: <String, Object?>{
          'left': actual.left,
          'top': actual.top,
          'width': actual.width,
          'height': actual.height,
          'generation': gen,
        },
      );

      // 13) 校验：不再是画布尺寸、尺寸 ≈ 面板尺寸、且**完整可见**。
      final bool notCanvas = !_approx(actual.width, _host.fixedCanvasSize.width) ||
          !_approx(actual.height, _host.fixedCanvasSize.height);
      final bool sizedLikePanel = _approx(actual.width, panelSize.width) &&
          _approx(actual.height, panelSize.height);
      final bool fullyVisible = await _host.isBoundsFullyVisible(actual);
      if (!notCanvas || !sizedLikePanel || !fullyVisible) {
        await _host.rollbackToRectangularPet('panel_bounds_invalid:${actual.width}x${actual.height}');
        wheelGeometryJournal.record(
          'panel.transition.rollback',
          fields: <String, Object?>{
            'reason': 'panel_bounds_invalid',
            'actual': '${actual.width}x${actual.height}',
            'fullyVisible': fullyVisible,
            'generation': gen,
          },
        );
        windowsSurfaceSession.changeTo(
          WindowsSurfaceMode.petFixedCanvas,
          source: 'controller.enterPanel.rollback',
        );
        return SurfaceTransitionResult(
          success: false,
          mode: windowsSurfaceSession.mode,
          generation: windowsSurfaceSession.generation,
          error: 'panel_bounds_invalid',
        );
      }

      // 14) 显示并聚焦，提交 panel 模式。
      await _host.showWindowAndFocus();
      wheelGeometryJournal.record(
        'panel.visible',
        fields: <String, Object?>{'generation': gen},
      );
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.panel,
        source: 'controller.enterPanel.complete',
      );
      wheelGeometryJournal.record(
        'panel.transition.complete',
        fields: <String, Object?>{'direction': 'to_panel', 'generation': gen},
      );
      return SurfaceTransitionResult(
        success: true,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
      );
    } catch (e) {
      await _host.rollbackToRectangularPet('enter_exception:$e');
      wheelGeometryJournal.record(
        'panel.transition.rollback',
        fields: <String, Object?>{'reason': 'exception', 'error': '$e', 'generation': gen},
      );
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.petFixedCanvas,
        source: 'controller.enterPanel.exception',
      );
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: '$e',
      );
    } finally {
      _inFlight = false;
    }
  }

  /// 从控制面板返回桌宠。返回是否成功。
  Future<SurfaceTransitionResult> returnToPet() async {
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.panel) {
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: 'not_in_panel',
      );
    }
    if (_inFlight) {
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: 'in_flight',
      );
    }
    _inFlight = true;

    // 1) 过渡态：只允许本事务写几何。
    final int gen = windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.transitioningToPet,
      source: 'controller.returnToPet',
    );
    wheelGeometryJournal.record(
      'panel.transition.start',
      fields: <String, Object?>{'direction': 'to_pet', 'generation': gen},
    );

    try {
      // 2) 隐藏面板窗口。
      await _host.setWindowVisible(false);

      // 3)-5) 读保存的桌宠屏幕位置 → 算画布矩形 → 提交一次画布 bounds。
      final Rect canvasRect = await _host.commitFixedCanvasBounds();
      wheelGeometryJournal.record(
        'panel.bounds.requested',
        fields: <String, Object?>{
          'left': canvasRect.left,
          'top': canvasRect.top,
          'width': canvasRect.width,
          'height': canvasRect.height,
          'direction': 'to_pet',
          'generation': gen,
        },
      );

      // 6)-7) 切回桌宠 widget 并等待布局。
      await _host.showPetWidgetAndSettle();
      if (!_alive(gen, WindowsSurfaceMode.transitioningToPet)) {
        return _dropped(gen);
      }

      // 8) 应用"仅桌宠" Region。
      final bool ready = await _host.applyPetOnlyRegion();

      // 9) 回读三件套。
      final Rect win = await _host.readWindowBounds();
      final PhysicalRect? box = await _host.readRegionBoundingBox();
      final Rect petScreen = await _host.readPetScreenRect();
      wheelGeometryJournal.record(
        'panel.bounds.actual',
        fields: <String, Object?>{
          'left': win.left,
          'top': win.top,
          'width': win.width,
          'height': win.height,
          'direction': 'to_pet',
          'generation': gen,
        },
      );

      // 10) 校验：Region 已应用（box 非空）+ 画布尺寸与提交一致 + 桌宠矩形有效。
      final bool ok = ready &&
          box != null &&
          _approx(win.width, canvasRect.width) &&
          _approx(win.height, canvasRect.height) &&
          petScreen.width > 0 &&
          petScreen.height > 0;
      if (!ok) {
        await _failReturn(gen, 'pet_canvas_invalid ready=$ready box=$box');
        return SurfaceTransitionResult(
          success: false,
          mode: windowsSurfaceSession.mode,
          generation: windowsSurfaceSession.generation,
          error: 'pet_canvas_invalid',
        );
      }

      await _host.showWindowAndFocus();
      windowsSurfaceSession.changeTo(
        WindowsSurfaceMode.petFixedCanvas,
        source: 'controller.returnToPet.complete',
      );
      wheelGeometryJournal.record(
        'panel.transition.complete',
        fields: <String, Object?>{'direction': 'to_pet', 'generation': gen},
      );
      return SurfaceTransitionResult(
        success: true,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
      );
    } catch (e) {
      await _failReturn(gen, 'return_exception:$e');
      return SurfaceTransitionResult(
        success: false,
        mode: windowsSurfaceSession.mode,
        generation: windowsSurfaceSession.generation,
        error: '$e',
      );
    } finally {
      _inFlight = false;
    }
  }

  /// 返回失败：绝不留下半个面板 / 大透明窗口 —— 清 Region + 恢复普通矩形窗口 +
  /// 显式错误提示 + 保持托盘可用。
  Future<void> _failReturn(int generation, String reason) async {
    await _host.rollbackToRectangularPet(reason);
    await _host.showStatusMessage('返回桌宠失败：$reason');
    wheelGeometryJournal.record(
      'panel.transition.rollback',
      fields: <String, Object?>{'reason': reason, 'generation': generation},
    );
    windowsSurfaceSession.changeTo(
      WindowsSurfaceMode.petFixedCanvas,
      source: 'controller.returnToPet.rollback',
    );
  }

  SurfaceTransitionResult _dropped(int generation) {
    wheelGeometryJournal.record(
      'panel.transition.rollback',
      fields: <String, Object?>{'reason': 'stale_generation', 'generation': generation},
    );
    return SurfaceTransitionResult(
      success: false,
      mode: windowsSurfaceSession.mode,
      generation: windowsSurfaceSession.generation,
      error: 'stale_generation',
    );
  }

  static bool _approx(double a, double b) => (a - b).abs() <= sizeTolerance;
}
