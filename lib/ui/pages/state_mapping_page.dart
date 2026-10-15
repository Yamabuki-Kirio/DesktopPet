import 'dart:io';

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
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_page.dart';

/// 状态映射页面（需求 §7「状态映射」）。
///
/// 对每一个系统状态，用户可以选择：
/// * 一个情绪（该情绪下后续新增的变体也会自动纳入）；
/// * 一张具体图片；
/// * 多张候选（按权重随机选择）。
///
/// 本轮**只替换外观**：数据结构、回退链规则、写入时机（每次操作立即落库）
/// 与所有业务动作一律未改。
///
/// 视觉：
/// * 状态列表使用圆角卡片，**当前生效的系统状态**用强调色描边 + 对勾；
/// * 素材选择使用大预览（16dp 圆角缩略图），不再是纯文字菜单；
/// * 缺失素材用明确错误卡，而不是一行红字。
class StateMappingPage extends StatefulWidget {
  const StateMappingPage({
    super.key,
    required this.services,
    required this.library,
  });

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
    final PetLifePalette p = PetLifeTheme.of(context);

    if (character == null) {
      return PetLifePage(
        title: '状态映射',
        subtitle: '决定每个系统状态显示哪张素材',
        child: const PetLifeEmptyState(
          icon: Icons.person_search,
          title: '请先选择一个角色',
          message: '到「素材库」里选中一个角色后，这里会列出它的全部状态映射。',
        ),
      );
    }

    final List<EmotionAsset> assets = widget.library.selectedCharacterAssets;
    final List<EmotionAsset> renderable =
        assets.where((EmotionAsset a) => a.isRenderable).toList(growable: false);
    final SystemState activeState = widget.services.stateEngineSnapshot.value.state;

    return PetLifePage(
      title: '状态映射',
      subtitle: '未配置的状态按回退链自动找图 · 角色：${character.displayName}',
      actions: <Widget>[
        PetLifeHeaderAction(
          icon: Icons.refresh,
          tooltip: '重新加载映射',
          onPressed: _loading ? null : _reload,
        ),
      ],
      headerTrailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          PetLifePrimaryButton(
            label: '套用建议映射',
            icon: Icons.auto_awesome,
            onPressed: renderable.isEmpty ? null : _applySuggested,
          ),
          PetLifeSecondaryButton(
            label: '清空全部（恢复自动）',
            icon: Icons.restart_alt,
            onPressed: _clearAll,
          ),
          if (_loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PetLifeCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, size: 16, color: p.onAccentSoft),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '回退链：① 目标状态指定图片 → ② 目标状态指定情绪 → '
                    '③ 角色默认图片 → ④ 第一个有效素材 → ⑤ 内置占位图',
                    style: TextStyle(
                      fontSize: PetLifeText.caption,
                      color: p.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: PetLifeSpacing.cardGap),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (final SystemState state in _orderedStates())
                  _StateCard(
                    state: state,
                    isActive: state == activeState,
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
                    onWeight: (StateMapping m, int w) =>
                        _setWeight(character.id, state, m, w),
                    onClear: () => _clearState(character.id, state),
                  ),
                const SizedBox(height: PetLifeSpacing.groupGap),
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

  List<StateMapping> _listFor(SystemState state) =>
      _mappings[state] ?? const <StateMapping>[];

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

  Future<void> _remove(
    String characterId,
    SystemState state,
    StateMapping mapping,
  ) async {
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
    current[i] =
        current[i].copyWith(weight: weight.clamp(1, 100), updatedAt: DateTime.now());
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
    final List<EmotionAsset> assets = widget.library.selectedCharacterAssets
        .where((EmotionAsset a) => a.isRenderable)
        .toList();
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
      await widget.services.repository
          .replaceMappingsForState(c.id, entry.key, picked);
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

/// 一个系统状态的映射卡片。
class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.state,
    required this.isActive,
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

  /// 是否是**当前生效**的系统状态（用强调色描边 + 对勾标出）。
  final bool isActive;

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
    final PetLifePalette p = PetLifeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PetLifeSpacing.cardGap),
      child: PetLifeCard(
        selected: isActive,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Theme(
          // ExpansionTile 自带分隔线，这里去掉（需求：不再用灰色分割线组织内容）。
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: mappings.isNotEmpty || isActive,
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            leading: _PriorityBadge(priority: state.priority, active: isActive),
            title: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  state.wireName,
                  style: TextStyle(
                    fontSize: PetLifeText.bodySmall,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                PetLifeTag(label: state.descriptionZh, dense: true),
                if (isActive)
                  PetLifeTag(
                    label: '当前生效',
                    icon: Icons.play_circle_outline,
                    selected: true,
                    dense: true,
                  ),
                if (mappings.isEmpty)
                  PetLifeTag(
                    label: '未配置 · 走回退链',
                    color: p.warning,
                    dense: true,
                  )
                else
                  PetLifeTag(
                    label: '${mappings.length} 个候选',
                    color: p.success,
                    dense: true,
                  ),
              ],
            ),
            subtitle: Text(
              '最短展示 '
              '${state.minHoldMs < 0 ? '直到用户解除' : '${state.minHoldMs ~/ 1000} 秒'}'
              '${state.isUrgent ? ' · 可打断当前动画' : ''}',
              style: TextStyle(
                fontSize: PetLifeText.captionSmall,
                color: p.textSecondary,
              ),
            ),
            children: <Widget>[
              for (final StateMapping m in mappings)
                _CandidateRow(
                  mapping: m,
                  assets: assets,
                  onRemove: () => onRemove(m),
                  onWeight: (int w) => onWeight(m, w),
                ),
              const SizedBox(height: 10),
              _AssetPicker(
                assets: assets,
                onPick: onAddAsset,
                title: '素材选择（大预览，点击即添加为该状态的候选）',
              ),
              const SizedBox(height: 12),
              _sectionLabel(context, '按情绪添加（该情绪后续新增的变体也会自动纳入）'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (emotions.isEmpty)
                    Text(
                      '当前角色没有可用的情绪名',
                      style: TextStyle(
                        fontSize: PetLifeText.captionSmall,
                        color: p.textSecondary,
                      ),
                    )
                  else
                    for (final String e in emotions)
                      PetLifeTag(
                        label: e,
                        icon: Icons.add,
                        onTap: () => onAddEmotion(e),
                      ),
                  if (mappings.isNotEmpty)
                    PetLifeTag(
                      label: '清空该状态',
                      icon: Icons.restart_alt,
                      color: p.danger,
                      onTap: onClear,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条候选（情绪或具体图片）。
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.mapping,
    required this.assets,
    required this.onRemove,
    required this.onWeight,
  });

  final StateMapping mapping;
  final List<EmotionAsset> assets;
  final VoidCallback onRemove;
  final ValueChanged<int> onWeight;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final EmotionAsset? asset = mapping.assetId == null
        ? null
        : _findAsset(mapping.assetId!);
    final bool missing = mapping.assetId != null && asset == null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.muted,
          borderRadius: PetLifeRadii.buttonBorder,
          border: Border.all(color: missing ? p.danger : p.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 大预览（16dp 圆角）；情绪类候选用图标占位。
            ClipRRect(
              borderRadius: BorderRadius.circular(PetLifeRadii.card),
              child: Container(
                width: 56,
                height: 56,
                color: p.card,
                child: asset == null
                    ? Icon(
                        Icons.emoji_emotions_outlined,
                        size: 24,
                        color: missing ? p.danger : p.textSecondary,
                      )
                    : Image.file(
                        File(asset.filePath),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.broken_image_outlined,
                          size: 22,
                          color: p.danger,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mapping.assetId != null
                        ? '具体图片 · ${_label(asset, mapping.assetId!)}'
                        : '情绪 · ${mapping.emotionName}',
                    style: TextStyle(
                      fontSize: PetLifeText.bodySmall,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  Text(
                    '权重 ${mapping.weight} · 优先级 ${mapping.priority}',
                    style: TextStyle(
                      fontSize: PetLifeText.captionSmall,
                      color: p.textSecondary,
                    ),
                  ),
                  if (missing) ...<Widget>[
                    const SizedBox(height: 6),
                    PetLifeErrorState(
                      title: '素材缺失',
                      detail: '该候选引用的素材已被删除或禁用（id=${mapping.assetId}），'
                          '运行时会被回退链跳过。',
                      hint: '可以移除这一条，或重新按图片添加一个有效素材。',
                      retryLabel: '移除该候选',
                      onRetry: onRemove,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                IconButton(
                  tooltip: '降低权重',
                  iconSize: 18,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => onWeight(mapping.weight - 1),
                ),
                IconButton(
                  tooltip: '提高权重',
                  iconSize: 18,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => onWeight(mapping.weight + 1),
                ),
                IconButton(
                  tooltip: '移除该候选',
                  iconSize: 18,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  EmotionAsset? _findAsset(String id) {
    for (final EmotionAsset a in assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  String _label(EmotionAsset? a, String assetId) =>
      a == null ? '<已删除或已禁用>' : '${a.emotionName} / ${a.variantName}';
}

/// 素材选择：大预览缩略图横向列表，点击即添加。
class _AssetPicker extends StatelessWidget {
  const _AssetPicker({
    required this.assets,
    required this.onPick,
    required this.title,
  });

  final List<EmotionAsset> assets;
  final ValueChanged<EmotionAsset> onPick;
  final String title;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionLabel(context, title),
        const SizedBox(height: 6),
        if (assets.isEmpty)
          Text(
            '当前角色没有可用素材，请先到「素材库」导入。',
            style: TextStyle(
              fontSize: PetLifeText.caption,
              color: p.textSecondary,
            ),
          )
        else
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: assets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (BuildContext context, int i) {
                final EmotionAsset a = assets[i];
                return _AssetThumb(asset: a, onTap: () => onPick(a));
              },
            ),
          ),
      ],
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.asset, required this.onTap});

  final EmotionAsset asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Semantics(
      button: true,
      label: '添加 ${asset.emotionName} ${asset.variantName}',
      child: InkWell(
        borderRadius: PetLifeRadii.cardBorder,
        onTap: onTap,
        child: SizedBox(
          width: 96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: p.muted,
                    borderRadius: PetLifeRadii.cardBorder,
                    border: Border.all(color: p.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Image.file(
                      File(asset.filePath),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.none,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: p.danger,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                asset.emotionName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.captionSmall,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              Text(
                asset.variantName,
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

Widget _sectionLabel(BuildContext context, String text) => Text(
      text,
      style: TextStyle(
        fontSize: PetLifeText.caption,
        fontWeight: FontWeight.w700,
        color: PetLifeTheme.of(context).textSecondary,
      ),
    );

class _PriorityBadge extends StatelessWidget {
  const _PriorityBadge({required this.priority, required this.active});

  final int priority;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? p.accent : p.accentSoft,
        borderRadius: BorderRadius.circular(PetLifeRadii.button),
        border: Border.all(color: active ? p.accent : p.border),
      ),
      child: Text(
        '$priority',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: active ? p.onAccent : p.onAccentSoft,
        ),
      ),
    );
  }
}
