/// **轮盘内调整层**（增量 C1）：点「轮盘大小 / 按钮大小 / 菜单距离 / 主题」不跳控制面板，
/// 而是在轮盘里进入一个固定的调整层，就地加减、恢复默认、返回。
///
/// 为什么要有这个文件
/// ------------------
/// Android 的调整层是**数据驱动**的：层级、条目、步进、上下限都在一处声明，
/// 视图只负责渲染。Windows 若把"减小 / 增加"的逻辑散进 Painter / View / 设置页，
/// 迟早出现"界面显示 130% 而实际存的是 120%"这种不可判定的问题。
///
/// 因此这里把调整层收敛成**纯数据 + 纯函数**：
/// * [WheelAdjustmentKind]：可调整的量（含范围 / 步进 / 默认值 / 取值格式化）；
/// * [WheelAdjustmentLayer]：据当前值生成 5 个固定条目（减小 / 当前值 / 增大 / 恢复默认 / 返回）；
/// * [WheelSettingRevision]：明确版本的"设置修订号"，让并发的画布重建事务能判新旧，
///   **不依赖任何延时**。
library;

import 'dart:math' as math;

import 'menu_contract.dart'
    show MenuLevel, MenuNode, MenuNavigationIds;
import 'wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import 'wheel_theme.dart' show WheelMenuThemes, WheelThemeIds;

/// 可调整的量（**唯一**枚举）。
enum WheelAdjustmentKind {
  /// 轮盘主题（离散集合，不是数值）。
  theme(
    id: 'theme',
    levelId: 'adjust_theme',
    labelZh: '轮盘主题',
    min: 0,
    max: 0,
    step: 0,
    defaultValue: 0,
  ),

  /// 轮盘大小（50% ~ 250%，步进 10%）。
  wheelScale(
    id: 'wheel_scale',
    levelId: 'adjust_wheel_scale',
    labelZh: '轮盘大小',
    min: WheelMenuLayoutSettings.minScale,
    max: WheelMenuLayoutSettings.maxScale,
    step: WheelMenuLayoutSettings.step,
    defaultValue: WheelMenuLayoutSettings.defaultScale,
  ),

  /// 按钮大小（50% ~ 250%，步进 10%）。
  buttonScale(
    id: 'button_scale',
    levelId: 'adjust_button_scale',
    labelZh: '按钮大小',
    min: WheelMenuLayoutSettings.minButtonScale,
    max: WheelMenuLayoutSettings.maxButtonScale,
    step: WheelMenuLayoutSettings.step,
    defaultValue: WheelMenuLayoutSettings.defaultButtonScale,
  ),

  /// 菜单距离（0.05 ~ 0.30，步进 0.02）。
  menuDistance(
    id: 'menu_distance',
    levelId: 'adjust_menu_distance',
    labelZh: '菜单距离',
    min: WheelMenuLayoutSettings.minDistance,
    max: WheelMenuLayoutSettings.maxDistance,
    step: WheelMenuLayoutSettings.distanceStep,
    defaultValue: WheelMenuLayoutSettings.defaultDistance,
  );

  const WheelAdjustmentKind({
    required this.id,
    required this.levelId,
    required this.labelZh,
    required this.min,
    required this.max,
    required this.step,
    required this.defaultValue,
  });

  final String id;

  /// 调整层自己的层级 id（**不进** `MenuCatalog.levels`，避免污染跨端对账）。
  final String levelId;

  final String labelZh;

  final double min;
  final double max;
  final double step;
  final double defaultValue;

  /// 是否数值型（主题是离散集合）。
  bool get isNumeric => this != WheelAdjustmentKind.theme;

  /// 百分比量（显示成 `130%`）。
  bool get isPercent =>
      this == WheelAdjustmentKind.wheelScale ||
      this == WheelAdjustmentKind.buttonScale;

  /// 把数值格式化成用户看到的文案。
  String formatValue(double value) {
    if (this == WheelAdjustmentKind.theme) {
      return WheelMenuThemes.preset(
            _themeIdAt(value.round()),
          )?.displayName ??
          '自定义';
    }
    if (isPercent) return '${(value * 100).round()}%';
    return value.toStringAsFixed(2);
  }

  /// 从 levelId 反查（未知返回 null）。
  static WheelAdjustmentKind? fromLevelId(String? levelId) {
    if (levelId == null) return null;
    for (final WheelAdjustmentKind kind in WheelAdjustmentKind.values) {
      if (kind.levelId == levelId) return kind;
    }
    return null;
  }
}

/// 主题的离散取值顺序（与 Android 同款主题列表一致，**不建第二套 id**）。
const List<String> kWheelThemeOrder = <String>[
  WheelThemeIds.p3pPink,
  WheelThemeIds.blue,
  WheelThemeIds.red,
  WheelThemeIds.purple,
  WheelThemeIds.green,
  WheelThemeIds.custom,
];

String _themeIdAt(int index) => kWheelThemeOrder[
    index.clamp(0, kWheelThemeOrder.length - 1)];

/// 调整层的动作 id 助手（稳定、自描述，跨端可对账）。
abstract final class WheelAdjustmentActionIds {
  /// `adjust_<kindId>_decrease`
  static String decrease(WheelAdjustmentKind kind) => 'adjust_${kind.id}_decrease';

  /// `adjust_<kindId>_increase`
  static String increase(WheelAdjustmentKind kind) => 'adjust_${kind.id}_increase';

  /// `adjust_<kindId>_reset`
  static String reset(WheelAdjustmentKind kind) => 'adjust_${kind.id}_reset';

  /// `adjust_<kindId>_value`（只读展示，不可点）
  static String value(WheelAdjustmentKind kind) => 'adjust_${kind.id}_value';

  /// 全部调整动作 id（测试用）。
  static Set<String> get all => <String>{
        for (final WheelAdjustmentKind kind in WheelAdjustmentKind.values) ...<String>[
          decrease(kind),
          increase(kind),
          reset(kind),
          value(kind),
        ],
      };

  /// 解析动作 id → (kind, 方向)。不是调整动作时返回 null。
  static ({WheelAdjustmentKind kind, WheelAdjustmentVerb verb})? parse(
    String actionId,
  ) {
    for (final WheelAdjustmentKind kind in WheelAdjustmentKind.values) {
      if (actionId == decrease(kind)) {
        return (kind: kind, verb: WheelAdjustmentVerb.decrease);
      }
      if (actionId == increase(kind)) {
        return (kind: kind, verb: WheelAdjustmentVerb.increase);
      }
      if (actionId == reset(kind)) {
        return (kind: kind, verb: WheelAdjustmentVerb.reset);
      }
    }
    return null;
  }
}

/// 调整动作的三种语义。
enum WheelAdjustmentVerb { decrease, increase, reset }

/// 调整层的纯计算。
abstract final class WheelAdjustmentLayer {
  /// 生成调整层的层级定义。
  ///
  /// 固定 5 个条目：减小 / 当前值 / 增大 / 恢复默认 / 返回。
  /// [currentValue] 决定"当前值"条目显示的文案（以及图标）。
  static MenuLevel build(WheelAdjustmentKind kind, double currentValue) {
    final String shown = kind.formatValue(currentValue);
    // 为了让渲染层能把"当前值"画成非交互的信息行，同时**不新增枚举值**，
    // 这里用 `MenuActionKind.info` 语义的 actionId 前缀 `adjust_<kind>_value`；
    // `MenuActionDefinitions` 会把它登记成 info，因此永远不会被执行为业务动作。
    return MenuLevel(
      id: kind.levelId,
      titleZh: kind.labelZh,
      titleEn: kind.id.toUpperCase(),
      nodes: <MenuNode>[
        MenuNode(
          id: WheelAdjustmentActionIds.decrease(kind),
          actionId: WheelAdjustmentActionIds.decrease(kind),
          labelZh: '减小',
        ),
        MenuNode(
          id: WheelAdjustmentActionIds.value(kind),
          actionId: WheelAdjustmentActionIds.value(kind),
          labelZh: shown,
        ),
        MenuNode(
          id: WheelAdjustmentActionIds.increase(kind),
          actionId: WheelAdjustmentActionIds.increase(kind),
          labelZh: '增大',
        ),
        MenuNode(
          id: WheelAdjustmentActionIds.reset(kind),
          actionId: WheelAdjustmentActionIds.reset(kind),
          labelZh: '恢复默认',
        ),
        MenuNode(
          id: MenuNavigationIds.back,
          actionId: MenuNavigationIds.back,
          labelZh: '返回',
        ),
      ],
    );
  }

  /// 把数值**量化**到步进（并夹取到 [WheelAdjustmentKind.min]/[max]）。
  ///
  /// 量化用"最近步进"，与设置页滑杆的整数分档一致，避免出现 `0.1800000001`。
  static double quantize(WheelAdjustmentKind kind, double value) {
    if (!kind.isNumeric) return value;
    final double clamped = value.clamp(kind.min, kind.max);
    final double steps = ((clamped - kind.min) / kind.step).roundToDouble();
    final double quantized = kind.min + steps * kind.step;
    // 归一化到步进精度（避免浮点尾巴）。
    return double.parse(quantized.toStringAsFixed(4)).clamp(kind.min, kind.max);
  }

  /// 加减一步；已在边界时返回**原值**（调用方据此显示"已到边界"而不是误报成功）。
  static double stepped(WheelAdjustmentKind kind, double current, int direction) {
    if (!kind.isNumeric) return current;
    final double base = quantize(kind, current);
    final double next = quantize(kind, base + kind.step * direction);
    return next;
  }

  /// 主题的"上 / 下一个预设"（离散集合，循环）。
  static String nextThemeId(String currentThemeId, int direction) {
    final int index = kWheelThemeOrder.indexOf(currentThemeId);
    final int from = index < 0 ? 0 : index;
    final int next =
        (from + direction) % kWheelThemeOrder.length; // Dart 的 % 对负数返回非负
    return kWheelThemeOrder[next < 0 ? next + kWheelThemeOrder.length : next];
  }

  /// 取值是否已到边界（用于"已到最大 / 最小"反馈，而不是假装成功）。
  static bool atMin(WheelAdjustmentKind kind, double value) =>
      kind.isNumeric && quantize(kind, value) <= kind.min + 1e-9;

  static bool atMax(WheelAdjustmentKind kind, double value) =>
      kind.isNumeric && quantize(kind, value) >= kind.max - 1e-9;

  /// 是否就是默认值（用于"恢复默认"按钮的可用性 / 反馈文案）。
  static bool isDefault(WheelAdjustmentKind kind, double value) =>
      (quantize(kind, value) - kind.defaultValue).abs() <= 1e-9;

  /// 百分比 → 供 UI 显示的整数（`0.5 → 50`）。
  static int asPercent(double value) => (value * 100).round();

  /// 数值化的比例（0~1），供条形 / 圆环指示用。
  static double ratioOf(WheelAdjustmentKind kind, double value) {
    if (!kind.isNumeric || kind.max <= kind.min) return 0;
    return ((quantize(kind, value) - kind.min) / (kind.max - kind.min))
        .clamp(0.0, 1.0);
  }

  /// 主题列表（与 Android 同款）。
  static List<String> themeIds() => List<String>.unmodifiable(kWheelThemeOrder);

  static double clampToRange(WheelAdjustmentKind kind, double value) =>
      math.min(kind.max, math.max(kind.min, value));
}

/// **设置修订号**：每次设置变化递增。
///
/// 用途：尺寸变化可能触发固定画布重建；用户连续点"增大"时会产生多个重建请求。
/// 这里用**明确的版本号**代替"延时合并"：
/// * 每个请求携带发起时的 `revision`；
/// * 事务在真正提交前检查 `revision` 是否仍是最新 —— 不是就**直接放弃**；
/// * 因此最终只应用最新 revision，且**不依赖任何不可判定的延时**。
class WheelSettingRevision {
  int _value = 0;

  /// 当前修订号。
  int get value => _value;

  /// 递增并返回新值（每次设置写入成功后调用一次）。
  int bump() => ++_value;

  /// 给定修订号是否仍是最新。
  bool isCurrent(int revision) => revision == _value;

  @override
  String toString() => 'WheelSettingRevision($_value)';
}
