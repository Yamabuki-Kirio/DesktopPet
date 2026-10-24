import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/core/app_exit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShutdownCoordinator（统一退出事务，规格§二）', () {
    test('事务只执行一次：顺序重复触发不重入', () async {
      final ShutdownCoordinator coordinator = ShutdownCoordinator();
      int runs = 0;

      await coordinator.run('tray.exit', () async {
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await coordinator.run('panel.exit', () async {
        runs++;
      });

      expect(runs, 1, reason: '第二次触发必须等待同一次事务而不是再跑一遍');
      expect(coordinator.isShutdownStarted, isTrue);
    });

    test('并发触发只执行一次且全部等待同一次完成', () async {
      final ShutdownCoordinator coordinator = ShutdownCoordinator();
      int runs = 0;

      final List<Future<void>> pending = <Future<void>>[];
      final Future<void> a = coordinator.run('a', () async {
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      final Future<void> b = coordinator.run('b', () async {
        runs++;
      });
      pending
        ..add(a)
        ..add(b);
      await Future.wait<void>(pending);

      expect(runs, 1);
    });

    test('事务抛异常被吞掉且事务仍视为完成', () async {
      final ShutdownCoordinator coordinator = ShutdownCoordinator();
      int runs = 0;

      await coordinator.run('window.close', () async {
        runs++;
        throw StateError('清理失败');
      });

      expect(runs, 1, reason: '退出路径不能被清理失败卡住');
    });

    test('看门狗超时强制结束并只记录一次', () async {
      bool forced = false;
      final ShutdownCoordinator coordinator = ShutdownCoordinator(
        watchdogTimeout: const Duration(milliseconds: 50),
        onForceExit: () => forced = true,
      );

      // 永不完成的事务：只有看门狗能结束它。
      final Future<void> never = coordinator.run('system', () async {
        await Completer<void>().future;
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(forced, isTrue, reason: '超时必须强制结束，不产生后台常驻副本');
      // 看门狗已 complete，run 返回的 future 可完成。
      await never;
    });
  });
}
