/// 固定画布 / 正式轮盘的**运行时诊断开关**（设置页 ↔ 桌面探针的唯一桥）。
///
/// 增量 A 的诊断观测点（RegionOwner / WheelUiState / 层级 / 槽位 / Region 矩形数 /
/// GDI / 硬断言 / Region 边界可视化）全部保留，但**默认关闭** ——
/// 正式 P3P 轮盘上线后，诊断面板不该再遮挡菜单。
///
/// 六色块测试菜单同理：代码保留（回归对照用），默认关闭。
library;

import 'package:flutter/foundation.dart';

/// 诊断开关（进程内单例）。
class FixedCanvasDiagnosticsFlags {
  FixedCanvasDiagnosticsFlags._();

  /// 是否显示诊断面板（右下角）。
  static final ValueNotifier<bool> panelVisible = ValueNotifier<bool>(false);

  /// 是否用**六色块测试菜单**替代正式轮盘（仅诊断对照用）。
  static final ValueNotifier<bool> legacyTestMenu = ValueNotifier<bool>(false);

  /// 是否把当前 Region 矩形画成绿框。
  static final ValueNotifier<bool> regionVisualization = ValueNotifier<bool>(false);
}
