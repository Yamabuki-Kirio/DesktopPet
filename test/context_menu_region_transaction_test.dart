import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/context_menu_anchor.dart';
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/region_owner.dart';

/// 回归 #A：右键菜单的 Region 事务必须"先放大、后恢复"，且异常路径也恢复。
///
/// 本轮变化：恢复不再"无条件"，而是把 [expandRegion] 返回的**凭据**交给
/// [restoreRegion]；由 `RegionCoordinator` 判断凭据是否仍然有效。
void main() {
  const RegionLease lease = RegionLease(
    transactionId: 7,
    generation: 3,
    owner: RegionOwner.contextMenu,
  );

  test('#3 正常路径：放大 → body → 恢复（顺序正确，且凭据被透传）', () async {
    final List<String> order = <String>[];
    final String result = await runContextMenuRegionTransaction<String>(
      expandRegion: () async {
        order.add('expand');
        return lease;
      },
      restoreRegion: (RegionLease l) async {
        order.add('restore:tx=${l.transactionId} gen=${l.generation}'
            ' owner=${l.owner.wireName}');
      },
      body: () async {
        order.add('body');
        return 'ok';
      },
    );

    expect(result, 'ok');
    expect(order, <String>[
      'expand',
      'body',
      'restore:tx=7 gen=3 owner=context_menu',
    ]);
  });

  test('#4 异常路径：body 抛错仍然恢复 Region（finally）', () async {
    final List<String> order = <String>[];
    await expectLater(
      runContextMenuRegionTransaction<void>(
        expandRegion: () async {
          order.add('expand');
          return lease;
        },
        restoreRegion: (RegionLease _) async => order.add('restore'),
        body: () async {
          order.add('body');
          throw StateError('showMenu 抛错 / 页面切换');
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(order, <String>['expand', 'body', 'restore']);
  });

  test('expand 抛错时不进入 body（且不吞掉异常）', () async {
    final List<String> order = <String>[];
    await expectLater(
      runContextMenuRegionTransaction<void>(
        expandRegion: () async {
          order.add('expand');
          throw StateError('Region 放大失败');
        },
        restoreRegion: (RegionLease _) async => order.add('restore'),
        body: () async => order.add('body'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(order, <String>['expand']);
  });

  test('未注入端口（null）时事务是纯 body：不写 Region，也不炸', () async {
    final List<String> order = <String>[];
    final String result = await runContextMenuRegionTransaction<String>(
      expandRegion: null,
      restoreRegion: null,
      body: () async {
        order.add('body');
        return 'ok';
      },
    );
    expect(result, 'ok');
    expect(order, <String>['body']);
  });

  test('expand 未拿到凭据（RegionLease.none）时，恢复侧拿到的是失效凭据', () async {
    RegionLease? seen;
    await runContextMenuRegionTransaction<void>(
      // 探针处于回退态 / 被更高优先级抢占 → 不返回有效凭据。
      expandRegion: () async => const RegionLease.none(),
      restoreRegion: (RegionLease l) async => seen = l,
      body: () async {},
    );
    expect(seen, isNotNull);
    expect(seen!.isValid, isFalse, reason: '失效凭据会被协调器判 dropped_stale');
  });

  group('ContextMenuBridge（切面板前主动 dismiss）', () {
    tearDown(() => contextMenuBridge.resetForTest());

    test('register → dismissAndWait 会调用 dismiss 并等待关闭', () async {
      bool dismissed = false;
      contextMenuBridge.register(dismiss: () {
        dismissed = true;
        contextMenuBridge.unregister();
      });
      expect(contextMenuBridge.isOpen, isTrue);

      await contextMenuBridge.dismissAndWait();

      expect(dismissed, isTrue);
      expect(contextMenuBridge.isOpen, isFalse);
    });

    test('未打开菜单时 dismissAndWait 是安全的空操作', () async {
      await contextMenuBridge.dismissAndWait();
      expect(contextMenuBridge.isOpen, isFalse);
    });
  });
}
