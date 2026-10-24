import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 在测试宿主里没有平台实现：mock 一个临时目录。
  final Directory fakeSupport =
      Directory.systemTemp.createTempSync('petlife_gate_support_');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return fakeSupport.path;
        }
        return null;
      },
    );
  });
  tearDownAll(() {
    try {
      fakeSupport.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    AppPaths.resetForTest();
    AppPaths.environmentReaderForTest = () => null;
  });

  tearDown(() {
    AppPaths.environmentReaderForTest = null;
    AppPaths.resetForTest();
  });

  group('PETLIFE_DATA_ROOT 验收模式门控（交付审查修正 #1）', () {
    test('正式运行（无 --acceptance）：环境变量被忽略，使用默认目录', () async {
      AppPaths.environmentReaderForTest =
          () => r'C:\Users\nobody\petlife_env_dir';
      StorageAcceptanceMode.parseFromArgs(<String>[]);

      final String described =
          await AppPaths.describeDataRoot(); // 不能抛 plugin 异常才能取到真实口径

      expect(StorageAcceptanceMode.enabled, isFalse);
      expect(described, isNot(contains('petlife_env_dir')));
    });

    test('--acceptance 模式：环境变量沙箱生效', () async {
      StorageAcceptanceMode.parseFromArgs(<String>['--acceptance']);
      AppPaths.environmentReaderForTest =
          () => r'C:\Users\nobody\petlife_env_dir';

      final String described = await AppPaths.describeDataRoot();

      expect(StorageAcceptanceMode.enabled, isTrue);
      expect(described, r'C:\Users\nobody\petlife_env_dir');
    });

    test('--acceptance 模式但环境变量未设置：回退默认目录', () async {
      StorageAcceptanceMode.parseFromArgs(<String>['--acceptance']);
      AppPaths.environmentReaderForTest = () => null;

      final String described = await AppPaths.describeDataRoot();

      expect(described, isNot(contains('petlife_env_dir')));
    });

    test('显式 overrideRoot 优先级最高（测试装配路径不受验收开关影响）', () async {
      StorageAcceptanceMode.parseFromArgs(<String>['--acceptance']);
      AppPaths.environmentReaderForTest =
          () => r'C:\Users\nobody\petlife_env_dir';

      final String described = await AppPaths.describeDataRoot(
        overrideRoot: Directory(r'C:\tmp\explicit'),
      );

      expect(described, r'C:\tmp\explicit');
    });

    test('initialize 使用验收沙箱目录且环境变量重定向真实生效', () async {
      StorageAcceptanceMode.parseFromArgs(<String>['--acceptance']);
      final Directory envRoot =
          await Directory.systemTemp.createTemp('petlife_gate_env_');
      AppPaths.environmentReaderForTest = () => envRoot.path;
      addTearDown(() async {
        try {
          await envRoot.delete(recursive: true);
        } catch (_) {}
      });

      await AppPaths.initialize();
      expect(AppPaths.instance.root.path, envRoot.path);
    });
  });
}
