/// Windows 桌面窗口的**显式模式机**（修复：切面板没有完整退出固定画布）。
///
/// 背景（真机回归）
/// ----------------
/// 双击桌宠进入控制面板后，面板**显示不正确**：固定画布模式并没有被完整退出 ——
/// 仍然残留"仅桌宠 Region"、`petAnchor` 持久化换算、窗口几何守卫、探针 widget
/// 以及旧的透明小窗口风格 / 命中区域。根因是这些状态散落在一堆布尔量里，
/// 没有人负责"一次性、原子地"完成窗口形态切换。
///
/// 修复思路
/// --------
/// 用**一个**显式模式描述桌宠窗口所处的形态，并在每次切换时递增**代际**
/// （generation）。所有异步回调（延迟 resize、菜单 Region 恢复、面板事务的后续步骤）
/// 在执行前都必须同时检查 `generation` 与 `mode`，任一不符即**丢弃**。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` / `foundation` / 同层的几何日志），
/// 可在 `flutter_tester` 直接单测。
library;

import 'package:flutter/foundation.dart';

import 'wheel_geometry_ownership.dart' show wheelGeometryJournal;

/// 桌宠窗口的形态。
///
/// 与前身 `DesktopShell.WindowMode`（只有 pet / panel）不同：这里把**过渡态**
/// 也显式建模，因为回归恰恰发生在过渡期间（约束最容易被绕过）。
enum WindowsSurfaceMode {
  /// 桌宠模式：固定画布（HWND 物理矩形固定）+ 仅桌宠 Region。
  petFixedCanvas,

  /// 正在进入控制面板（过渡态）：禁止一切桌宠侧几何写入。
  transitioningToPanel,

  /// 控制面板模式：普通矩形窗口，1180×760，可命中、可缩放。
  panel,

  /// 正在返回桌宠（过渡态）：只允许桌宠事务写几何。
  transitioningToPet;

  /// 线上 / 日志取值（snake_case）。
  String get wireName => switch (this) {
        WindowsSurfaceMode.petFixedCanvas => 'pet_fixed_canvas',
        WindowsSurfaceMode.transitioningToPanel => 'transitioning_to_panel',
        WindowsSurfaceMode.panel => 'panel',
        WindowsSurfaceMode.transitioningToPet => 'transitioning_to_pet',
      };

  /// 是否属于"面板侧"（面板 widget 应显示）。
  bool get isPanelLike =>
      this == WindowsSurfaceMode.panel ||
      this == WindowsSurfaceMode.transitioningToPanel;

  /// 是否属于"桌宠侧"（桌宠 widget 应显示）。
  bool get isPetLike =>
      this == WindowsSurfaceMode.petFixedCanvas ||
      this == WindowsSurfaceMode.transitioningToPet;

  /// 是否允许**普通桌宠 / 素材尺寸**写窗口（只有稳定的桌宠态允许）。
  bool get allowsPetResize => this == WindowsSurfaceMode.petFixedCanvas;

  /// 是否允许**面板**写窗口几何（含过渡中提交面板 bounds）。
  bool get allowsPanelGeometry =>
      this == WindowsSurfaceMode.panel ||
      this == WindowsSurfaceMode.transitioningToPanel;

  /// 是否允许建立 / 重建固定画布（桌宠态初始化，或返回桌宠的事务）。
  bool get allowsFixedCanvasCommit =>
      this == WindowsSurfaceMode.petFixedCanvas ||
      this == WindowsSurfaceMode.transitioningToPet;
}

/// 模式机状态 + 代际 + 事务令牌。
///
/// 这是一个**模块级共享**的单例（类似 `wheelSurfaceGeometry`），因为窗口控制器、
/// PetView 的延迟守卫、探针与外壳都必须读到同一份真值。
class WindowsSurfaceSession {
  WindowsSurfaceMode _mode = WindowsSurfaceMode.petFixedCanvas;
  int _generation = 0;

  WindowsSurfaceMode get mode => _mode;

  /// 代际：每次模式切换 +1。延迟回调据此判断"是否已过期"。
  int get generation => _generation;

  /// 切换模式。**每次调用都递增代际**（同一模式重复进入也算一次新事务，
  /// 这样旧事务的后续步骤会被可靠地作废）。
  int changeTo(WindowsSurfaceMode next, {String source = 'unknown'}) {
    final WindowsSurfaceMode previous = _mode;
    _mode = next;
    _generation++;
    wheelGeometryJournal.record(
      'surface.mode.changed',
      fields: <String, Object?>{
        'from': previous.wireName,
        'mode': next.wireName,
        'source': source,
      },
    );
    wheelGeometryJournal.record(
      'surface.generation',
      fields: <String, Object?>{'generation': _generation, 'mode': next.wireName},
    );
    // 严格时间线埋点：`surface.mode`（供复现矩阵与对账统一读取）。
    wheelGeometryJournal.record(
      'surface.mode',
      fields: <String, Object?>{
        'mode': next.wireName,
        'from': previous.wireName,
        'generation': _generation,
      },
    );
    return _generation;
  }

  /// 代际 + 模式双重校验：必须**同时**满足才继续执行后续步骤。
  bool isCurrent(int generation, {WindowsSurfaceMode? mode}) {
    if (generation != _generation) return false;
    if (mode != null && mode != _mode) return false;
    return true;
  }

  /// 仅测试使用：复位到初始状态。
  @visibleForTesting
  void resetForTest() {
    _mode = WindowsSurfaceMode.petFixedCanvas;
    _generation = 0;
  }
}

/// 模块级共享实例：外壳 / 窗口控制器 / PetView / 探针必须读**同一个**模式。
final WindowsSurfaceSession windowsSurfaceSession = WindowsSurfaceSession();
