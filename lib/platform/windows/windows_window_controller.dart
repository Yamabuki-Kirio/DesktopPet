import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/logger.dart';
import '../../menu/fixed_canvas_contract.dart';
import '../../menu/fixed_canvas_geometry.dart';
import '../../menu/pet_position_resolver.dart'
    show PetWindowStartupPolicy, WindowPositionSchema;
import '../../menu/wheel_geometry_ownership.dart';
import '../../menu/windows_surface_mode.dart';
import '../../settings/app_settings.dart';
import 'display_topology.dart';
import '../../desktop_window/window_controller.dart';

/// Windows 桌宠窗口控制器。
///
/// 用到的原生能力全部来自 `window_manager`（它底层是 Win32 API 的 Dart 封装）：
/// 透明背景、无边框、始终置顶、鼠标穿透、跳过任务栏、位置读写。
/// 因此阶段 0 不需要自己写 C++ 插件——需求只要求「Windows 原生能力使用 C++ 插件**或** Dart FFI」，
/// `window_manager` 走的正是 FFI 路线。
class WindowsWindowController with WindowListener implements WindowController {
  WindowsWindowController();

  DisplayTopology _displays = DisplayTopology.empty();

  void Function(double x, double y)? _onPositionCommitted;
  void Function()? _onCloseRequested;

  /// 上一帧的尺寸，用于在窗口尺寸变化时重新夹取位置。
  double _contentWidth = 256;
  double _contentHeight = 192;

  bool _initialized = false;

  /// 「程序化改窗口」区间标记（轮盘菜单几何提交期间为 true）。
  bool _externalBoundsChange = false;

  @override
  Future<void> initialize({required AppSettings settings}) async {
    if (_initialized) return;

    await windowManager.ensureInitialized();
    _displays = await DisplayTopology.load();

    final Size initialSize = Size(_contentWidth * settings.scale, _contentHeight * settings.scale);

    final WindowOptions options = WindowOptions(
      size: initialSize,
      center: false,
      backgroundColor: const Color(0x00000000),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: settings.alwaysOnTop,
      title: 'PetLife',
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
      await windowManager.setHasShadow(false);
      await windowManager.setPreventClose(true);
      // 固定画布探针（本轮新方向）：窗口必须**先**建立固定画布 + 窗口 Region
      // 再显示，否则会先闪出一个矩形窗口。因此这里**不**立即 show()，
      // 交给外壳在 `prepareFixedCanvas()` 完成之后 `setVisible(true)`。
      if (PetWindowProbeFlags.fixedCanvasRegionProbeEnabled) {
        Loggers.window.info('固定画布模式：窗口延迟显示（等待 canvas + Region 就绪）');
      } else {
        await windowManager.show();
      }
    });

    windowManager.addListener(this);
    _initialized = true;
    Loggers.window.info('桌宠窗口初始化完成: size=${initialSize.width.toInt()}x${initialSize.height.toInt()}');

    await applySettings(settings);
  }

  @override
  Future<void> applySettings(AppSettings settings) async {
    if (!_initialized) return;

    await _try('setAlwaysOnTop', () => windowManager.setAlwaysOnTop(settings.alwaysOnTop));

    // 鼠标穿透：forward: true 让点击落到下层窗口，桌宠变成纯装饰。
    await _try(
      'setIgnoreMouseEvents',
      () => windowManager.setIgnoreMouseEvents(settings.ignoreMouseEvents, forward: true),
    );

    // 「锁定位置」不调用 setMovable —— 这是一个真机踩到的坑：
    // window_manager 的 Dart 侧暴露了 setMovable/isMovable，但 Windows 原生插件
    // (windows/window_manager_plugin.cpp) 并未注册这两个方法，调用会抛
    // MissingPluginException 并中断整个启动流程。
    // 锁定实际上完全由 Dart 侧负责：PetView 依据 settings.lockPosition 决定是否挂
    // onPanStart（唯一的拖动入口），并同步切换光标。
    // 因此去掉这次原生调用不损失任何功能，见 docs/06。

    // ---------------------------------------------------------------------------
    // 位置与尺寸（真机回归：启动后桌宠不可见）
    // ---------------------------------------------------------------------------
    //
    // 旧的"按小窗口恢复位置 / 夹取 / 默认角落 + 按素材尺寸写窗口"这一整条路
    // **必须**在固定画布模式下整体跳过。它曾造成这条启动链：
    //
    //   位置加载 (-300, 307)
    //     → moveTo(-300,307) 按 256×192 小窗口夹取，临时挪到 (1640, 824)  ← 只改 HWND
    //     → 固定画布初始化**重读旧设置** (-300, 307) 当 petScreenPosition
    //     → 画布 (‑633, 13, 922×844)、人物 (‑300, 307, 256×256) 与显示器交集为 0
    //     → 可见性判据检查的是**画布**而不是**人物** → 判定"够了" → show()
    //
    // 固定画布启用后：窗口保持**隐藏**；位置与尺寸由外壳的 `prepareFixedCanvas()`
    // 独占（`PetPositionResolver` 解析 → 一次 `SetWindowPos` → Region → 回读校验）。
    if (!PetWindowStartupPolicy.allowsLegacySmallWindowPositioning(
      fixedCanvasEnabled: PetWindowProbeFlags.fixedCanvasRegionProbeEnabled,
    )) {
      wheelGeometryJournal.record(
        'startup.legacy_move_skipped',
        fields: <String, Object?>{
          'source': 'WindowsWindowController.applySettings',
          'reason': 'fixed_canvas_owns_position',
          'savedX': settings.windowX ?? 'none',
          'savedY': settings.windowY ?? 'none',
          'schema': WindowPositionSchema.nameOf(settings.windowPositionSchema),
          'resizeLegacy': PetWindowStartupPolicy.allowsLegacySmallWindowResize(
            fixedCanvasEnabled: PetWindowProbeFlags.fixedCanvasRegionProbeEnabled,
          ),
        },
      );
      Loggers.window.info(
        '固定画布模式：跳过旧小窗口位置恢复（位置由固定画布事务独占，窗口保持隐藏）',
      );
      return;
    }

    await resizeForContent(contentWidth: _contentWidth, contentHeight: _contentHeight);
    await _applyLegacySmallWindowPosition(settings);
  }

  /// 旧路线的位置恢复（**仅非固定画布时可达**；保留以便回退旧路线时行为不变）。
  Future<void> _applyLegacySmallWindowPosition(AppSettings settings) async {
    final double? x = settings.windowX;
    final double? y = settings.windowY;
    if (x != null && y != null) {
      final Offset? anchor = fixedCanvasAnchor.anchor;
      if (fixedCanvasAnchor.enabled && anchor != null) {
        await moveTo(x - anchor.dx, y - anchor.dy);
      } else {
        await moveTo(x, y);
      }
    } else {
      await _moveToDefaultCorner(settings);
    }

    Loggers.window.info(
      '窗口设置已应用: 置顶=${settings.alwaysOnTop} 穿透=${settings.ignoreMouseEvents} '
      '锁定位置=${settings.lockPosition}（Dart 侧生效）缩放=${settings.scale}',
    );
  }

  /// 单个窗口设置失败不应中断启动流程。
  ///
  /// 某些平台会缺失个别方法（见上面 setMovable 的说明），
  /// 这类失败只降级、不致命——否则一个装饰性开关会让桌宠完全起不来。
  Future<void> _try(String label, Future<void> Function() op) async {
    try {
      await op();
    } catch (e, st) {
      Loggers.window.warning('窗口操作 $label 失败（已忽略，功能降级）', e, st);
    }
  }

  @override
  Future<void> resizeForContent({
    required double contentWidth,
    required double contentHeight,
  }) async {
    _contentWidth = contentWidth;
    _contentHeight = contentHeight;
    if (!_initialized) return;
    // 模式守卫（**必须最先查**）：只有稳定的桌宠态允许素材尺寸写窗口。
    // 过渡 / 面板态下，任何延迟排队的 pet resize 都不得覆盖面板几何。
    if (!windowsSurfaceSession.mode.allowsPetResize) {
      wheelGeometryJournal.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'source': 'WindowsWindowController.resizeForContent',
          'reason': 'surface_${windowsSurfaceSession.mode.wireName}',
          'w': contentWidth,
          'h': contentHeight,
        },
      );
      return;
    }
    // 固定画布模式：画布物理矩形**固定**，素材尺寸变化**不得**写窗口
    // （否则会把固定画布缩成桌宠大小，Region 也随之失效）。
    // 画布与 Region 由外壳在 `prepareFixedCanvas()` 中统一（重）建立。
    if (fixedCanvasAnchor.enabled) {
      wheelGeometryJournal.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'source': 'WindowsWindowController.resizeForContent',
          'reason': 'fixed_canvas',
          'w': contentWidth,
          'h': contentHeight,
        },
      );
      return;
    }
    // 最低层守卫：轮盘过渡 / 展示、或控制面板接管期间，素材尺寸变化**不得**写窗口。
    // UI 层的 manageWindowSize 只能阻止"新的调度"，无法取消已入队的回调。
    if (!wheelSurfaceGeometry.allowsPetResize) {
      wheelGeometryJournal.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'source': 'WindowsWindowController.resizeForContent',
          'owner': wheelSurfaceGeometry.owner.wireName,
          'generation': wheelSurfaceGeometry.generation,
          'w': contentWidth,
          'h': contentHeight,
        },
      );
      return;
    }
    final Size size = Size(contentWidth, contentHeight);
    final Rect? before = await _readBoundsOrNull();
    await windowManager.setSize(size);
    final Rect? after = await _readBoundsOrNull();
    wheelGeometryJournal.recordSizeWrite(
      source: 'WindowsWindowController.resizeForContent',
      generation: wheelSurfaceGeometry.generation,
      owner: wheelSurfaceGeometry.owner,
      requested: Rect.fromLTWH(before?.left ?? 0, before?.top ?? 0, contentWidth, contentHeight),
      before: before,
      after: after,
    );
  }

  Future<Rect?> _readBoundsOrNull() async {
    try {
      return await windowManager.getBounds();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> resizeTo(Size size) async {
    if (!_initialized) return;
    await windowManager.setSize(size);
  }

  @override
  Future<void> setResizable(bool resizable) async {
    if (!_initialized) return;
    await windowManager.setResizable(resizable);
  }

  @override
  Future<void> moveTo(double x, double y) async {
    if (!_initialized) return;
    final ({double x, double y}) safe = _displays.clamp(
      x,
      y,
      windowWidth: _contentWidth,
      windowHeight: _contentHeight,
    );
    await windowManager.setPosition(Offset(safe.x, safe.y));
  }

  @override
  Future<({double x, double y})?> position() async {
    if (!_initialized) return null;
    try {
      final Offset offset = await windowManager.getPosition();
      return (x: offset.dx, y: offset.dy);
    } catch (e, st) {
      Loggers.window.warning('读取窗口位置失败', e, st);
      return null;
    }
  }

  @override
  Future<void> setVisible(bool visible) async {
    if (!_initialized) return;
    if (visible) {
      await windowManager.show();
      await windowManager.focus();
    } else {
      await windowManager.hide();
    }
    Loggers.window.info('桌宠${visible ? '显示' : '隐藏'}');
  }

  @override
  Future<bool> isVisible() async {
    if (!_initialized) return false;
    try {
      return await windowManager.isVisible();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setPreventClose(bool prevent) async {
    if (!_initialized) return;
    await windowManager.setPreventClose(prevent);
  }

  @override
  Future<void> destroy() async {
    if (!_initialized) return;
    try {
      windowManager.removeListener(this);
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      Loggers.window.info('桌宠窗口已销毁');
    } catch (e, st) {
      Loggers.window.warning('销毁窗口失败', e, st);
    }
    _initialized = false;
  }

  @override
  void onPositionCommitted(void Function(double x, double y) callback) {
    _onPositionCommitted = callback;
  }

  @override
  void onCloseRequested(void Function() callback) {
    _onCloseRequested = callback;
  }

  @override
  void setExternalBoundsChangeActive(bool active) {
    _externalBoundsChange = active;
  }

  // ---------------------------------------------------------------------------
  // WindowListener
  // ---------------------------------------------------------------------------

  @override
  void onWindowMoved() {
    // 拖动结束：记忆位置。
    _commitPosition();
  }

  @override
  void onWindowResized() {
    _commitPosition();
  }

  @override
  void onWindowClose() {
    // setPreventClose(true) 时点关闭按钮走到这里：隐藏到托盘而不是退出。
    Loggers.window.info('收到窗口关闭请求，隐藏到系统托盘');
    _onCloseRequested?.call();
  }

  @override
  void onWindowFocus() {
    Loggers.window.fine('窗口获得焦点');
  }

  @override
  void onWindowBlur() {
    Loggers.window.fine('窗口失去焦点');
  }

  Future<void> _commitPosition() async {
    // 轮盘菜单展开 / 收起期间的移动是**程序化几何提交**，
    // 绝不能当作"用户把桌宠拖到了这里"而写回持久化位置。
    if (_externalBoundsChange) return;
    // ⚠️ 真机回归 #3 的配套修正：面板 / 过渡态的窗口矩形**不是**桌宠位置。
    //
    // 进入面板时 `suspendFixedCanvas` 会清掉 `fixedCanvasAnchor`，而面板 bounds 是
    // 程序化提交（`SetWindowPos` 会触发 `onWindowMoved`）—— 旧代码于是把
    // "面板左上角"当成桌宠位置写进持久化，下次启动桌宠就落到面板位置去了。
    final WindowsSurfaceMode mode = windowsSurfaceSession.mode;
    if (mode != WindowsSurfaceMode.petFixedCanvas) {
      wheelGeometryJournal.record(
        'pet.position.commit_skipped',
        fields: <String, Object?>{'mode': mode.wireName},
      );
      return;
    }
    final ({double x, double y})? pos = await position();
    if (pos == null) return;
    // 固定画布模式：拖动的是整个画布窗口，持久化的是**桌宠锚点屏幕位置**
    // （= 窗口位置 + petAnchor），这样桌宠在画布内的局部偏移永远不变。
    final Offset? anchor = fixedCanvasAnchor.anchor;
    if (fixedCanvasAnchor.enabled && anchor != null) {
      _onPositionCommitted?.call(pos.x + anchor.dx, pos.y + anchor.dy);
      return;
    }
    _onPositionCommitted?.call(pos.x, pos.y);
  }

  Future<void> _moveToDefaultCorner(AppSettings settings) async {
    final double scale = settings.scale;
    final double w = _contentWidth * scale;
    final double h = _contentHeight * scale;
    final DisplayTopology topology = _displays.displays.isEmpty
        ? (await DisplayTopology.load())
        : _displays;
    _displays = topology;
    if (topology.displays.isEmpty) {
      await windowManager.center();
      return;
    }
    final DisplayBounds primary = topology.displays.firstWhere(
      (DisplayBounds d) => d.isPrimary,
      orElse: () => topology.displays.first,
    );
    await moveTo(primary.right - w - 32, primary.bottom - h - 96);
  }

  /// 供 UI 层使用：当前是否处于 Windows 桌面环境。
  static bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  Future<void> dispose() async {
    _externalBoundsChange = false;
    _onPositionCommitted = null;
    _onCloseRequested = null;
  }
}
