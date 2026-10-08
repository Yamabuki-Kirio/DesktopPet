/// 固定画布 + 窗口 Region 的**中立契约**（纯 Dart）。
///
/// 包含三部分：
/// 1. 原生通道与三条可调用方法名（`applyInteractionRegion` /
///    `clearInteractionRegion` / `restorePetOnlyRegion`）以及两条只读诊断；
/// 2. 旧"动态 setBounds"方案的**拒绝标记**与开关（默认关闭）；
/// 3. 窗口 / Region 操作的抽象接口，便于在 `flutter_tester` 里注入假实现。
///
/// 本文件不 import 任何桌面库，可在 `flutter_tester` 直接单测。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'fixed_canvas_geometry.dart' show PhysicalRect;
import 'wheel_geometry.dart' show WheelDisplayArea;

/// 原生通道名（与 C++ 侧 `kSurfaceChannelName` 逐字一致）。
const String windowsSurfaceChannelName = 'asia.akechi.petlife/windows_surface';

/// 三条可调用方法名（必须同时存在）。
const String windowsSurfaceApplyRegion = 'applyInteractionRegion';
const String windowsSurfaceClearRegion = 'clearInteractionRegion';
const String windowsSurfaceRestorePetOnly = 'restorePetOnlyRegion';

/// 两条只读诊断方法名。
const String windowsSurfaceGdiObjectCount = 'gdiObjectCount';
const String windowsSurfaceRegionBoundingBox = 'regionBoundingBox';

/// 桌宠窗口方案的"路线"枚举。
enum PetWindowProbeApproach {
  /// 旧的"按菜单开合动态放大 / 缩小同一个 HWND"方案。
  ///
  /// **本轮被操作者否决（REJECTED）**：真机连续失败两次
  /// （首次点击桌宠大面积消失、偶尔只剩一小块菜单、再点一次才恢复）。
  /// 保留代码 / 日志 / 测试，但**默认关闭**，不得继续修补此路径。
  dynamicSetBoundsRejected('dynamic_set_bounds_rejected'),

  /// 本轮新方向：**固定画布 + Win32 窗口 Region（`SetWindowRgn`）**。
  fixedCanvasRegion('fixed_canvas_region');

  const PetWindowProbeApproach(this.wireName);

  final String wireName;
}

/// 方案开关（编译期常量，便于一键回退）。
class PetWindowProbeFlags {
  PetWindowProbeFlags._();

  /// 当前生效的路线。
  static const PetWindowProbeApproach activeApproach =
      PetWindowProbeApproach.fixedCanvasRegion;

  /// 旧的动态 `setBounds` 探针：**默认 OFF + 已标记 rejected**。
  static const bool dynamicSetBoundsProbeEnabled = false;

  /// 固定画布 + 窗口 Region 探针：本轮默认开启（仅 Windows 生效）。
  static const bool fixedCanvasRegionProbeEnabled = true;
}

/// 一次 Region 应用的返回结果（解析自原生 Map，宽容）。
class RegionApplyResult {
  const RegionApplyResult({
    required this.success,
    this.boundingBox,
    this.rectCount = 0,
    this.error,
  });

  const RegionApplyResult.failure(String reason)
      : success = false,
        boundingBox = null,
        rectCount = 0,
        error = reason;

  /// 是否成功应用（原生 `SetWindowRgn` 成功）。
  final bool success;

  /// 原生返回的**实际**区域包围盒（物理客户端像素）；不可用为 null。
  final PhysicalRect? boundingBox;

  /// 参与合并的矩形数量。
  final int rectCount;

  /// 失败原因（成功为 null）。
  final String? error;

  /// 从原生返回值解析；任何异常输入都退化为失败（绝不谎报成功）。
  factory RegionApplyResult.fromMap(Object? raw) {
    if (raw is! Map) {
      return const RegionApplyResult.failure('原生返回类型不是 Map');
    }
    final Object? ok = raw['success'];
    if (ok != true) {
      return RegionApplyResult.failure(
        (raw['error'] as Object?)?.toString() ?? '原生报告失败',
      );
    }
    final Object? count = raw['rectCount'];
    return RegionApplyResult(
      success: true,
      boundingBox: PhysicalRect.fromMap(raw['boundingBox']),
      rectCount: count is num ? count.toInt() : 0,
    );
  }

  @override
  String toString() => success
      ? 'RegionApplyResult(ok rects=$rectCount box=${boundingBox ?? 'none'})'
      : 'RegionApplyResult(fail ${error ?? '未知'})';
}

/// 固定画布探针所需的**窗口几何**能力（生产由 `window_manager` 实现，测试注入假实现）。
///
/// 注意：`commitBounds` 是**唯一**允许的窗口矩形提交点（一次 `SetWindowPos`），
/// 打开 / 关闭菜单期间**绝不允许**调用它。
abstract interface class FixedCanvasWindowOps {
  /// 读取当前窗口矩形（逻辑像素）。
  Future<Rect> currentBounds();

  /// **一次原子提交**窗口矩形（= 一次 `SetWindowPos`）。
  Future<void> commitBounds(Rect bounds);

  /// 显示 / 隐藏窗口。
  ///
  /// 只在**固定画布重建事务**里使用：重建期间先隐藏，回读校验通过后再显示，
  /// 避免 Flutter surface 重排的过程中露出"半张画布 / 大块透明窗口"。
  /// 打开 / 关闭菜单期间**绝不**调用。
  Future<void> setVisible(bool visible);

  /// 当前窗口的 devicePixelRatio。
  double devicePixelRatio();

  /// 找到包含 [point] 的显示器可见区域；找不到返回 null。
  Future<WheelDisplayArea?> displayForPoint(Offset point);

  /// 全部显示器的可用工作区（启动位置校验 / 迁移需要枚举，`displayForPoint` 不够）。
  ///
  /// 顺序不保证；主显示器由 [WheelDisplayArea.isPrimary] 标注。
  Future<List<WheelDisplayArea>> displays();
}

/// 窗口 Region 的**原生能力**（生产由 `WindowsSurfaceBridge` 实现，测试注入假实现）。
///
/// 方法名与原生侧三条可调用方法**逐字一致**，这样"业务层直连原生"这类回归可以被
/// 静态扫描测试（`test/region_bare_write_scan_test.dart`）钉死。
///
/// **唯一调用者是 `RegionCoordinator`**。`lib/` 下除下列三个文件外，任何文件都
/// 不允许出现这三个方法名：
/// * `menu/fixed_canvas_contract.dart`（本文件 · 定义）；
/// * `menu/region_coordinator.dart`（唯一调用者）；
/// * `platform/windows/windows_surface_channel.dart`（原生适配器）。
abstract interface class RegionNativeOps {
  /// 应用交互区域（逻辑局部矩形列表，内部换算成物理像素）。
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  });

  /// 只保留桌宠区域（= [applyInteractionRegion] 的单个矩形特例）。
  Future<RegionApplyResult> restorePetOnlyRegion(
    Rect logicalPetRect, {
    required double devicePixelRatio,
  });

  /// 清除 Region，恢复普通矩形窗口。
  Future<bool> clearInteractionRegion();

  /// GDI 对象数（`GetGuiResources(GR_GDIOBJECTS)`）；不可用返回 null。
  Future<int?> gdiObjectCount();

  /// 当前窗口 Region 的实际包围盒（物理像素）；不可用返回 null。
  Future<PhysicalRect?> regionBoundingBox();
}

/// 固定画布探针的**诊断快照**（含硬断言结果）——纯数据，可单测。
class FixedCanvasProbeDiagnostics {
  FixedCanvasProbeDiagnostics({
    this.fixedCanvasRect,
    this.petAnchor,
    this.petSize,
    this.petScreenRect,
    this.menuLocalRect,
    List<Rect>? interactionRegionRects,
    this.devicePixelRatio,
    this.regionApplyResult,
    this.regionBoundingBox,
    this.gdiObjectCount,
    this.windowRectBeforeOpen,
    this.windowRectAfterOpen,
    this.windowRectAfterClose,
    this.menuOnRight,
    List<String>? assertionFailures,
    this.wheelUiState,
    this.wheelInteractionState,
    this.regionOwner,
    this.levelId,
    this.highlightIndex,
    this.themeId,
    this.wheelScale,
    this.buttonScale,
    this.menuDistance,
    this.effectiveWheelScale,
    this.canvasCompressed,
    this.canvasScreenFactor,
    this.canvasRebuildCount,
    this.canvasAnchorErrorPx,
  })  : interactionRegionRects =
            interactionRegionRects ?? const <Rect>[],
        assertionFailures = assertionFailures ?? const <String>[];

  /// 固定画布窗口矩形（逻辑像素，= HWND 物理矩形）。
  final Rect? fixedCanvasRect;

  /// 桌宠在画布内的固定锚点（逻辑局部坐标）。
  final Offset? petAnchor;

  /// 当前桌宠逻辑尺寸。
  final Size? petSize;

  /// 桌宠屏幕矩形（逻辑像素）。
  final Rect? petScreenRect;

  /// 菜单局部矩形（逻辑像素）；未打开为 null。
  final Rect? menuLocalRect;

  /// 当前提交给原生的交互区域矩形（逻辑局部坐标）。
  final List<Rect> interactionRegionRects;

  final double? devicePixelRatio;

  /// 最近一次 Region 应用结果。
  final RegionApplyResult? regionApplyResult;

  /// 当前窗口 Region 的实际包围盒（物理像素）。
  final PhysicalRect? regionBoundingBox;

  final int? gdiObjectCount;

  final Rect? windowRectBeforeOpen;
  final Rect? windowRectAfterOpen;
  final Rect? windowRectAfterClose;

  /// 菜单镜像方向。
  final bool? menuOnRight;

  /// 硬断言失败项（为空 = 探针通过）。
  final List<String> assertionFailures;

  // --- 轮盘（增量 B）诊断字段 ---

  /// 轮盘七态阶段名（`closed` / `opening` / `open` / `switching` /
  /// `enteringLayer` / `exitingLayer` / `closing`）。
  final String? wheelUiState;

  /// 交互门状态名（`closed` / `opening` / `open` / `closing`）。
  final String? wheelInteractionState;

  /// 当前 Region 所有者（`pet` / `wheel` / `contextMenu` / `panelTransition` / `panel`）。
  final String? regionOwner;

  /// 当前菜单层级 id（`root` / `pet` / `appearance` / `records` / `tools` / `settings`）。
  final String? levelId;

  /// 当前高亮槽位（无高亮为 null）。
  final int? highlightIndex;

  /// 主题 id（`p3p-pink` / `blue` / …）。
  final String? themeId;

  /// 轮盘大小（0.50 ~ 2.50）。
  final double? wheelScale;

  /// 按钮大小（0.50 ~ 2.50）。
  final double? buttonScale;

  /// 菜单距离（0.05 ~ 0.30）——**不是** menuGap。
  final double? menuDistance;

  /// 当前屏幕上轮盘**实际**显示的大小比例（屏幕适配压缩后；未压缩 = wheelScale）。
  final double? effectiveWheelScale;

  /// 是否因屏幕可用空间不足而压缩了轮盘。
  final bool? canvasCompressed;

  /// 屏幕适配系数（1.0 = 未压缩）。
  final double? canvasScreenFactor;

  /// 已成功完成的固定画布重建次数。
  final int? canvasRebuildCount;

  /// 最近一次重建后的桌宠屏幕锚点误差（px）。
  final double? canvasAnchorErrorPx;

  /// DPI（= 96 × devicePixelRatio）。
  double? get dpi {
    final double? dpr = devicePixelRatio;
    if (dpr == null) return null;
    return 96 * dpr;
  }

  bool get passed => assertionFailures.isEmpty;

  /// 冻结的键顺序（复制文本与展示共用）。
  static const List<String> frozenKeys = <String>[
    'fixedCanvasRect',
    'petAnchor',
    'petScreenRect',
    'menuLocalRect',
    'interactionRegionRects',
    'devicePixelRatio',
    'dpi',
    'regionApplyResult',
    'regionBoundingBox',
    'gdiObjectCount',
    'windowRectBeforeOpen',
    'windowRectAfterOpen',
    'windowRectAfterClose',
    'menuOnRight',
    'assertionFailures',
    'wheelUiState',
    'wheelInteractionState',
    'regionOwner',
    'levelId',
    'highlightIndex',
    'themeId',
    'wheelScale',
    'buttonScale',
    'menuDistance',
    'effectiveWheelScale',
    'canvasCompressed',
    'canvasScreenFactor',
    'canvasRebuildCount',
    'canvasAnchorErrorPx',
  ];

  Map<String, Object?> toMap() => <String, Object?>{
        'fixedCanvasRect': _rect(fixedCanvasRect),
        'petAnchor': _offset(petAnchor),
        'petScreenRect': _rect(petScreenRect),
        'menuLocalRect': _rect(menuLocalRect),
        'interactionRegionRects': interactionRegionRects
            .map((Rect r) => _rect(r))
            .join(' | '),
        'devicePixelRatio': devicePixelRatio,
        'dpi': dpi,
        'regionApplyResult': regionApplyResult?.toString() ?? 'none',
        'regionBoundingBox': regionBoundingBox?.toString() ?? 'none',
        'gdiObjectCount': gdiObjectCount,
        'windowRectBeforeOpen': _rect(windowRectBeforeOpen),
        'windowRectAfterOpen': _rect(windowRectAfterOpen),
        'windowRectAfterClose': _rect(windowRectAfterClose),
        'menuOnRight': menuOnRight,
        'assertionFailures':
            assertionFailures.isEmpty ? 'none' : assertionFailures.join(' | '),
        'wheelUiState': wheelUiState,
        'wheelInteractionState': wheelInteractionState,
        'regionOwner': regionOwner,
        'levelId': levelId,
        'highlightIndex': highlightIndex,
        'themeId': themeId,
        'wheelScale': wheelScale,
        'buttonScale': buttonScale,
        'menuDistance': menuDistance,
        'effectiveWheelScale': effectiveWheelScale,
        'canvasCompressed': canvasCompressed,
        'canvasScreenFactor': canvasScreenFactor,
        'canvasRebuildCount': canvasRebuildCount,
        'canvasAnchorErrorPx': canvasAnchorErrorPx,
      };

  /// 稳定的 `key=value` 文本（每行一个键，顺序固定，便于 grep / 对账）。
  String toCopyText() {
    final Map<String, Object?> map = toMap();
    final StringBuffer buffer = StringBuffer('fixed_canvas_probe=1');
    for (final String key in frozenKeys) {
      buffer.write('\n$key=${map[key] ?? 'none'}');
    }
    return buffer.toString();
  }

  static String _rect(Rect? rect) {
    if (rect == null) return 'none';
    return '${_round(rect.left)},${_round(rect.top)} '
        '${_round(rect.width)}×${_round(rect.height)}';
  }

  static String _offset(Offset? offset) {
    if (offset == null) return 'none';
    return '${_round(offset.dx)},${_round(offset.dy)}';
  }

  static num _round(double value) {
    final double rounded = double.parse(value.toStringAsFixed(1));
    if (rounded == rounded.roundToDouble()) return rounded.toInt();
    return rounded;
  }
}

/// 探针硬断言（任何窗口矩形在开合菜单时的变化都算失败）。
class FixedCanvasAssertions {
  FixedCanvasAssertions._();

  /// 允许的偏差（像素）。
  static const double tolerancePx = 1.0;

  /// 校验一次"打开 → 关闭"往返。
  ///
  /// 返回失败原因列表（空 = 通过）。
  static List<String> evaluate({
    required Rect? before,
    required Rect? afterOpen,
    required Rect? afterClose,
    required Rect? petScreenBefore,
    required Rect? petScreenAfterOpen,
    required Rect? petScreenAfterClose,
  }) {
    final List<String> failures = <String>[];
    if (before == null || afterOpen == null || afterClose == null) {
      failures.add('windowRect 缺失：before/afterOpen/afterClose 都必须可读');
      return failures;
    }
    if (!_sameRect(before, afterOpen)) {
      failures.add(
        'windowRectBeforeOpen != windowRectAfterOpen'
        '（${_fmt(before)} vs ${_fmt(afterOpen)}）',
      );
    }
    if (!_sameRect(before, afterClose)) {
      failures.add(
        'windowRectBeforeOpen != windowRectAfterClose'
        '（${_fmt(before)} vs ${_fmt(afterClose)}）',
      );
    }
    if (petScreenBefore != null && petScreenAfterOpen != null) {
      final double error = _rectError(petScreenBefore, petScreenAfterOpen);
      if (error > tolerancePx) {
        failures.add('桌宠屏幕矩形误差 ${error.toStringAsFixed(2)}px > 1px（打开后）');
      }
    }
    if (petScreenBefore != null && petScreenAfterClose != null) {
      final double error = _rectError(petScreenBefore, petScreenAfterClose);
      if (error > tolerancePx) {
        failures.add('桌宠屏幕矩形误差 ${error.toStringAsFixed(2)}px > 1px（关闭后）');
      }
    }
    return failures;
  }

  static bool _sameRect(Rect a, Rect b) =>
      _rectError(a, b) <= tolerancePx;

  static double _rectError(Rect a, Rect b) =>
      (a.left - b.left).abs() +
      (a.top - b.top).abs() +
      (a.width - b.width).abs() +
      (a.height - b.height).abs();

  static String _fmt(Rect r) =>
      '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
      '${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)}';
}
