import 'package:flutter/material.dart';

/// 单行文本输入弹窗（重命名之类的轻量输入）。
///
/// ## 为什么是一个独立 StatefulWidget（而不是在调用方 new 控制器）
///
/// 与 `AssetImportFormDialog` / `DeviceEditDialog` 同因：
/// `await showDialog(...)` 在路由**开始**退场时就返回，而弹窗的 Element 要到
/// 退场动画结束才 unmount。调用方若在 `await` 之后立刻 `controller.dispose()`，
/// 就会在控件仍然依赖控制器时把它销毁，触发
/// `'_dependents.isEmpty': is not true.` 断言。控制器必须由弹窗自己的 State 持有。
///
/// 返回值语义（沿用改造前的行为，避免连带改动调用方）：
/// * 取消 → `null`；
/// * 确认但内容为空（去空白后）→ `null`（调用方据此不执行修改）。
class TextInputDialog extends StatefulWidget {
  const TextInputDialog({
    super.key,
    required this.title,
    this.initialText = '',
    this.hintText,
    this.fieldLabel,
  });

  final String title;
  final String initialText;
  final String? hintText;
  final String? fieldLabel;

  /// 打开弹窗；取消或留空都返回 `null`。
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String initialText = '',
    String? hintText,
    String? fieldLabel,
  }) =>
      showDialog<String>(
        context: context,
        builder: (BuildContext ctx) => TextInputDialog(
          title: title,
          initialText: initialText,
          hintText: hintText,
          fieldLabel: fieldLabel,
        ),
      );

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.fieldLabel,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
