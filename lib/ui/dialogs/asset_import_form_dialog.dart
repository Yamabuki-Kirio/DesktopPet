import 'package:flutter/material.dart';

/// 单张 / 多张图片导入时收集到的表单结果（**不可变**）。
///
/// `characterName` / `emotionName` 为 `null` 表示"用户留空"，
/// 由导入层按文件名解析 —— **留空是合法输入**，不是错误。
class AssetImportForm {
  const AssetImportForm({
    required this.packName,
    required this.characterName,
    required this.emotionName,
    required this.setAsDefault,
  });

  /// 作品包名称；留空时已由弹窗替换为调用方给的默认名称，因此**非空**。
  final String packName;

  /// 角色名称；null = 留空（按文件名解析）。
  final String? characterName;

  /// 情绪名称；null = 留空（按文件名解析）。
  final String? emotionName;

  final bool setAsDefault;

  @override
  String toString() => 'AssetImportForm(pack=$packName, '
      'character=$characterName, emotion=$emotionName, default=$setAsDefault)';
}

/// 「导入图片」信息填写弹窗。
///
/// ## 为什么是一个独立 StatefulWidget（而不是在调用方 new 控制器）
///
/// 控制器必须由**弹窗自己的 State** 创建并销毁：
///
/// * `await showDialog(...)` 在路由**开始**退场时就返回了
///   （`Navigator.pop` 会立刻 complete 掉那个 Future）；
/// * 此时弹窗的 Element 还挂在树上、还在跑退场动画
///   （要等动画结束才 unmount，`TextEditingController` 的 dispose 也会跟到那时）；
/// * 如果调用方在 `await` 之后立刻 `controller.dispose()`，
///   就会在"控件仍然依赖这个控制器"的时候把它销毁，
///   触发 `framework.dart` 的 `'_dependents.isEmpty': is not true.` 断言。
///
/// 因此这里把控制器收进本组件的 State：`initState` 创建、`dispose` 销毁，
/// 生命周期与弹窗路由完全对齐。调用方只用 [show] 拿结果，**不碰任何控制器**。
///
/// 三个字段都允许留空，因此没有阻塞性的表单校验：
/// 作品包留空走 [fallbackPackName]，角色 / 情绪留空返回 `null` 交给文件名解析。
class AssetImportFormDialog extends StatefulWidget {
  const AssetImportFormDialog({
    super.key,
    required this.count,
    required this.fallbackPackName,
    this.initialPackName,
    this.initialCharacterName,
  });

  /// 本次要导入的图片数量（仅用于标题）。
  final int count;

  /// 作品包名称留空时使用的默认名称。
  final String fallbackPackName;

  /// 作品包输入框的初始内容；null 表示用 [fallbackPackName] 预填。
  final String? initialPackName;

  /// 角色名称输入框的初始内容。
  final String? initialCharacterName;

  /// 打开弹窗。**取消返回 null**（调用方据此不执行导入）。
  static Future<AssetImportForm?> show(
    BuildContext context, {
    required int count,
    required String fallbackPackName,
    String? initialPackName,
    String? initialCharacterName,
  }) =>
      showDialog<AssetImportForm>(
        context: context,
        builder: (BuildContext ctx) => AssetImportFormDialog(
          count: count,
          fallbackPackName: fallbackPackName,
          initialPackName: initialPackName,
          initialCharacterName: initialCharacterName,
        ),
      );

  @override
  State<AssetImportFormDialog> createState() => _AssetImportFormDialogState();
}

class _AssetImportFormDialogState extends State<AssetImportFormDialog> {
  late final TextEditingController _pack;
  late final TextEditingController _character;
  late final TextEditingController _emotion;
  bool _setAsDefault = true;

  @override
  void initState() {
    super.initState();
    _pack = TextEditingController(
      text: widget.initialPackName ?? widget.fallbackPackName,
    );
    _character = TextEditingController(text: widget.initialCharacterName ?? '');
    _emotion = TextEditingController(text: 'default');
  }

  @override
  void dispose() {
    // 与弹窗路由同生共死：路由 unmount 时才会走到这里，
    // 因此不存在"控件还依赖控制器、控制器已被销毁"的窗口。
    _pack.dispose();
    _character.dispose();
    _emotion.dispose();
    super.dispose();
  }

  String? _nullIfBlank(TextEditingController controller) {
    final String text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  void _submit() {
    final String pack = _pack.text.trim();
    Navigator.pop(
      context,
      AssetImportForm(
        packName: pack.isEmpty ? widget.fallbackPackName : pack,
        characterName: _nullIfBlank(_character),
        emotionName: _nullIfBlank(_emotion),
        setAsDefault: _setAsDefault,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('导入 ${widget.count} 张图片'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _pack,
              decoration: const InputDecoration(
                labelText: '作品包名称',
                helperText: '已有同名作品包时会合并进去',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _character,
              decoration: const InputDecoration(
                labelText: '角色名称（留空则用文件名解析）',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emotion,
              decoration: const InputDecoration(
                labelText: '情绪名称（留空则用文件名解析）',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _setAsDefault,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (bool? v) => setState(() => _setAsDefault = v ?? false),
              title: const Text('设为该角色的默认图片'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}
