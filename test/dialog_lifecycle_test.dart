import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/ui/dialogs/asset_import_form_dialog.dart';
import 'package:petlife/ui/dialogs/device_edit_dialog.dart';
import 'package:petlife/ui/dialogs/text_input_dialog.dart';

/// 弹窗生命周期回归测试。
///
/// ## 背景（真机上真实发生过）
///
/// 素材导入弹窗与设备编辑弹窗原来都在**调用方**里 `new` 出
/// `TextEditingController`，`await showDialog(...)` 返回后立刻 `dispose()`。
/// 但 `Navigator.pop` 会**立刻**完成那个 Future，而弹窗 Element 要到**退场动画
/// 结束**才 unmount —— 于是控制器在控件仍然依赖它的时候被销毁，真机触发：
///
/// ```
/// 'package:flutter/src/widgets/framework.dart'
/// Failed assertion: line 6281 pos 12: '_dependents.isEmpty': is not true.
/// ```
///
/// 修复方式是把控制器收进**弹窗自己的 State**（`initState` 创建 / `dispose` 销毁）。
/// 这里的测试因此有两层：
///
/// 1. **组件行为**：把每种交互走一遍，并在路由退场动画跑完后断言"干干净净"
///    （无 `_dependents.isEmpty`、无"控制器已销毁后又被使用"、无
///    `setState() called after dispose()`）；
/// 2. **静态审计**：扫描 `lib/`，禁止"在调用方创建控制器 → await 弹窗 → 再 dispose"
///    这个形状再次出现（不依赖真机，也不依赖某个人记得这件事）。
void main() {
  // ---------------------------------------------------------------------------
  // 素材导入弹窗
  // ---------------------------------------------------------------------------
  group('素材导入弹窗', () {
    testWidgets('情绪名称留空 → 返回 null，交给文件名解析', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      // 三个输入框顺序：作品包 / 角色 / 情绪。
      await tester.enterText(find.byType(TextField).at(1), '绫里真宵');
      await tester.enterText(find.byType(TextField).at(2), '');
      await tester.tap(find.text('导入'));
      await _settleAndAssertClean(tester);

      expect(rec.returned, isTrue);
      expect(rec.value!.emotionName, isNull, reason: '留空必须合法，交给文件名解析');
      expect(rec.value!.characterName, '绫里真宵');
      expect(rec.value!.packName, '我的素材');
    });

    testWidgets('角色名称留空 → 返回 null，交给文件名解析', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      await tester.enterText(find.byType(TextField).at(1), '   ');
      await tester.enterText(find.byType(TextField).at(2), '开心');
      await tester.tap(find.text('导入'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.characterName, isNull);
      expect(rec.value!.emotionName, '开心');
    });

    testWidgets('作品包名称留空 → 回落到默认作品包名称', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      await tester.enterText(find.byType(TextField).at(0), '   ');
      await tester.tap(find.text('导入'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.packName, '我的素材');
    });

    testWidgets('三个字段全部填写 → 原样返回（首尾空白被裁掉）', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      await tester.enterText(find.byType(TextField).at(0), ' 逆转裁判 ');
      await tester.enterText(find.byType(TextField).at(1), '成步堂龙一 ');
      await tester.enterText(find.byType(TextField).at(2), ' 异议 ');
      await tester.tap(find.text('导入'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.packName, '逆转裁判');
      expect(rec.value!.characterName, '成步堂龙一');
      expect(rec.value!.emotionName, '异议');
      expect(rec.value!.setAsDefault, isTrue);
    });

    testWidgets('取消 → 返回 null（调用方不执行导入）', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      await tester.tap(find.text('取消'));
      await _settleAndAssertClean(tester);

      expect(rec.returned, isTrue);
      expect(rec.value, isNull, reason: '取消必须返回 null');
    });

    testWidgets('连续打开 → 取消 → 再打开 → 导入', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      await _pumpHost(tester, _AssetHost(onResult: rec.capture));

      await _openAssetDialog(tester);
      await tester.tap(find.text('取消'));
      await _settleAndAssertClean(tester);
      expect(rec.value, isNull);

      await _openAssetDialog(tester);
      await tester.enterText(find.byType(TextField).at(2), '');
      await tester.tap(find.text('导入'));
      await _settleAndAssertClean(tester);

      expect(rec.value, isNotNull);
      expect(rec.value!.emotionName, isNull);
    });

    testWidgets('弹窗退场过程中销毁父页面 → 不出现任何 FlutterError', (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      final ValueNotifier<bool> alive = await _pumpHost(
        tester,
        _AssetHost(onResult: rec.capture),
      );

      await _openAssetDialog(tester);
      await tester.tap(find.text('导入')); // pop 开始（弹窗 Future 此时就完成了）
      await tester.pump(); // 退场动画进行中，弹窗 Element 还在树上

      alive.value = false; // 父页面在退场动画期间被销毁
      await tester.pump();
      await _settleAndAssertClean(tester);

      expect(rec.returned, isTrue, reason: '结果在父页面销毁之前就已经交付');
    });

    testWidgets('父页面先被销毁、弹窗随后关闭 → 调用方不在已销毁的页面上做任何事',
        (WidgetTester tester) async {
      final _Recorder<AssetImportForm> rec = _Recorder<AssetImportForm>();
      final ValueNotifier<bool> alive = await _pumpHost(
        tester,
        _AssetHost(onResult: rec.capture),
      );

      await _openAssetDialog(tester);
      alive.value = false; // 弹窗还开着，父页面先没了
      await tester.pump();
      expect(
        find.byType(AssetImportFormDialog),
        findsOneWidget,
        reason: '弹窗挂在 Navigator 的 Overlay 上，父页面销毁不会带走它',
      );

      await tester.tap(find.text('导入')); // 关闭弹窗 → 调用方 await 恢复时 mounted == false
      await _settleAndAssertClean(tester);

      expect(
        rec.returned,
        isFalse,
        reason: 'mounted 保护：页面已销毁就不该再 setState / 回调（否则会 '
            '"setState() called after dispose()"）',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 设备编辑弹窗
  // ---------------------------------------------------------------------------
  group('设备编辑弹窗', () {
    testWidgets('修改设备名称后保存', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).first, '书房台式机');
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.deviceName, '书房台式机');
      expect(rec.value!.modelName, '旧型号');
    });

    testWidgets('修改型号备注后保存', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).at(1), 'ThinkPad X1 Carbon');
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.deviceName, '旧名称');
      expect(rec.value!.modelName, 'ThinkPad X1 Carbon');
    });

    testWidgets('型号备注留空 → 允许保存（为空是合法输入）', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).at(1), '   ');
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.modelName, '');
      expect(rec.value!.deviceName, '旧名称');
    });

    testWidgets('设备名称留空 → 显示校验错误，弹窗不关闭', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).first, '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('设备名称不能为空'), findsOneWidget);
      expect(find.byType(DeviceEditDialog), findsOneWidget, reason: '校验失败时弹窗必须保持打开');
      expect(rec.returned, isFalse, reason: '校验不通过就不该产生结果');
    });

    testWidgets('设备名称超过 128 字符 → 显示校验错误，弹窗不关闭；正好 128 字符可以保存',
        (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).first, 'a' * 129);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('设备名称最多 128 个字符'), findsOneWidget);
      expect(find.byType(DeviceEditDialog), findsOneWidget);
      expect(rec.returned, isFalse);

      // 边界：正好 128 字符应当可以保存。
      await tester.enterText(find.byType(TextFormField).first, 'a' * 128);
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.deviceName.length, 128);
    });

    testWidgets('型号备注超过 128 字符 → 显示校验错误，弹窗不关闭', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.enterText(find.byType(TextFormField).at(1), 'b' * 129);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('型号备注最多 128 个字符'), findsOneWidget);
      expect(find.byType(DeviceEditDialog), findsOneWidget);
      expect(rec.returned, isFalse);
    });

    testWidgets('取消编辑 → 返回 null（调用方不调用服务端）', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.tap(find.text('取消'));
      await _settleAndAssertClean(tester);

      expect(rec.returned, isTrue);
      expect(rec.value, isNull);
    });

    testWidgets('连续打开 → 取消 → 再打开 → 保存', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      await _pumpHost(tester, _DeviceHost(onResult: rec.capture));

      await _openDeviceDialog(tester);
      await tester.tap(find.text('取消'));
      await _settleAndAssertClean(tester);
      expect(rec.value, isNull);

      await _openDeviceDialog(tester);
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(rec.value!.deviceName, '旧名称');
    });

    testWidgets('弹窗退场过程中销毁父页面 → 不出现任何 FlutterError', (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      final ValueNotifier<bool> alive = await _pumpHost(
        tester,
        _DeviceHost(onResult: rec.capture),
      );

      await _openDeviceDialog(tester);
      await tester.tap(find.text('保存')); // pop 开始
      await tester.pump(); // 退场动画进行中

      alive.value = false; // 父页面在退场动画期间被销毁
      await tester.pump();
      await _settleAndAssertClean(tester);

      expect(rec.returned, isTrue, reason: '结果在父页面销毁之前就已经交付');
    });

    testWidgets('父页面先被销毁、弹窗随后关闭 → 调用方不在已销毁的页面上做任何事',
        (WidgetTester tester) async {
      final _Recorder<DeviceEditResult> rec = _Recorder<DeviceEditResult>();
      final ValueNotifier<bool> alive = await _pumpHost(
        tester,
        _DeviceHost(onResult: rec.capture),
      );

      await _openDeviceDialog(tester);
      alive.value = false;
      await tester.pump();
      expect(find.byType(DeviceEditDialog), findsOneWidget);

      await tester.tap(find.text('保存')); // 关闭弹窗 → 调用方 await 恢复时 mounted == false
      await _settleAndAssertClean(tester);

      expect(
        rec.returned,
        isFalse,
        reason: 'mounted 保护：页面已销毁就不该再 setState / 回调',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 通用文本输入弹窗（审计时发现的同类写法）
  // ---------------------------------------------------------------------------
  group('通用文本输入弹窗', () {
    testWidgets('确认返回原文，调用方自己 trim', (WidgetTester tester) async {
      String? captured;
      bool returned = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => ElevatedButton(
              onPressed: () async {
                captured = await TextInputDialog.show(
                  ctx,
                  title: '修改显示名称',
                  initialText: '旧名字',
                );
                returned = true;
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), ' 新名字 ');
      await tester.tap(find.text('保存'));
      await _settleAndAssertClean(tester);

      expect(returned, isTrue);
      expect(captured, ' 新名字 ');
    });

    testWidgets('取消 → 返回 null', (WidgetTester tester) async {
      String? captured = 'sentinel';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => ElevatedButton(
              onPressed: () async {
                captured = await TextInputDialog.show(ctx, title: '改名');
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await _settleAndAssertClean(tester);

      expect(captured, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 静态审计：禁止"调用方创建控制器 → await 弹窗 → 再 dispose"
  // ---------------------------------------------------------------------------
  group('静态审计（不依赖真机）', () {
    test('审计器本身有效：能识别旧写法，且不误报 State 字段的写法', () {
      // 改造前的真实形状。
      const String legacy = '''
class _Legacy {
  Future<void> ask() async {
    final TextEditingController name = TextEditingController();
    final bool? saved = await showDialog<bool>(context: context, builder: _b);
    name.dispose();
  }
}
''';
      expect(
        findDialogControllerViolations(legacy, 'legacy.dart'),
        isNotEmpty,
        reason: '审计器认不出旧写法，这组断言就是空跑',
      );

      // 正确写法：控制器是 State 字段，随 State 一起销毁。
      const String proper = '''
class _Proper extends State<X> {
  final TextEditingController _name = TextEditingController();
  Future<void> ask() async {
    await showDialog<void>(context: context, builder: _b);
  }
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}
''';
      expect(
        findDialogControllerViolations(proper, 'proper.dart'),
        isEmpty,
        reason: 'State 字段形式的控制器是正确写法，不该被误报',
      );
    });

    test('lib/ 下不存在"在调用方创建控制器、弹窗返回后再 dispose"的写法', () {
      final Directory lib = Directory(p.join(Directory.current.path, 'lib'));
      final List<String> violations = <String>[];

      for (final File file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final String relative = p.relative(file.path).replaceAll('\\', '/');
        violations.addAll(
          findDialogControllerViolations(file.readAsStringSync(), relative),
        );
      }

      expect(
        violations,
        isEmpty,
        reason: '这就是真机上 `_dependents.isEmpty` 崩溃的形状：\n'
            'await showDialog 在路由**开始**退场时就返回，而弹窗 Element 要到退场动画结束\n'
            '才 unmount。调用方在那之后 dispose 控制器，等于把仍在使用的控制器销毁。\n'
            '请把控制器收进弹窗自己的 State（initState 创建 / dispose 销毁）：\n'
            '${violations.join('\n')}',
      );
    });
  });
}

/// 找出"在调用方创建控制器 → await 弹窗 → 再 dispose"这一形状。
///
/// 判定规则：同一文件里，某控制器**以局部变量**（缩进 > 2）形式声明，
/// 之后出现 `showDialog` / `showModalBottomSheet`，再之后才 `.dispose()`。
///
/// * State 字段（缩进 2 空格）+ 在 `State.dispose()` 里销毁 —— 正确写法，不报；
/// * 声明 → 弹窗 → 销毁 的先后顺序必须成立，避免误伤无关的局部控制器。
List<String> findDialogControllerViolations(String source, String label) {
  final List<String> violations = <String>[];

  // 只匹配**行首空白 + 可选 final + 类型 + 名字**。
  // 这里必须用 [ \t]* 而不是 \s*：\s 能匹配换行，会把类成员误判成局部变量。
  final RegExp declaration = RegExp(
    r'^([ \t]*)(?:(?:final|late\s+final)\s+)?(TextEditingController|FocusNode)\s+(\w+)',
    multiLine: true,
  );
  final RegExp dialogCall = RegExp(r'showDialog|showModalBottomSheet');

  int lineOf(String text, int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;

  for (final RegExpMatch decl in declaration.allMatches(source)) {
    if (decl.group(1)!.length <= 2) continue; // 类成员（State 字段）跳过
    final String name = decl.group(3)!;
    final int declLine = lineOf(source, decl.start);

    final List<int> disposeLines =
        RegExp('\\b${RegExp.escape(name)}\\.dispose\\(\\)')
            .allMatches(source)
            .map((RegExpMatch m) => lineOf(source, m.start))
            .where((int l) => l > declLine)
            .toList();
    if (disposeLines.isEmpty) continue;

    final int disposeLine = disposeLines.first;
    final bool dialogBetween = dialogCall
        .allMatches(source)
        .map((RegExpMatch m) => lineOf(source, m.start))
        .any((int l) => l > declLine && l < disposeLine);

    if (dialogBetween) {
      violations.add(
        '$label:$declLine 声明 $name → 第 $declLine~$disposeLine 行之间调用了弹窗 → '
        '第 $disposeLine 行 dispose',
      );
    }
  }

  return violations;
}

// -----------------------------------------------------------------------------
// 测试脚手架
// -----------------------------------------------------------------------------

/// 记录弹窗返回值。
class _Recorder<T> {
  bool returned = false;
  T? value;

  void capture(T? result) {
    returned = true;
    value = result;
  }
}

/// 把宿主页面包进可切换的 [MaterialApp]：把 [alive] 置为 false 就能模拟
/// "弹窗还在退场、父页面已经被销毁"。
///
/// 注意 [MaterialApp] 本身留在原位（同一个 Element），所以**弹窗路由仍然存活**，
/// 这正好复现真机上那个时间窗。
Future<ValueNotifier<bool>> _pumpHost(WidgetTester tester, Widget host) async {
  final ValueNotifier<bool> alive = ValueNotifier<bool>(true);
  await tester.pumpWidget(
    ValueListenableBuilder<bool>(
      valueListenable: alive,
      builder: (BuildContext _, bool show, Widget? __) =>
          MaterialApp(home: show ? host : const SizedBox.shrink()),
    ),
  );
  return alive;
}

Future<void> _openAssetDialog(WidgetTester tester) async {
  await tester.tap(find.text('打开导入弹窗'));
  await tester.pumpAndSettle();
  expect(find.byType(AssetImportFormDialog), findsOneWidget);
}

Future<void> _openDeviceDialog(WidgetTester tester) async {
  await tester.tap(find.text('打开设备弹窗'));
  await tester.pumpAndSettle();
  expect(find.byType(DeviceEditDialog), findsOneWidget);
}

/// 跑完路由退场动画，并断言"干干净净"。
///
/// * `_dependents.isEmpty` / 控制器已销毁后又被使用 / `setState() called after dispose()`
///   都会以 FlutterError（断言）的形式抛出来 → `takeException()` 非 null；
/// * `transientCallbackCount != 0` 表示还有动画没跑完；
/// * 测试结束时若仍有 pending Timer，`testWidgets` 自己会失败。
Future<void> _settleAndAssertClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: '弹窗关闭过程中不应出现任何 FlutterError（含 _dependents.isEmpty 断言）',
  );
  expect(
    tester.binding.transientCallbackCount,
    0,
    reason: '不应留下未完成的动画',
  );
}

/// 复刻素材库页面的用法：只 await 结果，自己完全不碰控制器。
class _AssetHost extends StatefulWidget {
  const _AssetHost({this.onResult});

  final ValueChanged<AssetImportForm?>? onResult;

  @override
  State<_AssetHost> createState() => _AssetHostState();
}

class _AssetHostState extends State<_AssetHost> {
  int _delivered = 0;

  Future<void> _open() async {
    final AssetImportForm? form = await AssetImportFormDialog.show(
      context,
      count: 1,
      fallbackPackName: '我的素材',
      initialPackName: '我的素材',
    );
    // 与生产代码一致：先确认还挂在树上，再碰 State。
    // 少了这一句，页面在弹窗返回前被销毁就会 "setState() called after dispose()"。
    if (!mounted) return;
    setState(() => _delivered++);
    widget.onResult?.call(form);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ElevatedButton(
                onPressed: _open,
                child: const Text('打开导入弹窗'),
              ),
              Text('已收到结果 $_delivered 次'),
            ],
          ),
        ),
      );
}

/// 复刻账户与同步页面的用法。
class _DeviceHost extends StatefulWidget {
  const _DeviceHost({this.onResult});

  final ValueChanged<DeviceEditResult?>? onResult;

  @override
  State<_DeviceHost> createState() => _DeviceHostState();
}

class _DeviceHostState extends State<_DeviceHost> {
  int _delivered = 0;

  Future<void> _open() async {
    final DeviceEditResult? result = await DeviceEditDialog.show(
      context,
      initialDeviceName: '旧名称',
      initialModelName: '旧型号',
    );
    // 与生产代码一致：先确认还挂在树上，再碰 State。
    if (!mounted) return;
    setState(() => _delivered++);
    widget.onResult?.call(result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ElevatedButton(
                onPressed: _open,
                child: const Text('打开设备弹窗'),
              ),
              Text('已收到结果 $_delivered 次'),
            ],
          ),
        ),
      );
}
