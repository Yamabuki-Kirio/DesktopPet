/// 「轮盘菜单诊断」卡片（增量 A）。
///
/// 只读展示 Windows 轮盘几何探针的**打开 / 关闭**事件快照，并支持一键复制，
/// 便于把真机几何事实带着走。刻意做成非侵入式：不影响任何既有设置项。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../menu/wheel_menu_diagnostics.dart';

class WheelMenuDiagnosticsCard extends StatefulWidget {
  const WheelMenuDiagnosticsCard({super.key});

  @override
  State<WheelMenuDiagnosticsCard> createState() =>
      _WheelMenuDiagnosticsCardState();
}

class _WheelMenuDiagnosticsCardState extends State<WheelMenuDiagnosticsCard> {
  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: wheelMenuDiagnostics.toCopyText()),
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('轮盘菜单诊断信息已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: wheelMenuDiagnostics,
      builder: (BuildContext context, Widget? _) {
        final WheelMenuDiagnosticSample? sample = wheelMenuDiagnostics.latest;
        return Card(
          color: const Color(0xFFF3F6FA),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '轮盘菜单诊断（Windows 几何探针）',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text(
                  '单击桌宠打开测试轮盘；这里记录每次打开 / 关闭的窗口矩形、'
                  'DPI、提交耗时与桌宠屏幕坐标误差。',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: wheelMenuDiagnostics.diagnosticMode,
                  title: const Text('诊断模式（记录前 12 帧几何）',
                      style: TextStyle(fontSize: 12)),
                  subtitle: const Text('默认关闭，避免刷屏',
                      style: TextStyle(fontSize: 10)),
                  onChanged: (bool value) {
                    setState(() => wheelMenuDiagnostics.diagnosticMode = value);
                  },
                ),
                if (sample == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('尚无记录（先单击桌宠打开一次轮盘菜单）',
                        style: TextStyle(fontSize: 11)),
                  )
                else
                  SelectableText(
                    _formatSample(sample),
                    style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制诊断信息'),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: wheelMenuDiagnostics.hasSamples
                          ? () => wheelMenuDiagnostics.clear()
                          : null,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('清空'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatSample(WheelMenuDiagnosticSample sample) {
    final Map<String, Object?> map = sample.toMap();
    return WheelMenuDiagnosticSample.frozenKeys
        .map((String key) => "$key = ${map[key] ?? 'none'}")
        .join('\n');
  }
}
