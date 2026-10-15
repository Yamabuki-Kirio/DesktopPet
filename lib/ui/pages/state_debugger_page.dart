import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../core/logger.dart';
import '../../diagnostics/perf_sampler.dart';
import '../../state_engine/fallback_chain.dart';
import '../../state_engine/state_debouncer.dart';
import '../../state_engine/state_snapshot.dart';
import '../../state_engine/system_state.dart';
import '../library_controller.dart';
import '../pet/pet_view.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_page.dart';

/// 构造状态调试器的一次手动触发请求。
///
/// 阶段 0 的全部 11 个状态都由调试器手动触发，因此：
/// - `force: true`：绕过优先级与「最短展示时长」，保证 `default` 在 `error`
///   之后也能被触发（验收第 14 项）；
/// - `immediate: true`：**人工验证工具必须立即生效**——非紧急状态不再等待
///   当前动画播完一轮（一轮最长约 6.6 秒），点击后马上开始淡入淡出。
///
/// 注意：这只影响调试器；真实的自动状态切换仍然遵守 `waitForAnimationCycle`
/// 平滑切换规则（见 [StateDebouncer]）。快速切换抑制窗口（400ms）依旧生效，
/// 用于观察「快速切换不闪烁」（验收第 15 项）。
///
/// 单独抽成顶层函数是为了让测试可以断言请求确实携带 `force=true` 与
/// `immediate=true`，而不必构造整个 Widget 树。
@visibleForTesting
StateChangeRequest debuggerStateRequest(
  SystemState state, {
  String? manualAssetId,
}) =>
    StateChangeRequest(
      state: state,
      trigger: StateTrigger.debugger,
      reason: '状态调试器手动触发 ${state.wireName}',
      force: true,
      immediate: true,
      manualAssetId: state == SystemState.manual ? manualAssetId : null,
    );

/// 状态调试器（需求 §7「状态调试器」，定位为**开发工具页**）。
///
/// 本轮**只改外观与分组**：状态机、事件注入、自动联动逻辑与触发参数一律未动。
///
/// 布局：宽屏两栏（左：手动触发工具；右：当前状态 / 素材 / 回退链 / 防抖参数），
/// 窄屏自动堆叠；诊断文本使用等宽字体区域。
class StateDebuggerPage extends StatefulWidget {
  const StateDebuggerPage({
    super.key,
    required this.services,
    required this.library,
  });

  final AppServices services;
  final LibraryController library;

  @override
  State<StateDebuggerPage> createState() => _StateDebuggerPageState();
}

class _StateDebuggerPageState extends State<StateDebuggerPage> {
  String? _manualAssetId;

  @override
  void dispose() {
    widget.services.perfSampler.removeListener(_onPerf);
    super.dispose();
  }

  void _onPerf() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppServices s = widget.services;
    return ValueListenableBuilder<StateSnapshot>(
      valueListenable: s.stateEngineSnapshot,
      builder: (BuildContext context, StateSnapshot snap, Widget? _) {
        return PetLifePage(
          title: '状态调试器',
          subtitle: '手动触发全部 11 个状态；不改变状态机与自动联动规则',
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double scale = MediaQuery.textScalerOf(context).scale(1.0);
              // 窄窗口 / 大字体下改为单栏堆叠，避免两栏被压到溢出。
              final bool twoColumns = constraints.maxWidth >= 860 * scale;
              if (!twoColumns) {
                return ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    _triggerSection(s),
                    const SizedBox(height: PetLifeSpacing.groupGap),
                    _statusSection(s, snap),
                    const SizedBox(height: PetLifeSpacing.groupGap),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: <Widget>[
                        _triggerSection(s),
                        const SizedBox(height: PetLifeSpacing.groupGap),
                      ],
                    ),
                  ),
                  const SizedBox(width: PetLifeSpacing.groupGap),
                  Expanded(
                    flex: 4,
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: <Widget>[
                        _statusSection(s, snap),
                        const SizedBox(height: PetLifeSpacing.groupGap),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 左：手动触发工具
  // ---------------------------------------------------------------------------

  Widget _triggerSection(AppServices s) {
    final CharacterModel? character = widget.library.selectedCharacter;
    final List<EmotionAsset> assets = widget.library.selectedRenderableAssets;
    final PetLifePalette p = PetLifeTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '手动触发',
          subtitle: '工具卡：强制 + 立即生效，但快速切换抑制窗口（400ms）仍然有效',
        ),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final SystemState state in SystemState.values)
                    _StateTriggerChip(
                      state: state,
                      onTap: () => _trigger(s, state),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _blockLabel('manual 状态：临时锁定指定图片'),
              DropdownButtonFormField<String?>(
                initialValue: _manualAssetId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '选择要锁定的图片（留空则按状态映射解析）',
                ),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(child: Text('不指定（按映射解析）')),
                  for (final EmotionAsset a in assets)
                    DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(
                        '${a.emotionName} / ${a.variantName}'
                        '${a.isAnimated ? ' · 动态${a.frameCount}帧' : ' · 静态'}',
                      ),
                    ),
                ],
                onChanged: (String? v) => setState(() => _manualAssetId = v),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  PetLifePrimaryButton(
                    label: '锁定 manual',
                    icon: Icons.lock_outline,
                    onPressed: character == null
                        ? null
                        : () => s.stateEngine.lockManual(
                              assetId: _manualAssetId,
                              reason: '状态调试器手动锁定',
                            ),
                  ),
                  PetLifeSecondaryButton(
                    label: '解除锁定 / 恢复自动',
                    icon: Icons.lock_open,
                    onPressed: () => s.stateEngine.releaseManual(),
                  ),
                ],
              ),
              if (character == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '尚未在素材库选中角色：请先到「素材库」选择一个角色。',
                    style: TextStyle(
                      fontSize: PetLifeText.captionSmall,
                      color: p.warning,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              _blockLabel('快速切换测试'),
              Text(
                '连续触发 6 个状态，用于观察是否存在明显闪烁。'
                '抑制窗口内被推迟的请求会显示在右侧「最近决策」。',
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              PetLifeSecondaryButton(
                label: '连续切换 6 次（间隔 120ms）',
                icon: Icons.flash_on,
                onPressed: () => _rapidSwitchStress(s),
              ),
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.cardGap),
        const PetLifeSectionTitle(
          title: '实时预览',
          subtitle: '与桌宠窗口同一套渲染，不负责调整原生窗口尺寸',
          marker: false,
        ),
        PetLifeCard(child: _PetPreview(services: s)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 右：当前状态详情
  // ---------------------------------------------------------------------------

  Widget _statusSection(AppServices s, StateSnapshot snap) {
    final EmotionAsset? asset = snap.currentAsset;
    final PetLifePalette p = PetLifeTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '当前状态',
          subtitle: '状态 / 来源 / 规则 / 稳定时间',
        ),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  PetLifeTag(
                    label: snap.state.wireName,
                    icon: Icons.flag_outlined,
                    selected: true,
                  ),
                  PetLifeTag(
                    label: '${snap.state.descriptionZh} · P${snap.state.priority}',
                    dense: true,
                  ),
                  PetLifeTag(label: '来源 ${snap.trigger.label}', dense: true),
                ],
              ),
              const SizedBox(height: 12),
              _kv('触发原因', snap.reason),
              _kv('状态开始时间', _fmt(snap.startedAt)),
              _kv('已持续', '${DateTime.now().difference(snap.startedAt).inSeconds} 秒'),
              _kv(
                '下次允许切换',
                snap.nextAllowedChangeAt == null
                    ? '无自动切换计划（manual 需用户解除）'
                    : '${_fmt(snap.nextAllowedChangeAt!)}（还需 '
                        '${_remaining(snap.nextAllowedChangeAt!)}）',
              ),
              if (snap.pendingState != null)
                _kv(
                  '等待中的状态',
                  '${snap.pendingState!.wireName}（自 ${_fmt(snap.pendingSince!)} 起等待）',
                ),
              const SizedBox(height: 10),
              _blockLabel('最近决策（等宽）'),
              _monoBlock(
                snap.lastDecisionNote.isEmpty ? '（暂无决策记录）' : snap.lastDecisionNote,
              ),
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.cardGap),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _blockLabel('当前素材'),
              _kv('当前角色', snap.currentCharacter?.displayName ?? '—'),
              _kv('当前情绪', asset?.emotionName ?? '（无）'),
              _kv('当前变体', asset?.variantName ?? '—'),
              _kv('素材文件', asset == null ? '（内置占位图）' : asset.filePath),
              _kv('静态 / 动态', asset == null ? '—' : (asset.isAnimated ? '动态' : '静态')),
              _kv('帧数', asset?.frameCount.toString() ?? '—'),
              _kv('图片尺寸', asset == null ? '—' : '${asset.width}×${asset.height}'),
              _kv('透明通道', asset == null ? '—' : (asset.hasAlpha ? '有' : '无')),
              _kv(
                '一轮动画时长',
                asset == null || asset.animationDurationMs == 0
                    ? '—'
                    : '${asset.animationDurationMs} ms',
              ),
              _kv(
                '文件哈希(前16位)',
                asset == null || asset.fileHash.length < 16
                    ? (asset?.fileHash ?? '—')
                    : asset.fileHash.substring(0, 16),
              ),
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.cardGap),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _blockLabel('回退链'),
              _kv(
                '命中级别',
                '${snap.fallbackLevel.label}'
                '（第 ${FallbackLevel.values.indexOf(snap.fallbackLevel) + 1} 级'
                ' / 共 ${FallbackLevel.values.length} 级）',
              ),
              _kv('回退原因', snap.resolution.reason),
              const SizedBox(height: 8),
              for (final FallbackLevel level in FallbackLevel.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        level == snap.fallbackLevel
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 14,
                        color: level == snap.fallbackLevel ? p.accent : p.textDisabled,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${FallbackLevel.values.indexOf(level) + 1}. ${level.label}',
                          style: TextStyle(
                            fontSize: PetLifeText.caption,
                            fontWeight: level == snap.fallbackLevel
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: level == snap.fallbackLevel
                                ? p.onAccentSoft
                                : p.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.cardGap),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _blockLabel('防抖参数'),
              _kv('前台应用稳定要求', '10 秒'),
              _kv('普通状态最短展示', '15 秒'),
              _kv('happy 最短展示', '10 秒'),
              _kv('tired 最短展示', '5 分钟'),
              _kv('快速切换抑制窗口', '400 毫秒'),
              _kv('等动画一轮的等待上限', '8000 毫秒（超时强制切换）'),
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.cardGap),
        PetLifeCard(child: PerfMiniPanel(sampler: s.perfSampler)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 动作（逻辑未改动）
  // ---------------------------------------------------------------------------

  Future<void> _trigger(AppServices s, SystemState state) async {
    Loggers.state.info('调试器触发状态 ${state.wireName}');
    await s.stateEngine.requestState(
      debuggerStateRequest(state, manualAssetId: _manualAssetId),
    );
  }

  Future<void> _rapidSwitchStress(AppServices s) async {
    const List<SystemState> seq = <SystemState>[
      SystemState.focused,
      SystemState.gaming,
      SystemState.happy,
      SystemState.tired,
      SystemState.concerned,
      SystemState.error,
    ];
    Loggers.state.info(
      '开始快速切换压力测试：${seq.map((SystemState e) => e.wireName).join(' -> ')}',
    );
    for (final SystemState state in seq) {
      await _trigger(s, state);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  // ---------------------------------------------------------------------------
  // 小组件
  // ---------------------------------------------------------------------------

  Widget _blockLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: PetLifeText.bodySmall,
            fontWeight: FontWeight.w700,
            color: PetLifeTheme.of(context).textPrimary,
          ),
        ),
      );

  /// 等宽诊断文本块（可复制、可滚动）。
  Widget _monoBlock(String text) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 64, maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.muted,
        borderRadius: PetLifeRadii.cardBorder,
        border: Border.all(color: p.border),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              fontFamily: 'Consolas',
              color: p.textPrimary,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) =>
      PetLifeKeyValue(label: k, value: v, selectable: true, labelWidth: 128);

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

  String _remaining(DateTime target) {
    final int ms = target.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return '已可切换';
    return '${(ms / 1000).toStringAsFixed(1)} 秒';
  }
}

/// 一个状态触发按钮（紧急状态用警告底色区分，但不用大面积黄色）。
class _StateTriggerChip extends StatelessWidget {
  const _StateTriggerChip({required this.state, required this.onTap});

  final SystemState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Semantics(
      button: true,
      label: '触发状态 ${state.wireName}',
      child: InkWell(
        borderRadius: PetLifeRadii.buttonBorder,
        onTap: onTap,
        child: Container(
          width: 156,
          constraints: const BoxConstraints(minHeight: PetLifeSpacing.minTouch),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: state.isUrgent
                ? p.danger.withValues(alpha: 0.10)
                : p.muted,
            borderRadius: PetLifeRadii.buttonBorder,
            border: Border.all(
              color: state.isUrgent
                  ? p.danger.withValues(alpha: 0.5)
                  : p.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                state.wireName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: FontWeight.w700,
                  color: state.isUrgent ? p.danger : p.textPrimary,
                ),
              ),
              Text(
                '${state.descriptionZh} · P${state.priority}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  color: p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 控制面板里的桌宠实时预览。
class _PetPreview extends StatelessWidget {
  const _PetPreview({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (BuildContext context, Widget? _) => SizedBox(
        height: 220,
        child: Align(
          alignment: Alignment.centerLeft,
          child: PetView(
            renderer: services.renderer,
            scale: services.settings.settings.scale,
            smoothScaling: services.settings.settings.smoothScaling,
            opacity: services.settings.settings.opacity,
            lockPosition: true,
            // 预览不负责调整原生窗口尺寸。
            manageWindowSize: false,
          ),
        ),
      ),
    );
  }
}

/// 供调试器展示性能采样（诊断页也复用）。
class PerfMiniPanel extends StatelessWidget {
  const PerfMiniPanel({super.key, required this.sampler});

  final PerfSampler sampler;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final PerfReport? report = sampler.buildReport();
    final TextStyle style =
        TextStyle(fontSize: PetLifeText.caption, color: p.textPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '采样 · 运行 ${sampler.duration.inMinutes} 分 '
          '${sampler.duration.inSeconds % 60} 秒 · '
          '${sampler.samples.length} 个采样点',
          style: style.copyWith(fontWeight: FontWeight.w600),
        ),
        if (report != null) ...<Widget>[
          Text(
            '内存 最新 ${report.lastWorkingSetMb.toStringAsFixed(1)} MB · '
            '均值 ${report.avgWorkingSetMb.toStringAsFixed(1)} MB · '
            '峰值 ${report.peakWorkingSetMb.toStringAsFixed(1)} MB',
            style: style,
          ),
          Text(
            'CPU 均值 ${report.avgCpuOneCore.toStringAsFixed(2)}%（单核）· '
            '峰值 ${report.peakCpuOneCore.toStringAsFixed(2)}%',
            style: style,
          ),
          Text(
            '句柄数净变化 ${report.handleGrowth >= 0 ? '+' : ''}${report.handleGrowth}',
            style: style,
          ),
          if (report.memoryKeepsGrowing)
            Text(
              '⚠ 内存呈持续增长趋势，建议排查',
              style: style.copyWith(color: p.danger, fontWeight: FontWeight.w600),
            ),
        ] else
          Text(
            '尚无采样数据（可在「诊断」页开始采样）。',
            style: style.copyWith(color: p.textSecondary),
          ),
      ],
    );
  }
}
