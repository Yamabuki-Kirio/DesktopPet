import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../asset_import/asset_importer.dart';
import '../../asset_import/import_models.dart';
import '../../character/character_repository.dart';
import '../../character/models/character_model.dart';
import '../../character/models/character_pack.dart';
import '../../character/models/emotion_asset.dart';
import '../../character/models/enums.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../platform/file_import_provider.dart';
import '../../state_engine/system_state.dart';
import '../dialogs/asset_import_form_dialog.dart';
import '../desktop/legacy/legacy_asset_library_page.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_page.dart';
import 'state_asset_mapping_page.dart';

/// 素材库页面（视觉优先布局）。
///
/// 支持：导入单张 / 多张 / 文件夹 / ZIP、切换角色、切换图片、禁用图片、
/// 设为默认图片、删除**应用目录内**的用户素材。
/// 用户原始目录中的文件永远不会被修改或删除（仓库层的路径守卫保证）。
///
/// **本轮只改视觉**：素材解析、ZIP 导入、角色状态映射协议与导入流程一行未动。
/// 页面结构改为：统一操作栏 → 手机顶部筛选 / 宽屏左侧结构树 → 素材大卡片。
class AssetLibraryPage extends StatefulWidget {
  const AssetLibraryPage({
    super.key,
    required this.ownerId,
    required this.importer,
    required this.fileImportProvider,
    required this.library,
    this.onActivated,
    this.overlay,
  });

  final String ownerId;

  /// 导入的**唯一入口**（装配层注入的是 `AssetImportRouter`）。
  final AssetImporter importer;

  /// 文件选择器（两端行为不同：文件夹仅桌面支持）。
  final FileImportProvider fileImportProvider;

  final LibraryController library;

  /// 成功"设为当前桌宠角色"后的回调（移动端据此切回"桌宠"页）。
  final VoidCallback? onActivated;

  /// Android 悬浮桌宠协调器（"当前使用素材"的真值来源 + 状态映射页预览）。
  final OverlayPetController? overlay;

  @override
  State<AssetLibraryPage> createState() => _AssetLibraryPageState();
}

class _AssetLibraryPageState extends State<AssetLibraryPage> {
  /// 宽屏阈值：>= 该宽度才用左右分栏，否则纵向流程 + 顶部筛选。
  static const double _kWideBreakpoint = 720;

  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  bool _busy = false;
  String _status = '';
  ImportReport? _lastReport;

  /// 上一次「导入图片」的选择统计（选择数 / 取得内容数 / 无法读取明细）。
  String? _lastSelectionNote;

  /// 状态（情绪）筛选：null = 全部。纯界面筛选，不改动素材解析与映射协议。
  String? _emotionFilter;

  /// 名称搜索：纯界面筛选。
  String _search = '';

  @override
  void initState() {
    super.initState();
    _pathController.text = _guessAceAttorneyPath() ?? '';
    _searchController.addListener(() {
      if (_search == _searchController.text) return;
      setState(() => _search = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _pathController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 尝试猜测工作区里的 Ace Attorney 素材目录，方便一键导入。
  static String? _guessAceAttorneyPath() {
    try {
      final List<String> candidates = <String>[
        p.join(Directory.current.path, 'Ace Attorney'),
        p.join(Directory.current.path, '..', 'Ace Attorney'),
        p.join(Directory.current.path, '..', '..', 'Ace Attorney'),
      ];
      for (final String c in candidates) {
        if (Directory(c).existsSync()) return p.normalize(p.absolute(c));
      }
    } catch (_) {
      // 忽略。
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // ⚠ Windows 控制面板与本页共用同一个类：桌面主题里没有 PetLifeTheme 扩展时
    // 原样回落到改造前的实现，保证「Windows UI 不受影响」。
    if (PetLifeTheme.maybeOf(context) == null) {
      return LegacyAssetLibraryPage(
        ownerId: widget.ownerId,
        importer: widget.importer,
        fileImportProvider: widget.fileImportProvider,
        library: widget.library,
        onActivated: widget.onActivated,
        overlay: widget.overlay,
      );
    }

    final LibraryController lib = widget.library;
    final LibrarySnapshot? snap = lib.snapshot;
    final bool empty = snap == null || snap.isEmpty;

    return PetLifePage(
      title: '素材库',
      subtitle: empty
          ? '还没有导入任何素材'
          : '${snap.packs.length} 个作品包 · ${snap.characters.length} 个角色 · '
              '${snap.assets.length} 个素材',
      actions: <Widget>[
        if (!empty)
          PetLifeHeaderAction(
            icon: Icons.tune,
            tooltip: '筛选',
            onPressed: () => _openFilterSheet(),
          ),
        PetLifeHeaderAction(
          icon: Icons.add,
          tooltip: '导入素材',
          onPressed: _busy ? null : _openImportSheet,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _importBar(),
          if (_busy) ...<Widget>[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: const LinearProgressIndicator(minHeight: 4),
            ),
            const SizedBox(height: 4),
            Text(
              _status,
              style: TextStyle(
                fontSize: PetLifeText.captionSmall,
                color: PetLifeTheme.of(context).textSecondary,
              ),
            ),
          ],
          if (_lastReport != null) ...<Widget>[
            const SizedBox(height: 10),
            _ImportReportCard(
              report: _lastReport!,
              selectionNote: _lastSelectionNote,
            ),
          ],
          const SizedBox(height: PetLifeSpacing.cardGap),
          Expanded(
            child: empty
                ? PetLifeEmptyState(
                    icon: Icons.photo_library_outlined,
                    title: '还没有任何素材',
                    message: '点下方「导入素材」选择文件夹、图片或 ZIP 素材包。\n'
                        '手机端建议使用 ZIP 素材包；\n'
                        '文件名遵循 角色名_情绪名_序号 规则，会自动识别角色与情绪。',
                    actionLabel: '导入素材',
                    onAction: _busy ? null : _openImportSheet,
                  )
                : LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      final bool wide = constraints.maxWidth >= _kWideBreakpoint;
                      return wide ? _buildWideLayout(lib) : _buildNarrowLayout(lib);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 统一操作栏（导入能力收进一个入口，窄屏不会横向溢出）
  // ---------------------------------------------------------------------------

  Widget _importBar() {
    final PetLifePalette p = PetLifeTheme.of(context);
    final bool folderImport = widget.fileImportProvider.supportsFolderImport;
    final LibraryController lib = widget.library;

    // 「导入能力收进统一操作栏」：这里只放一个明确的入口 + 两个辅助动作，
    // 具体导入方式（文件夹 / 多图 / 单图 / ZIP / 按路径）全部收进底部弹窗。
    // 这样在 360dp 甚至横屏 360dp 高度下都不会横向溢出、也不会吃掉内容区高度。
    return PetLifeCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '导入素材',
                  style: TextStyle(
                    fontSize: PetLifeText.bodySmall,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                Text(
                  folderImport
                      ? '文件夹 / 多张 / 单张 / ZIP / 按路径'
                      : '多张 / 单张 / ZIP 素材包',
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PetLifePrimaryButton(
            label: '导入',
            icon: Icons.file_download_outlined,
            busy: _busy,
            onPressed: _busy ? null : _openImportSheet,
          ),
          PetLifeHeaderAction(
            icon: Icons.refresh,
            tooltip: '刷新素材库',
            onPressed: _busy ? null : () => lib.mutated(),
          ),
          PetLifeHeaderAction(
            icon: Icons.filter_alt_outlined,
            tooltip: '筛选素材',
            onPressed: _busy ? null : _openFilterSheet,
          ),
        ],
      ),
    );
  }

  /// 导入方式选择（底部弹窗）：把全部导入能力收进一个入口。
  Future<void> _openImportSheet() async {
    final bool folderImport = widget.fileImportProvider.supportsFolderImport;
    final _ImportAction? action = await showModalBottomSheet<_ImportAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const PetLifeSectionTitle(
                title: '导入素材',
                subtitle: '素材解析、ZIP 校验与角色状态映射协议均未改动',
                marker: false,
              ),
              if (folderImport)
                _importOption(
                  icon: Icons.folder_open,
                  title: '导入文件夹',
                  subtitle: '扫描整个目录，按文件名自动识别角色与情绪',
                  action: _ImportAction.folder,
                ),
              _importOption(
                icon: Icons.collections,
                title: '导入多张图片',
                subtitle: '一次选择多张，可指定作品包与角色',
                action: _ImportAction.images,
              ),
              _importOption(
                icon: Icons.image,
                title: '导入单张图片',
                subtitle: '导入一张并填写作品包 / 角色 / 情绪',
                action: _ImportAction.singleImage,
              ),
              _importOption(
                icon: Icons.folder_zip,
                title: '导入 ZIP 素材包',
                subtitle: '做安全校验（路径穿越、解压体积、压缩比）后导入',
                action: _ImportAction.zip,
              ),
              if (folderImport) ...<Widget>[
                const SizedBox(height: 6),
                TextField(
                  controller: _pathController,
                  decoration: const InputDecoration(
                    labelText: '文件夹路径',
                    hintText: '粘贴路径后点右侧按钮',
                    prefixIcon: Icon(Icons.link, size: 18),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                PetLifeSecondaryButton(
                  label: '按路径导入',
                  icon: Icons.download_outlined,
                  expand: true,
                  onPressed: _busy || _pathController.text.trim().isEmpty
                      ? null
                      : () {
                          final String dir = _pathController.text.trim();
                          Navigator.pop(context);
                          _runImportFolder(dir);
                        },
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ImportAction.folder:
        await _importFolder();
      case _ImportAction.images:
        await _importImages();
      case _ImportAction.singleImage:
        await _importSingleImage();
      case _ImportAction.zip:
        await _importZip();
    }
  }

  Widget _importOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required _ImportAction action,
  }) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: p.accentSoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 18, color: p.onAccentSoft),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: PetLifeText.bodySmall,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
      ),
      onTap: () => Navigator.pop(context, action),
    );
  }

  /// 手机端筛选（顶部筛选的底部弹窗版本，同时供宽屏使用）。
  Future<void> _openFilterSheet() async {
    final LibrarySnapshot? snap = widget.library.snapshot;
    if (snap == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _FilterSheet(
        library: widget.library,
        emotions: _availableEmotions(),
        emotionFilter: _emotionFilter,
        onEmotionChanged: (String? value) {
          setState(() => _emotionFilter = value);
        },
        search: _search,
        onSearchChanged: (String value) {
          _searchController.text = value;
        },
      ),
    );
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 布局：宽屏分栏 / 窄屏纵向 + 顶部筛选
  // ---------------------------------------------------------------------------

  /// 打开「状态素材映射」编辑器。
  Future<void> _openMappings(String characterId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => StateAssetMappingPage(
          library: widget.library,
          characterId: characterId,
          overlay: widget.overlay,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 反向分配：把某素材分配给多个状态。
  Future<void> _assignStates(EmotionAsset asset) async {
    await showAssignStatesDialog(
      context,
      library: widget.library,
      characterId: asset.characterId,
      assetId: asset.id,
    );
    if (mounted) setState(() {});
  }

  Widget _buildWideLayout(LibraryController lib) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 260,
          child: PetLifeCard(
            child: _PackCharacterTree(
              library: lib,
              onActivate: _activateCharacter,
              onOpenMappings: _openMappings,
            ),
          ),
        ),
        const SizedBox(width: PetLifeSpacing.cardGap),
        Expanded(
          child: _AssetGrid(
            library: lib,
            columns: 4,
            emotions: _availableEmotions(),
            emotionFilter: _emotionFilter,
            search: _search,
            onEmotionFilterChanged: (String? v) => setState(() => _emotionFilter = v),
            onAssignStates: _assignStates,
            overlay: widget.overlay,
          ),
        ),
      ],
    );
  }

  /// 手机纵向流程：操作栏 → 顶部筛选 → 素材两列大卡片。
  Widget _buildNarrowLayout(LibraryController lib) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _topFilters(lib),
        const SizedBox(height: PetLifeSpacing.cardGap),
        Expanded(
          child: _AssetGrid(
            library: lib,
            columns: 2,
            emotions: _availableEmotions(),
            emotionFilter: _emotionFilter,
            search: _search,
            onEmotionFilterChanged: (String? v) => setState(() => _emotionFilter = v),
            onAssignStates: _assignStates,
            overlay: widget.overlay,
          ),
        ),
      ],
    );
  }

  /// 手机端顶部筛选：作品包下拉 + 角色胶囊 + 状态胶囊 + 搜索。
  Widget _topFilters(LibraryController lib) {
    final LibrarySnapshot snap = lib.snapshot!;
    final PetLifePalette p = PetLifeTheme.of(context);
    final List<CharacterModel> chars = lib.selectedPackId == null
        ? const <CharacterModel>[]
        : snap.charactersOf(lib.selectedPackId!);

    return PetLifeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: lib.selectedPackId,
              hint: const Text('选择作品包'),
              items: <DropdownMenuItem<String>>[
                for (final CharacterPack pack in snap.packs)
                  DropdownMenuItem<String>(
                    value: pack.id,
                    child: Text(
                      '${pack.name}（${snap.charactersOf(pack.id).length} 个角色）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (String? id) {
                if (id != null) lib.selectPack(id);
              },
            ),
          ),
          const SizedBox(height: 10),
          if (chars.isEmpty)
            Text(
              '该作品包下还没有角色',
              style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final CharacterModel c in chars)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: PetLifeTag(
                        label: c.displayName,
                        selected: c.id == lib.selectedCharacterId,
                        icon: c.id == lib.activeCharacterId
                            ? Icons.check_circle
                            : Icons.person_outline,
                        onTap: () => lib.selectCharacter(c.id),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              PetLifePrimaryButton(
                label: lib.selectedCharacter != null &&
                        lib.selectedCharacter!.id == lib.activeCharacterId
                    ? '已是当前桌宠角色'
                    : '设为当前桌宠角色',
                icon: lib.selectedCharacter != null &&
                        lib.selectedCharacter!.id == lib.activeCharacterId
                    ? Icons.check_circle
                    : Icons.play_circle_outline,
                onPressed: lib.selectedCharacter == null
                    ? null
                    : () => _activateCharacter(lib.selectedCharacter!.id),
              ),
              PetLifeSecondaryButton(
                label: '状态映射',
                icon: Icons.tune,
                onPressed: lib.selectedCharacter == null
                    ? null
                    : () => _openMappings(lib.selectedCharacter!.id),
              ),
              PetLifeSecondaryButton(
                label: '筛选',
                icon: Icons.filter_alt_outlined,
                onPressed: _openFilterSheet,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: '搜索状态或变体名',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前作品包 / 角色下可用的情绪名（用于筛选胶囊）。
  List<String> _availableEmotions() {
    final String? characterId = widget.library.selectedCharacterId;
    if (characterId == null) return const <String>[];
    return widget.library.snapshot?.emotionsOf(characterId) ?? const <String>[];
  }

  // ---------------------------------------------------------------------------
  // 导入动作（**逻辑与改造前逐字一致**，只改了触发入口）
  // ---------------------------------------------------------------------------

  Future<void> _importFolder() async {
    try {
      // 文件夹导入只有桌面平台支持；Android 上按钮会被隐藏
      // （SAF 目录选择需要原生通道，见 file_import_provider.dart 说明）。
      final String? dir = await widget.fileImportProvider.pickFolderPath();
      if (dir == null || dir.isEmpty) return;
      _pathController.text = dir;
      await _runImportFolder(dir);
    } catch (e, st) {
      _fail('选择文件夹失败', e, st);
    }
  }

  Future<void> _runImportFolder(String dir) async {
    await _run(
      request: FolderImportRequest(ownerId: widget.ownerId, folderPath: dir),
      label: '扫描文件夹',
    );
  }

  Future<void> _importSingleImage() async {
    await _importFiles(multi: false);
  }

  Future<void> _importImages() async {
    await _importFiles(multi: true);
  }

  /// 导入一张或多张图片。
  ///
  /// 硬约束（Phase 4A 真机缺陷二：选了多张只导入一张）：
  /// * 选择与「物化」全部交给 [FileImportProvider] —— 页面不再自己
  ///   `whereType<String>()`，因此 Android SAF 里 `path == null` 的文件不会被丢掉；
  /// * 选择数量 / 取得内容数量 / 成功导入数量 / 跳过原因全部如实展示；
  /// * 导入结束后只清理**本次产生的临时副本**，用户原始文件永不删除。
  Future<void> _importFiles({required bool multi}) async {
    ImagePickResult? picked;
    try {
      picked = await widget.fileImportProvider.pickImages(allowMultiple: multi);
      // 用户取消（一个都没选）。
      if (picked == null || (picked.files.isEmpty && !picked.hasRejected)) return;
      if (!mounted) return;

      if (picked.files.isEmpty) {
        _fail(
          '导入图片失败',
          '所选 ${picked.selectedCount} 张图片都无法读取：\n${_describeRejected(picked.rejected)}',
          null,
        );
        return;
      }

      final AssetImportForm? form = await _askFileImportForm(picked.files.length);
      if (form == null) return;

      await _run(
        request: FileImportRequest(
          ownerId: widget.ownerId,
          files: picked.files,
          packName: form.packName,
          characterName: form.characterName,
          emotionName: form.emotionName,
          setAsCharacterDefault: form.setAsDefault,
        ),
        label: '导入图片',
        selection: picked,
      );
    } catch (e, st) {
      _fail('选择图片失败', e, st);
    } finally {
      await _cleanupTemporaries(picked?.files ?? const <SelectedImportFile>[]);
    }
  }

  /// 只清理本次操作产生的临时副本（以及它专属的空子目录）。
  Future<void> _cleanupTemporaries(List<SelectedImportFile> files) async {
    for (final SelectedImportFile f in files) {
      if (!f.isTemporary) continue;
      try {
        final File file = File(f.localPath);
        if (await file.exists()) await file.delete();
        final Directory dir = file.parent;
        // 每个临时副本都有独立子目录；目录非空时 delete() 会失败，天然安全。
        if (await dir.exists()) {
          try {
            await dir.delete();
          } catch (_) {
            // 忽略：目录非空说明还有别的东西，不该递归删。
          }
        }
        Loggers.importer.info('已清理图片临时副本: ${f.localPath}');
      } catch (e, st) {
        Loggers.importer.warning('清理图片临时副本失败（不影响导入结果）', e, st);
      }
    }
  }

  /// 把「选择 / 取得内容 / 解析 / 新增 / 更新 / 数据库确认 / 失败」拼成一段说明。
  ///
  /// 需求：不允许把"处理过"当成"保存成功" —— 因此新增/更新/数据库确认
  /// 三项必须来自导入报告（它由真实查询得出），而不是调用次数。
  String? _selectionNote(ImagePickResult? selection, ImportReport report) {
    final StringBuffer buffer = StringBuffer();
    if (selection != null) {
      buffer.write('${selection.summary()} · ');
    }
    buffer
      ..write(report.batchSummary())
      ..write(' · 失败 ${report.failedCount + report.skippedCount} 个');
    if (selection != null && selection.rejected.isNotEmpty) {
      buffer
        ..write('\n')
        ..write(_describeRejected(selection.rejected));
    }
    return buffer.toString();
  }

  String _describeRejected(List<RejectedImportFile> rejected) {
    final List<String> lines = <String>[
      for (final RejectedImportFile r in rejected.take(5)) '· ${r.name} —— ${r.reason}',
    ];
    if (rejected.length > 5) {
      lines.add('…（其余 ${rejected.length - 5} 个见日志）');
    }
    return lines.join('\n');
  }

  Future<void> _importZip() async {
    PickedZip? picked;
    try {
      // 两端都走系统的文件选择器（Android 是 SAF）。
      // 选择器负责把结果变成**本进程可读的路径**：Android 若只有字节流，
      // 会先复制到应用私有临时文件（isTemporary=true），由下面 finally 清理。
      picked = await widget.fileImportProvider.pickZip();
      if (picked == null) return;

      final File zipFile = File(picked.path);
      if (!await zipFile.exists()) {
        if (!mounted) return;
        _fail('ZIP 文件不可读', '所选文件不存在或已被移动：${picked.path}', null);
        return;
      }

      final bool confirmed = await _confirm(
        title: '导入 ZIP 素材包',
        message: '将对 ZIP 做安全校验（路径穿越、解压体积、压缩比）。\n'
            '仅图片条目会被导入，ZIP 内的其他文件会被忽略。\n\n${picked.path}',
      );
      if (!confirmed) return;

      await _run(
        request: ZipImportRequest(ownerId: widget.ownerId, zipPath: picked.path),
        label: '解压 ZIP',
      );
    } catch (e, st) {
      _fail('选择 ZIP 失败', e, st);
    } finally {
      // 只清理**我们自己**生成的临时副本；用户原始文件永远不删。
      if (picked != null && picked.isTemporary) {
        try {
          final File copy = File(picked.path);
          if (await copy.exists()) await copy.delete();
          Loggers.importer.info('已清理 ZIP 临时副本: ${picked.path}');
        } catch (e, st) {
          Loggers.importer.warning('清理 ZIP 临时副本失败（不影响导入结果）', e, st);
        }
      }
    }
  }

  Future<void> _run({
    required ImportRequest request,
    required String label,
    ImagePickResult? selection,
  }) async {
    // 弹窗 / 文件选择器都是异步的：返回时页面可能已经被销毁（例如用户切走或退出），
    // 这里必须先确认还挂在树上，否则会 "setState() called after dispose()"。
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = '$label…';
      _lastReport = null;
      _lastSelectionNote = null;
    });
    try {
      final Result<ImportReport> result = await widget.importer.import(
        request,
        onProgress: (int current, int total, String file) {
          if (!mounted) return;
          setState(() => _status = '$label $current/$total · $file');
        },
      );
      if (!mounted) return;
      if (result is Err<ImportReport>) {
        final Failure failure = result.failure;
        final String message =
            failure.detail == null ? failure.message : '${failure.message}（${failure.detail}）';
        setState(() => _status = '导入失败：$message');
        _fail('导入失败', message, null);
        return;
      }
      final ImportReport report = (result as Ok<ImportReport>).value;
      setState(() {
        _lastReport = report;
        _lastSelectionNote = _selectionNote(selection, report);
        _status = report.isConsistent ? report.batchSummary() : report.consistencyIssues.first;
      });
      // 报告与数据库不一致：必须显式报错，绝不能当成功（历史缺陷：报"成功 3 个"、
      // 数据库里只剩 1 个）。
      if (!report.isConsistent) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(report.consistencyIssues.first),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
      // 导入已经成功：刷新失败只能提示"界面没刷新"，绝不能显示成"导入失败"。
      try {
        await widget.library.mutated();
      } catch (e, st) {
        Loggers.importer.warning('导入成功，但素材库刷新失败', e, st);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导入已成功，但界面刷新失败，请重新进入素材库查看：$e'),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
    } catch (e, st) {
      _fail('导入过程异常', e, st);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 真正把某个角色设为当前桌宠角色，并给出明确反馈。
  Future<void> _activateCharacter(String characterId) async {
    final String? error = await widget.library.activateCharacter(characterId);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red.shade700),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已设为当前桌宠角色')),
    );
    widget.onActivated?.call();
  }

  void _fail(String what, Object error, StackTrace? st) {
    Loggers.importer.warning('$what: $error', error, st);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '$what：$error';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what：$error'), backgroundColor: Colors.red.shade700),
    );
  }

  Future<bool> _confirm({required String title, required String message}) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          PetLifePrimaryButton(
            label: '继续',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 单张图片导入时要问作品包 / 角色 / 情绪 / 是否设为默认。
  ///
  /// 控制器与表单状态都在 [AssetImportFormDialog] 自己的 State 里，
  /// 这里只准备两个默认值、然后接收**不可变结果**：取消时是 `null`。
  Future<AssetImportForm?> _askFileImportForm(int count) {
    final LibrarySnapshot? snap = widget.library.snapshot;
    final String defaultPack =
        snap != null && snap.packs.isNotEmpty ? snap.packs.first.name : '我的素材';
    final String initialPack =
        widget.library.selectedPackId == null ? defaultPack : '';
    return AssetImportFormDialog.show(
      context,
      count: count,
      fallbackPackName: defaultPack,
      initialPackName: initialPack,
      initialCharacterName: widget.library.selectedCharacter?.displayName,
    );
  }
}

/// 导入方式（统一操作栏 → 底部弹窗）。
enum _ImportAction { folder, images, singleImage, zip }

/// 导入结果卡片（默认只显示摘要，明细按需展开）。
class _ImportReportCard extends StatefulWidget {
  const _ImportReportCard({required this.report, this.selectionNote});

  final ImportReport report;

  /// 「选择 / 取得内容 / 成功 / 跳过」统计（含无法读取的文件及原因）。
  final String? selectionNote;

  @override
  State<_ImportReportCard> createState() => _ImportReportCardState();
}

class _ImportReportCardState extends State<_ImportReportCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette palette = PetLifeTheme.of(context);
    final ImportReport report = widget.report;
    // 一致性校验失败比"有条目损坏"更严重：报告说的成功并未落到数据库。
    final bool inconsistent = !report.isConsistent;
    final bool hasIssue = report.hasFailures || inconsistent;
    final bool hasDetails = report.failed.isNotEmpty || report.warnings.isNotEmpty;
    final Color tone = inconsistent
        ? palette.danger
        : (hasIssue ? palette.warning : palette.success);

    return PetLifeCard(
      color: tone.withValues(alpha: 0.07),
      borderColor: tone.withValues(alpha: 0.45),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                inconsistent
                    ? Icons.error_outline
                    : (hasIssue ? Icons.warning_amber : Icons.check_circle_outline),
                size: 18,
                color: tone,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  report.summary(),
                  style: TextStyle(
                    fontSize: PetLifeText.bodySmall,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (widget.selectionNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.selectionNote!,
                style: TextStyle(fontSize: PetLifeText.caption, color: palette.textPrimary),
              ),
            ),
          if (inconsistent)
            for (final String issue in report.consistencyIssues)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '⚠ $issue',
                  style: TextStyle(
                    fontSize: PetLifeText.caption,
                    color: palette.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          if (report.characterNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '角色：${report.characterNames.join('、')}'
                '${report.packNames.isEmpty ? '' : ' · 作品包：${report.packNames.join('、')}'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: PetLifeText.caption, color: palette.textSecondary),
              ),
            ),
          if (_expanded) ...<Widget>[
            if (report.seededMappingCount > 0)
              Text(
                '自动生成状态映射 ${report.seededMappingCount} 条（可在「状态映射」里修改）',
                style: TextStyle(fontSize: PetLifeText.caption, color: palette.textPrimary),
              ),
            for (final String w in report.warnings)
              Text(
                '⚠ $w',
                style: TextStyle(fontSize: PetLifeText.caption, color: palette.warning),
              ),
            if (report.failed.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '损坏 / 跳过明细（${report.failed.length} 条）：',
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
              for (final FailedItem f in report.failed.take(20))
                Text(
                  '· ${p.basename(f.path)} — ${f.failure.message}'
                  '${f.failure.detail == null ? '' : '（${f.failure.detail}）'}',
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    color: palette.textSecondary,
                  ),
                ),
              if (report.failed.length > 20)
                Text(
                  '…（更多明细见日志）',
                  style: TextStyle(
                    fontSize: PetLifeText.captionSmall,
                    color: palette.textSecondary,
                  ),
                ),
            ],
          ],
          if (hasDetails)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? '收起'
                      : '详情（告警 ${report.warnings.length} · 失败 ${report.failed.length}）',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "使用中"标记。
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: p.accent,
        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
      ),
      child: Text(
        '使用中',
        style: TextStyle(
          color: p.onAccent,
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 作品包 / 角色树（宽屏左侧）。
class _PackCharacterTree extends StatelessWidget {
  const _PackCharacterTree({
    required this.library,
    required this.onActivate,
    required this.onOpenMappings,
  });

  final LibraryController library;
  final Future<void> Function(String characterId) onActivate;
  final Future<void> Function(String characterId) onOpenMappings;

  @override
  Widget build(BuildContext context) {
    final LibrarySnapshot snap = library.snapshot!;
    final PetLifePalette p = PetLifeTheme.of(context);
    return ListView(
      shrinkWrap: true,
      children: <Widget>[
        Text(
          '作品包',
          style: TextStyle(
            fontSize: PetLifeText.bodySmall,
            fontWeight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        for (final CharacterPack pack in snap.packs)
          ListTile(
            dense: true,
            selected: pack.id == library.selectedPackId,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder, size: 18),
            title: Text(pack.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${snap.charactersOf(pack.id).length} 个角色 · ${pack.sourceType.wireName}',
              style: TextStyle(fontSize: PetLifeText.captionSmall),
            ),
            onTap: () => library.selectPack(pack.id),
            trailing: IconButton(
              tooltip: '删除作品包（不影响原始文件）',
              icon: const Icon(Icons.delete_outline, size: 16),
              onPressed: () async {
                final bool? ok = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext ctx) => AlertDialog(
                    title: const Text('删除作品包'),
                    content: Text(
                      '将从 PetLife 中删除「${pack.name}」及其全部角色与素材索引。\n\n'
                      '⚠ 只删除应用数据目录中的托管副本，'
                      '你的原始素材文件夹不会被修改或删除。',
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      PetLifeDangerButton(
                        label: '删除',
                        onPressed: () => Navigator.pop(ctx, true),
                      ),
                    ],
                  ),
                );
                if (ok ?? false) await library.deletePack(pack.id);
              },
            ),
          ),
        const SizedBox(height: 10),
        Text(
          '角色',
          style: TextStyle(
            fontSize: PetLifeText.bodySmall,
            fontWeight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        if (library.selectedPackId == null)
          Text(
            '请先选择作品包',
            style: TextStyle(fontSize: PetLifeText.caption, color: p.textSecondary),
          )
        else
          for (final CharacterModel c in snap.charactersOf(library.selectedPackId!))
            ListTile(
              dense: true,
              selected: c.id == library.selectedCharacterId,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                c.id == library.selectedCharacterId
                    ? Icons.pets
                    : Icons.person_outline,
                size: 18,
              ),
              title: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(c.displayName, overflow: TextOverflow.ellipsis),
                  ),
                  if (c.id == library.activeCharacterId) ...<Widget>[
                    const SizedBox(width: 6),
                    const _ActiveBadge(compact: true),
                  ],
                ],
              ),
              subtitle: Text(
                '${snap.assetsOf(c.id).length} 个素材 · ${c.internalName}',
                style: TextStyle(fontSize: PetLifeText.captionSmall),
              ),
              onTap: () => library.selectCharacter(c.id),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '状态映射（这个状态显示哪张图）',
                    icon: const Icon(Icons.tune, size: 16),
                    onPressed: () => onOpenMappings(c.id),
                  ),
                  IconButton(
                    tooltip: c.id == library.activeCharacterId
                        ? '当前桌宠角色'
                        : '设为当前桌宠角色',
                    icon: Icon(
                      c.id == library.activeCharacterId
                          ? Icons.check_circle
                          : Icons.play_circle_outline,
                      size: 16,
                      color: c.id == library.activeCharacterId ? p.accent : null,
                    ),
                    onPressed: () => onActivate(c.id),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// 素材网格（两列大卡片 / 宽屏更多列）。
class _AssetGrid extends StatelessWidget {
  const _AssetGrid({
    required this.library,
    required this.columns,
    required this.emotions,
    required this.emotionFilter,
    required this.search,
    required this.onEmotionFilterChanged,
    required this.onAssignStates,
    this.overlay,
  });

  final LibraryController library;
  final int columns;
  final List<String> emotions;
  final String? emotionFilter;
  final String search;
  final ValueChanged<String?> onEmotionFilterChanged;
  final void Function(EmotionAsset asset) onAssignStates;
  final OverlayPetController? overlay;

  /// 当前**真正在使用**的素材 id：优先原生诊断回报的素材，回落角色默认素材。
  ///
  /// 这样「使用中」标记与悬浮窗实际显示的是同一张图，而不是靠猜测。
  String? get _inUseAssetId {
    final String? native = overlay?.stateDiagnostics.stateAssetId;
    if (native != null && native.isNotEmpty) return native;
    return library.selectedCharacter?.defaultAssetId;
  }

  List<EmotionAsset> get _filtered {
    Iterable<EmotionAsset> assets = library.selectedCharacterAssets;
    if (emotionFilter != null) {
      assets = assets.where((EmotionAsset a) => a.emotionName == emotionFilter);
    }
    if (search.isNotEmpty) {
      final String needle = search.toLowerCase();
      assets = assets.where(
        (EmotionAsset a) =>
            a.emotionName.toLowerCase().contains(needle) ||
            a.variantName.toLowerCase().contains(needle),
      );
    }
    return assets.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final String? characterId = library.selectedCharacterId;
    if (characterId == null) {
      return const PetLifeEmptyState(
        icon: Icons.person_search,
        title: '请选择角色',
        message: '先在作品包里选择一个角色，再查看它的素材。',
        compact: true,
      );
    }
    final List<EmotionAsset> assets = _filtered;
    final bool isActiveCharacter = characterId == library.activeCharacterId;
    final PetLifePalette p = PetLifeTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (emotions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PetLifeTag(
                      label: '全部状态',
                      selected: emotionFilter == null,
                      dense: true,
                      onTap: () => onEmotionFilterChanged(null),
                    ),
                  ),
                  for (final String emotion in emotions)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: PetLifeTag(
                        label: emotion,
                        selected: emotionFilter == emotion,
                        dense: true,
                        onTap: () => onEmotionFilterChanged(
                          emotionFilter == emotion ? null : emotion,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                '${library.selectedCharacter?.displayName ?? ''} · ${assets.length} 个素材',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PetLifeText.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
            ),
            if (isActiveCharacter) ...<Widget>[
              const SizedBox(width: 6),
              const _ActiveBadge(),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: assets.isEmpty
              ? PetLifeEmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  title: '没有符合筛选条件的素材',
                  message: '试试清除「状态」筛选或搜索关键字。',
                  compact: true,
                  actionLabel: '清除筛选',
                  onAction: () {
                    onEmotionFilterChanged(null);
                  },
                )
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double scale =
                        MediaQuery.textScalerOf(context).scale(1.0);
                    // 系统字体放大时卡片需要更高，否则文字块会顶到边界。
                    final double extent = 236 + ((scale - 1).clamp(0.0, 1.5) * 96);
                    // 卡片突出人物预览：预览区占据剩余空间，正文只占底部固定几条。
                    return GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: extent,
                        crossAxisSpacing: PetLifeSpacing.cardGap,
                        mainAxisSpacing: PetLifeSpacing.cardGap,
                      ),
                      itemCount: assets.length,
                      itemBuilder: (BuildContext context, int i) {
                        final EmotionAsset a = assets[i];
                        return _AssetCard(
                          asset: a,
                          inUse: a.id == _inUseAssetId,
                          onPreview: () => showAssetPreview(context, a),
                          onToggleEnabled: () =>
                              library.setAssetEnabled(a.id, !a.enabled),
                          onSetDefault: () =>
                              library.setDefaultAsset(a.characterId, a.id),
                          onToggleFavorite: () =>
                              library.setAssetFavorite(a.id, !a.favorite),
                          onAssignStates: () => onAssignStates(a),
                          onDelete: () => _confirmDelete(context, a),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 删除素材（**先查出引用它的状态并如实告知**）。
  Future<void> _confirmDelete(BuildContext context, EmotionAsset asset) async {
    // 引用提示必须在删除**之前**查：删除时映射会被同一个事务清掉，
    // 事后再查就什么都看不到了。
    List<SystemState> referencing = const <SystemState>[];
    try {
      referencing = await library.statesReferencingAsset(asset.id);
    } catch (e, st) {
      Loggers.character.warning('查询素材引用失败（按无引用继续）', e, st);
    }
    if (!context.mounted) return;

    final String referenceBlock = referencing.isEmpty
        ? ''
        : '\n\n该素材正被以下状态使用：\n'
            '${referencing.map((SystemState s) => '· ${s.descriptionZh}（${s.wireName}）').join('\n')}\n\n'
            '删除后这些状态将使用回退素材。';

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除素材'),
        content: Text(
          '要删除「${asset.emotionName} / ${asset.variantName}」吗？'
          '$referenceBlock\n\n'
          '⚠ 仅删除 PetLife 托管目录中的副本：\n${asset.filePath}\n\n'
          '你的原始文件不受影响：\n${asset.originalFilePath ?? '<无>'}',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          PetLifeDangerButton(
            label: '删除',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok ?? false) await library.deleteAsset(asset.id);
  }
}

/// 素材大卡片：突出人物预览，其余信息作为次要信息。
class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.inUse,
    required this.onPreview,
    required this.onToggleEnabled,
    required this.onSetDefault,
    required this.onToggleFavorite,
    required this.onAssignStates,
    required this.onDelete,
  });

  final EmotionAsset asset;

  /// 当前正在使用的素材（强调色描边 + 右上角对勾）。
  final bool inUse;

  final VoidCallback onPreview;
  final VoidCallback onToggleEnabled;
  final VoidCallback onSetDefault;
  final VoidCallback onToggleFavorite;
  final VoidCallback onAssignStates;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final bool valid = asset.validationStatus == ValidationStatus.valid;

    return PetLifeCard(
      padding: const EdgeInsets.all(8),
      selected: inUse,
      onTap: onPreview,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 预览区：占据卡片主要空间，保证「图片不变形」。
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.muted,
                      borderRadius: PetLifeRadii.buttonBorder,
                    ),
                    child: valid
                        ? Padding(
                            padding: const EdgeInsets.all(4),
                            child: Image.file(
                              File(asset.filePath),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.none,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          )
                        : Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: p.danger,
                            ),
                          ),
                  ),
                ),
                if (inUse)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(PetLifeRadii.pill),
                      ),
                      child: Text(
                        '使用中',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: p.onAccent,
                        ),
                      ),
                    ),
                  ),
                if (asset.favorite)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(Icons.bookmark, size: 16, color: p.warning),
                  ),
                if (!asset.enabled)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Icon(Icons.visibility_off, size: 14, color: p.textSecondary),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            asset.emotionName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: PetLifeText.bodySmall,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          Text(
            asset.variantName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
          ),
          Text(
            '${asset.width}×${asset.height} · '
            '${asset.isAnimated ? '${asset.frameCount} 帧' : '静态'} · '
            '${asset.mimeType.replaceFirst('image/', '').toUpperCase()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.textSecondary),
          ),
          if (!valid)
            Text(
              '损坏：${asset.validationError ?? '校验未通过'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: PetLifeText.captionSmall, color: p.danger),
            ),
          const SizedBox(height: 4),
          // 底部操作区：收藏 / 更多（编辑、预览、设为使用中、删除）。
          // 用 Wrap 而不是 Row：任何宽度下都不会横向溢出。
          Wrap(
            spacing: 2,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _cardAction(
                tooltip: asset.favorite ? '取消收藏' : '收藏',
                icon: Icon(
                  asset.favorite ? Icons.bookmark : Icons.bookmark_border,
                  color: asset.favorite ? p.warning : null,
                ),
                onPressed: onToggleFavorite,
              ),
              _cardAction(
                tooltip: inUse ? '当前使用中' : '设为该角色的使用素材',
                icon: Icon(
                  inUse ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: inUse ? p.accent : null,
                ),
                onPressed: onSetDefault,
              ),
              PopupMenuButton<_AssetMenuAction>(
                tooltip: '更多操作',
                padding: EdgeInsets.zero,
                iconSize: 18,
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onSelected: (_AssetMenuAction action) {
                  switch (action) {
                    case _AssetMenuAction.preview:
                      onPreview();
                    case _AssetMenuAction.editMapping:
                      onAssignStates();
                    case _AssetMenuAction.toggleEnabled:
                      onToggleEnabled();
                    case _AssetMenuAction.setInUse:
                      onSetDefault();
                    case _AssetMenuAction.delete:
                      onDelete();
                  }
                },
                itemBuilder: (BuildContext ctx) => <PopupMenuEntry<_AssetMenuAction>>[
                  const PopupMenuItem<_AssetMenuAction>(
                    value: _AssetMenuAction.preview,
                    child: Text('预览'),
                  ),
                  const PopupMenuItem<_AssetMenuAction>(
                    value: _AssetMenuAction.editMapping,
                    child: Text('编辑（分配给状态…）'),
                  ),
                  PopupMenuItem<_AssetMenuAction>(
                    value: _AssetMenuAction.toggleEnabled,
                    child: Text(asset.enabled ? '禁用该素材' : '启用该素材'),
                  ),
                  const PopupMenuItem<_AssetMenuAction>(
                    value: _AssetMenuAction.setInUse,
                    child: Text('设为使用素材'),
                  ),
                  const PopupMenuItem<_AssetMenuAction>(
                    value: _AssetMenuAction.delete,
                    child: Text('删除（仅删托管副本）'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 紧凑图标按钮（触摸区仍是 34×34，配合 PopupMenu 的 34 不会溢出）。
  Widget _cardAction({
    required String tooltip,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      visualDensity: VisualDensity.compact,
      icon: icon,
      onPressed: onPressed,
    );
  }
}

/// 素材卡片「更多」菜单的动作。
enum _AssetMenuAction { preview, editMapping, toggleEnabled, setInUse, delete }

/// 素材预览（大图 + 元信息）。纯展示，不修改任何数据。
Future<void> showAssetPreview(BuildContext context, EmotionAsset asset) {
  final bool valid = asset.validationStatus == ValidationStatus.valid;
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      final PetLifePalette p = PetLifeTheme.of(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.all(PetLifeSpacing.cardInner),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${asset.emotionName} / ${asset.variantName}',
                  style: TextStyle(
                    fontSize: PetLifeText.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.muted,
                      borderRadius: PetLifeRadii.cardBorder,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: valid
                          ? Image.file(
                              File(asset.filePath),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.none,
                            )
                          : Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 48,
                                color: p.danger,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                PetLifeKeyValue(label: '尺寸', value: '${asset.width}×${asset.height}'),
                PetLifeKeyValue(
                  label: '帧数',
                  value: asset.isAnimated ? '${asset.frameCount} 帧（动态）' : '静态图',
                ),
                PetLifeKeyValue(label: '格式', value: asset.mimeType),
                PetLifeKeyValue(
                  label: '文件大小',
                  value: '${(asset.fileSize / 1024).toStringAsFixed(1)} KB',
                ),
                PetLifeKeyValue(
                  label: '透明通道',
                  value: asset.hasAlpha ? '有' : '无',
                ),
                if (!valid)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '该素材校验未通过：${asset.validationError ?? '未知原因'}',
                      style: TextStyle(fontSize: PetLifeText.caption, color: p.danger),
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: PetLifePrimaryButton(
                    label: '关闭',
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 筛选弹窗（作品包 / 角色 / 状态 / 搜索）。
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.library,
    required this.emotions,
    required this.emotionFilter,
    required this.onEmotionChanged,
    required this.search,
    required this.onSearchChanged,
  });

  final LibraryController library;
  final List<String> emotions;
  final String? emotionFilter;
  final ValueChanged<String?> onEmotionChanged;
  final String search;
  final ValueChanged<String> onSearchChanged;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final TextEditingController _search =
      TextEditingController(text: widget.search);
  String? _emotion;

  @override
  void initState() {
    super.initState();
    _emotion = widget.emotionFilter;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LibrarySnapshot? snap = widget.library.snapshot;
    final PetLifePalette p = PetLifeTheme.of(context);
    if (snap == null) return const SizedBox.shrink();
    final List<CharacterModel> chars = widget.library.selectedPackId == null
        ? const <CharacterModel>[]
        : snap.charactersOf(widget.library.selectedPackId!);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const PetLifeSectionTitle(
                title: '筛选素材',
                subtitle: '作品包 / 角色 / 状态 / 搜索',
                marker: false,
              ),
              TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: '搜索状态或变体名',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (String value) {
                  widget.onSearchChanged(value);
                  setState(() {});
                },
              ),
              const SizedBox(height: 14),
              Text(
                '作品包',
                style: TextStyle(
                  fontSize: PetLifeText.caption,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final CharacterPack pack in snap.packs)
                    PetLifeTag(
                      label: pack.name,
                      selected: pack.id == widget.library.selectedPackId,
                      onTap: () {
                        widget.library.selectPack(pack.id);
                        setState(() {
                          _emotion = null;
                          widget.onEmotionChanged(null);
                        });
                      },
                    ),
                ],
              ),
              if (chars.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                Text(
                  '角色',
                  style: TextStyle(
                    fontSize: PetLifeText.caption,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final CharacterModel c in chars)
                      PetLifeTag(
                        label: c.displayName,
                        selected: c.id == widget.library.selectedCharacterId,
                        onTap: () {
                          widget.library.selectCharacter(c.id);
                          setState(() {
                            _emotion = null;
                            widget.onEmotionChanged(null);
                          });
                        },
                      ),
                  ],
                ),
              ],
              if (widget.emotions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                Text(
                  '状态',
                  style: TextStyle(
                    fontSize: PetLifeText.caption,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    PetLifeTag(
                      label: '全部',
                      selected: _emotion == null,
                      onTap: () {
                        setState(() => _emotion = null);
                        widget.onEmotionChanged(null);
                      },
                    ),
                    for (final String emotion in widget.emotions)
                      PetLifeTag(
                        label: emotion,
                        selected: _emotion == emotion,
                        onTap: () {
                          final String? next =
                              _emotion == emotion ? null : emotion;
                          setState(() => _emotion = next);
                          widget.onEmotionChanged(next);
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              PetLifePrimaryButton(
                label: '完成',
                expand: true,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
