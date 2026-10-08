/// 「固定画布 / 正式轮盘」运行时诊断开关（设置页 → 桌面探针）。
///
/// 三个开关默认全部关闭，避免诊断面板遮挡正式菜单：
/// * **诊断面板**：右下角显示 RegionOwner / WheelUiState / 层级 / 槽位 / 主题 /
///   尺寸 / Region 矩形数 / GDI 对象数 / 硬断言，并可一键复制；
/// * **六色块测试菜单**：用增量 A 的测试菜单替代正式轮盘（回归对照用）；
/// * **显示 Region 边界**：把当前提交给原生的 Region 矩形画成绿框。
library;

import 'package:flutter/material.dart';

import '../desktop/fixed_canvas_diagnostics_flags.dart';

class FixedCanvasDiagnosticsSwitches extends StatelessWidget {
  const FixedCanvasDiagnosticsSwitches({super.key});

  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xFFF3F6FA),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '运行时诊断（默认关闭）',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              _flagTile(
                notifier: FixedCanvasDiagnosticsFlags.panelVisible,
                title: '诊断面板',
                subtitle: '桌宠右下角显示轮盘 / Region / 原生状态快照',
              ),
              _flagTile(
                notifier: FixedCanvasDiagnosticsFlags.legacyTestMenu,
                title: '六色块测试菜单',
                subtitle: '用增量 A 的测试菜单替代正式轮盘（回归对照）',
              ),
              _flagTile(
                notifier: FixedCanvasDiagnosticsFlags.regionVisualization,
                title: '显示 Region 边界',
                subtitle: '把当前提交给原生的交互区域画成绿框',
              ),
            ],
          ),
        ),
      );

  Widget _flagTile({
    required ValueNotifier<bool> notifier,
    required String title,
    required String subtitle,
  }) =>
      ValueListenableBuilder<bool>(
        valueListenable: notifier,
        builder: (BuildContext context, bool value, Widget? _) => SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: value,
          title: Text(title, style: const TextStyle(fontSize: 12)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 10)),
          onChanged: (bool v) => notifier.value = v,
        ),
      );
}
