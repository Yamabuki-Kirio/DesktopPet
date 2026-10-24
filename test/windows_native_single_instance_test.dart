import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Runner 单实例协调器的源码级固化测试（规格§一/§六）。
///
/// 真实进程行为（20 连启 / 唤醒 / 退出归零）由
/// `tool/acceptance_single_instance.ps1` 在真机上验证，这里固化结构不变量。
void main() {
  final String mainCpp =
      File('windows/runner/main.cpp').readAsStringSync();
  final String coordinator =
      File('windows/runner/single_instance_coordinator.cpp').readAsStringSync();
  final String coordinatorHeader =
      File('windows/runner/single_instance_coordinator.h').readAsStringSync();
  final String flutterWindow =
      File('windows/runner/flutter_window.cpp').readAsStringSync();
  final String manifest =
      File('windows/runner/runner.exe.manifest').readAsStringSync();
  final String platformSource = File(
    'lib/platform/windows/windows_platform_services.dart',
  ).readAsStringSync();

  test('仲裁在 Flutter 引擎与窗口创建之前完成（wWinMain 最先执行）', () {
    final int gate = mainCpp.indexOf('AcquireOrAct');
    final int sink = mainCpp.indexOf('CreateSinkWindow');
    final int dartProject = mainCpp.indexOf('flutter::DartProject project');
    final int windowCreate = mainCpp.indexOf('window.Create(');

    expect(gate, greaterThanOrEqualTo(0));
    expect(sink, greaterThan(gate), reason: '接收窗口必须在引擎创建之前建立');
    expect(sink, lessThan(dartProject));
    expect(gate, lessThan(windowCreate));
  });

  test('互斥体使用规格指定的名称且为进程级存在标记', () {
    expect(coordinator,
        contains(r"Local\\PetLife.Desktop.SingleInstance.v1"));
    // 进程级存在标记：不取得线程所有权，异常退出由 Windows 自动销毁。
    expect(coordinator, contains('CreateMutexW(nullptr, FALSE'));
    expect(coordinator, contains('ERROR_ALREADY_EXISTS'));
    expect(coordinator, contains('ERROR_ACCESS_DENIED'));
  });

  test('第二实例不启动第二套引擎：仲裁失败立即 return', () {
    final int branch = mainCpp.indexOf('!=\n      petlife::SecondInstanceDecision::kPrimary');
    expect(branch, greaterThan(-1),
        reason: '非主实例必须立即返回，不初始化 Flutter/SQLite/托盘');
    expect(mainCpp, contains('second_instance_exit_code()'));
  });

  test('第二实例通过消息窗口通知主实例并以超时探测无响应', () {
    expect(coordinator, contains('SendMessageTimeoutW'));
    expect(coordinator, contains('SMTO_ABORTIFHUNG'));
    expect(coordinator, contains('FindWindowExW'));
    expect(coordinator, contains('PetLifeSingleInstanceSink'));
    expect(coordinator, contains('已在运行但暂时无响应'));
  });

  test('主实例退出中：等待互斥体释放后提示重试，不重启第二套数据库', () {
    expect(coordinator, contains('Local\\\\PetLife.Desktop.ShuttingDown.v1'));
    expect(coordinator, contains('WaitForPrimaryExitThenPrompt'));
    expect(coordinator, contains('正在退出，请稍后重新启动'));
  });

  test('主实例经生命周期通道把第二实例信号转发给 Dart', () {
    expect(flutterWindow, contains('asia.akechi.petlife/app_lifecycle'));
    expect(flutterWindow, contains('onSecondInstance'));
    expect(flutterWindow, contains('onExitRequested'));
    // 系统注销 / 关机：先通知 Dart 落盘，再泵等待（≤3s）。
    expect(flutterWindow, contains('WM_QUERYENDSESSION'));
    expect(flutterWindow, contains('WM_ENDSESSION'));
    expect(flutterWindow, contains('PumpUntilShutdownComplete'));
  });

  test('协调器释放顺序：消息窗口先于互斥体销毁', () {
    final int destroySink = mainCpp.indexOf('DestroySinkWindow()');
    final int release = mainCpp.indexOf('ReleasePrimaryLock()');
    expect(destroySink, greaterThan(-1));
    expect(release, greaterThan(destroySink));
  });

  test('manifest 固定 asInvoker（规格§三：不申请管理员权限）', () {
    expect(manifest, contains('requestedExecutionLevel level="asInvoker"'));
    expect(manifest, isNot(contains('requireAdministrator')));
    expect(manifest, isNot(contains('highestAvailable')));
  });

  test('协调器接口提供唤醒/退出处理器与退出协作标记', () {
    expect(coordinatorHeader, contains('SetWakeHandler'));
    expect(coordinatorHeader, contains('SetShutdownRequestHandler'));
    expect(coordinatorHeader, contains('MarkShuttingDown'));
    expect(coordinatorHeader, contains('MarkShutdownComplete'));
    expect(coordinatorHeader, contains('HasShutdownSwitch'));
  });

  test('Dart 启动不再使用线程所有权的互斥体守卫', () {
    expect(platformSource, isNot(contains('WindowsSingleInstanceGuard')));
    expect(platformSource,
        isNot(contains("import 'windows_single_instance.dart'")));
  });
}
