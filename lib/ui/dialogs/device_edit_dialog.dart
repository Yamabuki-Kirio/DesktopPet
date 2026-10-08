import 'package:flutter/material.dart';

/// 设备编辑弹窗的返回值（**不可变**，且一定已通过校验）。
class DeviceEditResult {
  const DeviceEditResult({required this.deviceName, required this.modelName});

  /// 设备名称：已去掉首尾空白，**非空**，长度 ≤ [DeviceEditDialog.maxFieldLength]。
  final String deviceName;

  /// 型号备注：已去掉首尾空白，**允许为空**，长度 ≤ [DeviceEditDialog.maxFieldLength]。
  final String modelName;

  @override
  String toString() => 'DeviceEditResult(name=$deviceName, model=$modelName)';
}

/// 「修改当前设备」弹窗。
///
/// ## 为什么是一个独立 StatefulWidget（而不是在调用方 new 控制器）
///
/// 与 `AssetImportFormDialog` 同因：`await showDialog(...)` 在路由**开始**退场时就返回，
/// 但弹窗的 Element 要到退场动画结束才 unmount。调用方若在 `await` 之后立刻
/// `controller.dispose()`，就会在控件仍然依赖控制器时把它销毁，触发
/// `'_dependents.isEmpty': is not true.` 断言。控制器因此必须由弹窗自己的
/// State 持有（`initState` 创建 / `dispose` 销毁）。
///
/// ## 校验（需求要求"关闭前完成校验"）
///
/// | 字段 | 规则 |
/// |---|---|
/// | 设备名称 | 不能为空；长度 ≤ 128（与服务端 `DeviceUpdateRequest` 一致） |
/// | 型号备注 | 允许为空；长度 ≤ 128 |
///
/// 校验不通过时**弹窗保持打开**，并在对应输入框下方显示错误；
/// 只有校验通过才会 `Navigator.pop` 出 [DeviceEditResult]。
class DeviceEditDialog extends StatefulWidget {
  const DeviceEditDialog({
    super.key,
    this.initialDeviceName = '',
    this.initialModelName = '',
  });

  /// 与服务端 `DeviceUpdateRequest` 的 `max_length=128` 保持一致。
  static const int maxFieldLength = 128;

  final String initialDeviceName;
  final String initialModelName;

  /// 打开弹窗。取消返回 null（调用方据此不调用服务端）。
  static Future<DeviceEditResult?> show(
    BuildContext context, {
    String initialDeviceName = '',
    String initialModelName = '',
  }) =>
      showDialog<DeviceEditResult>(
        context: context,
        builder: (BuildContext ctx) => DeviceEditDialog(
          initialDeviceName: initialDeviceName,
          initialModelName: initialModelName,
        ),
      );

  @override
  State<DeviceEditDialog> createState() => _DeviceEditDialogState();
}

class _DeviceEditDialogState extends State<DeviceEditDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _model;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialDeviceName);
    _model = TextEditingController(text: widget.initialModelName);
  }

  @override
  void dispose() {
    _name.dispose();
    _model.dispose();
    super.dispose();
  }

  /// 长度按 **Unicode 码点**计数，与服务端 Python 的 `len()` 口径一致
  /// （`String.length` 数的是 UTF-16 码元，emoji 会被多算）。
  static String? _validateLength(String text, String label, {required bool required}) {
    final String trimmed = text.trim();
    if (required && trimmed.isEmpty) return '$label不能为空';
    if (trimmed.runes.length > DeviceEditDialog.maxFieldLength) {
      return '$label最多 ${DeviceEditDialog.maxFieldLength} 个字符';
    }
    return null;
  }

  void _submit() {
    // 校验失败时 **不** pop：弹窗保持打开，错误显示在对应输入框下方。
    if (!(_formKey.currentState?.validate() ?? false)) return;

    Navigator.pop(
      context,
      DeviceEditResult(
        deviceName: _name.text.trim(),
        modelName: _model.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改当前设备'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '设备名称',
                hintText: '例如：我的台式机',
              ),
              validator: (String? value) =>
                  _validateLength(value ?? '', '设备名称', required: true),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: '型号备注（可选）',
                hintText: '例如：ThinkPad X1 Carbon',
              ),
              // 允许为空：required=false。
              validator: (String? value) =>
                  _validateLength(value ?? '', '型号备注', required: false),
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
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
