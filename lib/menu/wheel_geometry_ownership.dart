/// 窗口几何**所有权**与**代际（generation）**的唯一来源（增量 A 修复）。
///
/// 背景（真机缺陷）
/// ----------------
/// Windows 只有一个 HWND：桌宠窗口在"展开成轮盘"与"缩回桌宠"之间切换时，
/// 存在**多个写入者**争夺同一块窗口矩形——
/// * `PetView` 的 post-frame 回调会 `setSize(素材尺寸)`；
/// * 轮盘探针会 `setBounds(放大矩形)`；
/// * 控制面板切换会 `resizeTo(面板尺寸)`。
///
/// 由于 post-frame 回调是**异步排队**的，`manageWindowSize` 这个 widget 布尔量
/// 根本来不及取消已经入队的回调，于是放大后的窗口会被下一次 `setSize` 缩回，
/// 表现为"单击后菜单极小 / 布局错位，再点一次才正常"。
///
/// 修复思路
/// --------
/// 1. 引入显式 [WindowsSurfaceGeometryOwner]：任一时刻只有一个所有者；
/// 2. 每次所有权切换 `generation++`：所有延迟回调在**执行前**都要重查代际；
/// 3. 所有尺寸写入都记录到 [WheelGeometryJournal]，便于对账"谁覆盖了谁"。
///
/// 本文件是**纯 Dart**（只依赖 `dart:ui` 的矩形类型），可在 `flutter_tester`
/// 直接单测（见 `test/wheel_geometry_ownership_test.dart`）。
library;

import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import 'windows_surface_mode.dart';

/// 窗口几何的**所有者**。
///
/// * [pet]：正常桌宠态，允许按素材尺寸调整窗口；
/// * [wheelTransition]：轮盘展开 / 收起过渡期，**禁止**任何来自 PetView / 素材的窗口写入；
/// * [wheel]：轮盘已稳定显示，窗口由轮盘接管；
/// * [panel]：控制面板模式，窗口尺寸由面板流程接管。
enum WindowsSurfaceGeometryOwner {
  pet,
  wheelTransition,
  wheel,
  panel;

  /// 线上 / 日志取值（snake_case）。
  String get wireName => switch (this) {
        WindowsSurfaceGeometryOwner.pet => 'pet',
        WindowsSurfaceGeometryOwner.wheelTransition => 'wheel_transition',
        WindowsSurfaceGeometryOwner.wheel => 'wheel',
        WindowsSurfaceGeometryOwner.panel => 'panel',
      };
}

/// 几何所有权状态机（可监听，供 UI 重绘）。
class WheelSurfaceGeometry extends ChangeNotifier {
  WheelSurfaceGeometry({WheelGeometryJournal? journal})
      : _journal = journal ?? wheelGeometryJournal;

  final WheelGeometryJournal _journal;

  WindowsSurfaceGeometryOwner _owner = WindowsSurfaceGeometryOwner.pet;
  int _generation = 0;

  WindowsSurfaceGeometryOwner get owner => _owner;

  /// 代际：每次所有权切换 +1。延迟回调据此判断"是否已过期"。
  int get generation => _generation;

  /// 是否允许按素材尺寸调整窗口（只有 [pet] 态允许）。
  bool get allowsPetResize => _owner == WindowsSurfaceGeometryOwner.pet;

  /// 轮盘是否已打开或正在打开 / 关闭（过渡也算）。
  bool get isMenuOpen =>
      _owner == WindowsSurfaceGeometryOwner.wheel ||
      _owner == WindowsSurfaceGeometryOwner.wheelTransition;

  /// 是否处于轮盘过渡期（最容易发生竞态的窗口）。
  bool get isTransitioning => _owner == WindowsSurfaceGeometryOwner.wheelTransition;

  /// 切换所有权。**同值不切换、不递增代际**。
  ///
  /// 返回切换后的代际；调用方可据此记录"这次写入属于哪一代"。
  int change(WindowsSurfaceGeometryOwner next, {String source = 'unknown'}) {
    if (next == _owner) return _generation;
    final WindowsSurfaceGeometryOwner previous = _owner;
    _owner = next;
    _generation++;
    _journal.record(
      'geometry.owner.changed',
      fields: <String, Object?>{
        'from': previous.wireName,
        'owner': next.wireName,
        'source': source,
      },
    );
    _journal.record(
      'geometry.generation',
      fields: <String, Object?>{'generation': _generation, 'owner': next.wireName},
    );
    notifyListeners();
    return _generation;
  }

  /// 仅测试使用：复位到初始状态。
  @visibleForTesting
  void resetForTest() {
    _owner = WindowsSurfaceGeometryOwner.pet;
    _generation = 0;
  }
}

/// 模块级共享实例：PetView / 探针 / 最低层守卫必须读**同一个**所有者。
final WheelSurfaceGeometry wheelSurfaceGeometry = WheelSurfaceGeometry();

/// 一条几何事件（可断言、可复制）。
class WheelGeometryEvent {
  const WheelGeometryEvent(this.event, this.timestampMs, this.fields);

  /// 事件名（`geometry.owner.changed` / `pet.resize.dropped` / `wheel.present` …）。
  final String event;

  /// 发生时刻（毫秒时间戳）。
  final int timestampMs;

  final Map<String, Object?> fields;

  /// 稳定的单行文本，便于 grep / 对账。
  String toLine() {
    final StringBuffer buffer = StringBuffer('$event ts=$timestampMs');
    for (final MapEntry<String, Object?> entry in fields.entries) {
      buffer.write(' ${entry.key}=${entry.value ?? 'none'}');
    }
    return buffer.toString();
  }

  @override
  String toString() => toLine();
}

/// 几何事件日志（有界，避免刷屏）。
///
/// * 关键事件（所有权 / 提交 / 回滚 / 关闭）**始终**记录；
/// * 逐帧事件（`wheel.measure.frame`）只允许**诊断模式 + 前 12 帧**，
///   由调用方控制（见 [WheelOpenTransaction]）。
class WheelGeometryJournal extends ChangeNotifier {
  /// [capacity] 为 null 时使用 [maxEvents]；测试可放大以便完整对账长序列。
  WheelGeometryJournal({int? capacity}) : _capacity = capacity ?? maxEvents;

  /// 默认事件上限。
  static const int maxEvents = 600;

  /// 本实例的事件上限。
  final int _capacity;

  final List<WheelGeometryEvent> _events = <WheelGeometryEvent>[];

  /// 上一次尺寸写入后的**实际**窗口矩形（用于判断是否被后续写入覆盖）。
  Rect? _lastWriteAfter;

  List<WheelGeometryEvent> get events =>
      List<WheelGeometryEvent>.unmodifiable(_events);

  bool get isEmpty => _events.isEmpty;

  bool contains(String event) => _events.any((WheelGeometryEvent e) => e.event == event);

  WheelGeometryEvent? lastOf(String event) {
    for (int i = _events.length - 1; i >= 0; i--) {
      if (_events[i].event == event) return _events[i];
    }
    return null;
  }

  int countOf(String event) =>
      _events.where((WheelGeometryEvent e) => e.event == event).length;

  /// 记录一条事件。
  void record(String event, {Map<String, Object?> fields = const <String, Object?>{}}) {
    _events.add(WheelGeometryEvent(event, DateTime.now().millisecondsSinceEpoch, fields));
    if (_events.length > _capacity) {
      _events.removeRange(0, _events.length - _capacity);
    }
    notifyListeners();
  }

  /// 记录一次**窗口尺寸写入**（需求：每次写入都要能看出是谁覆盖了谁）。
  ///
  /// [requested] 是本次请求的矩形，[before] / [after] 是写入前 / 写入后**读回**的
  /// 实际矩形。若本次 `before` 与上一次写入的 `after` 不一致，说明两次写入之间
  /// 有"第三者"动过窗口（历史竞态的典型特征），在 `overwrote_previous` 标出。
  void recordSizeWrite({
    required String source,
    required int generation,
    required WindowsSurfaceGeometryOwner owner,
    required Rect? requested,
    required Rect? before,
    required Rect? after,
    String? note,
  }) {
    final Rect? previousAfter = _lastWriteAfter;
    final bool overwrotePrevious = previousAfter != null &&
        before != null &&
        !_approxRectSame(before, previousAfter);
    record(
      'geometry.size.write',
      fields: <String, Object?>{
        'source': source,
        'generation': generation,
        'owner': owner.wireName,
        'requested': formatRect(requested),
        'before': formatRect(before),
        'after': formatRect(after),
        'overwrote_previous': overwrotePrevious,
        if (note != null) 'note': note,
      },
    );
    _lastWriteAfter = after ?? _lastWriteAfter;
  }

  /// 全部事件文本（最新在后）。
  List<String> get lines =>
      _events.map((WheelGeometryEvent e) => e.toLine()).toList(growable: false);

  String toCopyText() {
    final StringBuffer buffer = StringBuffer('wheel_geometry_journal=1')
      ..write('\nevent_count=${_events.length}');
    for (final WheelGeometryEvent event in _events) {
      buffer.write('\n${event.toLine()}');
    }
    return buffer.toString();
  }

  void clear() {
    _events.clear();
    _lastWriteAfter = null;
    notifyListeners();
  }

  /// `left,top w×h`；null → `none`。
  static String formatRect(Rect? rect) {
    if (rect == null) return 'none';
    return '${_round(rect.left)},${_round(rect.top)} '
        '${_round(rect.width)}×${_round(rect.height)}';
  }

  static String formatOffset(Offset? offset) {
    if (offset == null) return 'none';
    return '${_round(offset.dx)},${_round(offset.dy)}';
  }

  static bool _approxRectSame(Rect a, Rect b) =>
      (a.left - b.left).abs() < 0.5 &&
      (a.top - b.top).abs() < 0.5 &&
      (a.width - b.width).abs() < 0.5 &&
      (a.height - b.height).abs() < 0.5;

  static num _round(double value) {
    final double rounded = double.parse(value.toStringAsFixed(1));
    if (rounded == rounded.roundToDouble()) return rounded.toInt();
    return rounded;
  }
}

/// 模块级共享实例：探针 / PetView / 最低层守卫共同写入。
final WheelGeometryJournal wheelGeometryJournal = WheelGeometryJournal();

/// 判断一次**延迟的** pet resize 是否仍应执行。
///
/// 供 PetView 与最低层守卫共用，避免两处判断漂移。
class PetResizeDecision {
  PetResizeDecision._();

  /// 返回 null 表示允许执行；否则返回"丢弃原因"（用于日志）。
  static String? evaluate({
    required bool mounted,
    required int scheduledGeneration,
    required WheelSurfaceGeometry surface,
  }) {
    if (!mounted) return 'unmounted';
    // **模式守卫必须最先查**：过渡 / 面板态下任何桌宠 resize 都必须被丢弃。
    if (!windowsSurfaceSession.mode.allowsPetResize) {
      return 'surface_${windowsSurfaceSession.mode.wireName}';
    }
    if (scheduledGeneration != surface.generation) return 'generation_changed';
    if (!surface.allowsPetResize) return 'owner_${surface.owner.wireName}';
    if (surface.isMenuOpen) return 'menu_open';
    return null;
  }
}
