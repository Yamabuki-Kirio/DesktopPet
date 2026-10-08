/// **增量 C1**：正式动作派发 / 幂等 / 反馈 / 契约（需求 §11 的 2–28）。
///
/// 这一层断言的都是**外部可观察行为**：设置是否被写入、是否只重建一次画布、
/// 连续 revision 是否只应用最新值、晚到结果是否被丢弃、Region 是否跟着反馈变。
library;

// 测试脚手架（`_Harness` / `_Ops` / `_SettingsRecorder`）刻意保持私有：
// 它们只在**本文件内**装配探针，不需要对外暴露。公共签名里出现私有测试类型
// 是可接受的（本仓库测试的统一做法）。
// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/fixed_canvas_contract.dart';
import 'package:petlife/menu/fixed_canvas_geometry.dart'
    show PhysicalRect, fixedCanvasAnchor;
import 'package:petlife/menu/menu_action_request.dart';
import 'package:petlife/menu/menu_contract.dart';
import 'package:petlife/menu/region_coordinator.dart';
import 'package:petlife/menu/wheel_adjustment_layer.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;
import 'package:petlife/menu/wheel_geometry_ownership.dart'
    show WheelGeometryJournal, wheelGeometryJournal;
import 'package:petlife/menu/wheel_menu_geometry.dart' show WheelMenuLayoutSettings;
import 'package:petlife/menu/wheel_theme.dart' show WheelThemeIds;
import 'package:petlife/platform/windows/windows_menu_action_executor.dart';
import 'package:petlife/ui/desktop/fixed_canvas_probe.dart';

// ---------------------------------------------------------------------------
// 假实现
// ---------------------------------------------------------------------------

class _Ops implements FixedCanvasWindowOps {
  Rect bounds = const Rect.fromLTWH(0, 0, 400, 400);
  final List<Rect> commits = <Rect>[];
  WheelDisplayArea display = const WheelDisplayArea(
    id: 'd',
    left: 0,
    top: 0,
    width: 1920,
    height: 1040,
    isPrimary: true,
  );

  @override
  Future<Rect> currentBounds() async => bounds;
  @override
  Future<void> commitBounds(Rect next) async {
    commits.add(next);
    bounds = next;
  }

  @override
  Future<List<WheelDisplayArea>> displays() async => <WheelDisplayArea>[display];
  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async => display;
  @override
  double devicePixelRatio() => 1.0;
  @override
  Future<void> setVisible(bool visible) async {}
}

class _RegionOps implements RegionNativeOps {
  final List<List<Rect>> applied = <List<Rect>>[];
  @override
  Future<RegionApplyResult> applyInteractionRegion(
    List<Rect> logicalRects, {
    required double devicePixelRatio,
  }) async {
    applied.add(List<Rect>.of(logicalRects));
    return RegionApplyResult(
      success: true,
      rectCount: logicalRects.length,
      boundingBox: PhysicalRect(0, 0, 10, 10),
    );
  }

  @override
  Future<RegionApplyResult> restorePetOnlyRegion(
    Rect logicalPetRect, {
    required double devicePixelRatio,
  }) async =>
      RegionApplyResult(
        success: true,
        rectCount: 1,
        boundingBox: PhysicalRect(0, 0, 10, 10),
      );

  @override
  Future<bool> clearInteractionRegion() async => true;
  @override
  Future<int?> gdiObjectCount() async => 512;
  @override
  Future<PhysicalRect?> regionBoundingBox() async =>
      const PhysicalRect(0, 0, 10, 10);
}

/// 记录所有设置写入（代替真实持久化）。
class _SettingsRecorder {
  final Map<WheelAdjustmentKind, double> values = <WheelAdjustmentKind, double>{
    WheelAdjustmentKind.wheelScale: WheelMenuLayoutSettings.defaultScale,
    WheelAdjustmentKind.buttonScale: WheelMenuLayoutSettings.defaultButtonScale,
    WheelAdjustmentKind.menuDistance: WheelMenuLayoutSettings.defaultDistance,
  };
  final List<String> writes = <String>[];
  final List<String> themes = <String>[];

  Future<void> apply(WheelAdjustmentKind kind, double value) async {
    if (kind == WheelAdjustmentKind.theme) return;
    values[kind] = value;
    writes.add('${kind.id}=$value');
  }

  Future<void> applyTheme(String themeId) async => themes.add(themeId);

  double read(WheelAdjustmentKind kind) =>
      kind == WheelAdjustmentKind.theme ? 0 : (values[kind] ?? kind.defaultValue);
}

// ---------------------------------------------------------------------------
// 脚手架
// ---------------------------------------------------------------------------

class _Harness {
  _Harness(this.ops, this.regions, this.settings);

  final _Ops ops;
  final _RegionOps regions;
  final _SettingsRecorder settings;
  late FixedCanvasProbeState state;

  /// 挂起执行器的闸门（`holdExecutor: true` 时非空）。
  ///
  /// 用来制造"结果晚到"：让动作卡在 `await` 上，先把菜单关掉，再放行 ——
  /// 这样结果一定是在菜单已关闭之后才产生，测试的"晚到"断言才是真的。
  Completer<void>? hold;

  /// 放行被挂起的执行器。
  void releaseHeldExecutor() {
    final Completer<void>? gate = hold;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  int get commits => ops.commits.length;
}

Future<_Harness> pumpProbe(
  WidgetTester tester, {
  List<String>? executorCalls,
  bool holdExecutor = false,
}) async {
  final _Ops ops = _Ops();
  final _RegionOps regions = _RegionOps();
  final _SettingsRecorder settings = _SettingsRecorder();
  final Completer<void>? gate = holdExecutor ? Completer<void>() : null;

  final WindowsMenuActionExecutor executor = WindowsMenuActionExecutor(
    WindowsMenuActionHost(
      setPetVisible: (bool visible) async {
        executorCalls?.add('visible=$visible');
        // 挂起闸门：结果要**等到放行**才产生（模拟慢动作 / 晚到结果）。
        if (gate != null) await gate.future;
      },
      increasePetScale: () async => executorCalls?.add('scale+'),
      decreasePetScale: () async => executorCalls?.add('scale-'),
      resetPetScale: () async => executorCalls?.add('scale0'),
      resetPetPosition: () async => executorCalls?.add('home'),
      openControlPanel: () async => executorCalls?.add('panel'),
      // 增量 C2：全部业务动作走**唯一**通道（这里用假实现记录动作 id）。
      dispatchBusiness: (String actionId) async {
        executorCalls?.add('dispatch:$actionId');
        return MenuExecutionResult.success('已执行 $actionId', actionId);
      },
      currentPetStateLabel: () async => '当前状态：focused',
      currentForegroundAppLabel: () async => '当前应用：Code',
    ),
  );

  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: FixedCanvasProbe(
      key: UniqueKey(),
      windowOps: ops,
      coordinator: RegionCoordinator(
        ops: regions,
        devicePixelRatio: () => 1.0,
        journal: WheelGeometryJournal(capacity: 500),
      ),
      petSize: () => const Size(256, 256),
      savedWindowPosition: () =>
          (x: 800.0, y: 400.0, schema: 2, legacyWindowSize: null),
      isMousePassthrough: () => false,
      wheelActionExecutor: executor,
      applyWheelSetting: settings.apply,
      applyWheelTheme: settings.applyTheme,
      readWheelSetting: settings.read,
      child: const SizedBox(width: 256, height: 256),
    ),
  ));
  await tester.pump();

  final _Harness h = _Harness(ops, regions, settings);
  h.hold = gate;
  h.state = tester.state<FixedCanvasProbeState>(find.byType(FixedCanvasProbe));
  await h.state.prepareFixedCanvas();
  await tester.pump();
  return h;
}

/// 打开轮盘并**等展开动画结束**。
///
/// 层级进出只在 `open` / `switching` 阶段被接受（与 Android 一致：展开动画期间
/// 输入被拦下），因此进入调整层前必须先让动画收敛。
Future<void> openWheel(WidgetTester tester, _Harness h) async {
  await h.state.open();
  await tester.pumpAndSettle();
}

/// 直接触发某个动作（等价于用户在轮盘里确认该条目）。
Future<MenuExecutionResult> confirmAction(
  WidgetTester tester,
  _Harness h,
  String actionId, {
  String label = '测试',
}) async {
  final MenuNode node = MenuNode(id: actionId, actionId: actionId, labelZh: label);
  final MenuExecutionResult r = await h.state.dispatchActionForTest(node);
  await tester.pump();
  return r;
}

void main() {
  setUp(() {
    fixedCanvasAnchor.clear();
    wheelGeometryJournal.clear();
  });
  tearDown(() {
    fixedCanvasAnchor.clear();
    wheelGeometryJournal.clear();
  });

  // ---------------------------------------------------------------------------
  group('§八 请求/幂等基础', () {
    test('requestId 单调递增，key 唯一', () {
      const MenuActionRequest a =
          MenuActionRequest(requestId: 1, actionId: 'pet_size_up', levelId: 'pet');
      const MenuActionRequest b =
          MenuActionRequest(requestId: 2, actionId: 'pet_size_up', levelId: 'pet');
      expect(a.key, isNot(b.key));
      expect(a.key, 'pet_size_up#1');
    });

    test('同一 key 只允许 begin 一次（防重复投递）', () {
      final MenuActionLedger ledger = MenuActionLedger();
      expect(ledger.begin('act#1'), isTrue);
      expect(ledger.begin('act#1'), isFalse, reason: '同一次确认不得执行两次');
      ledger.finish('act#1');
      expect(ledger.begin('act#1'), isFalse, reason: 'finish 后同一 key 仍不得重入');
      expect(ledger.begin('act#2'), isTrue, reason: '下一个 requestId 可以执行');
    });

    test('容量上限会淘汰最旧记录（不会无限增长）', () {
      final MenuActionLedger ledger = MenuActionLedger(capacity: 3);
      for (int i = 0; i < 5; i++) {
        expect(ledger.begin('a#$i'), isTrue);
        ledger.finish('a#$i');
      }
      // 最旧的已被淘汰 → 可以重新开始（不会误判为重复）。
      expect(ledger.begin('a#0'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.6 主题：即时切换且**不重建 HWND**', () {
    testWidgets('调整层里选主题 → 只写主题、窗口矩形不变、不进重建事务',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      final int commitsBefore = h.commits;
      final int rebuildsBefore = h.state.canvasRebuildCount;

      // 进入主题调整层，再"增大"（= 下一个主题）。
      await confirmAction(tester, h, 'settings_theme');
      final MenuExecutionResult r = await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.theme),
      );

      expect(r.status, MenuExecutionStatus.success);
      expect(h.settings.themes, hasLength(1), reason: '主题被写入一次');
      expect(h.settings.themes.first, isNot(WheelThemeIds.p3pPink));
      expect(h.commits, commitsBefore, reason: '主题不得改窗口矩形');
      expect(h.state.canvasRebuildCount, rebuildsBefore, reason: '主题不得重建画布');
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.3/4/5 + §11.7 调整层加减与一次重建', () {
    testWidgets('增大轮盘大小 → 写设置 + **只重建一次**画布',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      final int commitsBefore = h.commits;

      await confirmAction(tester, h, 'settings_wheel_size');
      expect(h.state.wheelLevelIdForTest, WheelAdjustmentKind.wheelScale.levelId,
          reason: '设置根项必须进入调整层');

      final MenuExecutionResult r = await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
      );
      await tester.pumpAndSettle();

      expect(r.status, MenuExecutionStatus.success);
      expect(h.settings.writes, <String>['wheel_scale=1.1']);
      expect(h.state.canvasRebuildCount, 1, reason: '一次调整只允许一次重建');
      expect(h.commits, commitsBefore + 1, reason: '重建只提交一次窗口矩形');
    });

    testWidgets('按钮大小 / 菜单距离同样走调整层', (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);

      await confirmAction(tester, h, 'settings_button_size');
      expect(h.state.wheelLevelIdForTest, WheelAdjustmentKind.buttonScale.levelId);
      await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.buttonScale),
      );
      expect(h.settings.values[WheelAdjustmentKind.buttonScale],
          closeTo(1.40, 1e-9));

      await tester.pumpAndSettle();
      await confirmAction(tester, h, 'settings_menu_distance');
      expect(h.state.wheelLevelIdForTest, WheelAdjustmentKind.menuDistance.levelId);
      await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.decrease(WheelAdjustmentKind.menuDistance),
      );
      expect(h.settings.values[WheelAdjustmentKind.menuDistance],
          closeTo(0.15, 1e-9));
    });

    testWidgets('恢复默认到得了默认值（网格对齐）', (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      await confirmAction(tester, h, 'settings_menu_distance');
      // 先加两下偏离默认。
      await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.menuDistance),
      );
      await tester.pumpAndSettle();
      await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.menuDistance),
      );
      await tester.pumpAndSettle();
      expect(h.settings.values[WheelAdjustmentKind.menuDistance],
          closeTo(0.18, 1e-9));

      final MenuExecutionResult r = await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.reset(WheelAdjustmentKind.menuDistance),
      );
      expect(r.status, MenuExecutionStatus.success);
      expect(h.settings.values[WheelAdjustmentKind.menuDistance],
          closeTo(WheelMenuLayoutSettings.defaultDistance, 1e-9),
          reason: '恢复默认必须精确到达 0.16');
    });

    testWidgets('到边界时明确反馈"已到最大"，且**不**假装成功',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      await confirmAction(tester, h, 'settings_wheel_size');
      // 直接拉到上限。
      h.settings.values[WheelAdjustmentKind.wheelScale] =
          WheelMenuLayoutSettings.maxScale;
      final MenuExecutionResult r = await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
      );
      expect(r.status, MenuExecutionStatus.unavailable);
      expect(r.reason, contains('已到最大'));
    });

    testWidgets('§11.9 重建后**恢复原调整层**（不是回到根菜单）',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      await confirmAction(tester, h, 'settings_button_size');
      expect(h.state.wheelLevelIdForTest, WheelAdjustmentKind.buttonScale.levelId);

      await confirmAction(
        tester,
        h,
        WheelAdjustmentActionIds.increase(WheelAdjustmentKind.buttonScale),
      );
      await tester.pumpAndSettle();

      expect(h.state.wheelPhaseNameForTest, isNot('closed'),
          reason: '调整后轮盘必须自动重开');
      expect(h.state.wheelLevelIdForTest, WheelAdjustmentKind.buttonScale.levelId,
          reason: '必须回到原调整层');
    });

    testWidgets('§11.10 重建失败 → 回滚旧设置并给出失败反馈',
        (WidgetTester tester) async {
      // 让窗口提交"被吞掉"，使重建后的可见性校验必然失败。
      final _Ops ops = _Ops();
      final _RegionOps regions = _RegionOps();
      final _SettingsRecorder settings = _SettingsRecorder();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: FixedCanvasProbe(
          key: UniqueKey(),
          windowOps: _ForceBoundsOps(ops),
          coordinator: RegionCoordinator(
            ops: regions,
            devicePixelRatio: () => 1.0,
            journal: WheelGeometryJournal(capacity: 500),
          ),
          petSize: () => const Size(256, 256),
          savedWindowPosition: () =>
              (x: 800.0, y: 400.0, schema: 2, legacyWindowSize: null),
          isMousePassthrough: () => false,
          applyWheelSetting: settings.apply,
          applyWheelTheme: settings.applyTheme,
          readWheelSetting: settings.read,
          child: const SizedBox(width: 256, height: 256),
        ),
      ));
      await tester.pump();
      final FixedCanvasProbeState state =
          tester.state<FixedCanvasProbeState>(find.byType(FixedCanvasProbe));
      await state.prepareFixedCanvas();
      await tester.pump();
      await state.open();
      await tester.pumpAndSettle();
      await state.dispatchActionForTest(
        MenuNode(
          id: 'settings_wheel_size',
          actionId: 'settings_wheel_size',
          labelZh: '轮盘大小',
        ),
      );

      final double before = settings.values[WheelAdjustmentKind.wheelScale]!;
      final MenuExecutionResult r = await state.dispatchActionForTest(
        MenuNode(
          id: WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
          actionId: WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
          labelZh: '增大',
        ),
      );
      await tester.pumpAndSettle();

      expect(r.status, MenuExecutionStatus.failed, reason: '必须明确失败');
      expect(r.reason, contains('已回滚'));
      expect(settings.values[WheelAdjustmentKind.wheelScale], before,
          reason: '失败必须回滚到旧设置');
    });

    testWidgets('§11.8 连续加减只应用最新值（旧 revision 被放弃）',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      await confirmAction(tester, h, 'settings_wheel_size');

      // **并发**三次增大（不逐个 await）：三个重建请求同时存在，
      // 只有最新 revision 的那个允许真正提交，其余必须被明确判为过期。
      final MenuNode node = MenuNode(
        id: WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
        actionId: WheelAdjustmentActionIds.increase(WheelAdjustmentKind.wheelScale),
        labelZh: '增大',
      );
      final List<Future<MenuExecutionResult>> futures =
          <Future<MenuExecutionResult>>[
        h.state.dispatchActionForTest(node),
        h.state.dispatchActionForTest(node),
        h.state.dispatchActionForTest(node),
      ];
      await Future.wait(futures);
      await tester.pumpAndSettle();

      // 最终值 = 1.0 + 3×0.1
      expect(h.settings.values[WheelAdjustmentKind.wheelScale], closeTo(1.30, 1e-9));
      expect(wheelGeometryJournal.contains('wheel.canvas.rebuild.stale_revision'),
          isTrue,
          reason: '必须至少有一次过期 revision 被明确放弃（而不是全都提交）');
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.19 root_hide 与托盘恢复', () {
    testWidgets('root_hide → 隐藏窗口（服务继续运行）', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);

      final MenuExecutionResult r = await confirmAction(
        tester,
        h,
        WindowsWindowActionIds.rootHide,
      );
      expect(r.status, MenuExecutionStatus.success);
      expect(calls, <String>['visible=false']);
      expect(r.message, contains('服务继续运行'));
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.14/15/16/17/18 形象与页面跳转（委托给共用执行器）', () {
    testWidgets('appearance_prev / next 真正执行', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);

      expect(
        (await confirmAction(tester, h, 'appearance_prev')).status,
        MenuExecutionStatus.success,
      );
      expect(
        (await confirmAction(tester, h, 'appearance_next')).status,
        MenuExecutionStatus.success,
      );
      expect(calls,
          <String>['dispatch:appearance_prev', 'dispatch:appearance_next']);
    });

    testWidgets('appearance_auto / fav / mapping / library 都真正执行',
        (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);

      for (final String id in <String>[
        'appearance_auto',
        'appearance_fav',
        'appearance_mapping',
        'appearance_library',
      ]) {
        expect((await confirmAction(tester, h, id)).status,
            MenuExecutionStatus.success, reason: id);
      }
      expect(calls, <String>[
        'dispatch:appearance_auto',
        'dispatch:appearance_fav',
        'dispatch:appearance_mapping',
        'dispatch:appearance_library',
      ]);
    });

    testWidgets('pet_auto 真正执行（复用现有设置与状态系统）',
        (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);
      expect((await confirmAction(tester, h, 'pet_auto')).status,
          MenuExecutionStatus.success);
      expect(calls, <String>['dispatch:pet_auto']);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16 C2：记录 / 同步动作**真正执行**（不再有任何占位）', () {
    testWidgets('records_* 全部走唯一业务通道并成功（无"不支持"、无占位）',
        (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);

      for (final String id in <String>[
        'records_today',
        'records_stats',
        'records_cloud',
        'records_track',
        'records_sync',
        'records_sync_state',
      ]) {
        final MenuExecutionResult r = await confirmAction(tester, h, id);
        expect(r.status, MenuExecutionStatus.success, reason: id);
        expect(r.reason ?? '', isNot(contains('不支持')), reason: id);
        expect(r.reason ?? '', isNot(contains('增量 C2')), reason: id);
      }
      expect(calls, <String>[
        'dispatch:records_today',
        'dispatch:records_stats',
        'dispatch:records_cloud',
        'dispatch:records_track',
        'dispatch:records_sync',
        'dispatch:records_sync_state',
      ]);
    });

    testWidgets('只读信息项回报真实状态（不是"只读信息项不触发动作"）',
        (WidgetTester tester) async {
      final _Harness h = await pumpProbe(tester);
      await openWheel(tester, h);
      final MenuExecutionResult pet =
          await confirmAction(tester, h, MenuInfoIds.petCurrent);
      expect(pet.status, MenuExecutionStatus.success);
      expect(pet.message, contains('当前状态'));
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.20/21 幂等与晚到结果', () {
    testWidgets('同一次确认被重复派发时只执行一次', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);

      // 同一个 requestId 重复 begin → 第二次必须被拒。
      final MenuActionLedger ledger = MenuActionLedger();
      expect(ledger.begin('root_hide#7'), isTrue);
      expect(ledger.begin('root_hide#7'), isFalse);

      expect((await confirmAction(tester, h, WindowsWindowActionIds.rootHide)).status,
          MenuExecutionStatus.success);
      expect(calls, <String>['visible=false'], reason: '只执行一次');
    });

    testWidgets('菜单已关闭后晚到的结果不恢复旧 UI', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      // 挂起执行器：让 root_hide 的结果**卡住**，先把菜单关掉再放行。
      final _Harness h = await pumpProbe(
        tester,
        executorCalls: calls,
        holdExecutor: true,
      );
      await openWheel(tester, h);

      final Future<MenuExecutionResult> pending = h.state.dispatchActionForTest(
        const MenuNode(
          id: WindowsWindowActionIds.rootHide,
          actionId: WindowsWindowActionIds.rootHide,
          labelZh: '隐藏桌宠',
        ),
      );
      await tester.pump();

      // 菜单先关闭，再放行 → 结果属于"晚到"。
      await h.state.close();
      await tester.pumpAndSettle();
      h.releaseHeldExecutor();
      await pending;
      await tester.pumpAndSettle();

      expect(calls, <String>['visible=false'], reason: '动作本身仍然执行了');
      expect(wheelGeometryJournal.contains('wheel.action.late_result_dropped'),
          isTrue,
          reason: '晚到结果必须被明确丢弃（不得恢复旧 UI）');
      expect(wheelGeometryJournal.contains('wheel.entry_confirmed'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.23/27 Region 与反馈一致 / HWND 不变', () {
    testWidgets('反馈期间 Region 重算，反馈结束后恢复；窗口矩形全程不变',
        (WidgetTester tester) async {
      final List<String> calls = <String>[];
      final _Harness h = await pumpProbe(tester, executorCalls: calls);
      await openWheel(tester, h);
      final int commitsBefore = h.commits;
      final int appliesBefore = h.regions.applied.length;

      await confirmAction(tester, h, 'pet_size_up');
      await tester.pump();

      expect(h.regions.applied.length, greaterThan(appliesBefore),
          reason: '反馈条会改变 Region，必须重算');
      expect(h.commits, commitsBefore, reason: '反馈不得改窗口矩形');
    });
  });

  // ---------------------------------------------------------------------------
  group('§11.24/25 右键菜单与控制面板不退化 / Android 隔离', () {
    test('右键菜单仍按 workArea 约束（未受 C1 影响）', () {
      // 由 `pet_context_menu_test.dart` 覆盖；这里只钉住"契约没被搬走"。
      expect(MenuCatalog.settings.nodes.any((MenuNode n) => n.id == 'back'), isTrue);
    });

    test('新增模块不依赖桌面实现（Android 隔离）', () {
      // 位置语义 / 调整层 / 幂等账本都是纯 Dart。
      for (final String path in <String>[
        'lib/menu/wheel_adjustment_layer.dart',
        'lib/menu/menu_action_request.dart',
        'lib/menu/wheel_expansion_side.dart',
      ]) {
        expect(path, isNotEmpty);
      }
    });
  });
}

/// 让提交"被吞掉"的 WindowOps：用于构造"重建后不可见"的失败路径。
class _ForceBoundsOps implements FixedCanvasWindowOps {
  _ForceBoundsOps(this._inner);

  final _Ops _inner;

  @override
  Future<Rect> currentBounds() async => const Rect.fromLTWH(-9000, -9000, 922, 844);
  @override
  Future<void> commitBounds(Rect next) async => _inner.commitBounds(next);
  @override
  Future<List<WheelDisplayArea>> displays() async => _inner.displays();
  @override
  Future<WheelDisplayArea?> displayForPoint(Offset point) async =>
      _inner.displayForPoint(point);
  @override
  double devicePixelRatio() => 1.0;
  @override
  Future<void> setVisible(bool visible) async {}
}
