import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/models/state_mapping.dart';
import '../../core/ids.dart';
import '../../core/logger.dart';
import '../../state_engine/suggested_emotions.dart';
import '../../state_engine/system_state.dart';
import '../library_controller.dart';

/// 状态映射页面（需求 9.3）。
///
/// 对每一个系统状态，用户可以选择：
/// - 一个情绪（该情绪下后续新增的变体也会自动纳入）
/// - 一张具体图片
/// - 多张候选（按权重随机选择）
class StateMappingPage extends StatefulWidget {
  const StateMappingPage({super.key, required this.services, required this.library});

  final AppServices services;
  final LibraryController library;

  @override
  State<StateMappingPage> createState() => _StateMappingPageState();
}

class _StateMappingPageState extends State<StateMappingPage> {
  Map<SystemState, List<StateMapping>> _mappings = <SystemState, List<StateMapping>>{};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.library.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final String? id = widget.library.selectedCharacterId;
    if (id == null) {
      if (mounted) setState(() => _mappings = <SystemState, List<StateMapping>>{});
      return;
    }
    setState(() => _loading = true);
    try {
      final Map<SystemState, List<StateMapping>> grouped =
          await widget.services.repository.groupedMappings(id);
      if (!mounted) return;
      setState(() {
        _mappings = grouped;
        _loading = false;
      });
    } catch (e, st) {
      Loggers.state.warning('加载状态映射失败', e, st);
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CharacterModel? character = widget.library.selectedCharacter;
    if (character == null) {
      return const Center(child: Text('请先在「素材库」里选择一个角色'));
    }
    final List<EmotionAsset> assets = widget.library.selectedCharacterAssets;
    final List<EmotionAsset> renderable =
        assets.where((EmotionAsset a) => a.isRenderable).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '角色：${character.displayName}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(width: 16),
              if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: renderable.isEmpty ? null : _applySuggested,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('套用建议映射'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _clearAll,
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('清空全部（恢复自动）'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '未配置的状态会按回退链自动找图：'
            '① 目标状态指定图片 → ② 目标状态指定情绪 → ③ 角色默认图片 → ④ 第一个有效素材 → ⑤ 内置占位图',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: <Widget>[
                for (final SystemState state in _orderedStates())
                  _StateCard(
                    state: state,
                    mappings: _mappings[state] ?? const <StateMapping>[],
                    assets: renderable,
                    emotions: widget.library.selectedEmotions,
                    onAddEmotion: (String emotion) => _add(
                      character.id,
                      state,
                      emotionName: emotion,
                    ),
                    onAddAsset: (EmotionAsset a) => _add(
                      character.id,
                      state,
                      assetId: a.id,
                    ),
                    onRemove: (StateMapping m) => _remove(character.id, state, m),
                    onWeight: (StateMapping m, int w) => _setWeight(character.id, state, m, w),
                    onClear: () => _clearState(character.id, state),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<SystemState> _orderedStates() {
    final List<SystemState> states = List<SystemState>.from(SystemState.values);
    // 按优先级从高到低展示，更符合"哪个更强势"的直觉。
    states.sort((SystemState a, SystemState b) => b.priority.compareTo(a.priority));
    return states;
  }

  List<StateMapping> _listFor(SystemState state) => _mappings[state] ?? const <StateMapping>[];

  Future<void> _add(
    String characterId,
    SystemState state, {
    String? emotionName,
    String? assetId,
  }) async {
    final List<StateMapping> current = List<StateMapping>.from(_listFor(state));
    // 去重：同一个情绪/图片不再重复添加。
    final bool exists = current.any((StateMapping m) =>
        (emotionName != null && m.emotionName == emotionName) ||
        (assetId != null && m.assetId == assetId));
    if (exists) {
      _toast('该候选已存在');
      return;
    }
    final DateTime now = DateTime.now();
    current.add(StateMapping(
      id: Ids.stateMappingId(characterId, state.wireName, current.length),
      characterId: characterId,
      systemState: state,
      emotionName: emotionName,
      assetId: assetId,
      weight: 1,
      priority: state.priority,
      createdAt: now,
      updatedAt: now,
    ));
    await widget.library.replaceMappings(characterId, state, current);
    await _reload();
  }

  Future<void> _remove(String characterId, SystemState state, StateMapping mapping) async {
    final List<StateMapping> current = List<StateMapping>.from(_listFor(state))
      ..removeWhere((StateMapping m) => m.id == mapping.id);
    await widget.library.replaceMappings(characterId, state, current);
    await _reload();
  }

  Future<void> _setWeight(
    String characterId,
    SystemState state,
    StateMapping mapping,
    int weight,
  ) async {
    final List<StateMapping> current = List<StateMapping>.from(_listFor(state));
    final int i = current.indexWhere((StateMapping m) => m.id == mapping.id);
    if (i < 0) return;
    current[i] = current[i].copyWith(weight: weight.clamp(1, 100), updatedAt: DateTime.now());
    await widget.library.replaceMappings(characterId, state, current);
    await _reload();
  }

  Future<void> _clearState(String characterId, SystemState state) async {
    await widget.library.clearMappings(characterId, state);
    await _reload();
  }

  Future<void> _clearAll() async {
    final CharacterModel? c = widget.library.selectedCharacter;
    if (c == null) return;
    for (final SystemState s in SystemState.values) {
      await widget.services.repository.clearMappingsForState(c.id, s);
    }
    await _reload();
    await widget.services.stateEngine.refresh();
  }

  /// 按需求「七」给出的建议一次性铺好映射（仅覆盖当前没有配置的状态）。
  Future<void> _applySuggested() async {
    final CharacterModel? c = widget.library.selectedCharacter;
    if (c == null) return;
    final ImportReportSeedResult result = await _seedFor(c);
    _toast('已按建议生成 ${result.count} 条映射（覆盖 ${result.states} 个状态）');
    await _reload();
    await widget.services.stateEngine.refresh();
  }

  Future<ImportReportSeedResult> _seedFor(CharacterModel c) async {
    final List<EmotionAsset> assets =
        widget.library.selectedCharacterAssets.where((EmotionAsset a) => a.isRenderable).toList();
    final Map<String, List<EmotionAsset>> byEmotion = <String, List<EmotionAsset>>{};
    for (final EmotionAsset a in assets) {
      byEmotion.putIfAbsent(a.emotionName.toLowerCase(), () => <EmotionAsset>[]).add(a);
    }

    int count = 0;
    int states = 0;
    for (final MapEntry<SystemState, List<String>> entry in kSuggestedEmotions.entries) {
      if (entry.value.isEmpty) continue;
      final List<StateMapping> picked = <StateMapping>[];
      final DateTime now = DateTime.now();
      for (final String suggestion in entry.value) {
        final List<EmotionAsset>? hit = byEmotion[suggestion.toLowerCase()];
        if (hit == null || hit.isEmpty) continue;
        picked.add(StateMapping(
          id: Ids.stateMappingId(c.id, entry.key.wireName, picked.length),
          characterId: c.id,
          systemState: entry.key,
          emotionName: hit.first.emotionName,
          weight: 1,
          priority: entry.key.priority,
          createdAt: now,
          updatedAt: now,
        ));
      }
      if (picked.isEmpty) continue;
      await widget.services.repository.replaceMappingsForState(c.id, entry.key, picked);
      count += picked.length;
      states += 1;
    }
    return ImportReportSeedResult(count: count, states: states);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class ImportReportSeedResult {
  const ImportReportSeedResult({required this.count, required this.states});

  final int count;
  final int states;
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.state,
    required this.mappings,
    required this.assets,
    required this.emotions,
    required this.onAddEmotion,
    required this.onAddAsset,
    required this.onRemove,
    required this.onWeight,
    required this.onClear,
  });

  final SystemState state;
  final List<StateMapping> mappings;
  final List<EmotionAsset> assets;
  final List<String> emotions;
  final ValueChanged<String> onAddEmotion;
  final ValueChanged<EmotionAsset> onAddAsset;
  final ValueChanged<StateMapping> onRemove;
  final void Function(StateMapping mapping, int weight) onWeight;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: mappings.isNotEmpty,
        leading: _PriorityBadge(priority: state.priority),
        title: Row(
          children: <Widget>[
            Text(state.wireName, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(state.descriptionZh, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(width: 12),
            if (mappings.isEmpty)
              const Chip(
                label: Text('未配置 · 走回退链', style: TextStyle(fontSize: 10)),
                visualDensity: VisualDensity.compact,
                backgroundColor: Color(0xFFF0F2F5),
              )
            else
              Chip(
                label: Text('${mappings.length} 个候选', style: const TextStyle(fontSize: 10)),
                visualDensity: VisualDensity.compact,
                backgroundColor: const Color(0xFFE4EFFA),
              ),
          ],
        ),
        subtitle: Text(
          '最短展示 ${state.minHoldMs < 0 ? '直到用户解除' : '${state.minHoldMs ~/ 1000} 秒'}'
          '${state.isUrgent ? ' · 可打断当前动画' : ''}',
          style: const TextStyle(fontSize: 11),
        ),
        children: <Widget>[
          for (final StateMapping m in mappings)
            ListTile(
              dense: true,
              leading: Icon(
                m.assetId != null ? Icons.image_outlined : Icons.emoji_emotions_outlined,
                size: 18,
              ),
              title: Text(
                m.assetId != null
                    ? '具体图片 · ${_assetLabel(m.assetId!)}'
                    : '情绪 · ${m.emotionName}',
                style: const TextStyle(fontSize: 12),
              ),
              subtitle: Text('权重 ${m.weight} · 优先级 ${m.priority}',
                  style: const TextStyle(fontSize: 10)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '降低权重',
                    iconSize: 16,
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => onWeight(m, m.weight - 1),
                  ),
                  IconButton(
                    tooltip: '提高权重',
                    iconSize: 16,
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => onWeight(m, m.weight + 1),
                  ),
                  IconButton(
                    tooltip: '移除该候选',
                    iconSize: 16,
                    icon: const Icon(Icons.close),
                    onPressed: () => onRemove(m),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                PopupMenuButton<String>(
                  tooltip: '按情绪添加',
                  enabled: emotions.isNotEmpty,
                  onSelected: onAddEmotion,
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                    for (final String e in emotions)
                      PopupMenuItem<String>(value: e, child: Text(e)),
                  ],
                  child: const Chip(
                    avatar: Icon(Icons.add, size: 14),
                    label: Text('按情绪添加', style: TextStyle(fontSize: 11)),
                  ),
                ),
                PopupMenuButton<EmotionAsset>(
                  tooltip: '按具体图片添加',
                  enabled: assets.isNotEmpty,
                  onSelected: onAddAsset,
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<EmotionAsset>>[
                    for (final EmotionAsset a in assets)
                      PopupMenuItem<EmotionAsset>(
                        value: a,
                        child: Text(
                          '${a.emotionName} / ${a.variantName}'
                          '${a.isAnimated ? ' · 动态${a.frameCount}帧' : ' · 静态'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                  child: const Chip(
                    avatar: Icon(Icons.add_photo_alternate_outlined, size: 14),
                    label: Text('按具体图片添加', style: TextStyle(fontSize: 11)),
                  ),
                ),
                if (mappings.isNotEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.restart_alt, size: 14),
                    label: const Text('清空该状态', style: TextStyle(fontSize: 11)),
                    onPressed: onClear,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _assetLabel(String assetId) {
    for (final EmotionAsset a in assets) {
      if (a.id == assetId) return '${a.emotionName} / ${a.variantName}';
    }
    return '<已删除或已禁用>';
  }
}

class _PriorityBadge extends StatelessWidget {
  const _PriorityBadge({required this.priority});

  final int priority;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF4A7EBB).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$priority',
        style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF2F4A63)),
      ),
    );
  }
}
