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

/// 状态调试器（需求 9.4）。
///
/// 阶段 0 不接入真实应用统计，因此**全部 11 个系统状态都由这里手动触发**。
/// 触发使用 `force: true`（绕过优先级与最短展示时长，保证 11 个状态都能被触发）
/// 与 `immediate: true`（所有手动触发立即生效，不等待当前动画播完一轮）；
/// 同时快速切换抑制仍然生效，
/// 用于验证「快速切换不闪烁」（验收第 15 项）。
class StateDebuggerPage extends StatefulWidget {
  const StateDebuggerPage({super.key, required this.services, required this.library});

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
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: 3, child: _buildTriggerPanel(s)),
            const VerticalDivider(width: 1),
            Expanded(flex: 4, child: _buildStatusPanel(s, snap)),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 左：手动触发
  // ---------------------------------------------------------------------------

  Widget _buildTriggerPanel(AppServices s) {
    final CharacterModel? character = widget.library.selectedCharacter;
    final List<EmotionAsset> assets = widget.library.selectedRenderableAssets;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('手动触发系统状态', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 4),
          const Text(
            '阶段 0 未接入前台应用统计，所有状态在此手动触发。\n'
            '触发使用强制 + 立即生效模式，点击后马上开始切换（不等当前动画播完一轮），'
            '但快速切换抑制窗口仍然生效，可用于观察「快速切换不闪烁」。',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final SystemState state in SystemState.values)
                SizedBox(
                  width: 158,
                  child: FilledButton.tonal(
                    onPressed: () => _trigger(s, state),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      backgroundColor: state.isUrgent
                          ? const Color(0xFFFFE9E6)
                          : const Color(0xFFE8F0F9),
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(state.wireName,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        Text('${state.descriptionZh} · P${state.priority}',
                            style: const TextStyle(fontSize: 10, color: Colors.black54)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const Text('manual 状态：临时锁定指定图片', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _manualAssetId,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
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
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            onChanged: (String? v) => setState(() => _manualAssetId = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FilledButton.icon(
                onPressed: character == null
                    ? null
                    : () => s.stateEngine.lockManual(
                          assetId: _manualAssetId,
                          reason: '状态调试器手动锁定',
                        ),
                icon: const Icon(Icons.lock_outline, size: 16),
                label: const Text('锁定 manual'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => s.stateEngine.releaseManual(),
                icon: const Icon(Icons.lock_open, size: 16),
                label: const Text('解除锁定 / 恢复自动'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const Text('快速切换测试', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            '连续触发 6 个状态，用于观察是否存在明显闪烁。抑制窗口内被推迟的请求会显示在右侧「最近决策」。',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _rapidSwitchStress(s),
            icon: const Icon(Icons.flash_on, size: 16),
            label: const Text('连续切换 6 次（间隔 120ms）'),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const Text('实时预览', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _PetPreview(services: s),
        ],
      ),
    );
  }

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
    Loggers.state.info('开始快速切换压力测试：${seq.map((SystemState e) => e.wireName).join(' -> ')}');
    for (final SystemState state in seq) {
      await _trigger(s, state);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  // ---------------------------------------------------------------------------
  // 右：当前状态详情
  // ---------------------------------------------------------------------------

  Widget _buildStatusPanel(AppServices s, StateSnapshot snap) {
    final EmotionAsset? asset = snap.currentAsset;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('当前状态', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          _kv('当前系统状态', '${snap.state.wireName}（${snap.state.descriptionZh}，优先级 ${snap.state.priority}）'),
          _kv('触发原因', snap.reason),
          _kv('触发来源', snap.trigger.label),
          _kv('上次决策', snap.lastDecisionNote.isEmpty ? '—' : snap.lastDecisionNote),
          _kv('状态开始时间', _fmt(snap.startedAt)),
          _kv(
            '已持续',
            '${DateTime.now().difference(snap.startedAt).inSeconds} 秒',
          ),
          _kv(
            '下次允许切换',
            snap.nextAllowedChangeAt == null
                ? '无自动切换计划（manual 需用户解除）'
                : '${_fmt(snap.nextAllowedChangeAt!)}（还需 '
                    '${_remaining(snap.nextAllowedChangeAt!)}）',
          ),
          if (snap.pendingState != null)
            _kv('等待中的状态', '${snap.pendingState!.wireName}（自 ${_fmt(snap.pendingSince!)} 起等待）'),
          const Divider(height: 24),
          const Text('当前素材', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          _kv('当前角色', snap.currentCharacter?.displayName ?? '—'),
          _kv('当前情绪', asset?.emotionName ?? '（无）'),
          _kv('当前变体', asset?.variantName ?? '—'),
          _kv('素材文件', asset == null ? '（内置占位图）' : asset.filePath),
          _kv('静态 / 动态', asset == null ? '—' : (asset.isAnimated ? '动态' : '静态')),
          _kv('帧数', asset?.frameCount.toString() ?? '—'),
          _kv('图片尺寸', asset == null ? '—' : '${asset.width}×${asset.height}'),
          _kv('透明通道', asset == null ? '—' : (asset.hasAlpha ? '有' : '无')),
          _kv('一轮动画时长', asset == null || asset.animationDurationMs == 0
              ? '—'
              : '${asset.animationDurationMs} ms'),
          _kv('文件哈希(前16位)', asset == null ? '—' : asset.fileHash.substring(0, 16)),
          const Divider(height: 24),
          const Text('回退链', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          _kv('命中级别', '${snap.fallbackLevel.label}'
              '（第 ${FallbackLevel.values.indexOf(snap.fallbackLevel) + 1} 级'
              ' / 共 ${FallbackLevel.values.length} 级）'),
          _kv('回退原因', snap.resolution.reason),
          const SizedBox(height: 6),
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
                    color: level == snap.fallbackLevel
                        ? const Color(0xFF4A7EBB)
                        : Colors.black26,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${FallbackLevel.values.indexOf(level) + 1}. ${level.label}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: level == snap.fallbackLevel
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          const Text('防抖参数', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          _kv('前台应用稳定要求', '10 秒'),
          _kv('普通状态最短展示', '15 秒'),
          _kv('happy 最短展示', '10 秒'),
          _kv('tired 最短展示', '5 分钟'),
          _kv('快速切换抑制窗口', '400 毫秒'),
          _kv('等动画一轮的等待上限', '8000 毫秒（超时强制切换）'),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 148,
              child: Text(k, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: SelectableText(v, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

  String _remaining(DateTime target) {
    final int ms = target.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return '已可切换';
    return '${(ms / 1000).toStringAsFixed(1)} 秒';
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
    final PerfReport? report = sampler.buildReport();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '运行 ${sampler.duration.inMinutes} 分 ${sampler.duration.inSeconds % 60} 秒 · '
              '${sampler.samples.length} 个采样点',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (report != null) ...<Widget>[
              Text('内存 最新 ${report.lastWorkingSetMb.toStringAsFixed(1)} MB · '
                  '均值 ${report.avgWorkingSetMb.toStringAsFixed(1)} MB · '
                  '峰值 ${report.peakWorkingSetMb.toStringAsFixed(1)} MB',
                  style: const TextStyle(fontSize: 12)),
              Text('CPU 均值 ${report.avgCpuOneCore.toStringAsFixed(2)}%（单核）· '
                  '峰值 ${report.peakCpuOneCore.toStringAsFixed(2)}%',
                  style: const TextStyle(fontSize: 12)),
              Text('句柄数净变化 ${report.handleGrowth >= 0 ? '+' : ''}${report.handleGrowth}',
                  style: const TextStyle(fontSize: 12)),
              if (report.memoryKeepsGrowing)
                const Text('⚠ 内存呈持续增长趋势，建议排查',
                    style: TextStyle(fontSize: 12, color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
