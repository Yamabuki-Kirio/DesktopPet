import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/character_repository.dart';
import '../../character/pet_renderer.dart';
import '../../core/error_handler.dart';
import '../../core/logger.dart';
import '../../diagnostics/perf_sampler.dart';
import '../../diagnostics/process_metrics.dart';
import '../library_controller.dart';

/// 诊断页面。
///
/// 阶段 0 验收需要「实际 CPU 和内存占用测试结果」以及对损坏素材、回退原因、
/// 解码缓存的可见性，因此把它做成独立一页，而不是藏在日志文件里。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, required this.services, required this.library});

  final AppServices services;
  final LibraryController library;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  LibraryStats? _stats;
  ProcessSample? _live;
  String _exportMessage = '';

  @override
  void initState() {
    super.initState();
    widget.services.perfSampler.addListener(_onChange);
    ErrorHandler.unhandledCount.addListener(_onChange);
    _refresh();
  }

  @override
  void dispose() {
    widget.services.perfSampler.removeListener(_onChange);
    ErrorHandler.unhandledCount.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final LibraryStats stats = await widget.services.repository.stats(widget.services.ownerId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        // 平台实现：Windows 走 FFI；Android 返回 null（页面据此隐藏该行）。
        _live = widget.services.platform.processDiagnostics.sample();
      });
    } catch (e, st) {
      Loggers.app.warning('刷新诊断信息失败', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppServices s = widget.services;
    final PerfSampler sampler = s.perfSampler;
    final Map<String, Object?> diag = s.diagnostics();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _title('运行环境'),
          _kvCard(<String, String>{
            '应用数据目录': '${diag['app_data_dir']}',
            '数据库': '${diag['database']}（已打开：${diag['db_open']}）',
            '日志文件': '${diag['log_file']}',
            'FFI 进程指标可用': '${diag['ffi_metrics_available']}',
            '逻辑核心数': '${Platform.numberOfProcessors}',
            '操作系统': Platform.operatingSystemVersion,
          }),
          const SizedBox(height: 16),
          _title('资源占用'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (_live != null) ...<Widget>[
                    Text('实时 · 工作集 ${_live!.workingSetMb.toStringAsFixed(1)} MB'
                        ' · 峰值 ${_live!.peakWorkingSetMb.toStringAsFixed(1)} MB'
                        ' · CPU 累计 ${(_live!.cpuTotalMs / 1000).toStringAsFixed(1)} s'
                        ' · 句柄 ${_live!.handleCount}'),
                  ] else
                    const Text('实时数据不可用'),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: sampler.isRunning
                            ? () => sampler.stop()
                            : () {
                                sampler.start();
                              },
                        icon: Icon(sampler.isRunning ? Icons.stop : Icons.play_arrow, size: 16),
                        label: Text(sampler.isRunning ? '停止采样' : '开始采样（每 30 秒）'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => sampler.reset(),
                        icon: const Icon(Icons.restart_alt, size: 16),
                        label: const Text('重置'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final String? path = await sampler.exportReports();
                          setState(() => _exportMessage =
                              path == null ? '导出失败（还没有采样数据）' : '已导出：$path');
                        },
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text('导出 CSV + JSON'),
                      ),
                    ],
                  ),
                  if (_exportMessage.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    SelectableText(_exportMessage, style: const TextStyle(fontSize: 11)),
                  ],
                  const SizedBox(height: 10),
                  _PerfSummary(sampler: sampler),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _title('素材库统计'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _stats == null
                  ? const Text('加载中…')
                  : Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: <Widget>[
                        _stat('作品包', '${_stats!.packCount}'),
                        _stat('角色', '${_stats!.characterCount}'),
                        _stat('素材总数', '${_stats!.assetCount}'),
                        _stat('动态素材', '${_stats!.animatedCount}'),
                        _stat('静态素材', '${_stats!.staticCount}'),
                        _stat('校验失败', '${_stats!.invalidCount}'),
                        _stat('被禁用', '${_stats!.disabledCount}'),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
          _title('当前渲染（实时）'),
          // 动画每推进一帧都会通知，因此把这块单独包一个 ListenableBuilder，
          // 只有这张卡片逐帧刷新，其余页面内容不受影响。
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ListenableBuilder(
                listenable: s.renderer,
                builder: (BuildContext context, Widget? _) {
                  final PetRenderer r = s.renderer;
                  final int? frame = r.currentFrameIndex;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('当前素材：${r.currentAssetId ?? '（内置占位图）'}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      Text('类型：${r.isAnimated ? '动态动画' : '静态图片 / 占位'}',
                          style: const TextStyle(fontSize: 12)),
                      Text('当前帧 frameIndex：${frame ?? '—'}'
                          '${frame == null ? '' : '（应随时间递增并循环回绕）'}',
                          style: const TextStyle(fontSize: 12)),
                      Text('距本轮动画结束：${r.remainingMsInCycle} ms',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          _title('解码缓存（有限缓存策略）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('静态图解缓存：${diag['decoded_image_entries']} 项 / '
                      '${(diag['decoded_image_mb']! as double).toStringAsFixed(1)} MB'),
                  Text('文件字节缓存：${diag['cached_file_entries']} 项 / '
                      '${(diag['cached_file_mb']! as double).toStringAsFixed(1)} MB'),
                  const SizedBox(height: 6),
                  const Text(
                    '上限：静态图 24 项 / 192 MB，文件字节 32 项 / 96 MB。'
                    '淘汰时立即 dispose，长时间运行不会累积内存。',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _title('错误与日志'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('未处理异常次数：${ErrorHandler.unhandledCount.value}'),
                  if (ErrorHandler.lastError.value != null)
                    Text('最近一次：${ErrorHandler.lastError.value}',
                        style: const TextStyle(fontSize: 11, color: Colors.red)),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () async {
                          final String text = AppLog.exportRecentLogText();
                          if (!context.mounted) return;
                          await showDialog<void>(
                            context: context,
                            builder: (BuildContext ctx) => AlertDialog(
                              title: const Text('最近日志（内存中的最后 500 条）'),
                              content: SizedBox(
                                width: 760,
                                height: 460,
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    text.isEmpty ? '（暂无日志）' : text,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'Consolas',
                                    ),
                                  ),
                                ),
                              ),
                              actions: <Widget>[
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.article_outlined, size: 16),
                        label: const Text('查看最近日志'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final String? path = AppLog.logFilePath;
                          if (path == null) return;
                          await Process.run('explorer', <String>['/select,$path']);
                        },
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('在资源管理器中定位日志文件'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2F4A63),
          ),
        ),
      );

  Widget _kvCard(Map<String, String> data) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final MapEntry<String, String> e in data.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 160,
                        child: Text(e.key,
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      ),
                      Expanded(child: SelectableText(e.value, style: const TextStyle(fontSize: 12))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      );
}

class _PerfSummary extends StatelessWidget {
  const _PerfSummary({required this.sampler});

  final PerfSampler sampler;

  @override
  Widget build(BuildContext context) {
    final PerfReport? report = sampler.buildReport();
    if (report == null) {
      return const Text('尚无采样数据。点「开始采样」后，这里会给出真实的 CPU / 内存统计。',
          style: TextStyle(fontSize: 12, color: Colors.black54));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('采样时长 ${report.duration.inMinutes} 分 ${report.duration.inSeconds % 60} 秒'
            ' · ${report.samples.length} 个采样点',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        Text('内存 起 ${report.firstWorkingSetMb.toStringAsFixed(1)} MB → '
            '终 ${report.lastWorkingSetMb.toStringAsFixed(1)} MB '
            '（均值 ${report.avgWorkingSetMb.toStringAsFixed(1)} / 峰值 ${report.peakWorkingSetMb.toStringAsFixed(1)} MB）',
            style: const TextStyle(fontSize: 12)),
        Text('CPU 均值 ${report.avgCpuOneCore.toStringAsFixed(2)}%（单核）· '
            '峰值 ${report.peakCpuOneCore.toStringAsFixed(2)}%（单核）'
            ' · 折合整机 ${(report.avgCpuOneCore / Platform.numberOfProcessors).toStringAsFixed(3)}%',
            style: const TextStyle(fontSize: 12)),
        Text('句柄数净变化 ${report.handleGrowth >= 0 ? '+' : ''}${report.handleGrowth}',
            style: const TextStyle(fontSize: 12)),
        if (report.memoryKeepsGrowing)
          const Text('⚠ 后 1/3 采样均值明显高于前 1/3，存在内存增长趋势',
              style: TextStyle(fontSize: 12, color: Colors.red)),
      ],
    );
  }
}
