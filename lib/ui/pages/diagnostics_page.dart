import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../character/character_repository.dart';
import '../../character/pet_renderer.dart';
import '../../core/error_handler.dart';
import '../../core/logger.dart';
import '../../diagnostics/perf_sampler.dart';
import '../../diagnostics/process_metrics.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_page.dart';

/// 诊断页面（需求 §7「诊断」）。
///
/// 本轮**只改外观与分组**：判定标准、取值来源、动作全部与改造前一致。
///
/// 分组：权限 → 数据库与存储 → 同步 → 运行环境 → 代理 → 采集 → 性能与资源
/// → 当前渲染 → 错误与日志。
///
/// * 正常状态用绿色状态标签，异常状态给出**原因 + 操作入口**；
/// * 大段诊断文本（日志）放在可复制、可滚动的等宽区域里。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.services,
    required this.library,
    this.overlay,
    this.embedded = false,
  });

  final AppServices services;
  final LibraryController library;

  /// Android 悬浮桌宠协调器（可选）。
  ///
  /// 桌面端为 null：Windows 的桌宠是独立窗口，没有系统级悬浮窗服务，
  /// 因此「权限」分组会自动只显示真实存在的条目。
  final OverlayPetController? overlay;

  /// 是否作为控制面板的**内嵌页**渲染。
  ///
  /// * `false`（默认）：自带 `Scaffold` + `AppBar`（移动端从设置页 push 进来时用）；
  /// * `true`：只渲染 `PetLifePage` 内容，标题由控制面板统一提供。
  final bool embedded;

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
      final LibraryStats stats =
          await widget.services.repository.stats(widget.services.ownerId);
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
    final Widget body = ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        ..._permissionGroup(context),
        ..._storageGroup(context),
        ..._syncGroup(context),
        ..._runtimeGroup(context),
        ..._proxyGroup(context),
        ..._activityGroup(context),
        ..._performanceGroup(context),
        ..._renderGroup(context),
        ..._errorGroup(context),
        const SizedBox(height: PetLifeSpacing.groupGap),
      ],
    );

    if (widget.embedded) {
      return PetLifePage(
        title: '诊断',
        subtitle: '运行环境、权限、同步与资源占用的真实状态',
        actions: <Widget>[
          PetLifeHeaderAction(
            icon: Icons.refresh,
            tooltip: '刷新诊断信息',
            onPressed: _refresh,
          ),
        ],
        child: body,
      );
    }

    // 作为独立路由打开（移动端从设置页进入）：自带 AppBar（含返回按钮）。
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断'),
        actions: <Widget>[
          PetLifeHeaderAction(
            icon: Icons.refresh,
            tooltip: '刷新诊断信息',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PetLifeSpacing.page),
        child: body,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 分组
  // ---------------------------------------------------------------------------

  List<Widget> _permissionGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    final OverlayPetController? overlay = widget.overlay;

    final String launchSupported =
        widget.services.startupRegistration.isSupported ? '支持' : '本平台不支持';
    final bool launchRegistered = widget.services.startupRegistration.isRegistered();

    return _group(
      title: '权限',
      subtitle: '每一项都由系统决定，应用无法自行开启',
      rows: <Widget>[
        _statusRow(
          '开机自动启动',
          launchRegistered ? '已注册' : '未注册',
          ok: launchRegistered,
          note: launchSupported == '支持'
              ? '注册表 HKCU\\...\\Run：'
                  '${widget.services.startupRegistration.registeredCommandOrNull() ?? '<未注册>'}'
              : '本平台不支持开机自启',
        ),
        if (overlay != null) ...<Widget>[
          _statusRow(
            '悬浮窗权限',
            overlay.permissions?.overlayGranted == true ? '已授予' : '未授予',
            ok: overlay.permissions?.overlayGranted == true,
            note: '未授予时桌宠无法显示在其他应用之上',
          ),
          _statusRow(
            '通知权限',
            overlay.permissions?.notificationsGranted == true ? '已授予' : '未授予',
            ok: overlay.permissions?.notificationsGranted == true,
            note: '拒绝也能运行，只是通知栏没有控制入口',
          ),
        ],
        _kv('系统采集能力',
            '${diag['supports_system_activity_tracking']}'),
        _kv('窗口管理能力', '${diag['supports_window_management']}'),
        _kv('托盘能力', '${diag['supports_tray']}'),
      ],
    );
  }

  List<Widget> _storageGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    return _group(
      title: '数据库与存储',
      subtitle: '应用私有目录，不会写入素材原目录',
      rows: <Widget>[
        _kv('应用数据目录', '${diag['app_data_dir']}', selectable: true),
        _kv('数据库', '${diag['database']}', selectable: true),
        _kv('数据库后端', '${diag['database_backend']}'),
        _kv('数据库已打开', '${diag['db_open']}'),
        _kv('日志文件', '${diag['log_file']}', selectable: true),
      ],
    );
  }

  List<Widget> _syncGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    final bool signedIn = diag['sync_signed_in'] == true;
    return _group(
      title: '同步',
      subtitle: '只上报使用时间段与自报信息，绝不上传窗口标题 / 输入 / 截图',
      rows: <Widget>[
        _statusRow(
          '登录状态',
          signedIn ? '已登录' : '未登录',
          ok: signedIn,
          note: signedIn
              ? '账户：${diag['sync_account']}'
              : '未登录不做任何网络请求，本地功能不受影响',
        ),
        _kv('同步状态', '${diag['sync_status']}'),
        _kv('待同步', '${diag['sync_pending']} 条'),
        _kv('连续失败次数', '${diag['sync_consecutive_failures']}'),
        _kv('最近成功同步', '${diag['sync_last_success']}'),
        _kv('最近错误', '${diag['sync_last_error']}'),
        _kv('需要重新登录', '${diag['sync_needs_reauth']}'),
        _kv('服务端', '${diag['sync_server']}', selectable: true),
        _kv('服务端设备 ID', '${diag['sync_device_id']}'),
        _kv('凭据后端', '${diag['sync_credential_backend']}'),
      ],
    );
  }

  List<Widget> _runtimeGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    return _group(
      title: '运行环境',
      subtitle: '平台与设备自报信息',
      rows: <Widget>[
        _kv('平台', '${diag['platform_name']} / ${diag['form_factor']}'),
        _kv('设备', '${diag['device_name']}（${diag['device_model']}）'),
        _kv('系统', '${diag['device_platform']} ${diag['device_os_version']}'),
        _kv('架构', '${diag['device_architecture']}'),
        _kv('逻辑核心数', '${Platform.numberOfProcessors}'),
        _kv('FFI 进程指标可用', '${diag['process_metrics_available']}'),
        _kv('未处理异常次数', '${diag['unhandled_errors']}'),
      ],
    );
  }

  List<Widget> _proxyGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    final String issue = '${diag['proxy_issue']}';
    final bool hasIssue = issue.isNotEmpty && issue != '<无>';
    return _group(
      title: '网络与代理',
      subtitle: 'Clash 用户建议开启 System Proxy 或填写 HTTP/Mixed 端口',
      rows: <Widget>[
        _statusRow(
          '代理状态',
          hasIssue ? '需要注意' : '正常',
          ok: !hasIssue,
          note: hasIssue ? issue : '当前出口：${diag['proxy_route']}',
        ),
        _kv('代理模式', '${diag['proxy_mode']}'),
        _kv('实际路由', '${diag['proxy_route']}'),
        _kv('代理地址', '${diag['proxy_authority']}'),
        _kv('来源', '${diag['proxy_source']}'),
        _kv('本地地址绕过代理', '${diag['proxy_bypass_localhost']}'),
        _kv('系统代理可读', '${diag['proxy_system_readable']}'),
        _kv('系统代理设置', '${diag['proxy_system_proxy_server']}'),
      ],
    );
  }

  List<Widget> _activityGroup(BuildContext context) {
    final Map<String, Object?> diag = widget.services.diagnostics();
    final bool available = diag['activity_provider_available'] == true;
    return _group(
      title: '使用统计采集',
      subtitle: '只记录可执行文件名、启动时段与分类',
      rows: <Widget>[
        _statusRow(
          '采集提供者',
          available ? '可用' : '不可用',
          ok: available,
          note: available ? null : '本平台不提供系统级前台应用采集，桌宠仍可正常使用',
        ),
        _kv('采集运行中', '${diag['activity_tracking_running']}'),
        _kv('采集状态', '${diag['activity_status']}'),
        _kv('已暂停', '${diag['activity_paused']}'),
        _kv('当前前台应用', '${diag['activity_current_app']}'),
        _kv('今日活跃', '${diag['activity_today_active_seconds']} 秒'),
        _kv('今日屏幕会话', '${diag['activity_today_session_seconds']} 秒'),
        _kv('今日空闲', '${diag['activity_today_idle_seconds']} 秒'),
        _kv('连续活跃', '${diag['activity_continuous_seconds']} 秒'),
        _kv('本机设备标识', '${diag['activity_device_id']}'),
        _kv('已登记应用', '${diag['activity_known_apps']} 个'),
        _kv('写入失败连续次数', '${diag['activity_failure_streak']}'),
      ],
    );
  }

  List<Widget> _performanceGroup(BuildContext context) {
    final AppServices s = widget.services;
    final PerfSampler sampler = s.perfSampler;
    final Map<String, Object?> diag = s.diagnostics();

    return _group(
      title: '性能与资源',
      subtitle: '真实采样结果，可导出 CSV + JSON',
      rows: <Widget>[
        if (_live != null)
          Text(
            '实时 · 工作集 ${_live!.workingSetMb.toStringAsFixed(1)} MB'
            ' · 峰值 ${_live!.peakWorkingSetMb.toStringAsFixed(1)} MB'
            ' · CPU 累计 ${(_live!.cpuTotalMs / 1000).toStringAsFixed(1)} s'
            ' · 句柄 ${_live!.handleCount}',
            style: TextStyle(
              fontSize: PetLifeText.caption,
              color: PetLifeTheme.of(context).textPrimary,
            ),
          )
        else
          Text(
            '实时数据不可用（本平台不提供进程指标）',
            style: TextStyle(
              fontSize: PetLifeText.caption,
              color: PetLifeTheme.of(context).textSecondary,
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            PetLifePrimaryButton(
              label: sampler.isRunning ? '停止采样' : '开始采样（每 30 秒）',
              icon: sampler.isRunning ? Icons.stop : Icons.play_arrow,
              onPressed: sampler.isRunning
                  ? sampler.stop
                  : () => sampler.start(),
            ),
            PetLifeSecondaryButton(
              label: '重置',
              icon: Icons.restart_alt,
              onPressed: sampler.reset,
            ),
            PetLifeSecondaryButton(
              label: '导出 CSV + JSON',
              icon: Icons.save_alt,
              onPressed: () async {
                final String? path = await sampler.exportReports();
                if (!mounted) return;
                setState(() => _exportMessage =
                    path == null ? '导出失败（还没有采样数据）' : '已导出：$path');
              },
            ),
          ],
        ),
        if (_exportMessage.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          SelectableText(
            _exportMessage,
            style: TextStyle(
              fontSize: PetLifeText.caption,
              fontFamily: 'Consolas',
              color: PetLifeTheme.of(context).textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _PerfSummary(sampler: sampler),
        const SizedBox(height: 14),
        _sectionLabel('素材库统计'),
        if (_stats == null)
          const PetLifeLoading(label: '正在统计素材库…')
        else
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: <Widget>[
              PetLifeStat(label: '作品包', value: '${_stats!.packCount}'),
              PetLifeStat(label: '角色', value: '${_stats!.characterCount}'),
              PetLifeStat(label: '素材总数', value: '${_stats!.assetCount}'),
              PetLifeStat(label: '动态素材', value: '${_stats!.animatedCount}'),
              PetLifeStat(label: '静态素材', value: '${_stats!.staticCount}'),
              PetLifeStat(
                label: '校验失败',
                value: '${_stats!.invalidCount}',
                valueColor: _stats!.invalidCount > 0
                    ? PetLifeTheme.of(context).danger
                    : null,
              ),
              PetLifeStat(label: '被禁用', value: '${_stats!.disabledCount}'),
            ],
          ),
        const SizedBox(height: 14),
        _sectionLabel('解码缓存（有限缓存策略）'),
        Text(
          '静态图解缓存：${diag['decoded_image_entries']} 项 / '
          '${(diag['decoded_image_mb']! as double).toStringAsFixed(1)} MB\n'
          '文件字节缓存：${diag['cached_file_entries']} 项 / '
          '${(diag['cached_file_mb']! as double).toStringAsFixed(1)} MB',
          style: TextStyle(
            fontSize: PetLifeText.caption,
            color: PetLifeTheme.of(context).textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '上限：静态图 24 项 / 192 MB，文件字节 32 项 / 96 MB。'
          '淘汰时立即 dispose，长时间运行不会累积内存。',
          style: TextStyle(
            fontSize: PetLifeText.captionSmall,
            color: PetLifeTheme.of(context).textSecondary,
          ),
        ),
      ],
    );
  }

  List<Widget> _renderGroup(BuildContext context) {
    final AppServices s = widget.services;
    return _group(
      title: '当前渲染（实时）',
      subtitle: '动画每推进一帧都会刷新这一张卡片',
      rows: <Widget>[
        // 动画每推进一帧都会通知，因此把这块单独包一个 ListenableBuilder，
        // 只有这张卡片逐帧刷新，其余页面内容不受影响。
        ListenableBuilder(
          listenable: s.renderer,
          builder: (BuildContext context, Widget? _) {
            final PetRenderer r = s.renderer;
            final int? frame = r.currentFrameIndex;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _kv('当前素材', r.currentAssetId ?? '（内置占位图）'),
                _kv('类型', r.isAnimated ? '动态动画' : '静态图片 / 占位'),
                _kv(
                  '当前帧 frameIndex',
                  '${frame ?? '—'}'
                      '${frame == null ? '' : '（应随时间递增并循环回绕）'}',
                ),
                _kv('距本轮动画结束', '${r.remainingMsInCycle} ms'),
              ],
            );
          },
        ),
      ],
    );
  }

  List<Widget> _errorGroup(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final int unhandled = ErrorHandler.unhandledCount.value;
    final String? lastError = ErrorHandler.lastError.value;

    return _group(
      title: '错误与日志',
      subtitle: '最近日志在内存中保留最后 500 条',
      rows: <Widget>[
        _statusRow(
          '未处理异常',
          unhandled == 0 ? '无' : '$unhandled 次',
          ok: unhandled == 0,
          note: lastError,
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 260),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.muted,
            borderRadius: PetLifeRadii.cardBorder,
            border: Border.all(color: p.border),
          ),
          // 可复制、可滚动的等宽区域。
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                _recentLogText(),
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  fontFamily: 'Consolas',
                  color: p.textPrimary,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            PetLifeSecondaryButton(
              label: '复制到剪贴板',
              icon: Icons.copy_all_outlined,
              onPressed: () async {
                await _copyRecentLog(context);
              },
            ),
            PetLifeSecondaryButton(
              label: '放大查看',
              icon: Icons.article_outlined,
              onPressed: () => _showLogDialog(context),
            ),
            if (widget.embedded)
              PetLifeSecondaryButton(
                label: '在资源管理器中定位日志文件',
                icon: Icons.folder_open,
                onPressed: () async {
                  final String? path = AppLog.logFilePath;
                  if (path == null) return;
                  await Process.run('explorer', <String>['/select,$path']);
                },
              ),
          ],
        ),
      ],
    );
  }

  String _recentLogText() {
    final String text = AppLog.exportRecentLogText();
    return text.isEmpty ? '（暂无日志）' : text;
  }

  Future<void> _copyRecentLog(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _recentLogText()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制最近日志')),
    );
  }

  Future<void> _showLogDialog(BuildContext context) async {
    final String text = _recentLogText();
    final PetLifePalette p = PetLifeTheme.of(context);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('最近日志（内存中的最后 500 条）'),
        content: SizedBox(
          width: 820,
          height: 520,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: p.muted,
              borderRadius: PetLifeRadii.cardBorder,
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    fontFamily: 'Consolas',
                    color: p.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: <Widget>[
          PetLifePrimaryButton(
            label: '关闭',
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 小组件
  // ---------------------------------------------------------------------------

  /// 组：分组标题 + 一张独立圆角卡片。
  List<Widget> _group({
    required String title,
    String? subtitle,
    required List<Widget> rows,
  }) =>
      <Widget>[
        PetLifeSectionTitle(title: title, subtitle: subtitle),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
        const SizedBox(height: PetLifeSpacing.groupGap),
      ];

  Widget _kv(String label, String value, {bool selectable = false}) =>
      PetLifeKeyValue(label: label, value: value, selectable: selectable);

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: PetLifeText.caption,
            fontWeight: FontWeight.w700,
            color: PetLifeTheme.of(context).textSecondary,
          ),
        ),
      );

  /// 状态行：正常用绿色标签，异常给出原因（需求 §7：不只显示红字）。
  Widget _statusRow(
    String label,
    String value, {
    required bool ok,
    String? note,
  }) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Widget trailing = PetLifeTag(
      label: value,
      color: ok ? p.success : p.warning,
      dense: true,
    );
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: PetLifeText.bodySmall,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        if (note != null && note.isNotEmpty)
          Text(
            note,
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              color: ok ? p.textSecondary : p.warning,
              height: 1.35,
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = MediaQuery.textScalerOf(context).scale(1.0);
          if (constraints.maxWidth < 320 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                text,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: text),
              const SizedBox(width: 12),
              trailing,
            ],
          );
        },
      ),
    );
  }
}

class _PerfSummary extends StatelessWidget {
  const _PerfSummary({required this.sampler});

  final PerfSampler sampler;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final PerfReport? report = sampler.buildReport();
    if (report == null) {
      return Text(
        '尚无采样数据。点「开始采样」后，这里会给出真实的 CPU / 内存统计。',
        style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
      );
    }
    final TextStyle style =
        TextStyle(fontSize: PetLifeText.caption, color: p.textPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '采样时长 ${report.duration.inMinutes} 分 ${report.duration.inSeconds % 60} 秒'
          ' · ${report.samples.length} 个采样点',
          style: style.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          '内存 起 ${report.firstWorkingSetMb.toStringAsFixed(1)} MB → '
          '终 ${report.lastWorkingSetMb.toStringAsFixed(1)} MB '
          '（均值 ${report.avgWorkingSetMb.toStringAsFixed(1)} / '
          '峰值 ${report.peakWorkingSetMb.toStringAsFixed(1)} MB）',
          style: style,
        ),
        Text(
          'CPU 均值 ${report.avgCpuOneCore.toStringAsFixed(2)}%（单核）· '
          '峰值 ${report.peakCpuOneCore.toStringAsFixed(2)}%（单核）'
          ' · 折合整机 '
          '${(report.avgCpuOneCore / Platform.numberOfProcessors).toStringAsFixed(3)}%',
          style: style,
        ),
        Text(
          '句柄数净变化 ${report.handleGrowth >= 0 ? '+' : ''}${report.handleGrowth}',
          style: style,
        ),
        if (report.memoryKeepsGrowing)
          Text(
            '⚠ 后 1/3 采样均值明显高于前 1/3，存在内存增长趋势',
            style: style.copyWith(color: p.danger, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }
}
