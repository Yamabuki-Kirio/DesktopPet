/// **桌宠屏幕位置的唯一语义**（真机回归：启动后桌宠不可见）。
///
/// 背景
/// ----
/// 启动阶段曾存在**两套位置语义**，互不认识：
///
/// 1. 旧 `WindowsWindowController` 把 `settings.windowX/Y` 当作**窗口左上角**；
/// 2. 固定画布把同一对字段当作 **`petScreenPosition`**（人物可见区域左上角）。
///
/// 于是出现这样的启动链（真机日志）：
///
/// ```
/// 位置加载 (-300, 307)
///   → 旧小窗口路径 moveTo(-300,307)，夹取后临时放到 (1640, 824)   ← 只改了 HWND
///   → 固定画布初始化**重新读旧设置** (-300, 307) 当 petScreenPosition
///   → canvasWindowRect = (-300 - petAnchor.dx, …) = (-633, 13, 922×844)
///   → 人物矩形 = (-300, 307, 256×256)，与显示器 [0,1920] 交集为 0
///   → 但旧的可见性判据检查的是 **画布矩形**（289×844 相交）→ 判定"够了"
///   → show()，日志写"桌宠显示"，人物实际在屏幕外
/// ```
///
/// 本文件把语义、迁移、校验、修正全部收进**纯函数**，让启动路径只有**一个**位置口径：
///
/// * [WindowPositionSchema.current] = v2：`settings.windowX/Y` == `petScreenPosition`；
/// * v1（或无版本）：旧窗口左上角，**不可**直接当 petScreenPosition 用；
/// * 迁移只做一次；不猜测语义不明的旧值，直接回退默认位置并写回 v2。
///
/// 纯 Dart（只依赖 `dart:ui` 与同层几何），可在 `flutter_tester` 直接单测，
/// 也不破坏 Android 平台隔离（见 `test/platform_isolation_test.dart`）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'wheel_geometry.dart' show WheelDisplayArea;

/// 位置语义版本。
///
/// * [v1]：`windowX/Y` = **窗口左上角**（固定画布启用前）。
/// * [v2]：`windowX/Y` = **`petScreenPosition`**（桌宠可见区域左上角）。
abstract final class WindowPositionSchema {
  /// 旧语义：窗口左上角。
  static const int v1 = 1;

  /// 当前语义：人物屏幕位置（`petScreenPosition`）。
  static const int v2 = 2;

  /// 写入时使用的版本。
  static const int current = v2;

  /// 无版本（历史数据）。
  static const int none = 0;

  static String nameOf(int version) => switch (version) {
        v1 => 'v1_window_topleft',
        v2 => 'v2_pet_screen_position',
        _ => 'none',
      };

  /// 该版本是否把 `windowX/Y` 解释为 `petScreenPosition`。
  static bool isPetScreenPosition(int version) => version == v2;
}

/// 位置解析来源（诊断 / 验收用，可判定）。
enum PetPositionSource {
  /// 来自已存的 v2 值，且校验通过。
  v2('v2'),

  /// v1 值 + 可确认的旧窗口尺寸 ≈ 人物尺寸 → 直接转换。
  migratedV1Exact('migrated_v1_exact'),

  /// v1 / 无版本且语义无法确定 → 回退默认位置（**不猜测**）。
  migratedV1Unknown('migrated_v1_unknown'),

  /// 无保存值（首次启动）= 回退默认位置。
  firstRun('first_run'),

  /// v2 值存在但不可见 → 修正到默认位置。
  correctedInvisible('corrected_invisible');

  const PetPositionSource(this.wireName);

  final String wireName;

  /// 是否发生过"写回 v2"的迁移 / 修正（外壳据此持久化）。
  bool get needsPersist =>
      this == migratedV1Exact ||
      this == migratedV1Unknown ||
      this == firstRun ||
      this == correctedInvisible;
}

/// 一次位置解析的结果。
class PetPositionResolution {
  const PetPositionResolution({
    required this.petScreenPosition,
    required this.petScreenRect,
    required this.source,
    required this.schemaVersion,
    required this.visibleRatio,
    required this.targetDisplayId,
    required this.corrected,
    required this.needsPersist,
    required this.reason,
  });

  /// 最终采用的**人物屏幕位置**（= 可见区域左上角）。
  final Offset petScreenPosition;

  /// 人物屏幕矩形（= [petScreenPosition] & 人物可见尺寸）。
  final Rect petScreenRect;

  final PetPositionSource source;

  /// 写出时应记录的版本（本实现恒为 [WindowPositionSchema.v2]）。
  final int schemaVersion;

  /// 与目标显示器工作区的可见面积比例（0~1）。
  final double visibleRatio;

  /// 选中显示器的 id（用于诊断 / 验收）。
  final String? targetDisplayId;

  /// 是否发生过修正（含迁移 / 回退默认）。
  final bool corrected;

  /// 是否需要立刻持久化（**禁止后续再读旧值**）。
  final bool needsPersist;

  /// 人类可读原因（直接进日志）。
  final String reason;

  bool get isVisible => visibleRatio >= PetPositionResolver.minVisibleRatio;
}

/// 目标显示器与工作区。
class PetDisplayTarget {
  const PetDisplayTarget({required this.area, required this.isPrimary});

  final WheelDisplayArea area;
  final bool isPrimary;

  String get id => area.id;

  Rect get rect => area.rect;
}

/// 位置语义解析 + 可见性校验（**纯函数**）。
class PetPositionResolver {
  PetPositionResolver._();

  /// 人物可见面积的最低比例；低于它就判定"不可见"并修正。
  ///
  /// 取 0.5：至少一半人物在屏内。这是"用户主动拖到边缘"与"数据坏了"的分界 ——
  /// 旧的 `moveTo` 夹取口径是"任一侧至少 48px"，对 256px 的人物相当于 19%，
  /// 不足以拦住"只剩一条边在屏内"的坏数据。
  static const double minVisibleRatio = 0.5;

  /// 默认位置的安全边距（右下角）。
  static const double defaultMargin = 32;

  /// 解析启动位置。
  ///
  /// * [savedX] / [savedY]：`settings.windowX/Y` 原值（可能为 null）。
  /// * [savedSchema]：这些值被写入时的语义版本（[WindowPositionSchema.none] = 无版本）。
  /// * [legacyWindowSize]：v1 数据写入时**窗口**的尺寸；仅当它约等于
  ///   [petVisibleSize] 时，v1 的窗口左上角才等价于人物左上角（可安全转换）。
  ///   传 null 表示语义无法确定 → 不猜测，回退默认。
  /// * [petVisibleSize]：人物**实际可见尺寸**（素材尺寸 × 缩放）。
  /// * [displays]：全部显示器（至少一块；顺序无关）。
  /// * [primaryDisplay]：主显示器（[displays] 中找不到时兜底）。
  static PetPositionResolution resolve({
    required double? savedX,
    required double? savedY,
    required int savedSchema,
    required Size petVisibleSize,
    required List<PetDisplayTarget> displays,
    Size? legacyWindowSize,
    PetDisplayTarget? primaryDisplay,
  }) {
    final PetDisplayTarget? primary = _pickPrimary(displays, primaryDisplay);
    if (primary == null || petVisibleSize.width <= 0 || petVisibleSize.height <= 0) {
      // 连显示器都拿不到：返回一个确定可用的位置，绝不返回 null。
      return PetPositionResolution(
        petScreenPosition: const Offset(defaultMargin, defaultMargin),
        petScreenRect: Rect.fromLTWH(
          defaultMargin,
          defaultMargin,
          math.max(petVisibleSize.width, 1),
          math.max(petVisibleSize.height, 1),
        ),
        source: PetPositionSource.firstRun,
        schemaVersion: WindowPositionSchema.current,
        visibleRatio: 0,
        targetDisplayId: null,
        corrected: true,
        needsPersist: true,
        reason: 'no_display',
      );
    }

    final bool hasSaved = savedX != null && savedY != null;
    if (!hasSaved) {
      return _defaultFor(
        primary,
        petVisibleSize,
        PetPositionSource.firstRun,
        'no_saved_position',
      );
    }

    final Offset saved = Offset(savedX, savedY);

    // --- 语义迁移 -----------------------------------------------------------
    if (!WindowPositionSchema.isPetScreenPosition(savedSchema)) {
      // v1 / 无版本：旧值是**窗口左上角**。
      final bool convertible = legacyWindowSize != null &&
          _approx(legacyWindowSize.width, petVisibleSize.width) &&
          _approx(legacyWindowSize.height, petVisibleSize.height);
      if (!convertible) {
        // 不猜测：语义无法确定时直接回退默认位置并写回 v2。
        return _defaultFor(
          primary,
          petVisibleSize,
          PetPositionSource.migratedV1Unknown,
          'schema_${WindowPositionSchema.nameOf(savedSchema)}_unknown_window_size',
        );
      }
      // 窗口尺寸 == 人物尺寸 ⇒ 窗口左上角就是人物左上角，可安全转换。
      final PetPositionResolution asPet = _validate(
        saved,
        petVisibleSize,
        displays,
        primary,
        source: PetPositionSource.migratedV1Exact,
        schemaVersion: WindowPositionSchema.current,
        corrected: true, // 需要立刻写回 v2（"迁移只执行一次"）
        needsPersist: true,
        reason: 'schema_${WindowPositionSchema.nameOf(savedSchema)}_window_eq_pet',
      );
      return asPet.isVisible
          ? asPet
          : _defaultFor(
              primary,
              petVisibleSize,
              PetPositionSource.migratedV1Exact,
              'migrated_position_invisible',
            );
    }

    // --- v2：直接校验可见性 ------------------------------------------------
    final PetPositionResolution v2 = _validate(
      saved,
      petVisibleSize,
      displays,
      primary,
      source: PetPositionSource.v2,
      schemaVersion: WindowPositionSchema.current,
      corrected: false,
      needsPersist: false,
      reason: 'v2_saved',
    );
    if (v2.isVisible) return v2;

    // v2 但不可见（例如 (-300, 307) 落在所有显示器之外）→ 修正 + 立刻写回。
    return _defaultFor(
      primary,
      petVisibleSize,
      PetPositionSource.correctedInvisible,
      'v2_invisible_ratio_${v2.visibleRatio.toStringAsFixed(3)}',
    );
  }

  /// 由 [displays] 与 [primaryDisplay] 选出主显示器（兜底取第一块）。
  static PetDisplayTarget? _pickPrimary(
    List<PetDisplayTarget> displays,
    PetDisplayTarget? primaryDisplay,
  ) {
    for (final PetDisplayTarget d in displays) {
      if (d.isPrimary) return d;
    }
    if (primaryDisplay != null) return primaryDisplay;
    return displays.isEmpty ? null : displays.first;
  }

  /// 校验 + 选择目标显示器（**不改位置**）。
  static PetPositionResolution _validate(
    Offset petScreen,
    Size petSize,
    List<PetDisplayTarget> displays,
    PetDisplayTarget primary, {
    required PetPositionSource source,
    required int schemaVersion,
    required bool corrected,
    required bool needsPersist,
    required String reason,
  }) {
    final Rect pet = Rect.fromLTWH(petScreen.dx, petScreen.dy, petSize.width, petSize.height);

    // 选显示器：用人物矩形**中心**命中（左上角对"半出屏"的位置会误判）。
    PetDisplayTarget target = primary;
    for (final PetDisplayTarget d in displays) {
      if (d.rect.contains(pet.center)) {
        target = d;
        break;
      }
    }

    final double ratio = visibleRatio(pet, target.rect);
    return PetPositionResolution(
      petScreenPosition: petScreen,
      petScreenRect: pet,
      source: source,
      schemaVersion: schemaVersion,
      visibleRatio: ratio,
      targetDisplayId: target.id,
      corrected: corrected,
      needsPersist: needsPersist,
      reason: reason,
    );
  }

  /// 某个显示器上的默认人物位置（右下角，保留 [defaultMargin] 安全边距）。
  static Offset defaultPetScreenPosition({
    required WheelDisplayArea area,
    required Size petSize,
    double margin = defaultMargin,
  }) {
    final double x = area.rect.right - petSize.width - margin;
    final double y = area.rect.bottom - petSize.height - margin;
    // 屏幕比人物还小 → 至少保证左上角在屏内。
    return Offset(
      x < area.rect.left ? area.rect.left : x,
      y < area.rect.top ? area.rect.top : y,
    );
  }

  static PetPositionResolution _defaultFor(
    PetDisplayTarget display,
    Size petSize,
    PetPositionSource source,
    String reason,
  ) {
    final Offset position =
        defaultPetScreenPosition(area: display.area, petSize: petSize);
    final Rect pet =
        Rect.fromLTWH(position.dx, position.dy, petSize.width, petSize.height);
    return PetPositionResolution(
      petScreenPosition: position,
      petScreenRect: pet,
      source: source,
      schemaVersion: WindowPositionSchema.current,
      visibleRatio: visibleRatio(pet, display.rect),
      targetDisplayId: display.id,
      corrected: true,
      needsPersist: true,
      reason: reason,
    );
  }

  /// 矩形 [rect] 落在 [area] 内的面积比例（0~1）。
  static double visibleRatio(Rect rect, Rect area) {
    final double rectArea = rect.width * rect.height;
    if (rectArea <= 0) return 0;
    final Rect inter = rect.intersect(area);
    if (inter.isEmpty) return 0;
    return (inter.width * inter.height) / rectArea;
  }

  static bool _approx(double a, double b) => (a - b).abs() <= 1.0;
}

/// **固定画布窗口位置**的计算（唯一公式）。
///
/// 保存 / 恢复 / 校验三处必须用同一个公式，否则又会出现两套语义。
class PetWindowPosition {
  PetWindowPosition._();

  /// `petScreenPosition = fixedCanvasWindowPosition + petAnchor`（**保存**公式）。
  static Offset petScreenFromWindow({
    required Offset windowPosition,
    required Offset petAnchor,
  }) =>
      Offset(
        windowPosition.dx + petAnchor.dx,
        windowPosition.dy + petAnchor.dy,
      );

  /// `fixedCanvasWindowPosition = petScreenPosition - petAnchor`（**恢复**公式）。
  static Offset windowFromPetScreen({
    required Offset petScreenPosition,
    required Offset petAnchor,
  }) =>
      Offset(
        petScreenPosition.dx - petAnchor.dx,
        petScreenPosition.dy - petAnchor.dy,
      );
}

/// 启动路径的**位置写入策略**。
///
/// 固定画布模式下**禁止**先按小窗口执行旧 `applySettings` / `moveTo` 再建画布 ——
/// 那条路只会把 HWND 挪来挪去，随后画布又从旧设置重读一次位置。
abstract final class PetWindowStartupPolicy {
  /// 旧"小窗口位置恢复 / 夹取 / 默认角落"是否允许执行。
  ///
  /// 固定画布启用时为 **false**：位置由画布事务（`prepareFixedCanvas`）独占，
  /// 窗口在 show 之前一直保持隐藏。
  static bool allowsLegacySmallWindowPositioning({required bool fixedCanvasEnabled}) =>
      !fixedCanvasEnabled;

  /// 旧"按素材尺寸写窗口尺寸"是否允许执行。
  ///
  /// 固定画布启用时为 **false**：画布物理矩形固定，尺寸由画布事务提交。
  static bool allowsLegacySmallWindowResize({required bool fixedCanvasEnabled}) =>
      !fixedCanvasEnabled;
}
