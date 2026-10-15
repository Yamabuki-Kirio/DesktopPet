import 'package:flutter/material.dart';

import '../widgets/petlife/petlife_nav.dart';

/// Android 控制面板的**五个根入口**（唯一真相）。
///
/// 需求：底部导航保持现有业务入口 —— 桌宠 / 使用统计 / 账户与同步 / 素材库 / 设置。
///
/// 抽成常量而不是散落在 `MobileShell.build` 里，有两个好处：
/// * 导航测试可以直接断言"就是这五个、就是这个顺序"，而不是复制一份字面量；
/// * 任何一处顺序调整都会同时反映到界面与测试上，不会偷偷漂移。
///
/// 顺序与 `MobileShell` 里 `PetLifePageSwitcher.children` 的索引**一一对应**：
/// 0 桌宠 / 1 使用统计 / 2 账户与同步 / 3 素材库 / 4 设置。
const List<PetLifeNavDestination> kPetLifeRootDestinations =
    <PetLifeNavDestination>[
  PetLifeNavDestination(
    label: '桌宠',
    icon: Icons.pets_outlined,
    selectedIcon: Icons.pets,
  ),
  PetLifeNavDestination(
    label: '使用统计',
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
  ),
  PetLifeNavDestination(
    label: '账户与同步',
    icon: Icons.sync_outlined,
    selectedIcon: Icons.sync,
  ),
  PetLifeNavDestination(
    label: '素材库',
    icon: Icons.folder_outlined,
    selectedIcon: Icons.folder,
  ),
  PetLifeNavDestination(
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

/// 五个根入口对应的页面标题（用于一致性断言）。
const List<String> kPetLifeRootTitles = <String>[
  '桌宠',
  '使用统计',
  '账户与同步',
  '素材库',
  '设置',
];
