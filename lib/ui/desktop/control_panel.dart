import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../core/logger.dart';
import '../library_controller.dart';
import '../pages/account_sync_page.dart';
import '../pages/asset_library_page.dart';
import '../pages/diagnostics_page.dart';
import '../pages/settings_page.dart';
import '../pages/state_debugger_page.dart';
import '../pages/state_mapping_page.dart';
import '../pages/usage_stats_page.dart';

/// 控制面板。
///
/// 需求「九、阶段 0 页面」要求提供：素材库 / 状态映射 / 状态调试器 / 设置
/// （外加桌宠窗口本身）。阶段 1 增加「使用统计」页。
/// 这里把它们做成一个带顶部拖拽条的分页面板。
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

  /// 使用统计页在页签中的下标（阶段 1 新增）。
  static const int usageStatsTabIndex = 3;

  /// 账户与同步页在页签中的下标（Phase 2 新增）。
  static const int accountSyncTabIndex = 4;

  /// 设置页下标（轮盘「完整设置」/桌面宠设置跳转用）。
  static const int settingsTabIndex = 5;

  /// 诊断页下标（增量 C2：轮盘 `PanelDestination.diagnostics` 的目标）。
  static const int diagnosticsTabIndex = 6;

  /// 页签总数。
  static const int tabCount = 7;

  @override
  State<ControlPanel> createState() => ControlPanelState();
}

/// 公开（而不是 `_` 私有）是为了让外壳可以通过 GlobalKey 切换页签，
/// 从而支持托盘「打开使用统计」直接定位。
class ControlPanelState extends State<ControlPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final LibraryController _library;

  /// 切换到指定页签（供外壳 / 托盘调用）。
  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _tabs.animateTo(index);
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: ControlPanel.tabCount,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, ControlPanel.tabCount - 1),
    );
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
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: Column(
        children: <Widget>[
          _Header(
            onClose: () async {
              await widget.onClose();
            },
            onExit: () async {
              await widget.onExit();
            },
          ),
          Material(
            color: Colors.white,
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const <Widget>[
                Tab(icon: Icon(Icons.photo_library_outlined), text: '素材库'),
                Tab(icon: Icon(Icons.account_tree_outlined), text: '状态映射'),
                Tab(icon: Icon(Icons.bug_report_outlined), text: '状态调试器'),
                Tab(icon: Icon(Icons.insights_outlined), text: '使用统计'),
                Tab(icon: Icon(Icons.cloud_sync_outlined), text: '账户与同步'),
                Tab(icon: Icon(Icons.settings_outlined), text: '设置'),
                Tab(icon: Icon(Icons.monitor_heart_outlined), text: '诊断'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                AssetLibraryPage(
                  ownerId: widget.services.ownerId,
                  importer: widget.services.importer,
                  fileImportProvider: widget.services.fileImportProvider,
                  library: _library,
                  // Phase 4C-6A.1：桌面也能打开「状态素材映射」编辑器
                  //（overlay 为 null：Windows 没有系统级悬浮窗，预览按钮会给出说明）。
                ),
                StateMappingPage(services: widget.services, library: _library),
                StateDebuggerPage(services: widget.services, library: _library),
                UsageStatsPage(
                  services: widget.services,
                  // 云端统计未登录时"去登录" → 切到「账户与同步」页
                  onOpenAccount: () =>
                      _tabs.animateTo(ControlPanel.accountSyncTabIndex),
                ),
                AccountSyncPage(services: widget.services),
                SettingsPage(services: widget.services),
                DiagnosticsPage(services: widget.services, library: _library),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部条：无边框窗口需要自己提供拖拽区与关闭按钮。
class _Header extends StatelessWidget {
  const _Header({required this.onClose, required this.onExit});

  final Future<void> Function() onClose;
  final Future<void> Function() onExit;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2F4A63),
      child: SizedBox(
        height: 46,
        child: Row(
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (DragStartDetails _) async {
                try {
                  await windowManager.startDragging();
                } catch (e) {
                  Loggers.window.fine('面板拖动不可用: $e');
                }
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.pets, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'PetLife 控制面板',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Tooltip(
              message: '回到桌宠模式',
              child: TextButton.icon(
                onPressed: () async => onClose(),
                icon: const Icon(Icons.arrow_back, size: 16, color: Colors.white),
                label: const Text('回到桌宠', style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: '退出 PetLife',
              child: IconButton(
                onPressed: () async => onExit(),
                icon: const Icon(Icons.power_settings_new, color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
