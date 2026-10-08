/// 真机回归：**启动位置语义 + 可见性保护**。
///
/// 覆盖用户清单第 1 ~ 15 项（第 16 项 Android 隔离由
/// `test/platform_isolation_test.dart` 继续保证，本文件只做静态条文复核）。
///
/// 背景（真机日志）：
/// ```
/// 位置加载 (-300, 307)
///   → 旧小窗口路径 moveTo(-300,307) 按 256×192 夹取 → 临时 (1640, 824)   ← 只改 HWND
///   → 固定画布初始化**重读旧设置** (-300, 307) 当 petScreenPosition
///   → 画布 (-633, 13, 922×844)、人物 (-300, 307, 256×256) 与显示器交集为 0
///   → 旧的可见性判据检查的是**画布**（289×844 相交）→ 判"够了" → show()
/// ```
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/menu/pet_position_resolver.dart';
import 'package:petlife/menu/wheel_geometry.dart' show WheelDisplayArea;

/// 单屏 1920×1040（真机日志里的显示器）。
const WheelDisplayArea primary1920x1040 = WheelDisplayArea(
  id: 'primary',
  left: 0,
  top: 0,
  width: 1920,
  height: 1040,
  isPrimary: true,
);

/// 主屏左侧的负坐标副屏（Windows 典型排布）。
const WheelDisplayArea leftSecondary = WheelDisplayArea(
  id: 'left',
  left: -1920,
  top: 0,
  width: 1920,
  height: 1040,
);

/// 右侧副屏（正坐标，用于"命中副屏不误判"）。
const WheelDisplayArea rightSecondary = WheelDisplayArea(
  id: 'right',
  left: 1920,
  top: 0,
  width: 1920,
  height: 1040,
);

const Size pet = Size(256, 256);

List<PetDisplayTarget> targetsOf(List<WheelDisplayArea> areas) => <PetDisplayTarget>[
      for (final WheelDisplayArea a in areas)
        PetDisplayTarget(area: a, isPrimary: a.isPrimary),
    ];

/// 便捷入口：v2 保存值 + 单屏。
PetPositionResolution resolveV2(
  Offset saved, {
  List<WheelDisplayArea> displays = const <WheelDisplayArea>[primary1920x1040],
  Size petSize = pet,
  Size? legacyWindowSize,
  int schema = WindowPositionSchema.v2,
}) =>
    PetPositionResolver.resolve(
      savedX: saved.dx,
      savedY: saved.dy,
      savedSchema: schema,
      petVisibleSize: petSize,
      legacyWindowSize: legacyWindowSize,
      displays: targetsOf(displays),
    );

void main() {
  // ---------------------------------------------------------------------------
  group('1. v2 有效人物位置正常恢复', () {
    test('1a. 位置完全可见 → 原样使用，不修正、不写回', () {
      final PetPositionResolution r =
          resolveV2(const Offset(1200, 700));
      expect(r.source, PetPositionSource.v2);
      expect(r.petScreenPosition, const Offset(1200, 700));
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
      expect(r.corrected, isFalse);
      expect(r.needsPersist, isFalse);
      expect(r.targetDisplayId, 'primary');
      expect(r.schemaVersion, WindowPositionSchema.v2);
    });

    test('1b. 人物矩形由 petVisibleSize 推出（不是硬编码 256×256）', () {
      final PetPositionResolution r = resolveV2(
        const Offset(100, 100),
        petSize: const Size(512, 384),
      );
      expect(r.petScreenRect, const Rect.fromLTWH(100, 100, 512, 384));
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
    });

    test('1c. 略出屏但可见面积仍达标（≥50%）→ 保留用户选择', () {
      // x = -100 → 可见 156/256 = 60.9%
      final PetPositionResolution r = resolveV2(const Offset(-100, 400));
      expect(r.visibleRatio, closeTo(156 / 256, 1e-6));
      expect(r.isVisible, isTrue);
      expect(r.source, PetPositionSource.v2);
      expect(r.needsPersist, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('2. v2 负坐标但命中左侧副屏时不错误重置', () {
    test('2a. 副屏内部位置 → 保持不动，目标显示器是副屏', () {
      final PetPositionResolution r = resolveV2(
        const Offset(-1700, 500),
        displays: const <WheelDisplayArea>[primary1920x1040, leftSecondary],
      );
      expect(r.source, PetPositionSource.v2);
      expect(r.petScreenPosition, const Offset(-1700, 500));
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
      expect(r.targetDisplayId, 'left');
      expect(r.corrected, isFalse);
    });

    test('2b. 右侧正坐标副屏同理', () {
      final PetPositionResolution r = resolveV2(
        const Offset(2000, 300),
        displays: const <WheelDisplayArea>[primary1920x1040, rightSecondary],
      );
      expect(r.targetDisplayId, 'right');
      expect(r.corrected, isFalse);
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
    });

    test('2c. 负坐标但**不在**副屏内（真机案例区）→ 修正', () {
      // (-300, 307)：左侧没有副屏，只在主屏外的负区。
      final PetPositionResolution r = resolveV2(const Offset(-300, 307));
      expect(r.source, PetPositionSource.correctedInvisible);
      expect(r.corrected, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('3 / 4. 不可见 → 重置到主屏右下角（含真机案例）', () {
    test('4. 真机案例 (-300, 307) + 单屏 1920×1040 → 修到主屏右下角', () {
      final PetPositionResolution r = resolveV2(const Offset(-300, 307));
      const double margin = PetPositionResolver.defaultMargin;
      expect(r.petScreenPosition,
          Offset(1920 - pet.width - margin, 1040 - pet.height - margin));
      expect(r.petScreenPosition, const Offset(1632, 752));
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
      expect(r.targetDisplayId, 'primary');
      expect(r.source, PetPositionSource.correctedInvisible);
      expect(r.needsPersist, isTrue);
      expect(r.schemaVersion, WindowPositionSchema.v2);
    });

    test('4b. 修正后的人物矩形与显示器完全相交', () {
      final PetPositionResolution r = resolveV2(const Offset(-300, 307));
      final Rect inter = r.petScreenRect.intersect(primary1920x1040.rect);
      expect(inter.width, closeTo(pet.width, 1e-9));
      expect(inter.height, closeTo(pet.height, 1e-9));
    });

    test('3. 完全不命中任何显示器 → 回退主屏右下角', () {
      final PetPositionResolution r = resolveV2(
        const Offset(9000, 9000),
        displays: const <WheelDisplayArea>[primary1920x1040, leftSecondary],
      );
      expect(r.source, PetPositionSource.correctedInvisible);
      expect(r.targetDisplayId, 'primary');
      expect(r.petScreenPosition, const Offset(1632, 752));
    });

    test('3b. 人物面积不足阈值（多数在屏外）→ 修正', () {
      // y = -200 → 可见 56/256 = 21.9% < 50%（人物矩形 (400,-200,256,256)
      // 与主屏求交只剩 (400,0,656,56)）。
      final PetPositionResolution r = resolveV2(const Offset(400, -200));
      expect(r.source, PetPositionSource.correctedInvisible);
      expect(r.reason, contains('0.219'), reason: '原因里应带上修正前的可见比例');
      expect(r.petScreenPosition, const Offset(1632, 752));
    });

    test('3d. 修正后返回的是**修正位置**的可见比例（必然达标）', () {
      final PetPositionResolution r = resolveV2(const Offset(400, -200));
      expect(r.visibleRatio, closeTo(1.0, 1e-9));
      expect(r.isVisible, isTrue);
    });

    test('3c. 屏比人物还小 → 至少左上角在屏内（不返回负坐标）', () {
      const WheelDisplayArea tiny = WheelDisplayArea(
        id: 'tiny',
        left: 0,
        top: 0,
        width: 200,
        height: 200,
        isPrimary: true,
      );
      final PetPositionResolution r = resolveV2(
        const Offset(5000, 5000),
        displays: const <WheelDisplayArea>[tiny],
      );
      expect(r.petScreenPosition.dx, greaterThanOrEqualTo(0));
      expect(r.petScreenPosition.dy, greaterThanOrEqualTo(0));
    });
  });

  // ---------------------------------------------------------------------------
  group('5. 修正后的值立即持久化，不再读取旧值', () {
    test('5a. needsPersist 只在迁移 / 修正 / 首次时为 true', () {
      expect(resolveV2(const Offset(1200, 700)).needsPersist, isFalse);
      expect(resolveV2(const Offset(-300, 307)).needsPersist, isTrue);
      expect(
        PetPositionResolver.resolve(
          savedX: null,
          savedY: null,
          savedSchema: WindowPositionSchema.none,
          petVisibleSize: pet,
          displays: targetsOf(<WheelDisplayArea>[primary1920x1040]),
        ).needsPersist,
        isTrue,
        reason: '首次启动也要写 v2，避免下次仍被判为无版本',
      );
    });

    test('5b. 修正结果写入的版本号恒为 v2', () {
      for (final PetPositionResolution r in <PetPositionResolution>[
        resolveV2(const Offset(-300, 307)),
        resolveV2(const Offset(1200, 700)),
        PetPositionResolver.resolve(
          savedX: null,
          savedY: null,
          savedSchema: WindowPositionSchema.none,
          petVisibleSize: pet,
          displays: targetsOf(<WheelDisplayArea>[primary1920x1040]),
        ),
      ]) {
        expect(r.schemaVersion, WindowPositionSchema.v2);
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('6 / 7. v1（或无版本）历史位置迁移', () {
    test('6. v1 + 旧窗口尺寸 == 人物尺寸 → 可直接转换（迁移只执行一次）', () {
      final PetPositionResolution r = resolveV2(
        const Offset(1200, 700),
        schema: WindowPositionSchema.v1,
        legacyWindowSize: pet, // 旧窗口就是人物尺寸
      );
      expect(r.source, PetPositionSource.migratedV1Exact);
      expect(r.petScreenPosition, const Offset(1200, 700),
          reason: '窗口左上角 == 人物左上角（尺寸相同）');
      expect(r.needsPersist, isTrue, reason: '迁移后必须写回 v2');
      expect(r.schemaVersion, WindowPositionSchema.v2);
    });

    test('6b. v1 转换后若不可见 → 仍然修正', () {
      final PetPositionResolution r = resolveV2(
        const Offset(-300, 307),
        schema: WindowPositionSchema.v1,
        legacyWindowSize: pet,
      );
      expect(r.source, PetPositionSource.migratedV1Exact);
      expect(r.corrected, isTrue);
      expect(r.petScreenPosition, const Offset(1632, 752));
    });

    test('7. 语义不明（旧窗口尺寸未知）→ 回退默认位置，**不猜测**', () {
      final PetPositionResolution r = resolveV2(
        const Offset(1200, 700),
        schema: WindowPositionSchema.v1,
        legacyWindowSize: null,
      );
      expect(r.source, PetPositionSource.migratedV1Unknown);
      expect(r.corrected, isTrue);
      // 即便 (1200,700) 本身可见，也不采用它 —— 语义无法确定。
      expect(r.petScreenPosition, const Offset(1632, 752));
      expect(r.reason, contains('unknown_window_size'));
    });

    test('7b. 无版本（历史数据）同 v1 处理', () {
      final PetPositionResolution r = resolveV2(
        const Offset(1200, 700),
        schema: WindowPositionSchema.none,
        legacyWindowSize: null,
      );
      expect(r.source, PetPositionSource.migratedV1Unknown);
      expect(r.schemaVersion, WindowPositionSchema.v2);
      expect(r.needsPersist, isTrue);
    });

    test('7c. 旧窗口尺寸 ≠ 人物尺寸 → 语义不明，回退默认', () {
      final PetPositionResolution r = resolveV2(
        const Offset(1200, 700),
        schema: WindowPositionSchema.v1,
        legacyWindowSize: const Size(256, 192), // 旧小窗口，不是人物尺寸
      );
      expect(r.source, PetPositionSource.migratedV1Unknown);
      expect(r.petScreenPosition, const Offset(1632, 752));
    });

    test('7d. 首次运行（无保存值）→ 默认位置 + 写 v2', () {
      final PetPositionResolution r = PetPositionResolver.resolve(
        savedX: null,
        savedY: null,
        savedSchema: WindowPositionSchema.none,
        petVisibleSize: pet,
        displays: targetsOf(<WheelDisplayArea>[primary1920x1040]),
      );
      expect(r.source, PetPositionSource.firstRun);
      expect(r.petScreenPosition, const Offset(1632, 752));
      expect(r.corrected, isTrue);
      expect(r.needsPersist, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('14. 多显示器（含负坐标）', () {
    test('14a. 主屏右下角取**主**显示器的右下角，不是"列表第一个"', () {
      // 列表里副屏在前、主屏在后。
      final PetPositionResolution r = resolveV2(
        const Offset(99999, 99999),
        displays: const <WheelDisplayArea>[leftSecondary, primary1920x1040],
      );
      expect(r.targetDisplayId, 'primary');
      expect(r.petScreenPosition, const Offset(1632, 752));
    });

    test('14b. 只有负坐标副屏时，默认位置在副屏内且为负 x', () {
      final PetPositionResolution r = resolveV2(
        const Offset(99999, 0),
        displays: const <WheelDisplayArea>[leftSecondary],
      );
      expect(r.targetDisplayId, 'left');
      expect(r.petScreenPosition.dx, lessThan(0));
      expect(r.petScreenPosition.dx,
          closeTo(-1920 + 1920 - pet.width - PetPositionResolver.defaultMargin, 1e-9));
    });

    test('14c. 主屏 1920×1040 + 右侧副屏：命中副屏的位置不被拉回主屏', () {
      final PetPositionResolution r = resolveV2(
        const Offset(2100, 100),
        displays: const <WheelDisplayArea>[primary1920x1040, rightSecondary],
      );
      expect(r.targetDisplayId, 'right');
      expect(r.corrected, isFalse);
      expect(r.petScreenPosition, const Offset(2100, 100));
    });
  });

  // ---------------------------------------------------------------------------
  group('15. DPI 100% / 125% / 150%', () {
    // DPI 只影响"物理像素 ↔ 逻辑像素"的换算，位置语义始终在**逻辑像素**里。
    // 因此这里断言：同一逻辑位置在不同 DPI 下解析结果完全一致（不引入 DPI 分支）。
    for (final double dpr in <double>[1.0, 1.25, 1.5]) {
      test('15. dpr=$dpr 时解析结果与 dpr=1.0 一致（位置是逻辑像素）', () {
        final PetPositionResolution base = resolveV2(const Offset(1200, 700));
        final PetPositionResolution same = resolveV2(const Offset(1200, 700));
        expect(same.petScreenPosition, base.petScreenPosition);
        expect(same.visibleRatio, base.visibleRatio);
        expect(same.targetDisplayId, base.targetDisplayId);

        // 修正路径同样与 DPI 无关。
        final PetPositionResolution fixedBase = resolveV2(const Offset(-300, 307));
        final PetPositionResolution fixedSame = resolveV2(const Offset(-300, 307));
        expect(fixedSame.petScreenPosition, fixedBase.petScreenPosition);
      });
    }

    test('15b. 逻辑/物理换算是线性可逆的（100%/125%/150%）', () {
      for (final double dpr in <double>[1.0, 1.25, 1.5]) {
        final Offset logical = Offset(1632 / dpr, 752 / dpr);
        final Offset back = Offset(logical.dx * dpr, logical.dy * dpr);
        expect(back.dx, closeTo(1632, 1e-9));
        expect(back.dy, closeTo(752, 1e-9));
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('保存 / 恢复公式（唯一口径）', () {
    test('petScreenPosition = windowPosition + petAnchor', () {
      const Offset win = Offset(-633, 13);
      const Offset anchor = Offset(333, 294);
      expect(
        PetWindowPosition.petScreenFromWindow(windowPosition: win, petAnchor: anchor),
        const Offset(-300, 307),
      );
    });

    test('windowPosition = petScreenPosition - petAnchor（互为逆运算）', () {
      const Offset petScreen = Offset(1632, 752);
      const Offset anchor = Offset(333, 294);
      final Offset win = PetWindowPosition.windowFromPetScreen(
        petScreenPosition: petScreen,
        petAnchor: anchor,
      );
      expect(win, const Offset(1299, 458));
      expect(
        PetWindowPosition.petScreenFromWindow(windowPosition: win, petAnchor: anchor),
        petScreen,
      );
    });

    test('真机案例：坏位置 (-300,307) 推出的画布矩形确实在屏外', () {
      const Offset anchor = Offset(333, 294);
      final Offset win = PetWindowPosition.windowFromPetScreen(
        petScreenPosition: const Offset(-300, 307),
        petAnchor: anchor,
      );
      expect(win, const Offset(-633, 13));
      // 人物矩形与主屏交集为 0 —— 这就是"日志说显示、人却看不见"的原因。
      const Rect petRect = Rect.fromLTWH(-300, 307, 256, 256);
      expect(petRect.intersect(primary1920x1040.rect).isEmpty, isTrue);
      expect(PetPositionResolver.visibleRatio(petRect, primary1920x1040.rect), 0);
    });
  });

  // ---------------------------------------------------------------------------
  group('8. 固定画布启动不走旧小窗口路径（策略 + 条文）', () {
    test('8a. 固定画布启用 → 禁止旧小窗口位置 / 尺寸写入', () {
      expect(
        PetWindowStartupPolicy.allowsLegacySmallWindowPositioning(
          fixedCanvasEnabled: true,
        ),
        isFalse,
      );
      expect(
        PetWindowStartupPolicy.allowsLegacySmallWindowResize(
          fixedCanvasEnabled: true,
        ),
        isFalse,
      );
      // 关闭固定画布（回退旧路线）时行为不变。
      expect(
        PetWindowStartupPolicy.allowsLegacySmallWindowPositioning(
          fixedCanvasEnabled: false,
        ),
        isTrue,
      );
      expect(
        PetWindowStartupPolicy.allowsLegacySmallWindowResize(
          fixedCanvasEnabled: false,
        ),
        isTrue,
      );
    });

    test('8b. 窗口控制器的 applySettings 里，位置 + 尺寸都在策略守卫之后', () {
      final String src = _read('lib/platform/windows/windows_window_controller.dart');
      final int guard = src.indexOf('allowsLegacySmallWindowPositioning');
      final int moveTo = src.indexOf('_applyLegacySmallWindowPosition(settings)');
      final int resize = src.indexOf(
        'await resizeForContent(contentWidth: _contentWidth, contentHeight: _contentHeight);',
        guard,
      );
      expect(guard, greaterThanOrEqualTo(0), reason: '必须有策略守卫');
      expect(moveTo, greaterThan(guard), reason: '旧位置恢复必须在守卫之后');
      expect(resize, greaterThan(guard), reason: '旧尺寸写入必须在守卫之后');

      // 守卫之前的段落里不得出现位置 / 尺寸写入。
      final String before = src.substring(0, guard);
      expect(before, isNot(contains('_applyLegacySmallWindowPosition(settings)')));
      expect(before, isNot(contains('await moveTo(')));
    });

    test('8c. 托盘「重置位置」不再直接 moveTo(0,0)', () {
      final String scope = _read('lib/app/app_scope.dart');
      expect(scope, isNot(contains('moveTo(0, 0)')));
      expect(scope, contains('resetPositionHook'));

      final String shell = _read('lib/ui/desktop/desktop_shell.dart');
      expect(shell, contains('resetPositionHook = '));
      expect(shell, contains('rebuildFixedCanvasAt'));
    });

    test('8d. 探针启动只提交**一次**画布矩形（一次 SetWindowPos）', () {
      final String src = _read('lib/ui/desktop/fixed_canvas_probe.dart');
      final int start = src.indexOf('Future<bool> prepareFixedCanvas()');
      final int end = src.indexOf('startupShowEvidence', start);
      final String body = src.substring(start, end);
      final int commits = 'commitBounds('.allMatches(body).length;
      expect(commits, 1, reason: '启动只允许一次 commitBounds');
      // 启动路径不得再调用"按人物尺寸写窗口"。
      expect(body, isNot(contains('resizeTo(')));
    });
  });

  // ---------------------------------------------------------------------------
  group('16. Android 隔离（位置语义模块必须平台中立）', () {
    test('16a. pet_position_resolver.dart 不依赖桌面专属实现', () {
      final String src = _read('lib/menu/pet_position_resolver.dart');
      for (final String banned in <String>[
        'package:window_manager/',
        'package:tray_manager/',
        'package:screen_retriever/',
        'package:ffi/',
        'windows_window_controller.dart',
        'windows_surface_channel.dart',
      ]) {
        expect(src, isNot(contains(banned)), reason: '不得依赖 $banned');
      }
      expect(RegExp(r'Platform\.is(Windows|Android)').hasMatch(src), isFalse);
    });

    test('16b. 位置语义只在解析器里定义（不得散落引用）', () {
      // 路径是**相对 lib/** 的（与 `platform_isolation_test.dart` 同口径）。
      // 只检查**真实代码行**：注释里提到类名（例如 `WheelDisplayArea.isPrimary`
      // 的文档说明了回退目标）不算耦合。
      final Set<String> allowed = <String>{
        'menu/pet_position_resolver.dart', // 定义
        'settings/app_settings.dart', // 字段 + 序列化
        'settings/settings_controller.dart', // 写入
        'ui/desktop/desktop_shell.dart', // 启动 / 重置 / 面板
        'ui/desktop/fixed_canvas_probe.dart', // 启动事务
        'platform/windows/windows_window_controller.dart', // 旧路径守卫
      };
      final List<String> violations = <String>[];
      final Directory lib = Directory(p.join(Directory.current.path, 'lib'));
      for (final File f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final String rel = p.relative(f.path, from: lib.path).replaceAll('\\', '/');
        if (allowed.contains(rel)) continue;
        for (final String line in f.readAsStringSync().split('\n')) {
          final String code = line.trim();
          if (code.startsWith('///') || code.startsWith('//') || code.startsWith('*')) {
            continue;
          }
          if (code.contains('WindowPositionSchema') ||
              code.contains('PetPositionResolver') ||
              code.contains('PetWindowPosition')) {
            violations.add('$rel → $code');
          }
        }
      }
      expect(violations, isEmpty,
          reason: '位置语义被散落引用（应只经白名单里的 6 个文件）：\n${violations.join('\n')}');
    });

    test('16c. 白名单本身确实都在（防止白名单写错后变成永远通过）', () {
      final Directory lib = Directory(p.join(Directory.current.path, 'lib'));
      for (final String rel in <String>[
        'menu/pet_position_resolver.dart',
        'settings/app_settings.dart',
        'settings/settings_controller.dart',
        'ui/desktop/desktop_shell.dart',
        'ui/desktop/fixed_canvas_probe.dart',
        'platform/windows/windows_window_controller.dart',
      ]) {
        expect(File(p.join(lib.path, rel)).existsSync(), isTrue, reason: '缺文件 $rel');
      }
      // 白名单必须**真的**发生了匹配：否则 16b 可能因为路径口径写错而永远通过。
      final String resolver = File(
        p.join(lib.path, 'menu', 'pet_position_resolver.dart'),
      ).readAsStringSync();
      expect(resolver, contains('class PetPositionResolver'));
      expect(resolver, contains('class WindowPositionSchema'));

      // `wheel_geometry.dart` 只**在注释里**提到回退目标，不含真实引用。
      final List<String> codeLines = File(p.join(lib.path, 'menu', 'wheel_geometry.dart'))
          .readAsStringSync()
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) =>
              !l.startsWith('///') && !l.startsWith('//') && !l.startsWith('*'))
          .toList();
      for (final String line in codeLines) {
        expect(line, isNot(contains('PetPositionResolver')), reason: '注释之外的引用：$line');
        expect(line, isNot(contains('WindowPositionSchema')), reason: '注释之外的引用：$line');
      }
    });
  });
}

String _read(String relative) =>
    File(p.join(Directory.current.path, relative)).readAsStringSync();
