import 'dart:io';

import 'package:flutter/material.dart';

import '../../character/models/emotion_asset.dart';

/// 素材选择器的结果动作。
enum StateAssetPickerAction {
  /// 设为此状态的素材（写显式映射）。
  setAsState,

  /// 设为该角色的默认素材。
  setAsDefault,
}

/// 一次选择的返回值（null = 用户取消，什么都没改）。
class StateAssetPickerResult {
  const StateAssetPickerResult(this.action, this.assetId);

  final StateAssetPickerAction action;
  final String assetId;
}

/// 打开「选择素材」选择器（Phase 4C-6A.1，需求 §5）。
///
/// 硬约束（需求 §5.1）：
/// * **只显示当前角色的素材**（调用方传入的 `assets` 已经是该角色的）；
/// * 只有 `isRenderable`（启用 + 校验通过）的素材可被选中，其余只做展示与说明；
/// * 点击素材**只是查看**，必须再点「设为此状态素材」才写入映射（需求 §5.3）。
Future<StateAssetPickerResult?> showStateAssetPicker(
  BuildContext context, {
  required List<EmotionAsset> assets,
  required String stateLabelZh,
  required String stateWire,
  required String? defaultAssetId,
  required String? currentExplicitAssetId,
  required Future<void> Function(String assetId, bool favorite) onToggleFavorite,
  Future<void> Function(String assetId)? onAssignToStates,
}) {
  return showModalBottomSheet<StateAssetPickerResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext ctx) => _StateAssetPickerSheet(
      assets: assets,
      stateLabelZh: stateLabelZh,
      stateWire: stateWire,
      defaultAssetId: defaultAssetId,
      currentExplicitAssetId: currentExplicitAssetId,
      onToggleFavorite: onToggleFavorite,
      onAssignToStates: onAssignToStates,
    ),
  );
}

class _StateAssetPickerSheet extends StatefulWidget {
  const _StateAssetPickerSheet({
    required this.assets,
    required this.stateLabelZh,
    required this.stateWire,
    required this.defaultAssetId,
    required this.currentExplicitAssetId,
    required this.onToggleFavorite,
    this.onAssignToStates,
  });

  final List<EmotionAsset> assets;
  final String stateLabelZh;
  final String stateWire;
  final String? defaultAssetId;
  final String? currentExplicitAssetId;
  final Future<void> Function(String assetId, bool favorite) onToggleFavorite;

  /// 「分配给状态…」（需求 §6 的"素材详情"入口）；为 null 时不显示该操作。
  final Future<void> Function(String assetId)? onAssignToStates;

  @override
  State<_StateAssetPickerSheet> createState() => _StateAssetPickerSheetState();
}

class _StateAssetPickerSheetState extends State<_StateAssetPickerSheet> {
  /// 本地收藏集合：切换收藏后立刻反映在网格上（数据库写入由外层完成）。
  late final Set<String> _favoriteIds = <String>{
    for (final EmotionAsset a in widget.assets)
      if (a.favorite) a.id,
  };

  @override
  Widget build(BuildContext context) {
    final bool hasRenderable =
        widget.assets.any((EmotionAsset a) => a.isRenderable);
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    final double tileExtent = (172 + (textScale - 1) * 72).clamp(172, 300);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (BuildContext ctx, ScrollController controller) {
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '为「${widget.stateLabelZh}」选择素材',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${widget.stateWire} · 只显示当前角色的素材'
                          '（共 ${widget.assets.length} 张）',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (widget.assets.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '当前角色还没有素材。\n请先在「素材库」导入图片后再回来设置映射。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Colors.black54),
                    ),
                  ),
                ),
              )
            else ...<Widget>[
              if (!hasRenderable)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '当前角色没有可用素材（全部损坏或已禁用），'
                    '这些素材只能查看，不能被选择。',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                  ),
                ),
              Expanded(
                child: GridView.builder(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisExtent: tileExtent,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: widget.assets.length,
                  itemBuilder: (BuildContext ctx, int index) {
                    final EmotionAsset asset = widget.assets[index];
                    return _AssetTile(
                      asset: asset,
                      favorite: _favoriteIds.contains(asset.id),
                      isDefault: widget.defaultAssetId == asset.id,
                      isCurrentMapping:
                          widget.currentExplicitAssetId == asset.id,
                      onTap: () => _openDetail(asset),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _openDetail(EmotionAsset asset) async {
    final StateAssetPickerResult? result = await showDialog<StateAssetPickerResult>(
      context: context,
      builder: (BuildContext ctx) => _AssetDetailDialog(
        asset: asset,
        stateLabelZh: widget.stateLabelZh,
        favorite: _favoriteIds.contains(asset.id),
        isDefault: widget.defaultAssetId == asset.id,
        isCurrentMapping: widget.currentExplicitAssetId == asset.id,
        onToggleFavorite: () async {
          final bool next = !_favoriteIds.contains(asset.id);
          await widget.onToggleFavorite(asset.id, next);
          if (!mounted) return;
          setState(() {
            if (next) {
              _favoriteIds.add(asset.id);
            } else {
              _favoriteIds.remove(asset.id);
            }
          });
        },
        onAssignToStates: widget.onAssignToStates == null
            ? null
            : () => widget.onAssignToStates!(asset.id),
      ),
    );
    if (result == null || !mounted) return;
    Navigator.of(context).pop(result);
  }
}

/// 网格里的一张素材（缩略图 + 名称 + 静态/动态 + 分辨率 + 文件大小 + 收藏/当前标记）。
///
/// 布局刻意用 `Expanded` 包住图片、文本一律 `maxLines + ellipsis`，
/// 因此**任何字体缩放与窄屏都不会溢出**（需求 §13）。
class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.favorite,
    required this.isDefault,
    required this.isCurrentMapping,
    required this.onTap,
  });

  final EmotionAsset asset;
  final bool favorite;
  final bool isDefault;
  final bool isCurrentMapping;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool usable = asset.isRenderable;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isCurrentMapping
                ? const Color(0xFF4A7EBB)
                : const Color(0xFFE3E7EC),
            width: isCurrentMapping ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _AssetThumbnail(asset: asset),
                    ),
                  ),
                  if (asset.isAnimated)
                    const Positioned(
                      left: 4,
                      top: 4,
                      child: _Badge(text: '动态', color: Color(0xFF2F6F4F)),
                    ),
                  if (favorite)
                    const Positioned(
                      right: 4,
                      top: 4,
                      child: Icon(Icons.bookmark,
                          size: 16, color: Color(0xFFE8A33D)),
                    ),
                  if (!usable)
                    const Positioned(
                      left: 4,
                      bottom: 4,
                      child: _Badge(text: '不可用', color: Color(0xFF9A3B3B)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${asset.emotionName} / ${asset.variantName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            Text(
              '${asset.width}×${asset.height} · ${formatBytes(asset.fileSize)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
            if (isCurrentMapping || isDefault)
              Text(
                isCurrentMapping ? '当前映射' : '角色默认',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFF4A7EBB)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 大图预览 + 操作（需求 §5.3 / §5.4）。
///
/// **点击素材不会立刻改映射** —— 必须在这里点「设为此状态素材」才写库。
class _AssetDetailDialog extends StatelessWidget {
  const _AssetDetailDialog({
    required this.asset,
    required this.stateLabelZh,
    required this.favorite,
    required this.isDefault,
    required this.isCurrentMapping,
    required this.onToggleFavorite,
    this.onAssignToStates,
  });

  final EmotionAsset asset;
  final String stateLabelZh;
  final bool favorite;
  final bool isDefault;
  final bool isCurrentMapping;
  final Future<void> Function() onToggleFavorite;
  final Future<void> Function()? onAssignToStates;

  @override
  Widget build(BuildContext context) {
    final bool usable = asset.isRenderable;
    return AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      title: Text(
        '${asset.emotionName} / ${asset.variantName}',
        style: const TextStyle(fontSize: 15),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: 220,
              child: Center(child: _AssetThumbnail(asset: asset, large: true)),
            ),
            const SizedBox(height: 8),
            Text(
              '${asset.isAnimated ? '动态 WebP（${asset.frameCount} 帧）' : '静态图片'}'
              ' · ${asset.width}×${asset.height} · ${formatBytes(asset.fileSize)}',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (asset.validationError != null)
              Text(
                '校验问题：${asset.validationError}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9A3B3B)),
              ),
            if (!usable)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '该素材已禁用或校验未通过，**不会**被使用；'
                  '请先到素材库恢复它，或另选一张。',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8A6D3B)),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ActionChip(
                  avatar: Icon(
                    favorite ? Icons.bookmark : Icons.bookmark_border,
                    size: 16,
                  ),
                  label: Text(
                    favorite ? '取消收藏' : '收藏',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () => onToggleFavorite(),
                ),
                ActionChip(
                  avatar: const Icon(Icons.fullscreen, size: 16),
                  label: const Text('查看原图', style: TextStyle(fontSize: 11)),
                  onPressed: () => _showFullScreen(context),
                ),
                if (onAssignToStates != null)
                  ActionChip(
                    avatar: const Icon(Icons.playlist_add_check, size: 16),
                    label: const Text('分配给状态…', style: TextStyle(fontSize: 11)),
                    onPressed: () => onAssignToStates!(),
                  ),
                if (isCurrentMapping)
                  const Chip(
                    label: Text('已是该状态素材', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
                if (isDefault)
                  const Chip(
                    label: Text('已是角色默认', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: usable
              ? () => Navigator.of(context).pop(
                    StateAssetPickerResult(
                        StateAssetPickerAction.setAsDefault, asset.id),
                  )
              : null,
          child: const Text('设为角色默认'),
        ),
        FilledButton(
          onPressed: usable
              ? () => Navigator.of(context).pop(
                    StateAssetPickerResult(
                        StateAssetPickerAction.setAsState, asset.id),
                  )
              : null,
          child: Text('设为「$stateLabelZh」素材'),
        ),
      ],
    );
  }

  void _showFullScreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(child: _AssetThumbnail(asset: asset, large: true)),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 缩略图：静态图直接显示；动态 WebP 显示首帧并由外层角标标注。
class _AssetThumbnail extends StatelessWidget {
  const _AssetThumbnail({required this.asset, this.large = false});

  final EmotionAsset asset;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final File file = File(asset.filePath);
    return Image.file(
      file,
      fit: large ? BoxFit.contain : BoxFit.cover,
      // 与素材库保持一致：宠物素材是像素风，不做平滑插值。
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
      errorBuilder: (BuildContext ctx, Object error, StackTrace? st) => Container(
        color: const Color(0xFFF0F2F5),
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined,
            size: 20, color: Colors.black38),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 9, color: Colors.white),
      ),
    );
  }
}

/// 文件大小的人类可读格式。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
