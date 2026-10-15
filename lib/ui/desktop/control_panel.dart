import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../core/logger.dart';
import '../../sync/models/sync_models.dart';
import '../library_controller.dart';
import '../pages/account_sync_page.dart';
import '../pages/asset_library_page.dart';
import '../pages/diagnostics_page.dart';
import '../pages/settings_page.dart';
import '../pages/state_debugger_page.dart';
import '../pages/state_mapping_page.dart';
import '../pages/usage_stats_page.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_desktop.dart';
import 'control_panel_destinations.dart';
import 'desktop_panel_flags.dart';
import 'legacy/legacy_account_sync_page.dart';
import 'legacy/legacy_asset_library_page.dart';
import 'legacy/legacy_settings_page.dart';
import 'legacy/legacy_usage_stats_page.dart';

/// Windows 控制面板（需求 §3 / §4）。
///
/// 结构：**顶部栏 + 左侧导航栏 + 内容区 + 底部状态条**，
/// 不再使用"七个标签横向挤在一起"的旧顶栏，也不再使用深蓝色实心横条。
///
/// 业务边界（本轮未改）：
/// * 仍然只有一个 [LibraryController]，由本 State 持有，页面切换**不重建**它；
/// * 页签下标与 [`DesktopShell._tabIndexFor`] 的映射保持不变，
///   轮盘 / 托盘跳转行为完全一致；
/// * `useLegacyDesktopControlPanel` 为 true 时切回 `legacy/` 的旧页面
///   （排障用，不在设置页暴露）。
class ControlPanel extends StatefulWidget {
  const ControlPanel({
    super.key,
    required this.services,
    required this.onClose,
    required this.onExit,
    this.initialTab = 0,
  });

  final AppServices services;
  final Future<void> Function() onClose;
  final Future<void> Function() onExit;

  /// 初始选中的页签。托盘「打开使用统计」会直接定位到统计页。
  final int initialTab;

  /// 素材库页下标（页签顺序：素材库 / 状态映射 / 状态调试器 / 使用统计 / 账户与同步 / 设置 / 诊断）。
  static const int assetLibraryTabIndex = 0;

  /// 状态映射页下标。
  static const int stateMappingTabIndex = 1;

  /// 状态调试器页下标。
  static const int stateDebuggerTabIndex = 2;

  /// 使用统计页在页签中的下标。
  static const int usageStatsTabIndex = 3;

  /// 账户与同步页在页签中的下标。
  static const int accountSyncTabIndex = 4;

  /// 设置页下标（轮盘「完整设置」/桌宠设置跳转用）。
  static const int settingsTabIndex = 5;

  /// 诊断页下标（轮盘 `PanelDestination.diagnostics` 的目标）。
  static const int diagnosticsTabIndex = 6;

  /// 页签总数。
  static const int tabCount = 7;

  @override
  State<ControlPanel> createState() => ControlPanelState();
}

/// 公开（而不是 `_` 私有）是为了让外壳可以通过 GlobalKey 切换页签，
/// 从而支持托盘「打开使用统计」直接定位。
class ControlPanelState extends State<ControlPanel> {
  late int _index;
  late final LibraryController _library;

  /// 切换到指定页签（供外壳 / 托盘调用）。
  void selectTab(int index) {
    if (index < 0 || index >= ControlPanel.tabCount) return;
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialTab.clamp(0, ControlPanel.tabCount - 1);
    _library = LibraryController(
      repository: widget.services.repository,
      ownerId: widget.services.ownerId,
      stateEngine: widget.services.stateEngine,
      settings: widget.services.settings,
    )..onLibraryMutated = () async {
        // 素材或映射变化后，让状态引擎重新解析当前状态。
        await widget.services.stateEngine.refresh();
        await _syncEngineCharacter();
      };
    _library.addListener(_onLibraryChanged);
    _library.load();
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  /// 让状态引擎跟随素材库里选中的角色。
  Future<void> _syncEngineCharacter() async {
    final String? id = _library.selectedCharacterId;
    if (id == null) return;
    await widget.services.stateEngine.setCharacter(id);
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    _library.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 页面装配
  // ---------------------------------------------------------------------------

  /// 七个页面。`useLegacyDesktopControlPanel` 打开时用 `legacy/` 的旧实现。
  List<Widget> _buildPages() {
    final bool legacy = useLegacyDesktopControlPanel;

    if (legacy) {
      return <Widget>[
        LegacyAssetLibraryPage(
          ownerId: widget.services.ownerId,
          importer: widget.services.importer,
          fileImportProvider: widget.services.fileImportProvider,
          library: _library,
        ),
        StateMappingPage(services: widget.services, library: _library),
        StateDebuggerPage(services: widget.services, library: _library),
        LegacyUsageStatsPage(
          services: widget.services,
          onOpenAccount: () =>
              selectTab(ControlPanel.accountSyncTabIndex),
        ),
        LegacyAccountSyncPage(services: widget.services),
        LegacySettingsPage(services: widget.services, library: _library),
        DiagnosticsPage(services: widget.services, library: _library),
      ];
    }

    return <Widget>[
      PetLifeDesktopContentWidth(
        child: AssetLibraryPage(
          ownerId: widget.services.ownerId,
          importer: widget.services.importer,
          fileImportProvider: widget.services.fileImportProvider,
          library: _library,
        ),
      ),
      PetLifeDesktopContentWidth(
        child: StateMappingPage(services: widget.services, library: _library),
      ),
      PetLifeDesktopContentWidth(
        child: StateDebuggerPage(services: widget.services, library: _library),
      ),
      PetLifeDesktopContentWidth(
        child: UsageStatsPage(
          services: widget.services,
          // 云端统计未登录时"去登录" → 切到「账户与同步」页
          onOpenAccount: () => selectTab(ControlPanel.accountSyncTabIndex),
        ),
      ),
      PetLifeDesktopContentWidth(
        child: AccountSyncPage(services: widget.services),
      ),
      // 设置项横跨整屏很难读：单独收窄到 1040px。
      PetLifeDesktopContentWidth(
        maxWidth: PetLifeDesktopBreakpoints.settingsContentMaxWidth,
        child: SettingsPage(services: widget.services, library: _library),
      ),
      PetLifeDesktopContentWidth(
        child: DiagnosticsPage(
          services: widget.services,
          library: _library,
          embedded: true,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.services.syncEngine,
      builder: (BuildContext context, Widget? _) {
        return PetLifeDesktopScaffold(
          destinations: kDesktopPanelDestinations,
          selectedIndex: _index,
          onSelected: selectTab,
          pages: _buildPages(),
          toolbar: PetLifeDesktopToolbar(
            title: 'PetLife 控制面板',
            pageName: kDesktopPanelTitles[_index],
            statusTag: _syncTag(context),
            onTitleBarDrag: _startWindowDrag,
            actions: <Widget>[
              Tooltip(
                message: '回到桌宠模式',
                child: PetLifeSecondaryButton(
                  label: '回到桌宠',
                  icon: Icons.arrow_back,
                  onPressed: () => widget.onClose(),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '退出 PetLife',
                child: PetLifeDangerButton(
                  label: '退出',
                  icon: Icons.power_settings_new,
                  onPressed: () => widget.onExit(),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          footer: _StatusBar(
            deviceLabel: widget.services.platform.device.deviceName,
            pendingCount: widget.services.syncEngine.pendingCount,
            lastSuccessAt: widget.services.syncEngine.lastSuccessAt,
          ),
        );
      },
    );
  }

  /// 顶部栏的同步状态小标签。
  Widget _syncTag(BuildContext context) {
    final SyncStatus status = widget.services.syncEngine.status;
    final PetLifePalette p = PetLifeTheme.of(context);
    final bool syncing = widget.services.syncEngine.isSyncing;
    return PetLifeTag(
      label: syncing ? '同步中…' : status.labelZh,
      icon: Icons.cloud_sync_outlined,
      color: status == SyncStatus.success ? p.success : p.textSecondary,
      dense: true,
    );
  }

  Future<void> _startWindowDrag() async {
    try {
      await windowManager.startDragging();
    } catch (e) {
      Loggers.window.fine('面板拖动不可用: $e');
    }
  }
}

/// 底部状态条（需求 §3：可选的当前设备、同步状态或版本信息）。
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.deviceLabel,
    required this.pendingCount,
    required this.lastSuccessAt,
  });

  final String deviceLabel;
  final int pendingCount;
  final DateTime? lastSuccessAt;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Material(
      color: p.surface,
      child: SizedBox(
        height: 30,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.divider)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: <Widget>[
                Icon(Icons.computer, size: 13, color: p.textSecondary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    deviceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: PetLifeText.captionSmall,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  pendingCount > 0 ? '待同步 $pendingCount 条' : '没有待同步记录',
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    color: pendingCount > 0 ? p.onAccentSoft : p.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  lastSuccessAt == null
                      ? '尚未成功同步'
                      : '最近同步 ${_format(lastSuccessAt!)}',
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _format(DateTime time) {
    final DateTime local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
