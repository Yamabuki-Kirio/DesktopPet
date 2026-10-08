import 'package:flutter/material.dart';

import '../../activity_tracking/models/usage_stats.dart';
import '../../app/app_scope.dart';
import '../../menu/context_menu_anchor.dart';
import '../../menu/context_menu_layout.dart';
import '../../menu/region_coordinator.dart' show RegionLease;
import '../../menu/wheel_geometry.dart' show WheelDisplayArea;
import '../../menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import '../../menu/windows_surface_mode.dart';
import '../../state_engine/state_snapshot.dart';
import '../desktop/pet_context_menu_overlay.dart';
import 'pet_view.dart';

/// 桌宠视图包装器。
///
/// 把三处变化汇总到同一个重建点：
/// - 设置变化（缩放 / 透明度 / 平滑 / 锁定位置）
/// - 状态引擎快照变化（当前角色、状态、素材）
/// 因此 [PetView] 本身可以保持无状态化，只负责画。
class PetViewWrapper extends StatelessWidget {
  const PetViewWrapper({
    super.key,
    required this.services,
    required this.onOpenPanel,
    required this.onExit,
    this.onToggleTracking,
    this.onOpenUsageStats,
    this.onPetTap,
    this.contextMenuRegion,
    this.displayForPoint,
    this.manageWindowSize = true,
  });

  final AppServices services;
  final Future<void> Function() onOpenPanel;
  final Future<void> Function() onExit;

  /// 暂停 / 恢复记录；为 null 时不显示该菜单项。
  final Future<void> Function()? onToggleTracking;

  /// 打开使用统计；为 null 时不显示该菜单项。
  final Future<void> Function()? onOpenUsageStats;

  /// 单击桌宠（Windows 上打开轮盘菜单探针）；为 null 时不响应单击。
  final VoidCallback? onPetTap;

  /// 右键菜单的 **Region 事务端口**（固定画布模式下由外壳注入）。
  ///
  /// 打开前把 Region 切成 owner=contextMenu（整块画布），关闭后**按凭据**恢复
  /// pet-only。凭据失效（例如左键轮盘已经抢占）时就什么都不做 —— 这正是本轮
  /// 修掉"右键 finally 覆盖轮盘 Region"的关键。
  final ContextMenuRegionPort? contextMenuRegion;

  /// 查询某全局坐标落在哪块显示器的**可用工作区**（Windows 注入；Android / 测试
  /// 可以为 null）。
  ///
  /// 右键菜单的高度上限必须由**鼠标所在显示器**的 workArea 决定，否则多屏 /
  /// 小屏下会再次出现"菜单摊开超出屏幕且不能滚"的回归。
  final Future<WheelDisplayArea?> Function(Offset globalPoint)? displayForPoint;

  final bool manageWindowSize;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (BuildContext context, Widget? _) {
        return ValueListenableBuilder<StateSnapshot>(
          valueListenable: services.stateEngineSnapshot,
          builder: (BuildContext context, StateSnapshot snapshot, Widget? __) {
            return PetView(
              renderer: services.renderer,
              scale: services.settings.settings.scale,
              smoothScaling: services.settings.settings.smoothScaling,
              opacity: services.settings.settings.opacity,
              lockPosition: services.settings.settings.lockPosition,
              manageWindowSize: manageWindowSize,
              // 宿主由平台装配决定：Windows = window_manager；Android = no-op。
              host: services.petHost,
              // 双击桌宠直接打开控制面板——这是桌宠最自然的入口。
              onDoubleTap: () => onOpenPanel(),
              // 右键：回调带指针全局坐标，菜单锚在指针附近（不再钉在画布右下角）。
              onRightClick: (Offset global) => _showPetContextMenu(context, global),
              onTap: onPetTap,
            );
          },
        );
      },
    );
  }

  /// 右键菜单文字样式（规划宽度与渲染共用同一份参数）。
  static const TextStyle _menuTextStyle =
      TextStyle(fontSize: 13, color: Color(0xFF111111));

  /// 右键菜单条目 —— 与旧 `showMenu` 的条目**动作一一对应**（本轮只改呈现与
  /// Region，不改动作集合）。
  List<ContextMenuItem> _buildContextMenuItems({
    required String state,
    required String currentApp,
    required String todayActive,
    required bool trackingPaused,
  }) {
    return <ContextMenuItem>[
      // 前三条是**只读状态**：不可点，但保留 value 供"打开时滚入可见区"定位。
      ContextMenuItem(label: '当前状态：$state', value: 'state', enabled: false),
      ContextMenuItem(label: '当前应用：$currentApp', value: 'app', enabled: false),
      ContextMenuItem(label: '今日活跃：$todayActive', value: 'today', enabled: false),
      const ContextMenuItem.divider(),
      const ContextMenuItem(label: '打开控制面板', value: 'panel'),
      if (onOpenUsageStats != null)
        const ContextMenuItem(label: '打开使用统计', value: 'stats'),
      if (onToggleTracking != null)
        ContextMenuItem(
          label: trackingPaused ? '恢复记录' : '暂停记录',
          value: 'toggleTracking',
        ),
      const ContextMenuItem(label: '切换鼠标穿透', value: 'toggleMouse'),
      const ContextMenuItem(label: '解除表情锁定', value: 'release'),
      const ContextMenuItem.divider(),
      const ContextMenuItem(label: '退出 PetLife', value: 'exit'),
    ];
  }

  /// 右键菜单：锚点 = **指针位置**（换算到 Overlay 局部坐标）。
  ///
  /// 真机回归 #2 的两处修正：
  /// 1. **高度受当前显示器 workArea 约束**（`ContextMenuLayout`），并且用
  ///    自建 `OverlayEntry` 取代 `showMenu` —— 后者的默认 constraints 没有
  ///    maxHeight，会把滚动容器撑成无限高，菜单一次摊开且不能滚；
  /// 2. Region 只覆盖 **pet ∪ 实际菜单矩形**（不再整块固定画布）。
  ///
  /// 仍然把"扩 Region → 菜单 → 按凭据恢复"包成事务（见
  /// [runContextMenuRegionTransaction]），异常路径也恢复。
  Future<void> _showPetContextMenu(BuildContext context, Offset? globalPosition) async {
    // 只在稳定的桌宠态响应右键。过渡 / 面板态下旧回调必须被丢弃
    // （否则会把"仅桌宠 Region"重新写回面板窗口，导致面板显示错乱）。
    if (windowsSurfaceSession.mode != WindowsSurfaceMode.petFixedCanvas) {
      wheelGeometryJournal.record(
        'context_menu.suppressed',
        fields: <String, Object?>{'mode': windowsSurfaceSession.mode.wireName},
      );
      return;
    }

    // 优先级 wheel > contextMenu：左键轮盘已打开时**不弹**右键菜单，
    // 否则两个 owner 会同时认为 Region 是自己的（真机缺陷场景 D）。
    final ContextMenuRegionPort? port = contextMenuRegion;
    if (port != null && !port.canOpenContextMenu) {
      wheelGeometryJournal.record(
        'context_menu.rejected',
        fields: <String, Object?>{'reason': 'wheel_open'},
      );
      return;
    }

    final OverlayState? overlay = Overlay.maybeOf(context);
    final RenderBox? overlayBox =
        overlay?.context.findRenderObject() as RenderBox?;
    if (overlay == null || overlayBox == null || !overlayBox.hasSize) return;

    final Size overlaySize = overlayBox.size;
    final Offset overlayOrigin = overlayBox.localToGlobal(Offset.zero);

    // 1) 指针全局坐标 → Overlay 局部坐标。
    final Offset? overlayLocal = globalPosition == null
        ? null
        : overlayBox.globalToLocal(globalPosition);

    // 2) 指针缺失时的回退：桌宠自身在 Overlay 中的矩形右下角。
    //    **绝不**退化为"整块画布右下角"。
    Rect? petOverlayRect;
    final RenderBox? selfBox = context.findRenderObject() as RenderBox?;
    if (selfBox != null && selfBox.hasSize) {
      final Offset topLeft =
          overlayBox.globalToLocal(selfBox.localToGlobal(Offset.zero));
      petOverlayRect =
          Rect.fromLTWH(topLeft.dx, topLeft.dy, selfBox.size.width, selfBox.size.height);
    }
    final Offset anchor = overlayLocal ??
        (petOverlayRect != null
            ? petOverlayRect.bottomRight
            : Offset(overlaySize.width - 1, overlaySize.height - 1));

    // 3) **鼠标所在显示器**的工作区（全局 → overlay 局部）。
    //    拿不到就退化为"整个 overlay"（Android / 测试注入为 null）。
    final WheelDisplayArea? display =
        await displayForPoint?.call(globalPosition ?? (overlayOrigin + anchor));
    final Rect workAreaLocal =
        (display?.rect ?? (Offset.zero & overlaySize)).shift(-overlayOrigin);

    // 4) 条目 + 几何规划（规划值 == 最终渲染值 → Region 可以精确贴合）。
    final tracker = services.activityTracker;
    final List<ContextMenuItem> items = _buildContextMenuItems(
      state: services.stateEngineSnapshot.value.state.wireName,
      currentApp: tracker.currentAppDisplayName ?? '—',
      todayActive: formatDurationZh(tracker.todayActiveSeconds),
      trackingPaused: tracker.isPaused,
    );
    final int stateIndex = items.indexWhere(
      (ContextMenuItem item) => item.value == 'state',
    );
    final ContextMenuPlan plan = ContextMenuLayout.plan(
      anchor: anchor,
      overlaySize: overlaySize,
      workArea: workAreaLocal,
      items: items,
      preferredWidth: measureContextMenuWidth(
        items: items,
        style: _menuTextStyle,
        maxWidth: ContextMenuLayout.maxWidthFor(workAreaLocal.size),
      ),
      initialIndex: stateIndex < 0 ? 0 : stateIndex,
    );

    wheelGeometryJournal.record(
      'context_menu.show',
      fields: <String, Object?>{
        'mode': windowsSurfaceSession.mode.wireName,
        'anchorX': anchor.dx,
        'anchorY': anchor.dy,
        'rect': WheelGeometryJournal.formatRect(plan.rect),
        'workArea': WheelGeometryJournal.formatRect(workAreaLocal),
        'items': items.length,
        'scrolls': plan.scrolls,
        'contentExtent': plan.contentExtent,
      },
    );

    if (!context.mounted) return;

    final String? value = await runContextMenuRegionTransaction<String?>(
      expandRegion: port == null
          ? null
          : () async {
              final RegionLease lease = await port.expandTo(plan.regionRect);
              wheelGeometryJournal.record(
                'context_menu.region_open',
                fields: <String, Object?>{
                  'lease': lease.wireName,
                  'menu': WheelGeometryJournal.formatRect(plan.regionRect),
                },
              );
              return lease;
            },
      restoreRegion: port == null
          ? null
          : (RegionLease lease) async {
              // 只有凭据仍有效（owner 仍为 contextMenu 且 transactionId / generation
              // 一致）才会真的写 Region；否则协调器记 dropped_stale 并放弃。
              final bool restored = await port.restore(lease);
              wheelGeometryJournal.record(
                'context_menu.close',
                fields: <String, Object?>{
                  'restored': restored,
                  'lease': lease.wireName,
                  'mode': windowsSurfaceSession.mode.wireName,
                },
              );
            },
      body: () => _presentContextMenu(overlay, items, plan),
    );
    wheelGeometryJournal.record(
      'context_menu.dismissed',
      fields: <String, Object?>{
        'mode': windowsSurfaceSession.mode.wireName,
        'value': value ?? 'none',
      },
    );

    // 5) 动作分发 —— 与旧实现逐条一致。
    switch (value) {
      case 'panel':
        await onOpenPanel();
      case 'stats':
        await onOpenUsageStats?.call();
      case 'toggleTracking':
        await onToggleTracking?.call();
      case 'toggleMouse':
        await services.settings.setIgnoreMouseEvents(
          !services.settings.settings.ignoreMouseEvents,
        );
        await services.windowController.applySettings(services.settings.settings);
      case 'release':
        await services.stateEngine.releaseManual();
      case 'exit':
        await onExit();
      default:
        break;
    }
  }

  /// 真正把菜单插进 Overlay 并等结果；登记 / 注销"可关闭句柄"。
  Future<String?> _presentContextMenu(
    OverlayState overlay,
    List<ContextMenuItem> items,
    ContextMenuPlan plan,
  ) async {
    try {
      return await PetContextMenuOverlay.show(
        overlay: overlay,
        items: items,
        plan: plan,
        initialValue: 'state',
        onPresented: (VoidCallback dismiss) =>
            contextMenuBridge.register(dismiss: dismiss),
      );
    } finally {
      // 立即注销：菜单一旦关闭（或抛错），外壳就不该再尝试 pop 它。
      contextMenuBridge.unregister();
    }
  }
}
