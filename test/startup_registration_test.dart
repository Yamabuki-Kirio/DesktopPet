import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/platform/android/android_platform_services.dart';
import 'package:petlife/platform/startup_registrar.dart';
import 'package:petlife/platform/windows/windows_platform_services.dart';
import 'package:petlife/platform/windows/windows_startup_registrar.dart';
import 'package:petlife/settings/app_settings.dart';
import 'package:petlife/settings/settings_controller.dart';
import 'package:petlife/settings/settings_repository.dart';
import 'package:petlife/settings/startup_registration_service.dart';
import 'package:petlife/ui/pages/settings_page.dart';

/// 开机自启（Windows 专属能力）。
///
/// 覆盖需求里点名的五类测试：**注册**、**删除**、**路径引号**、
/// **失败回滚**、**平台隔离**，外加一条端到端：
/// 「注册表往返」用例真的往 `HKCU\...\Run` 写一个**测试专用值名**，
/// 从而验证手写的 FFI 绑定（含中文路径的 `REG_SZ` 字节长度计算）是对的，
/// 用完立刻删掉，不碰用户真实的 `PetLife` 值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 路径引号（纯函数，任何平台都能跑）
  // ---------------------------------------------------------------------------
  group('启动命令的引号处理', () {
    test('含空格的路径必须加引号（否则 Windows 会按第一个空格切分命令）', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'C:\Program Files\PetLife\petlife.exe'),
        r'"C:\Program Files\PetLife\petlife.exe"',
      );
    });

    test('中文 + 空格 + 括号的路径同样加引号', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'D:\软件 目录\宠物 PetLife (v2)\petlife.exe'),
        r'"D:\软件 目录\宠物 PetLife (v2)\petlife.exe"',
      );
    });

    test('无空格路径也统一加引号（避免"有的机器行有的机器不行"）', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'C:\PetLife\petlife.exe'),
        r'"C:\PetLife\petlife.exe"',
      );
    });

    test('UNC 路径视为绝对路径', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'\\NAS\share\PetLife\petlife.exe'),
        r'"\\NAS\share\PetLife\petlife.exe"',
      );
    });

    test('首尾空白被裁掉', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'  C:\PetLife\petlife.exe  '),
        r'"C:\PetLife\petlife.exe"',
      );
    });

    test('已经带引号的路径不会被二次包裹', () {
      expect(
        WindowsStartupRegistrar.buildCommand(r'"C:\PetLife\petlife.exe"'),
        r'"C:\PetLife\petlife.exe"',
      );
    });

    test('空路径被明确拒绝', () {
      expect(
        () => WindowsStartupRegistrar.buildCommand('   '),
        throwsA(isA<StartupRegistrationException>()),
      );
    });

    test('相对路径被明确拒绝（写进 Run 项会导致"注册成功但启动不了"）', () {
      expect(
        () => WindowsStartupRegistrar.buildCommand(r'build\petlife.exe'),
        throwsA(
          isA<StartupRegistrationException>().having(
            (StartupRegistrationException e) => e.message,
            'message',
            contains('不是绝对路径'),
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 真实注册表往返（仅 Windows；用测试专用值名，测完立刻清理）
  // ---------------------------------------------------------------------------
  group('注册表往返（真实 HKCU Run）', () {
    // 刻意不叫 PetLife：绝不能碰用户真实的启动项。
    const String testValueName = 'PetLife__test__do_not_use';
    const WindowsStartupRegistrar registrar =
        WindowsStartupRegistrar(valueName: testValueName);
    setUp(() {
      if (registrar.isSupported) registrar.disable();
    });

    tearDown(() {
      if (registrar.isSupported) registrar.disable();
    });

    test('未注册时读回 null', () {
      expect(registrar.isSupported, isTrue, reason: 'Windows 上 advapi32.dll 必须可用');
      expect(registrar.registeredCommand(), isNull);
    });

    test('注册后读回同一命令；重复注册幂等', () {
      const String path = r'C:\PetLife\petlife.exe';
      registrar.enable(path);
      expect(registrar.registeredCommand(), '"$path"');

      registrar.enable(path);
      expect(registrar.registeredCommand(), '"$path"', reason: '覆盖写，不应产生第二条');
    });

    test('中文 + 空格路径能正确往返（验证 REG_SZ 的字节长度算法）', () {
      const String path = r'D:\软件 目录\宠物 PetLife\petlife.exe';
      registrar.enable(path);
      expect(
        registrar.registeredCommand(),
        '"$path"',
        reason: 'UTF-16 字节长度算错会写出截断的字符串',
      );
    });

    test('再次注册不同路径会覆盖为新路径（exe 被移动的场景）', () {
      registrar.enable(r'C:\Old Place\petlife.exe');
      registrar.enable(r'C:\New Place\petlife.exe');
      expect(registrar.registeredCommand(), r'"C:\New Place\petlife.exe"');
    });

    test('删除后读回 null，且重复删除不抛（幂等）', () {
      registrar.enable(r'C:\PetLife\petlife.exe');
      registrar.disable();
      expect(registrar.registeredCommand(), isNull);
      registrar.disable();
      expect(registrar.registeredCommand(), isNull);
    });

    test('值名与注册表子键符合需求约定', () {
      expect(WindowsStartupRegistrar.defaultValueName, 'PetLife');
      expect(
        WindowsStartupRegistrar.runKeyPath,
        r'Software\Microsoft\Windows\CurrentVersion\Run',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 开关逻辑：系统实况为准 + 失败回滚
  // ---------------------------------------------------------------------------
  group('开关逻辑（系统实况为准 / 失败回滚）', () {
    test('开启成功：注册表里有值，偏好被写成 true', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar();
      final _Harness h = await _Harness.create(registrar: registrar);

      await h.service.setEnabled(true);

      expect(registrar.command, '"${h.executable}"');
      expect(registrar.enableCalls, <String>[h.executable]);
      expect(h.settings.settings.launchAtStartup, isTrue);
      expect(h.service.isRegistered(), isTrue);
    });

    test('关闭成功：注册表里没有值，偏好被写成 false', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar()
        ..command = r'"C:\PetLife\petlife.exe"';
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await h.service.setEnabled(false);

      expect(registrar.command, isNull);
      expect(h.settings.settings.launchAtStartup, isFalse);
      expect(h.service.isRegistered(), isFalse);
    });

    test('开启失败：抛明确异常，且偏好**保持不变**（不能假装成功）', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar(failOnEnable: true);
      final _Harness h = await _Harness.create(registrar: registrar);

      await expectLater(
        h.service.setEnabled(true),
        throwsA(isA<StartupRegistrationException>()),
      );

      expect(h.settings.settings.launchAtStartup, isFalse, reason: '注册失败不能写偏好');
      expect(h.service.isRegistered(), isFalse);
    });

    test('关闭失败：抛异常，偏好仍为 true', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar(failOnDisable: true)
        ..command = r'"C:\PetLife\petlife.exe"';
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await expectLater(
        h.service.setEnabled(false),
        throwsA(isA<StartupRegistrationException>()),
      );

      expect(h.settings.settings.launchAtStartup, isTrue);
      expect(h.service.isRegistered(), isTrue, reason: '删除失败，系统里仍然有');
    });

    test('开关状态读系统而不是偏好：偏好 true 但注册表为空时显示未注册', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar();
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      expect(h.settings.settings.launchAtStartup, isTrue);
      expect(h.service.isRegistered(), isFalse,
          reason: '用户可能在 regedit / 任务管理器里手工删掉了启动项');
    });

    test('注册表读失败时不崩，按未注册处理', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar(failOnRead: true);
      final _Harness h = await _Harness.create(registrar: registrar);

      expect(h.service.isRegistered(), isFalse);
      expect(h.service.registeredCommandOrNull(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 启动对齐（需求 7）
  // ---------------------------------------------------------------------------
  group('启动对齐 reconcileOnStartup', () {
    test('偏好开启时按当前 exe 注册（首次开启后重启也能自愈）', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar();
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await h.service.reconcileOnStartup();

      expect(registrar.command, '"${h.executable}"');
      expect(h.settings.settings.launchAtStartup, isTrue);
    });

    test('发布目录被移动后，启动时把注册表路径更新到新位置', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar()
        ..command = r'"C:\Old Place\petlife.exe"';
      final _Harness h = await _Harness.create(
        registrar: registrar,
        preferred: true,
        executable: r'C:\New Place\petlife.exe',
      );

      await h.service.reconcileOnStartup();

      expect(registrar.command, r'"C:\New Place\petlife.exe"');
    });

    test('偏好关闭时不写注册表', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar();
      final _Harness h = await _Harness.create(registrar: registrar);

      await h.service.reconcileOnStartup();

      expect(registrar.enableCalls, isEmpty);
      expect(registrar.command, isNull);
    });

    test('偏好关闭但系统里有条目：以系统实况为准，把偏好校正为 true', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar()
        ..command = r'"C:\PetLife\petlife.exe"';
      final _Harness h = await _Harness.create(registrar: registrar);

      await h.service.reconcileOnStartup();

      expect(h.settings.settings.launchAtStartup, isTrue);
    });

    test('注册失败时偏好被校正为 false（不留下撒谎的 true）', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar(failOnEnable: true);
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await h.service.reconcileOnStartup();

      expect(h.settings.settings.launchAtStartup, isFalse);
      expect(h.service.isRegistered(), isFalse);
    });

    test('不支持开机自启的平台：对齐是空操作（不碰注册表、不改偏好）', () async {
      final _FakeStartupRegistrar registrar =
          _FakeStartupRegistrar(isSupported: false);
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await h.service.reconcileOnStartup();

      expect(registrar.enableCalls, isEmpty);
      expect(h.settings.settings.launchAtStartup, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 恢复默认设置（需求 9）
  // ---------------------------------------------------------------------------
  group('恢复默认设置', () {
    test('removeForReset 会删除系统启动项', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar()
        ..command = r'"C:\PetLife\petlife.exe"';
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await h.service.removeForReset();

      expect(registrar.command, isNull);
    });

    test('删除失败时把原因抛给调用方（便于提示用户）', () async {
      final _FakeStartupRegistrar registrar = _FakeStartupRegistrar(failOnDisable: true)
        ..command = r'"C:\PetLife\petlife.exe"';
      final _Harness h = await _Harness.create(registrar: registrar, preferred: true);

      await expectLater(
        h.service.removeForReset(),
        throwsA(isA<StartupRegistrationException>()),
      );
    });

    test('不支持开机自启的平台：removeForReset 静默返回，不抛', () async {
      final _FakeStartupRegistrar registrar =
          _FakeStartupRegistrar(isSupported: false);
      final _Harness h = await _Harness.create(registrar: registrar);

      await h.service.removeForReset();
    });
  });

  // ---------------------------------------------------------------------------
  // 平台隔离（需求 1、10）
  // ---------------------------------------------------------------------------
  group('平台隔离', () {
    test('Android：能力表关闭开机自启，装配给出"不支持"实现', () {
      final AndroidPlatformServices android = AndroidPlatformServices();

      expect(android.capabilities.supportsLaunchAtStartup, isFalse);
      expect(android.startupRegistrar.isSupported, isFalse);
      expect(android.startupRegistrar, isA<UnsupportedStartupRegistrar>());
    });

    test('Windows：能力表开启开机自启，装配给出真实实现', () {
      final WindowsPlatformServices windows = WindowsPlatformServices();

      expect(windows.capabilities.supportsLaunchAtStartup, isTrue);
      expect(windows.startupRegistrar.isSupported, isTrue);
      expect(windows.startupRegistrar, isA<WindowsStartupRegistrar>());
    });

    test('生产装配使用固定的值名 PetLife（在任务管理器里可辨认）', () {
      final StartupRegistrar registrar = WindowsPlatformServices().startupRegistrar;

      expect(
        (registrar as WindowsStartupRegistrar).valueName,
        'PetLife',
        reason: '需求要求启动项名称固定为 PetLife',
      );
    });

    test('不支持实现的读写行为明确（不会静默"假装成功"）', () {
      const UnsupportedStartupRegistrar registrar = UnsupportedStartupRegistrar();

      expect(registrar.registeredCommand(), isNull);
      expect(
        () => registrar.enable(r'C:\PetLife\petlife.exe'),
        throwsA(
          isA<StartupRegistrationException>().having(
            (StartupRegistrationException e) => e.message,
            'message',
            contains('仅 Windows 提供'),
          ),
        ),
      );
      expect(() => registrar.disable(), throwsA(isA<StartupRegistrationException>()));
    });

    test('不支持平台上调用 setEnabled 会抛，而不是悄悄写偏好', () async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar(isSupported: false),
      );

      await expectLater(
        h.service.setEnabled(true),
        throwsA(isA<StartupRegistrationException>()),
      );
      expect(h.settings.settings.launchAtStartup, isFalse);
    });

    test('设置页按能力表门控入口：StartupSwitchTile 必须在 supportsLaunchAtStartup 分支内', () {
      final String source = File(
        p.join(Directory.current.path, 'lib', 'ui', 'pages', 'settings_page.dart'),
      ).readAsStringSync();

      expect(
        RegExp(
          r'if \(services\.platform\.capabilities\.supportsLaunchAtStartup\)[\s\S]{0,200}?'
          r'StartupSwitchTile',
        ).hasMatch(source),
        isTrue,
        reason: '开关必须被能力表门控，否则 Android 上会出现一个点了就报错的入口',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 设置页开关组件（需求 6、8：状态来自系统、失败回滚并显示错误）
  // ---------------------------------------------------------------------------
  group('开机自启开关组件', () {
    Future<void> pumpTile(WidgetTester tester, StartupRegistrationService service) {
      return tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StartupSwitchTile(service: service))),
      );
    }

    bool switchValue(WidgetTester tester) =>
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

    testWidgets('初始状态来自系统实况：注册表里已注册 → 开关为开', (WidgetTester tester) async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar()..command = r'"C:\PetLife\petlife.exe"',
      );

      await pumpTile(tester, h.service);

      expect(switchValue(tester), isTrue);
      expect(find.textContaining('已注册：'), findsOneWidget);
    });

    testWidgets('初始状态来自系统实况：注册表为空 → 开关为关（即便偏好是 true）',
        (WidgetTester tester) async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar(),
        preferred: true,
      );

      await pumpTile(tester, h.service);

      expect(switchValue(tester), isFalse);
    });

    testWidgets('开启成功后开关变为开', (WidgetTester tester) async {
      final _Harness h = await _Harness.create(registrar: _FakeStartupRegistrar());
      await pumpTile(tester, h.service);
      expect(switchValue(tester), isFalse);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(switchValue(tester), isTrue);
      expect(find.textContaining('操作失败'), findsNothing);
    });

    testWidgets('开启失败：开关回滚到关闭并显示清晰错误', (WidgetTester tester) async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar(failOnEnable: true),
      );
      await pumpTile(tester, h.service);
      expect(switchValue(tester), isFalse);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(switchValue(tester), isFalse, reason: '失败必须回滚，不能假装已开启');
      expect(find.textContaining('操作失败'), findsOneWidget);
      expect(find.textContaining('模拟：注册表写入被拒绝'), findsOneWidget);
    });

    testWidgets('关闭失败：开关回滚到打开并显示错误', (WidgetTester tester) async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar(failOnDisable: true)
          ..command = r'"C:\PetLife\petlife.exe"',
      );
      await pumpTile(tester, h.service);
      expect(switchValue(tester), isTrue);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(switchValue(tester), isTrue);
      expect(find.textContaining('操作失败'), findsOneWidget);
    });

    testWidgets('「恢复默认设置」清掉启动项后，开关自动回到关闭', (WidgetTester tester) async {
      final _Harness h = await _Harness.create(
        registrar: _FakeStartupRegistrar()..command = r'"C:\PetLife\petlife.exe"',
        preferred: true,
      );
      await pumpTile(tester, h.service);
      expect(switchValue(tester), isTrue);

      // 模拟设置页的「恢复默认设置」：先重置偏好，再删启动项。
      await h.settings.resetToDefaults();
      await h.service.removeForReset();
      await tester.pumpAndSettle();

      expect(switchValue(tester), isFalse);
    });
  });
}

// -----------------------------------------------------------------------------
// 测试替身
// -----------------------------------------------------------------------------

/// 一组「设置 + 开机自启服务」的装配，省掉每个用例重复搭脚手架。
class _Harness {
  _Harness._(this.settings, this.service, this.executable);

  final SettingsController settings;
  final StartupRegistrationService service;
  final String executable;

  static const String _defaultExecutable = r'C:\PetLife\petlife.exe';

  static Future<_Harness> create({
    required _FakeStartupRegistrar registrar,
    bool preferred = false,
    String executable = _defaultExecutable,
  }) async {
    final SettingsController settings = SettingsController(
      repository: _MemorySettingsRepository(),
      ownerId: 'startup.test',
    );
    await settings.load();
    if (preferred) await settings.setLaunchAtStartup(true);

    return _Harness._(
      settings,
      StartupRegistrationService(
        registrar: registrar,
        settings: settings,
        executablePath: () => executable,
      ),
      executable,
    );
  }
}

/// 可控的假注册器：模拟注册表的值、以及读/写失败。
class _FakeStartupRegistrar implements StartupRegistrar {
  _FakeStartupRegistrar({
    this.isSupported = true,
    this.failOnEnable = false,
    this.failOnDisable = false,
    this.failOnRead = false,
  });

  @override
  final bool isSupported;

  final bool failOnEnable;
  final bool failOnDisable;
  final bool failOnRead;

  /// 模拟注册表里的值（null = 未注册）。
  String? command;

  /// 记录每次 enable 收到的路径（用于断言"用的是当前 exe"）。
  final List<String> enableCalls = <String>[];

  @override
  String? registeredCommand() {
    if (failOnRead) throw const StartupRegistrationException('模拟：读取注册表失败');
    return command;
  }

  @override
  void enable(String executablePath) {
    enableCalls.add(executablePath);
    if (failOnEnable) throw const StartupRegistrationException('模拟：注册表写入被拒绝');
    command = '"$executablePath"';
  }

  @override
  void disable() {
    if (failOnDisable) throw const StartupRegistrationException('模拟：删除启动项失败');
    command = null;
  }
}

/// 内存版设置仓储（不碰 SQLite）。
class _MemorySettingsRepository implements SettingsRepository {
  final Map<String, Map<String, String>> _byOwner = <String, Map<String, String>>{};

  @override
  Future<AppSettings> load(String ownerId) async =>
      AppSettings.fromKeyValues(_byOwner[ownerId] ?? const <String, String>{});

  @override
  Future<void> save(String ownerId, AppSettings settings) async {
    _byOwner[ownerId] = Map<String, String>.from(settings.toKeyValues());
  }

  @override
  Future<void> patch(String ownerId, Map<String, String?> values) async {
    final Map<String, String> current =
        _byOwner.putIfAbsent(ownerId, () => <String, String>{});
    values.forEach((String key, String? value) {
      if (value == null) {
        current.remove(key);
      } else {
        current[key] = value;
      }
    });
  }

  @override
  Future<void> reset(String ownerId) async {
    _byOwner.remove(ownerId);
  }
}
