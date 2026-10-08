import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../activity_tracking/android_usage_import_service.dart';
import '../../activity_tracking/android_usage_session.dart';
import '../../activity_tracking/models/usage_stats.dart';
import '../../app/app_scope.dart';
import '../../core/logger.dart';
import '../../platform/overlay_pet.dart';
import '../../state_engine/system_state.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../pages/state_asset_mapping_page.dart';

/// 「Android 悬浮桌宠」设置卡（Phase 4C-1 权限与生命周期 + 4C-2 素材状态）。
///
/// 显示五段信息：
/// * 权限（悬浮窗 / 通知 / **使用情况访问**）与运行状态；
/// * 窗口与手势、大小、菜单；
/// * 当前悬浮素材与素材加载状态；
/// * 视觉与动画（4C-4）；
/// * **状态联动诊断 + 手动覆盖**（4C-5，需求 §16 / §19）。
///
/// 三条硬规则（需求第五、十九节）：
/// * 权限**现场复查**：从系统设置页回来一律重新查 `Settings.canDrawOverlays`，
///   绝不把"打开过设置页"当成"已授权"；
/// * 权限不足时**不启动服务**，只给出明确提示并保留用户已有设置；
/// * 任何原生异常都渲染在卡片里（不弹连续弹窗、不显示堆栈）。
///
/// 显示模式、边缘吸附、触摸穿透、锁屏策略等开关属于 4C-6，
/// 会在这张卡上继续扩展，而不是重写。
class OverlayPetCard extends StatefulWidget {
  const OverlayPetCard({
    super.key,
    required this.controller,
    required this.services,
    this.library,
  });

  final OverlayPetController controller;

  /// 装配层服务：只用于读取 Phase 4C-5.1B 的使用记录采集器状态与导入器诊断。
  final AppServices services;

  /// 素材库控制器（Phase 4C-6A.1：「编辑状态素材」快捷入口需要它）。
  ///
  /// 为 null 时快捷入口会退化为"请到素材库操作"的提示 —— 绝不静默失效。
  final LibraryController? library;

  @override
  State<OverlayPetCard> createState() => _OverlayPetCardState();
}

class _OverlayPetCardState extends State<OverlayPetCard>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;

  /// 拖动滑块时的**本地即时值**（松手后清空，回到原生回报的真值）。
  double? _scaleDraft;

  /// 轮盘大小滑块的本地即时值（松手后清空）。
  double? _wheelScaleDraft;

  /// 按钮大小滑块的本地即时值（松手后清空）。
  double? _buttonScaleDraft;

  /// Phase 4C-5.1B：使用记录采集器状态（非 Android 为 null，整个区块不显示）。
  UsageCollectorState? _usageCollector;

  /// 双窗口探针诊断的本地快照（null = 尚未读取完成）。
  ///
  /// 用本地字段而不是直接读 controller：controller 的默认值是不支持的安全默认，
  /// 若直接读会先闪一下"不支持"再变成真值。这里用 null 表示"读取中"。
  DualWindowProbeStatus? _probe;

  /// 「双窗口实现」开关的本地快照（null = 尚未读取完成）。
  ///
  /// 与探针同源（同一张诊断卡）；同样是本地 null 表示"读取中"。
  DualWindowModeStatus? _dualWindowMode;

  /// 切换开关时的**乐观值**（回读原生真值后清空）。
  ///
  /// 先让开关即时响应，回读完成后回到原生真值 —— 失败即自动回退。
  bool? _dualWindowModeDraft;

  /// 探针诊断的可见期轮询计时器（卡片 dispose 时必须停掉）。
  Timer? _probeTimer;

  OverlayPetController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onControllerChanged);
    // 打开设置页时重新查一次权限与状态（可能是从系统设置页回来的）。
    _refresh();
    // 诊断的周期刷新由 [OverlayPetController] 统一驱动（每 2 秒一次只读读取），
    // 这里**不再自己起计时器** —— 否则统计页等其它读者会拿到陈旧数据。
    //
    // 双窗口探针是设置页**本地**的诊断卡：打开即读一次，之后仅在本卡可见
    // （即本 widget 已挂载）期间每 2 秒轮询一次，dispose 时停掉。
    unawaited(_refreshProbe());
    _probeTimer = Timer.periodic(
      const Duration(seconds: 2),
      (Timer _) => unawaited(_refreshProbe()),
    );
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _c.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页回到应用后重新检查权限（需求第五节的硬要求）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _onControllerChanged() {
    // 原生已经回报到我们拖到的那个值 → 丢掉本地草稿，回到"以原生为准"。
    final double? draft = _scaleDraft;
    if (draft != null) {
      final double reported = _c.state?.scale ?? draft;
      if ((reported - draft).abs() < 0.001) _scaleDraft = null;
    }
    if (mounted) setState(() {});
  }

  /// 拖动滑块时**实时预览**：本地立即反映，同时下发到原生。
  void _previewScale(double value) {
    setState(() => _scaleDraft = value);
    unawaited(_c.previewScale(value));
  }

  Future<void> _refresh() async {
    try {
      await _c.refresh();
    } catch (e, st) {
      Loggers.app.warning('读取悬浮桌宠状态失败', e, st);
      if (!mounted) return;
      setState(() => _error = '读取悬浮桌宠状态失败：$e');
    }
    await _refreshUsageCollector();
    if (!mounted) return;
    // Phase 4C-6B-1 / 1.1：轮盘主题与尺寸也一并回读（原生是权威来源）。
    await _c.refreshMenuTheme();
    if (!mounted) return;
    await _c.refreshWheelLayout();
    if (!mounted) return;
    // Phase 4D：开机自启开关与最近一次开机结果（原生是权威来源）。
    await _c.refreshAutostart();
  }

  /// 只读一次双窗口探针诊断（走 controller 透传 → 平台接口 → 通道）。
  ///
  /// **只读**：不启动/停止探针，也不改诊断模式开关。
  /// 同时回读「双窗口实现」开关的真值（卡加载 / 点「刷新」/ 周期轮询都会读到）。
  Future<void> _refreshProbe() async {
    final DualWindowProbeStatus next = await _c.refreshDualWindowProbeStatus();
    if (!mounted) return;
    setState(() => _probe = next);
    // 正在切换时不要用周期读覆盖本地乐观值（切换完成后会自己回读）。
    if (_busy) return;
    final DualWindowModeStatus mode = await _c.refreshDualWindowMode();
    if (!mounted) return;
    setState(() => _dualWindowMode = mode);
  }

  /// 切换「双窗口实现」开关：写 → **回读原生真值** → 失败即回退并提示。
  ///
  /// 不假设写入成功：回读到的真实值与请求值不一致时，开关自动回到真值，
  /// 并弹一条短提示（不谎报成功）。写入抛错时同样回退，并把原因显示在卡片里。
  Future<void> _toggleDualWindowMode(bool value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _dualWindowModeDraft = value; // 先乐观显示，回读后以原生真值为准。
    });
    _c.clearMessages();
    try {
      final DualWindowModeStatus next = await _c.setDualWindowMode(value);
      if (!mounted) return;
      setState(() => _dualWindowMode = next);
      if (next.dualWindowEnabled != value) {
        _toastNotice('切换双窗口实现失败，已保持原值：${next.modeLabelZh}');
      }
    } catch (e, st) {
      Loggers.app.warning('切换双窗口实现失败', e, st);
      if (!mounted) return;
      setState(() => _error = _describe(e));
      _toastNotice('切换双窗口实现失败，已保持原值');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _dualWindowModeDraft = null; // 回到原生真值（失败时即旧值）。
        });
      }
    }
  }

  /// 复制整份探针诊断（稳定的 `key=value` 文本块），并给出简短确认。
  ///
  /// 尚未读取完成也允许复制：controller 的有效值 = 最后一次成功读取
  /// （未成功时为不支持的安全默认），因此复制内容永远可用、可 grep。
  Future<void> _copyProbe() async {
    final DualWindowProbeStatus status =
        _probe ?? _c.dualWindowProbeStatus;
    await Clipboard.setData(ClipboardData(text: status.toCopyText()));
    _toastNotice('双窗口探针诊断信息已复制');
  }

  // ---------------------------------------------------------------------------
  // 轮盘大小（Phase 4C-6B-1.1）
  // ---------------------------------------------------------------------------

  /// 「轮盘大小」滑块：50% ~ 250%，10% 步进，改完立即下发（下次展开即生效）。
  Widget _wheelScaleRow() {
    final OverlayWheelLayoutSettings settings = _c.wheelLayoutSettings;
    final double value = _wheelScaleDraft ?? settings.preferredScale;
    final double buttonValue = _buttonScaleDraft ?? settings.buttonVisualScale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(width: 56, child: Text('轮盘大小', style: TextStyle(fontSize: 12))),
            Expanded(
              child: Slider(
                value: value.clamp(settings.minScale, settings.maxScale),
                min: settings.minScale,
                max: settings.maxScale,
                divisions:
                    ((settings.maxScale - settings.minScale) / settings.step).round().clamp(1, 64),
                label: '${(value * 100).round()}%',
                onChanged: _busy ? null : (double v) => setState(() => _wheelScaleDraft = v),
                onChangeEnd: (double v) => _run(() async {
                  await _c.setWheelScale(v, buttonScale: buttonValue);
                  if (mounted) setState(() => _wheelScaleDraft = null);
                }),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text('${(value * 100).round()}%', style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Row(
          children: <Widget>[
            const SizedBox(width: 56, child: Text('按钮大小', style: TextStyle(fontSize: 12))),
            Expanded(
              child: Slider(
                value: buttonValue.clamp(settings.minButtonScale, settings.maxButtonScale),
                min: settings.minButtonScale,
                max: settings.maxButtonScale,
                divisions: ((settings.maxButtonScale - settings.minButtonScale) / settings.step)
                    .round()
                    .clamp(1, 64),
                label: '${(buttonValue * 100).round()}%',
                onChanged: _busy ? null : (double v) => setState(() => _buttonScaleDraft = v),
                onChangeEnd: (double v) => _run(() async {
                  await _c.setWheelScale(value, buttonScale: v);
                  if (mounted) setState(() => _buttonScaleDraft = null);
                }),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${(buttonValue * 100).round()}%',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await _c.setWheelScale(
                          settings.defaultScale,
                          buttonScale: settings.defaultButtonScale,
                        );
                        if (mounted) {
                          setState(() {
                            _wheelScaleDraft = null;
                            _buttonScaleDraft = null;
                          });
                        }
                      }),
              child: const Text('恢复默认', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const Text(
          '轮盘大小 50%～250%、按钮大小 50%～250%（10% 步进，各自独立设置）。'
          '调按钮不会把整个轮盘一起放大；空间不足时优先压缩间距，'
          '按钮放大时轨道半径会自动外扩，相邻按钮不会重叠；'
          '按钮缩小时触摸范围仍不低于 48dp。',
          style: TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 轮盘主题（Phase 4C-6B-1）
  // ---------------------------------------------------------------------------

  /// 主题色块（点击即切换；选中态加粗描边）。
  Widget _themeChip({
    required String label,
    required String hex,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final Color color = _hexColor(hex);
    return InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF111111) : const Color(0x33000000),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Color(0xFFFFFFFF)),
        ),
      ),
    );
  }

  /// 把 `#RRGGBB` 转成 Flutter 颜色（解析失败退化为灰色，绝不抛错）。
  Color _hexColor(String hex) {
    final String text = hex.replaceFirst('#', '');
    final int? value = int.tryParse(text, radix: 16);
    if (value == null || text.length != 6) return const Color(0xFF9E9E9E);
    return Color(0xFF000000 | value);
  }

  /// 自定义主色：RGB 三个滑块（不引入任何第三方取色依赖）。
  Future<void> _pickCustomThemeColor() async {
    final OverlayMenuThemeState theme = _c.menuThemeState;
    // 直接解析十六进制，避免依赖 Color 的红/绿/蓝分量 API 版本差异。
    final String hex = theme.customPrimary.replaceFirst('#', '');
    final int startValue = int.tryParse(hex, radix: 16) ?? 0xF24D96;
    double r = ((startValue >> 16) & 0xFF).toDouble();
    double g = ((startValue >> 8) & 0xFF).toDouble();
    double b = (startValue & 0xFF).toDouble();
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) {
          final int value = 0xFF000000 | (r.round() << 16) | (g.round() << 8) | b.round();
          return AlertDialog(
            title: const Text('自定义轮盘主色'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(height: 40, color: Color(value)),
                _channelSlider('红', r, (double v) => setDialogState(() => r = v)),
                _channelSlider('绿', g, (double v) => setDialogState(() => g = v)),
                _channelSlider('蓝', b, (double v) => setDialogState(() => b = v)),
                const SizedBox(height: 6),
                const Text(
                  '其余颜色会自动派生，文字色按对比度自动选黑/白',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(value),
                child: const Text('应用'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    await _run(() async {
      await _c.selectMenuTheme(
        themeId: OverlayMenuThemeState.customThemeId,
        customPrimary: picked,
      );
    });
  }

  Widget _channelSlider(String label, double value, ValueChanged<double> onChanged) =>
      Row(
        children: <Widget>[
          SizedBox(width: 20, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: Slider(
              value: value,
              min: 0,
              max: 255,
              divisions: 255,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('${value.round()}', style: const TextStyle(fontSize: 11)),
          ),
        ],
      );

  /// 主题区块（设置 → 悬浮桌宠 → 轮盘主题）。
  Widget _menuThemeSection() {
    final OverlayMenuThemeState theme = _c.menuThemeState;
    if (!(_c.state?.supported ?? false)) return const SizedBox.shrink();
    if (theme.presets.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('轮盘主题：读取中…（若长期停在这里，说明原生未回报主题）',
            style: TextStyle(fontSize: 11)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 6),
        const Text('轮盘主题', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final OverlayMenuThemePreset preset in theme.presets)
              _themeChip(
                label: preset.displayName,
                hex: preset.colors.primary,
                selected: theme.themeId == preset.themeId,
                onTap: () => _run(() async {
                  await _c.selectMenuTheme(themeId: preset.themeId);
                }),
              ),
            _themeChip(
              label: '自定义',
              hex: theme.customPrimary,
              selected: theme.themeId == OverlayMenuThemeState.customThemeId,
              onTap: _pickCustomThemeColor,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '当前：${theme.displayName}（${theme.current.primary}）'
          '${theme.legible ? '' : ' · 文字对主色的对比度偏低'}',
          style: const TextStyle(fontSize: 11),
        ),
        _wheelScaleRow(),
        // 轮盘只读诊断（需求 §15 的调试指标）。
        Text(
          '轮盘：${_runtimeState().menuLevelLabelZh} · 槽位 ${_runtimeState().menuActiveIndex} · '
          '动画 ${_runtimeState().menuAnimation} · 手势 ${_runtimeState().menuGestureOwner}',
          style: const TextStyle(fontSize: 11),
        ),
        Text(_runtimeState().menuPerformance, style: const TextStyle(fontSize: 11)),
        // Phase 4C-6B-1.1 真机回归：菜单打开链路的可判定诊断。
        Text(
          _runtimeState().menuOpenDiagnostics,
          style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
        ),
      ],
    );
  }

  /// 开机自启（Phase 4D）。
  ///
  /// 与"显示 / 隐藏桌宠"是**两个独立设置**：这里只决定"重启后要不要把服务拉起来"，
  /// 不影响当前是否显示，也不会因为隐藏桌宠而被关掉。开关写透到原生
  /// SharedPreferences，`BOOT_COMPLETED` 接收器读的就是它 —— 因此不依赖
  /// Flutter 是否启动过。启动结果由原生如实回报，界面不猜。
  Widget _autostartSection() {
    final OverlayAutostartStatus a = _c.autostartState;
    if (!a.supported) return const SizedBox.shrink();
    final String? bootLabel = a.bootResultLabelZh;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 6),
        const Text('开机自启', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('开机自动启动', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            '重启手机并解锁后，自动把悬浮桌宠服务拉起来（当前：${a.switchLabelZh}）。'
            '与「显示 / 隐藏桌宠」是独立设置：关闭它不会停掉当前桌宠，'
            '隐藏桌宠也不会关掉它。',
            style: const TextStyle(fontSize: 11),
          ),
          value: a.enabled,
          onChanged: _busy
              ? null
              : (bool v) => _run(() async {
                    await _c.setAutostart(v);
                  }),
        ),
        _kv('开机自启状态', a.switchLabelZh),
        _kv('最近一次开机结果', bootLabel ?? '尚无记录（重启一次后显示）'),
        if (a.bootResultAt != null) _kv('结果时间', _timeLabel(a.bootResultAt!)),
        // 仅在原生确实报"被系统限制 / 需要用户介入"时才给厂商后台限制引导
        // （按需提示，不一刀切，也不把通知权限/电池优化说成唯一原因）。
        if (a.enabled && a.needsVendorGuidance)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '系统拒绝了开机后台启动。部分厂商 ROM 会限制应用后台自启，'
                  '可在系统设置里允许 PetLife 自启动 / 后台运行后重试 —— '
                  '不同机型限制不同，并非所有设备都需要这一步，'
                  '也与通知权限、电池优化不是同一件事。',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _run(_c.openAppDetails),
                  child: const Text('打开应用详情页', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        if (a.enabled && !a.overlayGranted)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '尚未授予悬浮窗权限：即使开启自启，重启后也无法显示（请先点下方「授权悬浮窗」）。',
              style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '「开机自动启动」只依赖接收开机广播这一普通权限；真正的启动结果'
            '（成功 / 缺少悬浮窗权限 / 被系统限制）会在上方如实显示，不假装成功。',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// 当前运行时状态的安全读取（非 Android 时为默认值）。
  OverlayRuntimeState _runtimeState() =>
      _c.state ?? OverlayRuntimeState.unsupported;

  /// 读取使用记录采集器状态（Phase 4C-5.1B；非 Android 为 null）。
  ///
  /// 顺带触发一次幂等导入 —— 用户回到设置页时最可能刚切过应用，
  /// 这正是需求 §7 列出的触发点之一。
  Future<void> _refreshUsageCollector() async {
    final AndroidUsageImportService? importer = widget.services.androidUsageImport;
    if (importer == null) return;
    try {
      await importer.importPending();
      final UsageCollectorState state = await importer.collectorState();
      if (!mounted) return;
      setState(() => _usageCollector = state);
    } catch (e, st) {
      Loggers.activity.warning('读取使用记录采集状态失败', e, st);
    }
  }

  /// 统一的动作包装：加锁 → 执行 → 让控制器把真实状态写回来。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _c.clearMessages();
    try {
      await action();
    } catch (e, st) {
      Loggers.app.warning('悬浮桌宠操作失败', e, st);
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(Object error) {
    if (error is OverlayPlatformException) return error.message;
    if (error is OverlayConfigException) return error.message;
    if (error is OverlayUnsupportedException) return error.message;
    return '操作失败：$error';
  }

  Future<void> _show() async {
    final OverlayPermissionState? permissions = _c.permissions;
    // 权限不足时**不启动服务**，只提示（需求第五节）。
    if (permissions != null && !permissions.overlayGranted) {
      setState(() {
        _error = '未获得悬浮窗权限，请先点「授权悬浮窗」';
      });
      return;
    }
    await _run(_c.show);
  }

  @override
  Widget build(BuildContext context) {
    final OverlayRuntimeState? state = _c.state;
    final OverlayPermissionState? permissions = _c.permissions;
    final String? failure = _error ?? _c.lastError;
    final String? notice = _c.lastNotice;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('Android 悬浮桌宠（系统级）',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: '重新检查权限与状态',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: _busy ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            _kv('悬浮窗权限', _grantLabel(permissions?.overlayGranted)),
            _kv('通知权限', _grantLabel(permissions?.notificationsGranted)),
            // --- Phase 4C-5：使用情况访问权限（与悬浮窗权限互相独立）---
            // 未授权时桌宠仍可显示与播放动画，只是状态保持默认（需求 §6）。
            _kv(
              '使用情况访问权限',
              _grantLabel(_c.stateDiagnostics.usageAccessGranted),
            ),
            if (!_c.stateDiagnostics.usageAccessGranted)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '未授予使用情况访问权限，桌宠将保持默认状态。'
                      '（桌宠仍可正常显示与播放动画）',
                      style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(_c.openUsageAccessSettings),
                      child: const Text('去授权使用情况访问', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            _kv('悬浮桌宠', state?.status.labelZh ?? '—'),
            // 窗口诊断：服务在跑但窗口没挂上/尺寸为 0 时，用户必须一眼看出来。
            _kv('窗口', state?.windowSummary ?? '—'),
            _kv('显示', (state?.windowVisible ?? false) ? '可见' : '不可见'),
            _kv(
              '尺寸',
              state == null || !state.windowAttached
                  ? '—'
                  : '${state.viewWidth} × ${state.viewHeight}'
                      '（素材 ${state.imageViewWidth} × ${state.imageViewHeight}）',
            ),
            _kv('已附着窗口', (state?.attachedToWindow ?? false) ? '是' : '否'),
            _kv('最近窗口操作', state?.lastWindowAction ?? '—'),
            // --- Phase 4C-3A：位置 / 大小 / 手势（真机验收时一眼能看出状态）---
            _kv('吸附边', state == null || !state.serviceRunning ? '—' : state.snapEdgeLabelZh),
            _kv('手势状态', state == null ? '—' : state.gestureState),
            _kv(
              '轮盘菜单',
              state == null
                  ? '—'
                  : '${state.menuStateLabelZh}'
                      '${state.menuLevel == 'none' ? '' : '（${state.menuLevelLabelZh}'
                          '·${state.menuButtonCount} 项）'}',
            ),
            if (state?.lastMenuAction != null)
              _kv('最近菜单操作', state!.lastMenuAction!),
            _kv(
              '相对位置',
              state == null
                  ? '—'
                  : '${state.xRatio.toStringAsFixed(2)} / ${state.yRatio.toStringAsFixed(2)}'
                      '（${state.snapOrientation}）',
            ),
            _scaleRow(state),
            _kv('当前悬浮素材', _c.currentAssetLabel ?? '未选择角色'),
            _kv('素材加载状态', _loadLabel(state)),
            // --- Phase 4C-4：视觉与动画（只读诊断，界面不驱动动画）---
            _kv('视觉类型', state == null ? '—' : state.visualTypeLabelZh),
            _kv('播放状态', state == null ? '—' : state.animationStateLabelZh),
            // --- Phase 4C-5：状态联动（只读诊断，界面不驱动切换）---
            ..._stateDiagnosticRows(),
            // --- Phase 4C-5.1B：使用记录采集（只读诊断）---
            ..._usageCollectorRows(),
            _automaticStateControl(),
            // Phase 4C-6A.1：「自动状态联动」下面就是它的编辑入口。
            _stateMappingShortcut(),
            _manualStateControl(),
            // Phase 4C-6B-1：轮盘主题（设置 → 悬浮桌宠 → 轮盘主题）。
            _menuThemeSection(),
            // Phase 4D：开机自启（独立于「显示 / 隐藏桌宠」）。
            _autostartSection(),
            if (state != null && state.windowMissing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '悬浮服务正在运行，但窗口未成功添加'
                  '${state.lastWindowError == null ? '' : '：${state.lastWindowError}'}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
                ),
              ),
            if (state != null && state.hasZeroSizedWindow)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '窗口已挂载但尺寸为 0，将不可见（请反馈此问题）',
                  style: TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
                ),
              ),
            // 诊断模式：完全不依赖素材的洋红方块（真机排障用）。
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('诊断模式（洋红方块）', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '不读取任何素材与历史位置，固定 200dp 洋红方块。'
                '用于区分"窗口/命令时序问题"与"素材解析问题"',
                style: TextStyle(fontSize: 11),
              ),
              value: state?.debugOverlayMode ?? false,
              onChanged: _busy
                  ? null
                  : (bool v) => _run(() => _c.setDebugOverlay(v)),
            ),
            // 双窗口探针的只读状态卡（诊断模式区；不驱动任何行为）。
            _dualWindowProbeCard(),
            if (state?.animatedFirstFrameOnly ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  OverlayRuntimeState.animatedFirstFrameFallbackText,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                ),
              ),
            if (state != null && state.serviceRunning && !state.windowAttached)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '服务在运行，但窗口当前不可见（已隐藏，或被系统关闭）',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '悬浮桌宠会显示在其他应用之上，因此需要系统级悬浮窗权限；'
              '权限只能在系统设置里手动开启。隐藏不会停止服务。'
              '单击桌宠会展开 P3P 风格的轮盘菜单：可以点按钮，也可以沿圆弧滑动选择、'
              '松手确认；轮盘外点击即关闭。菜单里除「返回/层级切换/关闭」外的业务项'
              '在本阶段只提示占位说明（真正的功能在 4C-6B-2 接入）。'
              '动态 WebP 在 Android 9 及以上会持续循环播放；更低版本只能显示第一帧。',
              style: const TextStyle(fontSize: 11),
            ),
            if (failure != null && failure.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  failure,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
                ),
              ),
            if (notice != null && notice.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(notice, style: const TextStyle(fontSize: 11)),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _run(_c.requestOverlayPermission),
                  icon: const Icon(Icons.layers_outlined, size: 16),
                  label: const Text('授权悬浮窗'),
                ),
                if (permissions?.notificationsRequired ?? false)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(_c.requestNotificationPermission),
                    icon: const Icon(Icons.notifications_outlined, size: 16),
                    label: const Text('授权通知'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _show,
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('显示悬浮桌宠'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !(state?.serviceRunning ?? false)
                      ? null
                      : () => _run(_c.hide),
                  icon: const Icon(Icons.visibility_off_outlined, size: 16),
                  label: const Text('隐藏悬浮桌宠'),
                ),
                TextButton.icon(
                  onPressed: _busy || !(state?.serviceRunning ?? false)
                      ? null
                      : () => _run(_c.stop),
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('停止服务'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 大小滑块（Phase 4C-3A）：50% ~ 200%，步长 10%，可恢复默认，拖动即时预览。
  ///
  /// 与原生 `PetOverlayStore.MIN_SCALE/MAX_SCALE` 使用同一组常量，
  /// 因此界面滑块与原生限制**不可能**对不上。
  Widget _scaleRow(OverlayRuntimeState? state) {
    final double current =
        _scaleDraft ?? state?.scale ?? OverlayPetConfig.defaultScale;
    final double safe = current
        .clamp(OverlayPetConfig.minScale, OverlayPetConfig.maxScale)
        .toDouble();
    final int divisions = ((OverlayPetConfig.maxScale - OverlayPetConfig.minScale) /
            OverlayPetConfig.scaleStep)
        .round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(
              width: 88,
              child: Text('大小',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: Slider(
                value: safe,
                min: OverlayPetConfig.minScale,
                max: OverlayPetConfig.maxScale,
                divisions: divisions,
                label: '${(safe * 100).round()}%',
                onChanged: _previewScale,
                onChangeEnd: _previewScale,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text('${(safe * 100).round()}%',
                  style: const TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () => _previewScale(OverlayPetConfig.defaultScale),
              child: const Text('默认', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 88),
          child: Text(
            '50% ~ 200%，步长 10%；调整即时生效，重启应用与服务后保持；'
            '窗口会按素材宽高比等比缩放，不拉伸变形。'
            '${state == null || !state.windowAttached ? '' : '当前窗口 ${state.petWidth}×${state.petHeight}。'}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// 「素材加载状态」：直接映射原生侧的真实可见状态。
  ///
  /// 用原生的 `visual` 而不是自己再推一遍，避免"界面说正常、窗口其实是空的"
  /// 这种自欺欺人的情况（4C-2 真机缺陷的教训）。
  String _loadLabel(OverlayRuntimeState? state) {
    if (state == null) return '—';
    if (!state.serviceRunning) return '未运行';
    if (state.hidden) return '已隐藏';
    switch (state.visual) {
      case 'asset':
        return state.animatedFirstFrameOnly ? '正常（第一帧）' : '正常';
      case 'loading':
        return '加载中…';
      case 'debug':
        return '诊断模式（洋红方块）';
      case 'failure':
        return '失败：${state.lastLoadError ?? "素材加载失败"}';
      case 'empty':
        return state.lastLoadError == null
            ? '尚未显示素材'
            : '失败：${state.lastLoadError}';
    }
    // 原生还没上报 visual（旧版本/异常）时退回按字段推断。
    if (state.lastLoadError != null && state.lastLoadError!.isNotEmpty) {
      return '失败：${state.lastLoadError}';
    }
    if (state.isPlaceholder) return '尚未显示素材';
    return state.showsExpectedAsset ? '正常' : '正在加载…';
  }

  String _grantLabel(bool? granted) {
    if (granted == null) return '—';
    return granted ? '已授权' : '未授权';
  }

  /// 一份可诊断的快照（Phase 4C-5.1B，需求 §12）。
  ///
  /// 只读展示：采集器状态 / 当前会话 / 当前会话时长 / journal 待导入数量 /
  /// 最近一次导入时间与错误。非 Android 时为 null（整个区块不显示）。
  ///
  /// 4C-5.1B 补充修复（跨端不一致排查）后追加「本机设备标识 / 服务端设备 ID /
  /// 待上传 / 最近同步成功」四项 —— 这样在**手机上就能自证**整条链路：
  /// `journal 待导入 = 0` → `outbox 待上传 = 0` → `最近同步成功` → 服务端设备 ID 正确。
  List<Widget> _usageCollectorRows() {
    final UsageCollectorState? c = _usageCollector;
    if (c == null) return const <Widget>[];
    final AndroidUsageImportService? importer = widget.services.androidUsageImport;
    final DateTime? lastImport = importer?.lastImportAt;
    final String? lastError = importer?.lastError;
    final String? serverDeviceId = widget.services.authenticatedApi.deviceServerId;
    final DateTime? lastSync = widget.services.syncEngine.lastSuccessAt;
    final int pendingUpload = widget.services.syncEngine.pendingCount;
    return <Widget>[
      const SizedBox(height: 6),
      const Text(
        '使用记录采集（Android）',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2F4A63)),
      ),
      _kv('采集状态', c.labelZh),
      _kv(
        '当前会话',
        c.currentSessionSeconds > 0 ? '使用中（已持续 ${formatDurationZh(c.currentSessionSeconds)}）' : '无',
      ),
      _kv('待导入记录', '${c.pendingCount} 条'),
      _kv('最近一次导入', lastImport == null ? '尚未导入' : _timeLabel(lastImport)),
      _kv(
        '暂存队列',
        c.journalAvailable
            ? '可用${c.corruptLines > 0 ? '（隔离损坏行 ${c.corruptLines}）' : ''}'
            : '不可用',
      ),
      const SizedBox(height: 6),
      const Text(
        '云端归属',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2F4A63)),
      ),
      // 本地标识与服务端 device_id 是**两个不同的东西**（决策 1），必须分开显示，
      // 否则"本地统计看不到数据"与"云端看不到数据"会被混为一谈。
      _kv('本机设备标识', widget.services.trackingDeviceLocalId),
      _kv(
        '服务端设备 ID',
        serverDeviceId == null
            ? '尚未注册（登录后会注册）'
            : (serverDeviceId.length > 12
                ? '${serverDeviceId.substring(0, 8)}…（${serverDeviceId.substring(serverDeviceId.length - 4)}）'
                : serverDeviceId),
      ),
      _kv('待上传记录', pendingUpload == 0 ? '0 条（已全部上传）' : '$pendingUpload 条'),
      _kv('最近同步成功', lastSync == null ? '尚未成功同步' : _timeLabel(lastSync)),
      if (!c.deviceLocalIdSet)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '原生尚未收到本机设备标识：这段记录导入时会按本机归属补齐',
            style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      if (serverDeviceId == null)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '未登录时本机照常采集，登录后会自动补传（数据不会丢）',
            style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      if (lastError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '最近一次导入失败：$lastError（记录已保留，稍后自动重试）',
            style: const TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
          ),
        ),
    ];
  }

  /// Phase 4C-6A：自动状态联动总开关（需求 §9）。
  ///
  /// 与"使用时长采集"**完全解耦**：关掉它只停止自动换素材，
  /// 前台识别与使用统计继续工作。开关持久化在 `AppSettings`，
  /// 并通过 `syncStateMapping()` 把新配置推给原生（原生也会持久化）。
  Widget _automaticStateControl() {
    final bool enabled = widget.services.settings.settings.overlayAutomaticState;
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('根据当前应用自动切换桌宠状态', style: TextStyle(fontSize: 13)),
      subtitle: Text(
        enabled
            ? '识别到前台应用后，等它稳定约 1.5 秒再切换素材（不闪图）'
            : '已关闭：不再自动换素材；前台识别与使用时长统计不受影响',
        style: const TextStyle(fontSize: 11),
      ),
      value: enabled,
      onChanged: _busy
          ? null
          : (bool value) async {
              await widget.services.settings.setOverlayAutomaticState(value);
              // 立刻把新配置推给原生，不等下一次状态变化。
              await _c.syncStateMapping();
              if (mounted) setState(() {});
            },
    );
  }

  /// 快捷入口：设置 → 悬浮桌宠 → 「编辑状态素材」（需求 §3.2）。
  ///
  /// 只负责**打开**编辑页面；素材网格与预览都在页面里完成 ——
  /// 悬浮窗内不实现任何复杂素材界面（需求 §3.2 末句）。
  Widget _stateMappingShortcut() {
    final LibraryController? library = widget.library;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.tune, size: 20),
      title: const Text('编辑状态素材', style: TextStyle(fontSize: 13)),
      subtitle: Text(
        library == null
            ? '请到「素材库」→ 选择角色 → 状态映射'
            : '为每个状态指定显示哪张图（当前角色：'
                '${_currentCharacterName(library)}）',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: library == null
          ? () => _toastNotice('请到「素材库」→ 选择角色 → 「状态映射」进行编辑')
          : () => _openStateMapping(library),
    );
  }

  /// 当前桌宠角色的显示名（拿不到时给出明确说明，而不是空白）。
  String _currentCharacterName(LibraryController library) {
    final String? activeId = library.activeCharacterId ??
        widget.services.settings.settings.lastCharacterId;
    return library.snapshot?.characterById(activeId)?.displayName ?? '未选择角色';
  }

  Future<void> _openStateMapping(LibraryController library) async {
    final String? activeId = library.activeCharacterId ??
        widget.services.settings.settings.lastCharacterId ??
        library.selectedCharacterId;
    final String? characterId = library.snapshot?.characterById(activeId)?.id ??
        library.selectedCharacterId;
    if (characterId == null) {
      _toastNotice('还没有可选角色：请先在「素材库」导入素材并选择角色');
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => StateAssetMappingPage(
          library: library,
          characterId: characterId,
          overlay: _c,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  void _toastNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 状态联动的只读诊断（需求 §19）。
  ///
  /// **只读**：Flutter 不驱动状态切换，这里只是把原生的判定结果呈现出来。
  /// 不显示任何内部绝对路径（只给素材 ID）。
  List<Widget> _stateDiagnosticRows() {
    final OverlayStateDiagnostics d = _c.stateDiagnostics;
    final String? fallback = d.fallbackLabelZh;
    return <Widget>[
      _kv('当前状态', '${d.stateLabel}（${d.stateId}）'),
      _kv('状态来源', d.sourceLabelZh),
      _kv(
        '自动联动',
        d.linkageLabelZh,
      ),
      // --- Phase 4C-6A：自动联动配置与命中规则（排查"为什么不换图"的第一入口）---
      _kv('自动切换配置', d.automaticStateEnabled ? '开启' : '关闭'),
      _kv('命中规则', d.matchedRuleZh ?? '尚未判定'),
      // --- Phase 4C-6A 真机诊断：状态提交链路的**原生真值** ---
      // 这一块刻意用原生字段名做标签，并且**全部直接来自 Android 原生服务**
      // （`getStateDiagnostics`），Flutter 不做任何推算/改写 —— 真机出问题时
      // 一眼就能判断卡在"分类 → 规则 → 防抖提交"的哪一步。
      ..._nativeTraceRows(),
      if (d.foregroundAppLabel != null) _kv('当前前台应用', d.foregroundAppLabel!),
      if (d.category != null)
        _kv(
          '应用分类',
          '${_categoryLabelZh(d.category!)}'
              '${d.categorySource == 'built-in-rule' ? '' : '（${d.categorySource}）'}',
        ),
      if (d.candidateState != null)
        _kv('候选状态', '${d.candidateState}（已连续 ${d.candidateCount} 次）'),
      _kv('当前状态素材', d.stateAssetId ?? '—'),
      _kv('映射版本', d.mappingRevision <= 0 ? '尚未下发' : 'rev ${d.mappingRevision}'),
      // --- 前台应用识别诊断（真机缺陷 C 的排查入口）---
      _kv('应用识别', d.detectionSourceLabelZh),
      _kv('事件数', d.eventSummaryZh),
      if (d.lastRawPackage != null) _kv('最后一条事件', d.lastRawPackage!),
      if (!d.appOpsAllowed && d.usageAccessGranted)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'AppOps 显示未允许，但实际能读到使用数据（个别 ROM 的口径差异）',
            style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      if (d.detectionReasonZh != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '识别说明：${d.detectionReasonZh}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      _kv('状态说明', d.stateReason),
      if (d.lastChangedAt != null) _kv('最近状态变化', _timeLabel(d.lastChangedAt!)),
      if (d.manualOverride != null)
        _kv('手动覆盖', '${d.manualOverride}（不响应自动切换）'),
      if (d.linkageHintZh != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            d.linkageHintZh!,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      if (fallback != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '素材回退：$fallback',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
      if (d.stateErrorCode != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '状态联动提示：${d.stateErrorCode}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
          ),
        ),
    ];
  }

  /// 状态提交链路的**原生真值**（Phase 4C-6A 真机诊断）。
  ///
  /// 字段名与原生 `OverlayStateBridge.stateDiagnostics()` 的键**逐字对应**，
  /// 因此"设置页看到的就是原生算出来的"。全部为只读展示。
  List<Widget> _nativeTraceRows() {
    final OverlayStateDiagnostics d = _c.stateDiagnostics;
    return <Widget>[
      const Padding(
        padding: EdgeInsets.only(top: 6, bottom: 2),
        child: Text(
          '实时诊断（原生真值）',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      _diagRow('automaticEnabled', d.automaticStateEnabled.toString()),
      _diagRow('collectorRunning', d.collectorRunning.toString()),
      _diagRow('foregroundPackage', d.foregroundPackage ?? '—'),
      _diagRow('foregroundLabel', d.foregroundLabel ?? '—'),
      _diagRow(
        'foregroundCategory',
        d.category == null
            ? '—'
            : '${d.category}${d.categoryDetail == null ? '' : '（${d.categoryDetail}）'}',
      ),
      _diagRow('foregroundDetectionSource', d.detectionSource),
      _diagRow('resolvedTargetState', d.resolvedTargetState ?? '—'),
      _diagRow(
        'candidateState',
        d.candidateState == null
            ? '—'
            : '${d.candidateState}（连续 ${d.candidateCount} 次）',
      ),
      _diagRow(
        'candidateSince',
        d.candidateSince == null
            ? '—'
            : '${_timeLabel(d.candidateSince!)}（已持续 ${d.candidateElapsedMs}ms）',
      ),
      _diagRow('stableState', d.stableStateId),
      _diagRow(
        'matchedRule',
        d.matchedRule == null ? '—' : '${d.matchedRule}（${d.matchedRuleZh}）',
      ),
      _diagRow(
        'mappingRevision',
        d.mappingRevision <= 0 ? '尚未下发' : 'rev ${d.mappingRevision}',
      ),
      _diagRow(
        'mappingReceivedAt',
        d.mappingReceivedAt == null ? '本次运行尚未收到' : _timeLabel(d.mappingReceivedAt!),
      ),
      _diagRow('manualOverrideState', d.manualOverride ?? '—（自动）'),
      // --- Phase 4C-6A.1：显示模式与临时预览（与"编辑映射"/"手动覆盖"三者分开）---
      _diagRow('displayMode', '${d.displayMode}（${d.displayModeZh}）'),
      if (d.isPreviewing)
        _diagRow(
          'previewState',
          '${d.previewState ?? '—'}'
          '${d.previewExpiresAt == null ? '' : '（到期 ${_timeLabel(d.previewExpiresAt!)}）'}',
        ),
      _diagRow(
        'lastTransitionResult',
        d.lastTransitionResult == null
            ? '—'
            : '${d.lastTransitionResult}（${d.transitionResultZh}）',
      ),
      _diagRow('lastTransitionReason', d.lastTransitionReason ?? '—'),
      _diagRow(
        'lastCommittedAt',
        d.lastCommittedAt == null ? '尚未提交过' : _timeLabel(d.lastCommittedAt!),
      ),
    ];
  }

  /// 双窗口探针的**只读**状态卡（设置页 → 诊断模式区）。
  ///
  /// 把 `getDualWindowProbeStatus` 的原生真值分组展示；失败行整行红色高亮。
  /// **只读**：不改诊断模式开关，不启动/停止探针，只展示与复制。
  Widget _dualWindowProbeCard() {
    final DualWindowProbeStatus? probe = _probe;
    if (probe == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('双窗口探针诊断：读取中…', style: TextStyle(fontSize: 11)),
      );
    }
    if (!probe.supported) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          '双窗口探针诊断：当前平台不支持（仅 Android 提供）。',
          style: TextStyle(fontSize: 11),
        ),
      );
    }
    final Set<String> failures = probe.failureKeys;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD6DEE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '双窗口探针诊断（只读）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              // 有效性 chip：无效时红色。
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: probe.probeValid
                      ? const Color(0xFF1B7F3B)
                      : const Color(0xFFB3261E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  probe.probeValid ? '有效' : '无效',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: () => unawaited(_refreshProbe()),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_copyProbe()),
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('复制诊断信息', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          // 本卡中**唯一可写**的项：迁移期临时回退开关（其余诊断均为只读）。
          _dualWindowModeSwitch(),
          _probeGroupOf('窗口计数与附着', <String>[
            'productionWindowAttached',
            'probeWindowCount',
            'expectedProbeWindowCount',
            'totalKnownOverlayWindowCount',
          ], probe, failures),
          _probeGroupOf('窗口添加计数', <String>[
            'petAddCount',
            'menuAddCount',
          ], probe, failures),
          _probeGroupOf('添加时序', <String>[
            'addSequence',
            'petLastAddSequence',
            'menuLastAddSequence',
            'menuWasReaddedAfterPet',
          ], probe, failures),
          _probeGroupOf('菜单窗口', <String>[
            'menuAttached',
            'menuTouchable',
          ], probe, failures),
          _probeGroupOf('矩形与锚点', <String>[
            'currentPetScreenRect',
            'menuAnchorPetRect',
            'currentMenuWindowRect',
            'anchorMatchesCurrentPet',
          ], probe, failures),
          _probeGroupOf('方向与布局', <String>[
            'menuDirection',
            'verticalMode',
            'clampedByScreen',
          ], probe, failures),
          _probeGroupOf('顶层窗口', <String>[
            'currentExpectedTopWindow',
            'actualVisualTop',
          ], probe, failures),
          _probeGroupOf('最近操作', <String>[
            'lastWindowOperation',
            'lastTouchReceiver',
          ], probe, failures),
          _probeGroupOf('设备', <String>[
            'orientation',
            'deviceModel',
            'sdkInt',
          ], probe, failures),
        ],
      ),
    );
  }

  /// 「双窗口实现」回退开关（迁移期临时开关；本卡唯一可写项）。
  ///
  /// 显示 `getDualWindowMode()` 的原生真值；切换时调 `setDualWindowMode` 后
  /// **回读**真值 —— 失败自动回退并给短提示。非 Android / 未读取完成时不渲染开关。
  Widget _dualWindowModeSwitch() {
    final DualWindowModeStatus? mode = _dualWindowMode;
    if (mode == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('双窗口实现开关：读取中…', style: TextStyle(fontSize: 11)),
      );
    }
    if (!mode.supported) {
      // 非 Android：与探针一致，明确显示"不支持"，而不是画一个点了报错的开关。
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('双窗口实现开关：当前平台不支持（仅 Android 提供）。',
            style: TextStyle(fontSize: 11)),
      );
    }
    final bool value = _dualWindowModeDraft ?? mode.dualWindowEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('双窗口实现（关闭则回退单窗口）',
              style: TextStyle(fontSize: 13)),
          subtitle: Text(
            '当前：${value ? '双窗口（新实现）' : '单窗口（回退）'}',
            style: const TextStyle(fontSize: 11),
          ),
          value: value,
          onChanged:
              _busy ? null : (bool v) => unawaited(_toggleDualWindowMode(v)),
        ),
        const Text(
          '提示：切换会重建悬浮窗，桌宠可能短暂消失（仅迁移回归期使用的临时开关）。',
          style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
        ),
      ],
    );
  }

  /// 一组探针诊断行（标题 + 若干 `key=value`）。
  Widget _probeGroupOf(
    String title,
    List<String> keys,
    DualWindowProbeStatus probe,
    Set<String> failures,
  ) {
    final Map<String, Object?> map = probe.toMap();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        for (final String key in keys)
          _probeRow(key, map[key], failure: failures.contains(key)),
      ],
    );
  }

  /// 单行探针诊断：键名 + 取值；失败行整行红字。null → `—`。
  Widget _probeRow(String key, Object? value, {required bool failure}) {
    const Color failColor = Color(0xFFB3261E);
    final TextStyle keyStyle = TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      color: failure ? failColor : Colors.black54,
    );
    final TextStyle valueStyle = TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      color: failure ? failColor : Colors.black87,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 190, child: Text(key, style: keyStyle)),
          Expanded(
            child: Text(
              _probeValueText(value),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
  }

  /// 探针取值的显示文本（null / 空串 → `—`，其余原样）。
  String _probeValueText(Object? value) {
    if (value == null) return '—';
    if (value is String) return value.isEmpty ? '—' : value;
    return value.toString();
  }

  /// 诊断行：标签用原生字段名（较长），因此单独一个更宽的布局。
  Widget _diagRow(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 168,
              child: Text(
                key,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black54,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );

  /// 状态调试器的手动覆盖（需求 §16）。
  ///
  /// 复用项目现有的 11 个 [SystemState]，**不新建第二套状态枚举**；
  /// 覆盖期间原生不响应前台应用自动切换，点「恢复自动」后立即重新检测。
  Widget _manualStateControl() {
    final String? current = _c.stateDiagnostics.manualOverride;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 88,
            child: Text('手动覆盖',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            child: DropdownButton<String?>(
              isDense: true,
              isExpanded: true,
              value: current,
              hint: const Text('自动（跟随前台应用）', style: TextStyle(fontSize: 12)),
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('自动（跟随前台应用）', style: TextStyle(fontSize: 12)),
                ),
                for (final SystemState s in SystemState.values)
                  DropdownMenuItem<String?>(
                    value: s.wireName,
                    child: Text(
                      '${s.descriptionZh}（${s.wireName}）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (String? value) => _run(() => _c.setManualState(value)),
            ),
          ),
        ],
      ),
    );
  }

  String _categoryLabelZh(String category) => switch (category) {
        'development' => '开发',
        'productivity' => '生产力',
        'gaming' => '游戏',
        'social' => '社交',
        'entertainment' => '娱乐',
        'browser' => '浏览器',
        'system' => '系统',
        _ => '其他',
      };

  String _timeLabel(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 88,
              child: Text(key,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
}
