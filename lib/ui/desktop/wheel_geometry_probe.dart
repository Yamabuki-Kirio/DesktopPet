/// 轮盘菜单几何探针（增量 A）。
///
/// **状态：REJECTED（本轮被操作者否决，默认关闭）。**
/// 该方案"动态放大 / 缩小同一个 HWND"在真机上连续失败两次：
/// 首次点击桌宠大面积消失、偶尔只剩一小块菜单、再点一次才恢复 ——
/// `setBounds` + Flutter surface resize + 桌宠局部补偿 + 菜单布局无法保证落在
/// 同一个可见帧。**不得继续修补此路径**；代码 / 日志 / 测试全部保留，
/// 由 [PetWindowProbeFlags.dynamicSetBoundsProbeEnabled]（默认 false）控制，
/// 新方向见 `ui/desktop/fixed_canvas_probe.dart`（固定画布 + 窗口 Region）。
///
/// 目标：在 Windows 上验证"**单窗口**点击桌宠 → 扩窗 → 摆菜单 → 关窗还原"的
/// 整条几何链路，**不替换**既有的右键菜单（右键菜单仍是回退入口）。
///
/// 关键设计
/// --------
/// * Windows 只有一个 HWND，所以"菜单"不是一个新窗口，而是**同一个窗口变大**后
///   在桌宠旁边画出来的测试色块；
/// * 展开 / 收起都走 [WheelOpenTransaction]（内部只调用一次
///   `setBounds`，位置 + 尺寸同时提交），绝不 `setSize` + `setPosition`；
/// * **先测量、后提交**：菜单先以不可见 / 不可点的方式参与布局，连续两帧测到
///   有效且稳定的尺寸后，才计算几何并原子提交；测量无效 / 超时绝不提交；
/// * 展开前记录桌宠屏幕矩形；展开后把桌宠按 `petLocal` 做局部补偿，
///   使**桌宠屏幕坐标不变**；
/// * 关闭后窗口**必须缩回桌宠矩形**，不留透明区域挡住桌面；
/// * 鼠标穿透开启时**不打开**可见但不可用的菜单，只给出明确提示；
/// * 本增量已知并接受：菜单打开期间整块放大窗口都会接收鼠标（不做区域级命中测试）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/logger.dart';
import '../../menu/fixed_canvas_contract.dart';
import '../../menu/menu_contract.dart';
import '../../menu/wheel_geometry.dart';
import '../../menu/wheel_measurement_gate.dart';
import '../../menu/wheel_menu_diagnostics.dart';
import '../../menu/wheel_open_transaction.dart';
import '../../menu/wheel_window_ops.dart';
import '../../platform/windows/windows_menu_action_executor.dart';
import '../../platform/windows/windows_wheel_window_ops.dart';
import '../../state_engine/system_state.dart';
import 'desktop_menu_action_bridge.dart';

/// 旧探针的**路线标记**：REJECTED。
///
/// 该常量只用于诊断 / 测试断言"这条路径已被明确标记为否决"，不参与运行逻辑；
/// 是否启用由 [PetWindowProbeFlags.dynamicSetBoundsProbeEnabled]（默认 false）决定。
const PetWindowProbeApproach kWheelGeometryProbeApproach =
    PetWindowProbeApproach.dynamicSetBoundsRejected;

/// 探针状态（供外壳通过 GlobalKey 打开 / 关闭）。
class WheelGeometryProbeState extends State<WheelGeometryProbe> {
  /// 探针测试菜单的包围盒尺寸（逻辑像素）—— 仅用于测量期的固定布局。
  static const Size menuSize = Size(320, 320);

  /// 探针测试菜单与桌宠的间距。
  static const double menuGap = 12;

  /// 测量超时：超时即回滚（绝不带着不确定的尺寸提交）。
  static const Duration measureTimeout = Duration(milliseconds: 1500);

  final GlobalKey _measureKey = GlobalKey();

  late final WheelOpenTransaction _tx = WheelOpenTransaction(
    ops: widget.ops ?? const WindowsWheelWindowOps(),
    waitForFrame: () => WidgetsBinding.instance.endOfFrame,
    minMenuSide: 64,
    menuGap: menuGap,
    // 逐帧事件只在诊断模式开启时记录（且事务内部限制前 12 帧）。
    diagnosticsEnabled: () => wheelMenuDiagnostics.diagnosticMode,
  );

  String? _transientMessage;
  MenuExecutionResult? _lastResult;
  Timer? _messageTimer;

  bool get isOpen => _tx.isOpen;

  late final WindowsMenuActionExecutor _executor =
      WindowsMenuActionExecutor(_buildHost());

  /// 业务动作桥：把桌宠 / 形象 / 页面导航**委托**给已有的
  /// `OverlayMenuActionExecutor`（绝不复制素材库、收藏或状态映射逻辑）。
  DesktopMenuActionBridge? _bridge;

  WindowsMenuActionHost _buildHost() => WindowsMenuActionHost(
        setPetVisible: (bool visible) =>
            widget.services.windowController.setVisible(visible),
        increasePetScale: () => _bumpScale(1),
        decreasePetScale: () => _bumpScale(-1),
        resetPetScale: () async {
          await widget.services.settings.setScale(2.0);
          await widget.services.windowController
              .applySettings(widget.services.settings.settings);
        },
        resetPetPosition: () => widget.services.windowController.moveTo(0, 0),
        openControlPanel: () async {
          await close();
          await widget.onOpenControlPanel?.call();
        },
        // --- 增量 C2：全部业务委托给共用执行器（唯一业务入口）---
        dispatchBusiness: _runBusiness,
        currentPetStateLabel: () async {
          final SystemState state = widget.services.stateEngine.snapshot.state;
          return '当前状态：${state.label}';
        },
        currentForegroundAppLabel: () async {
          final String? app =
              widget.services.activityTracker.currentAppDisplayName;
          return (app == null || app.isEmpty) ? '当前应用：暂无记录' : '当前应用：$app';
        },
      );

  /// 懒建业务桥（首次用到才装配，避免无用依赖）。
  Future<MenuExecutionResult> _runBusiness(String actionId) async {
    final DesktopMenuActionBridge bridge = _bridge ??= DesktopMenuActionBridge(
      services: widget.services,
      onDestination: (PanelDestination destination) async {
        await close();
        await widget.onOpenControlPanel?.call();
        widget.onNavigateDestination?.call(destination);
      },
    );
    return bridge.run(actionId);
  }

  Future<void> _bumpScale(int delta) async {
    final double current = widget.services.settings.settings.scale;
    final double next = (current + delta).clamp(1.0, 4.0).toDouble();
    if (next == current) return;
    await widget.services.settings.setScale(next);
    await widget.services.windowController
        .applySettings(widget.services.settings.settings);
  }

  @override
  void dispose() {
    _bridge?.dispose();
    _bridge = null;
    _messageTimer?.cancel();
    if (_tx.isBusy) {
      // 外壳销毁（退出 / 面板切换）时不能把窗口留在放大状态。
      unawaited(_tx.abort());
    }
    super.dispose();
  }

  /// 切换打开 / 关闭（桌宠单击入口）。
  Future<void> toggle() => isOpen ? close() : open();

  /// 打开测试轮盘。
  Future<void> open() async {
    if (_tx.isBusy) return;

    if (widget.services.settings.settings.ignoreMouseEvents) {
      // 穿透开着时点击本就不会落到桌宠上；这里再兜一层，绝不显示"能看见点不动"的菜单。
      wheelMenuDiagnostics.recordRejected(note: '鼠标穿透已开启，未打开轮盘菜单');
      _showMessage('鼠标穿透已开启：请先在设置里关闭「鼠标穿透」，再点击桌宠打开轮盘菜单');
      return;
    }

    // 素材尺寸无效 / 尚未解码 / 正在切换时拒绝打开（否则会拿不确定的尺寸提交几何）。
    final Size? content = widget.services.renderer.contentSize;
    if (content == null || content.width <= 0 || content.height <= 0) {
      wheelMenuDiagnostics.recordRejected(note: '素材尺寸无效，未打开轮盘菜单');
      _showMessage('当前素材尺寸无效，无法打开轮盘菜单');
      return;
    }

    final WheelOpenRequest request = await _tx.beginOpen();
    if (!request.accepted) {
      wheelMenuDiagnostics.recordRejected(note: request.reason ?? '无法打开轮盘菜单');
      _showMessage(request.reason ?? '无法打开轮盘菜单');
      return;
    }

    // 进入"程序化改窗口"区间：期间的移动不得被写回持久化位置。
    widget.services.windowController.setExternalBoundsChangeActive(true);
    if (mounted) setState(() {});
    await _measureThenCommit();
  }

  /// 逐帧测量：菜单在此阶段**参与布局但不可见、不可点**。
  ///
  /// 连续两帧测到有效且稳定的尺寸后，才计算几何并提交（绝不接受 0 / 1×1）。
  Future<void> _measureThenCommit() async {
    final Stopwatch watch = Stopwatch()..start();
    while (mounted && _tx.phase == WheelOpenPhase.measuring) {
      // endOfFrame 会在空闲时主动排一帧，保证测量循环持续推进。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _tx.phase != WheelOpenPhase.measuring) return;

      final Size? measured = _readMeasuredMenuSize();
      if (measured != null) {
        final WheelMeasureOutcome outcome = _tx.offerMenuMeasurement(measured);
        if (outcome == WheelMeasureOutcome.stable) {
          await _commit();
          return;
        }
      }
      if (watch.elapsed > measureTimeout) {
        await _abort('轮盘测量超时');
        return;
      }
    }
  }

  Future<void> _commit() async {
    if (mounted) setState(() {}); // 展示 committing 阶段（桌宠局部补偿已就位、菜单仍不可见）
    final Stopwatch watch = Stopwatch()..start();
    final WheelOpenOutcome outcome = await _tx.commitOpen();
    watch.stop();
    if (!mounted) return;

    if (outcome.opened) {
      _recordOpenDiagnostics(outcome, watch.elapsedMicroseconds / 1000);
      setState(() {});
      widget.onOpenChanged?.call(true);
      _startFrameLogging();
      return;
    }

    // 失败：事务内部已回滚窗口矩形与所有权。
    widget.services.windowController.setExternalBoundsChangeActive(false);
    setState(() {});
    _showMessage('轮盘布局失败');
    widget.onOpenChanged?.call(false);
  }

  Future<void> _abort(String reason) async {
    await _tx.abort();
    if (!mounted) return;
    widget.services.windowController.setExternalBoundsChangeActive(false);
    setState(() {});
    _showMessage('轮盘布局失败');
    widget.onOpenChanged?.call(false);
    Loggers.window.info('轮盘菜单已回滚：$reason');
  }

  /// 关闭测试轮盘并**原子还原**窗口矩形。
  Future<void> close() async {
    if (!_tx.isBusy) return;
    final WheelOpenPhase phase = _tx.phase;
    if (phase == WheelOpenPhase.measuring || phase == WheelOpenPhase.committing) {
      await _abort('打开过程中被取消');
      return;
    }
    if (phase != WheelOpenPhase.open) return;

    // 关闭顺序（需求 §4）：owner wheel → wheelTransition（同步）。
    _tx.beginClose();
    // 菜单立即停止接受输入并隐藏。
    if (mounted) setState(() {});
    final WheelCloseOutcome outcome = await _tx.finishClose();
    if (!mounted) return;
    widget.services.windowController.setExternalBoundsChangeActive(false);
    setState(() {});
    _recordCloseDiagnostics(outcome);
    widget.onOpenChanged?.call(false);
  }

  Future<void> _runAction(String actionId) async {
    final MenuExecutionResult result = await _executor.execute(actionId);
    if (!mounted) return;
    setState(() => _lastResult = result);
  }

  void _recordOpenDiagnostics(WheelOpenOutcome outcome, double commitDurationMs) {
    final WheelGeometryResult? geometry = _tx.geometry;
    final Rect? original = _tx.originalRect;
    if (geometry == null || original == null) return;
    wheelMenuDiagnostics.recordOpen(
      displayId: _tx.display?.id ?? 'unknown',
      devicePixelRatio: (widget.ops ?? const WindowsWheelWindowOps()).devicePixelRatio(),
      oldWindowRect: original,
      targetWindowRect: geometry.windowRect,
      actualWindowRect: outcome.actualBounds ?? geometry.windowRect,
      petLocalOffset: geometry.petLocal,
      commitDurationMs: commitDurationMs,
      petScreenErrorPx: outcome.petScreenErrorPx ?? 0,
      menuOnRight: geometry.menuOnRight,
      clampedByDisplay: geometry.clamped,
    );
  }

  void _recordCloseDiagnostics(WheelCloseOutcome outcome) {
    final Rect? actual = outcome.actualBounds;
    wheelMenuDiagnostics.recordClose(
      oldWindowRect: _tx.originalRect ?? Rect.zero,
      targetWindowRect: _tx.originalRect ?? Rect.zero,
      actualWindowRect: actual ?? Rect.zero,
      restoredAfterClose: outcome.restored,
      transparentRegionBlocksClicks: !outcome.restored,
      commitDurationMs: 0,
      petScreenErrorPx: 0,
    );
  }

  Size? _readMeasuredMenuSize() {
    final BuildContext? context = _measureKey.currentContext;
    if (context == null) return null;
    final RenderObject? object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    return object.size;
  }

  void _startFrameLogging() {
    if (!wheelMenuDiagnostics.diagnosticMode) return;
    _scheduleFrameLog(0);
  }

  /// 逐帧几何日志：**仅诊断模式**、**仅前 12 帧**、每帧一次（不刷屏）。
  void _scheduleFrameLog(int frameIndex) {
    if (frameIndex >= WheelMenuDiagnostics.maxFrameLogs) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final WheelGeometryResult? geometry = _tx.geometry;
      if (geometry == null) return;
      wheelMenuDiagnostics.logFrame(
        frameIndex,
        'window=${WheelMenuDiagnosticSample.formatRect(geometry.windowRect)} '
        'petLocal=${WheelMenuDiagnosticSample.formatOffset(geometry.petLocal)}',
      );
      _scheduleFrameLog(frameIndex + 1);
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _transientMessage = message);
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _transientMessage = null);
    });
  }

  Widget _menuWidget() => _TestWheelPanel(
        onClose: close,
        onRunAction: _runAction,
        lastResult: _lastResult,
      );

  @override
  Widget build(BuildContext context) {
    final WheelOpenPhase phase = _tx.phase;
    final bool measuring = phase == WheelOpenPhase.measuring;
    final bool visible = phase == WheelOpenPhase.open;
    final Offset petLocal = _tx.petLocal;
    final Offset menuLocal = _tx.menuLocal;
    final Size size = _tx.stableMenuSize ?? menuSize;
    final bool showMenu = phase != WheelOpenPhase.closed;

    return Stack(
      children: <Widget>[
        // 桌宠**始终**用同一个 Positioned 承载：避免打开 / 关闭时 widget 结构翻转
        // 导致 PetView 状态被销毁重建 —— 那正是"展开后被 setSize 缩回"的触发源之一。
        Positioned(
          left: petLocal.dx,
          top: petLocal.dy,
          child: widget.child,
        ),
        if (showMenu)
          measuring
              ? _buildMeasuringMenu()
              : Positioned(
                  left: menuLocal.dx,
                  top: menuLocal.dy,
                  width: size.width,
                  height: size.height,
                  child: visible
                      ? _menuWidget()
                      : IgnorePointer(
                          child: Opacity(opacity: 0, child: _menuWidget()),
                        ),
                ),
        if (_transientMessage != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(child: _MessageBanner(message: _transientMessage!)),
          ),
      ],
    );
  }

  /// 测量层：参与测量 / 布局，但**不可见、不可点击**，且用 [OverflowBox]
  /// 让它按设计尺寸布局（不受当前窗口约束影响）。
  Widget _buildMeasuringMenu() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0,
          child: Align(
            alignment: Alignment.topLeft,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: KeyedSubtree(
                key: _measureKey,
                child: SizedBox(
                  width: menuSize.width,
                  height: menuSize.height,
                  child: _menuWidget(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 探针用的**测试**菜单：明显的测试色块 + 几个按钮（无真实业务）。
class _TestWheelPanel extends StatelessWidget {
  const _TestWheelPanel({
    required this.onClose,
    required this.onRunAction,
    required this.lastResult,
  });

  final Future<void> Function() onClose;
  final Future<void> Function(String actionId) onRunAction;
  final MenuExecutionResult? lastResult;

  static const List<Color> _swatches = <Color>[
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
  ];

  @override
  Widget build(BuildContext context) {
    final String resultText = lastResult == null
        ? '尚未执行动作'
        : '${lastResult!.status.wireName}'
            '${lastResult!.reason != null ? ' · ${lastResult!.reason}' : ''}'
            '${lastResult!.message != null ? ' · ${lastResult!.message}' : ''}';
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF21B2430),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 2),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '轮盘菜单几何探针 · TEST',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => onClose(),
                  icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                  tooltip: '关闭菜单',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  for (int i = 0; i < _swatches.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        color: _swatches[i],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'B${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                resultText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _chip('关闭菜单', onClose),
                _actionChip('settings_theme'),
                _actionChip('records_sync'),
                _actionChip('appearance_library'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Future<void> Function() action) => OutlinedButton(
        onPressed: () => action(),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white38),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );

  Widget _actionChip(String actionId) => _chip(
        '演示：$actionId',
        () => onRunAction(actionId),
      );
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xE6313A4A),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      );
}

/// 探针宿主：包住桌宠视图，并在需要时把测试菜单叠在同一个窗口里。
class WheelGeometryProbe extends StatefulWidget {
  const WheelGeometryProbe({
    super.key,
    required this.services,
    required this.child,
    this.onOpenChanged,
    this.onOpenControlPanel,
    this.onNavigateDestination,
    this.ops,
  });

  final AppServices services;

  /// 桌宠视图（由外壳传入，探针只负责摆放与扩窗）。
  final Widget child;

  /// 打开 / 关闭状态变化（外壳据此暂停"窗口跟随素材尺寸"）。
  final ValueChanged<bool>? onOpenChanged;

  /// 打开控制面板（`tools_open_app` / `settings_open` 使用）。
  final Future<void> Function()? onOpenControlPanel;

  /// 页面跳转（`appearance_mapping` / `appearance_library`）：外壳打开控制面板并切页。
  final ValueChanged<PanelDestination>? onNavigateDestination;

  /// 窗口几何操作（测试可注入假实现；生产为 `WindowsWheelWindowOps`）。
  final WheelWindowOps? ops;

  @override
  State<WheelGeometryProbe> createState() => WheelGeometryProbeState();
}
