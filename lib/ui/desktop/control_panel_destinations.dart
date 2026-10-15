import 'package:flutter/material.dart';

import '../widgets/petlife/petlife_desktop.dart';

/// Windows 控制面板的**七个导航入口**（唯一真相）。
///
/// 顺序与 `ControlPanel` 的页签下标**严格一一对应**，也与
/// `DesktopShell._tabIndexFor(PanelDestination)` 的映射一致：
///
/// | 下标 | 入口 |
/// | --- | --- |
/// | 0 | 素材库 |
/// | 1 | 状态映射 |
/// | 2 | 状态调试器 |
/// | 3 | 使用统计 |
/// | 4 | 账户与同步 |
/// | 5 | 设置 |
/// | 6 | 诊断 |
///
/// 抽成常量而不是散落在 `build` 里：
/// * 桌面导航测试可以直接断言"就是这七个、就是这个顺序"；
/// * 轮盘 / 托盘跳转复用的下标不会与界面对不上。
const List<PetLifeDesktopDestination> kDesktopPanelDestinations =
    <PetLifeDesktopDestination>[
  PetLifeDesktopDestination(
    label: '素材库',
    icon: Icons.photo_library_outlined,
    selectedIcon: Icons.photo_library,
  ),
  PetLifeDesktopDestination(
    label: '状态映射',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
  ),
  PetLifeDesktopDestination(
    label: '状态调试器',
    icon: Icons.bug_report_outlined,
    selectedIcon: Icons.bug_report,
  ),
  PetLifeDesktopDestination(
    label: '使用统计',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
  ),
  PetLifeDesktopDestination(
    label: '账户与同步',
    icon: Icons.cloud_sync_outlined,
    selectedIcon: Icons.cloud_sync,
  ),
  PetLifeDesktopDestination(
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
  PetLifeDesktopDestination(
    label: '诊断',
    icon: Icons.monitor_heart_outlined,
    selectedIcon: Icons.monitor_heart,
  ),
];

/// 七个入口的标题（供测试与页面对照，避免两处各写一份字面量）。
const List<String> kDesktopPanelTitles = <String>[
  '素材库',
  '状态映射',
  '状态调试器',
  '使用统计',
  '账户与同步',
  '设置',
  '诊断',
];
