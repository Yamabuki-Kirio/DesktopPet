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
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import 'state_asset_mapping_page.dart';

/// 素材库页面（需求 9.2）。
///
/// 支持：导入单张 / 多张 / 文件夹 / ZIP、切换角色、切换图片、禁用图片、
/// 设为默认图片、删除**应用目录内**的用户素材。
/// 用户原始目录中的文件永远不会被修改或删除（仓库层的路径守卫保证）。
///
/// Phase 4A 的三处真机修复都落在这里：
/// 1. **ZIP 导入**：只依赖注入进来的 [importer]（装配层给的是统一路由器），
///    页面不再自行决定"哪个请求喂哪个导入器"；
/// 2. **角色激活**：播放按钮调 [LibraryController.activateCharacter]，
///    真正切换状态引擎；
/// 3. **响应式布局**：窄屏（手机）改成纵向流程，不再用固定 260px 左栏 + 右侧网格。
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

  /// Android 悬浮桌宠协调器（Phase 4C-6A.1：状态映射页的"预览"要用它）。
  ///
  /// 可为 null：Windows 没有系统级悬浮窗，既有测试也只关心导入与激活流程。
  final OverlayPetController? overlay;

  @override
  State<AssetLibraryPage> createState() => _AssetLibraryPageState();
}

class _AssetLibraryPageState extends State<AssetLibraryPage> {
  /// 宽屏阈值：>= 该宽度才用左右分栏，否则纵向流程。
  static const double _kWideBreakpoint = 720;

  final TextEditingController _pathController = TextEditingController();
  bool _busy = false;
  String _status = '';
  ImportReport? _lastReport;

  /// 上一次「导入图片」的选择统计（选择数 / 取得内容数 / 无法读取明细）。
  String? _lastSelectionNote;

  @override
  void initState() {
    super.initState();
    _pathController.text = _guessAceAttorneyPath() ?? '';
  }

  @override
  void dispose() {
    _pathController.dispose();
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
    final LibraryController lib = widget.library;
    final LibrarySnapshot? snap = lib.snapshot;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= _kWideBreakpoint;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildToolbar(constraints.maxWidth),
              if (_busy) ...<Widget>[
                const SizedBox(height: 12),
                const LinearProgressIndicator(value: null, minHeight: 3),
                const SizedBox(height: 4),
                Text(_status,
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
              if (_lastReport != null) ...<Widget>[
                const SizedBox(height: 8),
                _ImportReportCard(
                  report: _lastReport!,
                  selectionNote: _lastSelectionNote,
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: snap == null || snap.isEmpty
                    ? const _EmptyHint()
                    : wide
                        ? _buildWideLayout(lib)
                        : _buildNarrowLayout(lib),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 布局：宽屏分栏 / 窄屏纵向
  // ---------------------------------------------------------------------------

  /// 打开「状态素材映射」编辑器（Phase 4C-6A.1，需求 §3.1）。
  ///
  /// 入口刻意放在**角色层面**（作品包 → 角色 → 状态映射），
  /// 因为状态映射本就属于角色，而不是整个作品包。
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

  /// 反向分配：把某素材分配给多个状态（需求 §6 的"素材卡片菜单"入口）。
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
          child: _PackCharacterTree(
            library: lib,
            onActivate: _activateCharacter,
            onOpenMappings: _openMappings,
          ),
        ),
        const VerticalDivider(width: 24),
        Expanded(
          child: _AssetGrid(
            library: lib,
            wide: true,
            onAssignStates: _assignStates,
          ),
        ),
      ],
    );
  }

  /// 手机纵向流程：作品包 → 角色 → "设为当前桌宠" → 素材网格。
  ///
  /// 刻意不用固定的 260px 左栏：手机剩余宽度根本容不下右侧网格，
  /// 那正是真机 `RIGHT OVERFLOWED BY 88 PIXELS / 134 PIXELS` 的来源。
  Widget _buildNarrowLayout(LibraryController lib) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PackDropdown(library: lib),
        const SizedBox(height: 10),
        _CharacterChips(library: lib),
        const SizedBox(height: 10),
        _ActivateBar(
          library: lib,
          onActivate: _activateCharacter,
          onOpenMappings: _openMappings,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _AssetGrid(
            library: lib,
            wide: false,
            onAssignStates: _assignStates,
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(double maxWidth) {
    // 文件夹导入是桌面能力：Android 的 SAF 目录选择需要原生通道（Phase 4B）。
    // 因此这里按平台能力隐藏相应入口，而不是让用户点到一个必然报错的按钮。
    final bool folderImport = widget.fileImportProvider.supportsFolderImport;
    // 路径输入框按可用宽度收缩，避免窄窗口下把工具栏撑出边界。
    final double pathFieldWidth = maxWidth < 380 ? maxWidth : 380;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (folderImport)
          FilledButton.icon(
            onPressed: _busy ? null : _importFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('导入文件夹'),
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _importImages,
          icon: const Icon(Icons.collections, size: 18),
          label: const Text('导入多张图片'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _importSingleImage,
          icon: const Icon(Icons.image, size: 18),
          label: const Text('导入单张图片'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _importZip,
          icon: const Icon(Icons.folder_zip, size: 18),
          label: const Text('导入 ZIP 素材包'),
        ),
        if (folderImport) ...<Widget>[
          const SizedBox(width: 12),
          SizedBox(
            width: pathFieldWidth,
            child: TextField(
              controller: _pathController,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '文件夹路径（可粘贴后点右侧按钮）',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link, size: 18),
              ),
            ),
          ),
          OutlinedButton(
            onPressed: _busy || _pathController.text.trim().isEmpty
                ? null
                : () => _runImportFolder(_pathController.text.trim()),
            child: const Text('按路径导入'),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 导入动作
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

  /// 真正把某个角色设为当前桌宠角色，并给出明确反馈（需求 4/5/6/7）。
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
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 单张图片导入时要问作品包 / 角色 / 情绪 / 是否设为默认（需求 4.4）。
  ///
  /// 控制器与表单状态都在 [AssetImportFormDialog] 自己的 State 里
  /// （`initState` 创建 / `dispose` 销毁），这里只准备两个默认值、
  /// 然后接收**不可变结果**：取消时是 `null`，表示不执行导入。
  ///
  /// 之前把三个 `TextEditingController` 放在这个方法里、在 `await showDialog` 返回后
  /// 立刻 dispose，会在弹窗路由**还在跑退场动画**时销毁控制器，
  /// 触发 `framework.dart` 的 `'_dependents.isEmpty': is not true.` 断言 —— 见 docs/32。
  Future<AssetImportForm?> _askFileImportForm(int count) {
    final LibrarySnapshot? snap = widget.library.snapshot;
    final String defaultPack =
        snap != null && snap.packs.isNotEmpty ? snap.packs.first.name : '我的素材';
    // 已选中作品包时不预填（沿用改造前的交互）；此时留空仍会回落到默认作品包。
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

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              Icon(Icons.photo_library_outlined, size: 56, color: Colors.black26),
              SizedBox(height: 12),
              Text('还没有任何素材', style: TextStyle(fontSize: 16)),
              SizedBox(height: 6),
              Text(
                '点上方「导入文件夹」或「导入 ZIP 素材包」，选择素材所在位置即可\n'
                '（手机端请使用 ZIP 素材包）\n'
                '文件名遵循 角色名_情绪名_序号 规则，会自动识别角色与情绪',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
      );
}

/// 导入结果卡片。
///
/// 需求：不能永久占用大量屏幕高度 → 默认只显示摘要，明细按需展开。
class _ImportReportCard extends StatefulWidget {
  const _ImportReportCard({required this.report, this.selectionNote});

  final ImportReport report;

  /// 「选择 / 取得内容 / 成功 / 跳过」统计（含无法读取的文件及原因）。
  ///
  /// 需求：不允许静默跳过 —— 因此这些数量必须显示在导入结果里。
  final String? selectionNote;

  @override
  State<_ImportReportCard> createState() => _ImportReportCardState();
}

class _ImportReportCardState extends State<_ImportReportCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ImportReport report = widget.report;
    // 一致性校验失败比"有条目损坏"更严重：报告说的成功并未落到数据库。
    final bool inconsistent = !report.isConsistent;
    final bool hasIssue = report.hasFailures || inconsistent;
    final bool hasDetails = report.failed.isNotEmpty || report.warnings.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      color: inconsistent
          ? const Color(0xFFFFEBEE)
          : (hasIssue ? const Color(0xFFFFF4E5) : const Color(0xFFEAF5EC)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              report.summary(),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            if (widget.selectionNote != null)
              Text(
                widget.selectionNote!,
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            if (inconsistent)
              for (final String issue in report.consistencyIssues)
                Text(
                  '⚠ $issue',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB71C1C),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            if (report.characterNames.isNotEmpty)
              Text(
                '角色：${report.characterNames.join('、')}'
                '${report.packNames.isEmpty ? '' : ' · 作品包：${report.packNames.join('、')}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            if (_expanded) ...<Widget>[
              if (report.seededMappingCount > 0)
                Text('自动生成状态映射 ${report.seededMappingCount} 条（可在「状态映射」里修改）',
                    style: const TextStyle(fontSize: 12)),
              for (final String w in report.warnings)
                Text('⚠ $w',
                    style: const TextStyle(fontSize: 12, color: Colors.orange)),
              if (report.failed.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text('损坏 / 跳过明细（${report.failed.length} 条）：',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                for (final FailedItem f in report.failed.take(20))
                  Text(
                    '· ${p.basename(f.path)} — ${f.failure.message}'
                    '${f.failure.detail == null ? '' : '（${f.failure.detail}）'}',
                    style: const TextStyle(fontSize: 11, color: Colors.brown),
                  ),
                if (report.failed.length > 20)
                  const Text('…（更多明细见日志）', style: TextStyle(fontSize: 11)),
              ],
            ],
            if (hasDetails)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _expanded
                        ? '收起'
                        : '详情（告警 ${report.warnings.length} · 失败 ${report.failed.length}）',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
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
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF4A7EBB),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '使用中',
        style: TextStyle(color: Colors.white, fontSize: compact ? 9 : 10),
      ),
    );
  }
}

/// 窄屏：作品包下拉框。
class _PackDropdown extends StatelessWidget {
  const _PackDropdown({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final List<CharacterPack> packs = library.snapshot!.packs;
    return InputDecorator(
      decoration: const InputDecoration(
        isDense: true,
        labelText: '作品包',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: library.selectedPackId,
          isDense: true,
          items: <DropdownMenuItem<String>>[
            for (final CharacterPack pack in packs)
              DropdownMenuItem<String>(
                value: pack.id,
                child: Text(
                  '${pack.name}（${library.snapshot!.charactersOf(pack.id).length} 个角色）',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: (String? id) {
            if (id != null) library.selectPack(id);
          },
        ),
      ),
    );
  }
}

/// 窄屏：角色横向可滚动选择器（选中 ≠ 激活）。
class _CharacterChips extends StatelessWidget {
  const _CharacterChips({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final LibrarySnapshot snap = library.snapshot!;
    final String? packId = library.selectedPackId;
    if (packId == null) {
      return const Text('请先选择作品包',
          style: TextStyle(fontSize: 12, color: Colors.black45));
    }
    final List<CharacterModel> chars = snap.charactersOf(packId);
    if (chars.isEmpty) {
      return const Text('该作品包下还没有角色',
          style: TextStyle(fontSize: 12, color: Colors.black45));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final CharacterModel c in chars)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: c.id == library.selectedCharacterId,
                onSelected: (_) => library.selectCharacter(c.id),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(c.displayName, style: const TextStyle(fontSize: 13)),
                    if (c.id == library.activeCharacterId) ...<Widget>[
                      const SizedBox(width: 4),
                      const _ActiveBadge(compact: true),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 窄屏："设为当前桌宠角色"按钮 + 使用状态。
class _ActivateBar extends StatelessWidget {
  const _ActivateBar({
    required this.library,
    required this.onActivate,
    required this.onOpenMappings,
  });

  final LibraryController library;
  final Future<void> Function(String characterId) onActivate;
  final Future<void> Function(String characterId) onOpenMappings;

  @override
  Widget build(BuildContext context) {
    final CharacterModel? selected = library.selectedCharacter;
    final bool isActive =
        selected != null && selected.id == library.activeCharacterId;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          onPressed: selected == null ? null : () => onActivate(selected.id),
          icon: Icon(isActive ? Icons.check_circle : Icons.play_circle_outline,
              size: 18),
          label: Text(isActive ? '已是当前桌宠角色' : '设为当前桌宠角色'),
        ),
        // Phase 4C-6A.1：状态映射属于**角色**，入口因此放在角色层面。
        OutlinedButton.icon(
          onPressed:
              selected == null ? null : () => onOpenMappings(selected.id),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('状态映射'),
        ),
        if (selected != null)
          Text(
            '${library.selectedCharacterAssets.length} 个素材',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
      ],
    );
  }
}

/// 作品包 / 角色树（宽屏）。
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
    return ListView(
      children: <Widget>[
        const Text('作品包', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final CharacterPack pack in snap.packs)
          ListTile(
            dense: true,
            selected: pack.id == library.selectedPackId,
            leading: const Icon(Icons.folder, size: 18),
            title: Text(pack.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              '${snap.charactersOf(pack.id).length} 个角色 · ${pack.sourceType.wireName}',
              style: const TextStyle(fontSize: 11),
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
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('删除')),
                    ],
                  ),
                );
                if (ok ?? false) await library.deletePack(pack.id);
              },
            ),
          ),
        const Divider(),
        const Text('角色', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (library.selectedPackId == null)
          const Text('请先选择作品包', style: TextStyle(fontSize: 12, color: Colors.black45))
        else
          for (final CharacterModel c in snap.charactersOf(library.selectedPackId!))
            ListTile(
              dense: true,
              selected: c.id == library.selectedCharacterId,
              leading: Icon(
                c.id == library.selectedCharacterId
                    ? Icons.pets
                    : Icons.person_outline,
                size: 18,
              ),
              title: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(c.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  if (c.id == library.activeCharacterId) ...<Widget>[
                    const SizedBox(width: 6),
                    const _ActiveBadge(compact: true),
                  ],
                ],
              ),
              subtitle: Text(
                '${snap.assetsOf(c.id).length} 个素材 · ${c.internalName}',
                style: const TextStyle(fontSize: 11),
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
                  Tooltip(
                    message: c.id == library.activeCharacterId
                        ? '当前桌宠角色'
                        : '设为当前桌宠角色',
                    child: IconButton(
                      icon: Icon(
                        c.id == library.activeCharacterId
                            ? Icons.check_circle
                            : Icons.play_circle_outline,
                        size: 16,
                        color: c.id == library.activeCharacterId
                            ? const Color(0xFF4A7EBB)
                            : null,
                      ),
                      onPressed: () => onActivate(c.id),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// 素材网格。
class _AssetGrid extends StatelessWidget {
  const _AssetGrid({
    required this.library,
    required this.wide,
    required this.onAssignStates,
  });

  final LibraryController library;

  /// 是否使用宽屏（桌面）网格。由**页面级**断点决定，
  /// 而不是由网格自身宽度决定 —— 否则中等宽度下会误判成手机布局。
  final bool wide;

  /// 「分配给状态…」（需求 §6 的素材卡片菜单入口）。
  final void Function(EmotionAsset asset) onAssignStates;

  @override
  Widget build(BuildContext context) {
    final String? characterId = library.selectedCharacterId;
    if (characterId == null) {
      return const Center(child: Text('请选择角色'));
    }
    final List<EmotionAsset> assets = library.selectedCharacterAssets;
    final String? defaultAssetId = library.selectedCharacter?.defaultAssetId;
    final bool isActive = characterId == library.activeCharacterId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                '${library.selectedCharacter?.displayName ?? ''} · ${assets.length} 个素材',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (isActive) ...<Widget>[
              const SizedBox(width: 6),
              const _ActiveBadge(),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '情绪：${library.selectedEmotions.join('、')}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double scale = MediaQuery.textScalerOf(context).scale(1.0);
              // 系统字体放大时，卡片需要更高，否则固定高度的文字块会顶到边界。
              //
              // 216 → 252：Phase 4C-6A.1 给操作行加了「更多」按钮，窄卡片上
              // 可能换到第二行；这里按 `_AssetCard.actionRowBudget`（84）预留，
              // 多出来的空间由 `Expanded` 的缩略图吸收，不会浪费成空白。
              final double extent = 252 + ((scale - 1).clamp(0.0, 1.5) * 90);
              final SliverGridDelegate delegate = wide
                  ? SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      mainAxisExtent: extent,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    )
                  : SliverGridDelegateWithFixedCrossAxisCount(
                      // 手机 1～2 列：过窄时用 1 列，保证卡片上的按钮全部可见。
                      crossAxisCount: constraints.maxWidth < 340 ? 1 : 2,
                      mainAxisExtent: extent,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    );
              return GridView.builder(
                gridDelegate: delegate,
                itemCount: assets.length,
                itemBuilder: (BuildContext context, int i) {
                  final EmotionAsset a = assets[i];
                  return _AssetCard(
                    asset: a,
                    isDefault: a.id == defaultAssetId,
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

  /// 删除素材（需求 §10.1：**先查出引用它的状态并如实告知**）。
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
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok ?? false) await library.deleteAsset(asset.id);
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.isDefault,
    required this.onToggleEnabled,
    required this.onSetDefault,
    required this.onToggleFavorite,
    required this.onAssignStates,
    required this.onDelete,
  });

  final EmotionAsset asset;
  final bool isDefault;
  final VoidCallback onToggleEnabled;
  final VoidCallback onSetDefault;

  /// 收藏 / 取消收藏（Phase 4C-6A.1）。
  final VoidCallback onToggleFavorite;

  /// 「分配给状态…」（Phase 4C-6A.1）。
  final VoidCallback onAssignStates;

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool valid = asset.validationStatus == ValidationStatus.valid;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isDefault
              ? const Color(0xFF4A7EBB)
              : (valid ? const Color(0xFFE0E4EA) : const Color(0xFFD9534F)),
          width: isDefault ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: InkWell(
                onTap: onSetDefault,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: Container(
                        width: double.infinity,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF7F9FC),
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                        ),
                        child: valid
                            ? Image.file(
                                File(asset.filePath),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.none,
                                gaplessPlayback: true,
                              )
                            : const Center(
                                child: Icon(Icons.broken_image_outlined,
                                    color: Colors.redAccent),
                              ),
                      ),
                    ),
                    // Phase 4C-6A.1：收藏标记（只影响回退链的先后，不影响可用性）。
                    if (asset.favorite)
                      const Positioned(
                        right: 2,
                        top: 2,
                        child: Icon(Icons.bookmark,
                            size: 16, color: Color(0xFFE8A33D)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${asset.emotionName} / ${asset.variantName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Text(
              '${asset.width}×${asset.height} · '
              '${asset.isAnimated ? '动态 ${asset.frameCount}帧' : '静态'} · '
              '${asset.hasAlpha ? '带透明' : '不透明'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
            Text(
              '${(asset.fileSize / 1024).toStringAsFixed(1)} KB · '
              '${asset.mimeType.replaceFirst('image/', '')}'
              '${asset.animationDurationMs > 0 ? ' · ${asset.animationDurationMs}ms/轮' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
            if (!valid)
              Text(
                '损坏：${asset.validationError ?? '校验未通过'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.red),
              ),
            // 手机上卡片可能只有 ~160px 宽：这里刻意只放 4 个紧凑按钮
            // （默认 / 启用 / 更多 / 删除），其余操作收进「更多」菜单。
            //
            // 用 **Wrap 而不是 Row**：不同 Flutter 版本 / 主题下按钮的实际宽度
            // 不完全可控（`IconButton` 的最小点击区会参与计算），Wrap 在放不下时
            // 换行而**永远不会横向溢出**；卡片高度已为此预留一行（见 extent 计算）。
            Wrap(
              spacing: 2,
              runSpacing: 0,
              alignment: WrapAlignment.spaceBetween,
              children: <Widget>[
                _cardAction(
                  tooltip: isDefault ? '当前默认图片' : '设为角色默认图片',
                  icon: Icon(
                    isDefault ? Icons.star : Icons.star_border,
                    color: isDefault ? const Color(0xFFE8A33D) : null,
                  ),
                  onPressed: onSetDefault,
                ),
                _cardAction(
                  tooltip: asset.enabled ? '禁用该素材' : '启用该素材',
                  icon: Icon(
                      asset.enabled ? Icons.visibility : Icons.visibility_off),
                  onPressed: onToggleEnabled,
                ),
                PopupMenuButton<_AssetMenuAction>(
                  tooltip: '更多操作',
                  padding: EdgeInsets.zero,
                  iconSize: 17,
                  constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                  onSelected: (_AssetMenuAction action) {
                    switch (action) {
                      case _AssetMenuAction.toggleFavorite:
                        onToggleFavorite();
                      case _AssetMenuAction.assignStates:
                        onAssignStates();
                      case _AssetMenuAction.setDefault:
                        onSetDefault();
                    }
                  },
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<_AssetMenuAction>>[
                    PopupMenuItem<_AssetMenuAction>(
                      value: _AssetMenuAction.toggleFavorite,
                      child: Text(
                        asset.favorite ? '取消收藏' : '收藏',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const PopupMenuItem<_AssetMenuAction>(
                      value: _AssetMenuAction.assignStates,
                      child: Text('分配给状态…', style: TextStyle(fontSize: 13)),
                    ),
                    const PopupMenuItem<_AssetMenuAction>(
                      value: _AssetMenuAction.setDefault,
                      child: Text('设为角色默认', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                _cardAction(
                  tooltip: '删除（仅删托管副本）',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 固定 30×30 的紧凑按钮。
  ///
  /// 尺寸是算出来的，不是拍的：手机 2 列时卡片内容宽度约 127px（320px 屏），
  /// 这一行要放下 4 个按钮（默认 / 启用 / 更多 / 删除）→ 4×30 = 120 ≤ 127。
  /// 之前用 32 时，393px 屏上会 `RenderFlex overflowed by 4.5 pixels`。
  Widget _cardAction({
    required String tooltip,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 17,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      visualDensity: VisualDensity.compact,
      icon: icon,
      onPressed: onPressed,
    );
  }
}

/// 素材卡片「更多」菜单的动作（Phase 4C-6A.1）。
enum _AssetMenuAction { toggleFavorite, assignStates, setDefault }
