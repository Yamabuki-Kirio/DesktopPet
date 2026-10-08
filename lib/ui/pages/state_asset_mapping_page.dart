import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../character/character_repository.dart';
import '../../character/models/character_model.dart';
import '../../character/models/character_pack.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/models/state_mapping.dart';
import '../../core/logger.dart';
import '../../platform/overlay_pet.dart';
import '../../settings/settings_controller.dart';
import '../../state_engine/fallback_chain.dart';
import '../../state_engine/system_state.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../widgets/state_asset_picker.dart';

/// 状态 → 素材映射编辑器（Phase 4C-6A.1）。
///
/// 入口（需求 §3）：
/// * **素材库** → 选择作品包/角色 → 「状态映射」；
/// * **设置** → 「Android 悬浮桌宠」卡片 → 「编辑状态素材」；
/// * 轮盘菜单（后续阶段）只需打开本页，**不在悬浮窗里实现素材网格**。
///
/// 与既有的 `StateMappingPage`（Windows 桌面「候选 + 权重 + 情绪绑定」编辑器）
/// 的关系：**并存**。本页是"一个状态一张图"的简化口径（需求 §4/§7），
/// 旧页保留多候选与权重能力，两者写同一张 `state_mappings` 表。
class StateAssetMappingPage extends StatefulWidget {
  const StateAssetMappingPage({
    super.key,
    required this.library,
    required this.characterId,
    this.overlay,
    this.onChanged,
  });

  /// 素材库控制器：本页的**唯一**数据入口（读快照 + 写映射 + 触发重新发布）。
  ///
  /// 刻意不依赖 `AppServices`：页面只需要"角色 / 素材 / 映射 / 自动开关"，
  /// 依赖面越小，越容易被 Widget 测试覆盖。
  final LibraryController library;

  final String characterId;

  /// Android 悬浮桌宠协调器；非 Android 为 null（此时预览按钮会给出说明）。
  final OverlayPetController? overlay;

  /// 保存成功后的回调（素材库入口用它刷新自身列表）。
  final VoidCallback? onChanged;

  @override
  State<StateAssetMappingPage> createState() => _StateAssetMappingPageState();
}

class _StateAssetMappingPageState extends State<StateAssetMappingPage> {
  /// §4.2 固定展示顺序：先 6 个常用状态，其余按优先级降序。
  static const List<SystemState> _preferredOrder = <SystemState>[
    SystemState.defaultState,
    SystemState.focused,
    SystemState.social,
    SystemState.gaming,
    SystemState.entertained,
    SystemState.away,
  ];

  bool _busy = false;

  LibraryController get _library => widget.library;

  @override
  void initState() {
    super.initState();
    _library.addListener(_onChanged);
  }

  @override
  void dispose() {
    _library.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final CharacterModel? character = _library.snapshot?.characterById(widget.characterId);
    if (character == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('状态素材映射')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '角色不存在（可能已被删除）。请返回素材库重新选择角色。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final List<EmotionAsset> allAssets = _library.assetsFor(character.id);
    final List<EmotionAsset> renderable = allAssets
        .where((EmotionAsset a) => a.isRenderable)
        .toList(growable: false);
    final Map<SystemState, List<StateMapping>> grouped =
        _library.snapshot?.mappingsOf(character.id) ?? <SystemState, List<StateMapping>>{};

    final List<_StateRow> rows = <_StateRow>[
      for (final SystemState s in _orderedStates())
        _buildRow(character, s, allAssets, renderable, grouped[s] ?? const <StateMapping>[]),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('状态素材映射'),
        actions: <Widget>[
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          _header(character, allAssets, renderable),
          const SizedBox(height: 8),
          _previewBanner(),
          LayoutBuilder(
            builder: (BuildContext ctx, BoxConstraints constraints) {
              // §13：窄屏单列、宽屏双列；卡片高度由内容决定，**不使用固定高度**，
              // 因此字体放大 / 横屏 / 分屏都不会溢出。
              final int columns = constraints.maxWidth >= 720 ? 2 : 1;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < rows.length; i += columns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          for (int c = 0; c < columns; c++) ...<Widget>[
                            if (c > 0) const SizedBox(width: 8),
                            Expanded(
                              child: i + c < rows.length
                                  ? _stateCard(character, rows[i + c])
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<SystemState> _orderedStates() {
    final List<SystemState> rest = SystemState.values
        .where((SystemState s) => !_preferredOrder.contains(s))
        .toList(growable: true)
      ..sort((SystemState a, SystemState b) => b.priority.compareTo(a.priority));
    return <SystemState>[..._preferredOrder, ...rest];
  }

  _StateRow _buildRow(
    CharacterModel character,
    SystemState state,
    List<EmotionAsset> allAssets,
    List<EmotionAsset> renderable,
    List<StateMapping> mappings,
  ) {
    StateMapping? explicit;
    for (final StateMapping m in mappings) {
      if (m.assetId != null) {
        explicit = m;
        break;
      }
    }
    EmotionAsset? explicitAsset;
    if (explicit != null) {
      for (final EmotionAsset a in allAssets) {
        if (a.id == explicit.assetId) {
          explicitAsset = a;
          break;
        }
      }
    }
    // 回退链用固定种子：同一份库内容每次得到同一结果，界面上不会"看一次变一次"。
    final AssetResolution resolution = FallbackChain(random: math.Random(0))
        .resolve(
      state: state,
      renderableAssets: renderable,
      mappingsForState: mappings,
      characterDefaultAssetId: character.defaultAssetId,
    );
    final bool missingFile = explicitAsset != null &&
        explicitAsset.isRenderable &&
        !File(explicitAsset.filePath).existsSync();
    return _StateRow(
      state: state,
      mappings: mappings,
      explicit: explicit,
      explicitAsset: explicitAsset,
      resolution: resolution,
      missingFile: missingFile,
    );
  }

  // ---------------------------------------------------------------------------
  // 顶部：当前上下文与诊断（需求 §4 / §15）
  // ---------------------------------------------------------------------------

  Widget _header(
    CharacterModel character,
    List<EmotionAsset> allAssets,
    List<EmotionAsset> renderable,
  ) {
    String packName = '—';
    for (final CharacterPack p in _library.snapshot?.packs ?? const <CharacterPack>[]) {
      if (p.id == character.packId) {
        packName = p.name;
        break;
      }
    }
    final OverlayPetController? overlay = widget.overlay;
    final OverlayStateDiagnostics? d = overlay?.stateDiagnostics;

    String assetLabel(String? assetId, String fallback) {
      if (assetId == null) return fallback;
      for (final EmotionAsset a in allAssets) {
        if (a.id == assetId) return '${a.emotionName} / ${a.variantName}';
      }
      return '$assetId（已不在库中）';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _kv('当前作品包', packName),
            _kv('当前角色', '${character.displayName}（${character.internalName}）'),
            _kv('可用素材', '${renderable.length} / ${allAssets.length} 张可用'),
            const Divider(height: 16),
            _automaticSwitch(overlay),
            const Divider(height: 16),
            // --- 诊断（需求 §15）---
            _kv('当前稳定状态',
                d == null ? '—（非 Android）' : '${d.stateLabel}（${d.stateId}）'),
            _kv('当前显示模式', d?.displayModeZh ?? '—'),
            _kv('当前实际素材', assetLabel(d?.stateAssetId, '—')),
            _kv(
              '素材来源',
              d == null
                  ? '—'
                  : '${d.sourceLabelZh}'
                      '${d.fallbackLevel <= 1 ? '' : ' · 回退第 ${d.fallbackLevel} 级'}',
            ),
            _kv('命中的状态映射', d?.matchedRuleZh ?? '—'),
            _kv(
              'mappingRevision',
              d == null || d.mappingRevision <= 0 ? '—' : 'rev ${d.mappingRevision}',
            ),
            _kv(
              'mappingReceivedAt',
              d?.mappingReceivedAt == null ? '本次运行尚未收到' : _time(d!.mappingReceivedAt!),
            ),
            _kv(
              '最近发布结果',
              overlay == null
                  ? '—（非 Android）'
                  : '${overlay.publishResultZh}'
                      '${overlay.lastPublishError == null ? '' : '：${overlay.lastPublishError}'}',
            ),
          ],
        ),
      ),
    );
  }

  /// 「根据当前应用自动切换桌宠状态」开关（与映射编辑**不是**同一件事）。
  ///
  /// 关掉它只停自动换图，映射照常保存；重新打开后**立即**恢复联动。
  Widget _automaticSwitch(OverlayPetController? overlay) {
    final SettingsController? settings = _library.settings;
    if (settings == null) {
      // 没有设置控制器（测试 / 精简装配）时如实说明，不假装有这个开关。
      return const Text(
        '自动状态联动开关不可用（未注入设置控制器）',
        style: TextStyle(fontSize: 11, color: Colors.black54),
      );
    }
    final bool enabled = settings.settings.overlayAutomaticState;
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('根据当前应用自动切换桌宠状态',
          style: TextStyle(fontSize: 13)),
      subtitle: Text(
        enabled
            ? '开启：状态变化后按本页映射换图'
            : '已关闭：不再自动换图（映射仍然保存并保留）',
        style: const TextStyle(fontSize: 11),
      ),
      value: enabled,
      onChanged: _busy
          ? null
          : (bool value) async {
              await settings.setOverlayAutomaticState(value);
              if (!mounted) return;
              setState(() {});
              // 立刻把新配置推给原生，不等下一次状态变化。
              await overlay?.syncStateMapping();
            },
    );
  }

  Widget _previewBanner() {
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;
    if (d == null || !d.isPreviewing) return const SizedBox.shrink();
    final String label =
        SystemState.fromWire(d.previewState ?? '').descriptionZh;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8D9A8)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.visibility_outlined, size: 18, color: Color(0xFF8A6D3B)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在临时预览「$label」的素材'
              '${d.previewExpiresAt == null ? '' : '，约 ${_secondsLeft(d.previewExpiresAt!)} 秒后自动恢复'}'
              '（不影响桌宠状态）',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B5324)),
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await widget.overlay?.clearPreview();
                    }),
            child: const Text('恢复自动', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  int _secondsLeft(DateTime expiresAt) {
    final int ms = expiresAt.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  // ---------------------------------------------------------------------------
  // 状态卡片（需求 §4.1 / §4.3）
  // ---------------------------------------------------------------------------

  Widget _stateCard(CharacterModel character, _StateRow row) {
    final _StatusView status = _statusOf(row);
    final OverlayStateDiagnostics? d = widget.overlay?.stateDiagnostics;
    final bool previewingThis = d != null && d.isPreviewing && d.previewState == row.state.wireName;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: 64, height: 64, child: _thumbnail(row, status)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              row.state.descriptionZh,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              row.state.wireName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black54),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status.assetLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          _chip(status.title, status.color),
                          if (status.assetIsAnimated)
                            _chip('动态 WebP', const Color(0xFF2F6F4F)),
                          if (d?.stateId == row.state.wireName)
                            _chip('当前状态', const Color(0xFF4A7EBB)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (status.hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  status.hint!,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _togglePreview(row, previewingThis),
                  icon: Icon(
                    previewingThis ? Icons.stop_circle_outlined : Icons.visibility_outlined,
                    size: 16,
                  ),
                  label: Text(previewingThis ? '结束预览' : '预览',
                      style: const TextStyle(fontSize: 12)),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pickAsset(character, row),
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: Text(row.explicit == null ? '选择素材' : '更换',
                      style: const TextStyle(fontSize: 12)),
                ),
                if (row.explicit != null)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _clearMapping(row),
                    icon: const Icon(Icons.layers_clear_outlined, size: 16),
                    label: const Text('清除', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(_StateRow row, _StatusView status) {
    final EmotionAsset? asset = row.explicitAsset ?? row.resolution.asset;
    if (asset == null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported_outlined,
            size: 22, color: Colors.black38),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(asset.filePath),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
        errorBuilder: (BuildContext ctx, Object e, StackTrace? st) => Container(
          color: const Color(0xFFF0F2F5),
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image_outlined,
              size: 20, color: Colors.black38),
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );

  /// 把一行的实际状态翻译成"用户能读懂 + **不把回退伪装成已映射**"的文案（需求 §4.3）。
  _StatusView _statusOf(_StateRow row) {
    final EmotionAsset? explicitAsset = row.explicitAsset;
    final AssetResolution r = row.resolution;
    final EmotionAsset? resolved = r.asset;

    String nameOf(EmotionAsset? a) =>
        a == null ? '（没有可用素材）' : '${a.emotionName} / ${a.variantName}';

    if (row.explicit != null) {
      if (explicitAsset == null) {
        return _StatusView(
          title: '映射已失效',
          color: const Color(0xFF9A3B3B),
          assetLabel: '原本映射的素材已被删除',
          hint: '已自动回退：${r.level.label} → ${nameOf(resolved)}',
          assetIsAnimated: resolved?.isAnimated ?? false,
        );
      }
      if (!explicitAsset.isRenderable) {
        return _StatusView(
          title: '映射已失效',
          color: const Color(0xFF9A3B3B),
          assetLabel: nameOf(explicitAsset),
          hint: '该素材被禁用或校验未通过；已自动回退：'
              '${r.level.label} → ${nameOf(resolved)}',
          assetIsAnimated: resolved?.isAnimated ?? false,
        );
      }
      if (row.missingFile) {
        return _StatusView(
          title: '文件丢失',
          color: const Color(0xFF9A3B3B),
          assetLabel: nameOf(explicitAsset),
          hint: '文件不在磁盘上；已自动回退：${r.level.label} → ${nameOf(resolved)}',
          assetIsAnimated: resolved?.isAnimated ?? false,
        );
      }
      return _StatusView(
        title: '已映射',
        color: const Color(0xFF2F6F4F),
        assetLabel: nameOf(explicitAsset),
        assetIsAnimated: explicitAsset.isAnimated,
      );
    }

    if (resolved == null) {
      return _StatusView(
        title: '无可用素材',
        color: const Color(0xFF9A3B3B),
        assetLabel: '桌宠将显示内置占位图',
        hint: '请先导入素材，或为这个状态指定一张图。',
        assetIsAnimated: false,
      );
    }

    final String label = nameOf(resolved);
    return switch (r.level) {
      FallbackLevel.stateEmotion => _StatusView(
          title: '按情绪匹配',
          color: const Color(0xFF4A7EBB),
          assetLabel: label,
          hint: '通过"情绪映射"命中（来自导入时生成的映射），不是显式指定的图片。',
          assetIsAnimated: resolved.isAnimated,
        ),
      FallbackLevel.characterFavorite => _StatusView(
          title: '回退 · 收藏素材',
          color: const Color(0xFF8A6D3B),
          assetLabel: label,
          hint: '该状态未设置素材，正在使用角色收藏的素材。',
          assetIsAnimated: resolved.isAnimated,
        ),
      FallbackLevel.characterDefault => _StatusView(
          title: '回退 · 角色默认',
          color: const Color(0xFF8A6D3B),
          assetLabel: label,
          hint: '该状态未设置素材，正在使用角色默认图片。',
          assetIsAnimated: resolved.isAnimated,
        ),
      FallbackLevel.firstValidAsset => _StatusView(
          title: '回退 · 任意可用素材',
          color: const Color(0xFF8A6D3B),
          assetLabel: label,
          hint: '该状态未设置素材，正在使用角色里第一张可用素材。',
          assetIsAnimated: resolved.isAnimated,
        ),
      _ => _StatusView(
          title: '无可用素材',
          color: const Color(0xFF9A3B3B),
          assetLabel: '桌宠将显示内置占位图',
          assetIsAnimated: false,
        ),
    };
  }

  // ---------------------------------------------------------------------------
  // 动作
  // ---------------------------------------------------------------------------

  /// preview / 结束预览（需求 §11 / §12：与手动覆盖、编辑映射**不是**同一件事）。
  Future<void> _togglePreview(_StateRow row, bool previewingThis) async {
    final OverlayPetController? overlay = widget.overlay;
    if (overlay == null) {
      _toast('当前平台不支持系统级悬浮桌宠，无法预览');
      return;
    }
    await _run(() async {
      if (previewingThis) {
        await overlay.clearPreview();
      } else {
        await overlay.previewState(row.state.wireName);
      }
    });
  }

  Future<void> _pickAsset(CharacterModel character, _StateRow row) async {
    final List<EmotionAsset> assets = _library.assetsFor(character.id);
    final StateAssetPickerResult? result = await showStateAssetPicker(
      context,
      assets: assets,
      stateLabelZh: row.state.descriptionZh,
      stateWire: row.state.wireName,
      defaultAssetId: character.defaultAssetId,
      currentExplicitAssetId: row.explicit?.assetId,
      onToggleFavorite: (String assetId, bool favorite) =>
          _library.setAssetFavorite(assetId, favorite),
      onAssignToStates: (String assetId) => showAssignStatesDialog(
        context,
        library: _library,
        characterId: character.id,
        assetId: assetId,
      ),
    );
    if (result == null || !mounted) return;

    switch (result.action) {
      case StateAssetPickerAction.setAsState:
        await _run(() => _library.setStateAssetMapping(
              character.id,
              row.state,
              result.assetId,
            ));
        _toast('已把「${row.state.descriptionZh}」设为该素材');
      case StateAssetPickerAction.setAsDefault:
        await _run(() => _library.setDefaultAsset(character.id, result.assetId));
        _toast('已设为角色默认素材');
    }
    widget.onChanged?.call();
  }

  Future<void> _clearMapping(_StateRow row) async {
    final bool isDefault = row.state == SystemState.defaultState;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('清除「${row.state.descriptionZh}」的素材映射？'),
        content: Text(
          isDefault
              ? '清除后将回到回退链：其它未设置素材的状态可能改用'
                  '**角色收藏素材**或**任意可用素材**，画面可能与现在不同。'
              : '清除后该状态会按回退链自动找图'
                  '（角色默认 → 收藏素材 → 任意可用素材）。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => _library.clearStateAssetMapping(
          widget.characterId,
          row.state,
        ));
    _toast('已清除「${row.state.descriptionZh}」的映射');
    widget.onChanged?.call();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e, st) {
      Loggers.character.warning('状态素材映射操作失败', e, st);
      _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 116,
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

/// 一行（一个状态）解析出来的展示信息。
class _StateRow {
  const _StateRow({
    required this.state,
    required this.mappings,
    required this.explicit,
    required this.explicitAsset,
    required this.resolution,
    required this.missingFile,
  });

  final SystemState state;
  final List<StateMapping> mappings;
  final StateMapping? explicit;
  final EmotionAsset? explicitAsset;
  final AssetResolution resolution;
  final bool missingFile;
}

class _StatusView {
  const _StatusView({
    required this.title,
    required this.color,
    required this.assetLabel,
    required this.assetIsAnimated,
    this.hint,
  });

  final String title;
  final Color color;
  final String assetLabel;
  final bool assetIsAnimated;
  final String? hint;
}

/// 反向分配：把某素材分配给多个状态（需求 §6）。
///
/// * 勾选 → 设为该素材；取消勾选 → **仅**解除它对**本素材**的引用；
/// * 提交前显示变更摘要；整批**一个事务**（实现在仓储层）。
Future<void> showAssignStatesDialog(
  BuildContext context, {
  required LibraryController library,
  required String characterId,
  required String assetId,
}) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _AssignStatesDialog(
      library: library,
      characterId: characterId,
      assetId: assetId,
    ),
  );
}

class _AssignStatesDialog extends StatefulWidget {
  const _AssignStatesDialog({
    required this.library,
    required this.characterId,
    required this.assetId,
  });

  final LibraryController library;
  final String characterId;
  final String assetId;

  @override
  State<_AssignStatesDialog> createState() => _AssignStatesDialogState();
}

class _AssignStatesDialogState extends State<_AssignStatesDialog> {
  /// 打开对话框时的初始勾选状态（该素材已经显式映射到的状态）。
  late final Set<SystemState> _initial = _currentStates();
  late final Set<SystemState> _selected = <SystemState>{..._initial};

  bool _saving = false;

  Set<SystemState> _currentStates() {
    final Set<SystemState> out = <SystemState>{};
    final Map<SystemState, List<StateMapping>> grouped =
        widget.library.snapshot?.mappingsOf(widget.characterId) ??
            <SystemState, List<StateMapping>>{};
    for (final MapEntry<SystemState, List<StateMapping>> e in grouped.entries) {
      if (e.value.any((StateMapping m) => m.assetId == widget.assetId)) {
        out.add(e.key);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final List<StateSystem> ordered = <StateSystem>[
      for (final SystemState s in SystemState.values)
        StateSystem(s, _selected.contains(s)),
    ];
    final List<String> summary = <String>[
      for (final StateSystem entry in ordered)
        if (_selected.contains(entry.state) != _initial.contains(entry.state))
          _selected.contains(entry.state)
              ? '${entry.state.descriptionZh}：${_previousLabel(entry.state)} → 本素材'
              : '${entry.state.descriptionZh}：本素材 → 未设置',
    ];

    return AlertDialog(
      title: const Text('分配给状态'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '勾选后，这些状态的素材会被替换为当前素材；'
                '取消勾选只会解除**当前素材**的引用，其它候选不受影响。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              for (final StateSystem entry in ordered)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: entry.checked,
                  title: Text(
                    '${entry.state.descriptionZh}（${entry.state.wireName}）',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    _previousLabel(entry.state),
                    style: const TextStyle(fontSize: 11),
                  ),
                  onChanged: (bool? v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(entry.state);
                      } else {
                        _selected.remove(entry.state);
                      }
                    });
                  },
                ),
              if (summary.isNotEmpty) ...<Widget>[
                const Divider(),
                const Text('变更摘要',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final String line in summary)
                  Text('• $line', style: const TextStyle(fontSize: 11)),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('（没有变更）',
                      style: TextStyle(fontSize: 11, color: Colors.black54)),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving || summary.isEmpty ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  /// 该状态当前显示的是哪张素材（用于摘要里的"素材 A → 素材 B"）。
  String _previousLabel(SystemState state) {
    final Map<SystemState, List<StateMapping>> grouped =
        widget.library.snapshot?.mappingsOf(widget.characterId) ??
            <SystemState, List<StateMapping>>{};
    final List<StateMapping> rows = grouped[state] ?? const <StateMapping>[];
    for (final StateMapping m in rows) {
      if (m.assetId == null) continue;
      return m.assetId == widget.assetId ? '当前素材' : '已设置其它素材';
    }
    return '未设置';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // 先取好 messenger：pop 之后 context 可能已经失效。
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      final List<StateAssignmentChange> changes = await widget.library
          .assignAssetToStates(widget.characterId, widget.assetId, _selected);
      if (!mounted) return;
      navigator.pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            changes.isEmpty
                ? '没有变化，未做修改'
                : '已更新 ${changes.length} 个状态的素材',
          ),
        ),
      );
    } catch (e, st) {
      Loggers.character.warning('反向分配状态失败', e, st);
      if (!mounted) return;
      setState(() => _saving = false);
      messenger?.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }
}

/// 复选列表用的一行（把 checked 与状态绑定，避免在 build 里查集合）。
class StateSystem {
  const StateSystem(this.state, this.checked);

  final SystemState state;
  final bool checked;
}

/// 时间格式化。
String _time(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}
