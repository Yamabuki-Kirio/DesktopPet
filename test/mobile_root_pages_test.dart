import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/platform/overlay_pet.dart';
import 'package:petlife/state_engine/fallback_chain.dart';
import 'package:petlife/state_engine/state_snapshot.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/sync/models/sync_models.dart';
import 'package:petlife/ui/mobile/pet_status_view.dart';
import 'package:petlife/ui/mobile/root_pages.dart';
import 'package:petlife/ui/pages/settings_sections.dart';
import 'package:petlife/ui/widgets/petlife/petlife_nav.dart';

/// 五个根页面 / 首页状态卡 / 设置分组的契约测试。
///
/// 说明（为什么不是"pump 整个 MobileShell"）：
/// 整壳会在 `initState` 里启动采集定时器、同步引擎并打开 SQLite，
/// 与 `testWidgets` 的 fake-async + "不得留下 pending Timer" 契约直接冲突
/// （既有 `mobile_ui_test` 已经写明这一点）。
/// 因此这里分三层验证，且三层都不依赖 `AppServices`：
///
/// 1. **数据层**：五个根入口与七个设置分组都是常量 / 枚举，直接断言；
/// 2. **纯逻辑层**：首页状态卡的绑定逻辑抽在 [PetLifePetStatusView]，
///    可以构造任意服务读数组合；
/// 3. **源码契约层**：外壳把五个入口按固定顺序接到五个页面上 ——
///    用静态断言固化，避免"界面能点开但接错页面"。
void main() {
  final String root = Directory.current.path;

  String readLib(String relative) =>
      File(p.join(root, 'lib', relative)).readAsStringSync();

  group('五个根入口（底部导航保持现有业务入口）', () {
    test('恰好五个，顺序与标题符合需求', () {
      expect(kPetLifeRootDestinations, hasLength(5));
      expect(
        kPetLifeRootDestinations.map((PetLifeNavDestination d) => d.label).toList(),
        kPetLifeRootTitles,
      );
      expect(kPetLifeRootTitles, <String>[
        '桌宠',
        '使用统计',
        '账户与同步',
        '素材库',
        '设置',
      ]);
    });

    test('每一项都有独立的线性图标与实心图标（未选中是线性图标）', () {
      for (final PetLifeNavDestination d in kPetLifeRootDestinations) {
        expect(d.icon, isNotNull);
        expect(d.selectedIcon, isNotNull);
        expect(d.icon, isNot(d.selectedIcon));
      }
    });

    test('外壳按同一顺序装配五个页面，且不重新实现业务导航', () {
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      const List<String> pages = <String>[
        'MobileHomePage(',
        'UsageStatsPage(',
        'AccountSyncPage(',
        'AssetLibraryPage(',
        'SettingsPage(',
      ];
      int cursor = -1;
      for (final String page in pages) {
        final int at = shell.indexOf(page);
        expect(at, greaterThan(cursor), reason: '$page 缺失或顺序不对');
        cursor = at;
      }
      // 底部导航直接使用唯一的常量列表。
      expect(shell, contains('destinations: kPetLifeRootDestinations'));
    });

    test('轮盘菜单跳转仍然映射到相同的五个下标（导航契约未变）', () {
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      expect(
        RegExp(r'case AppDestination\.assetLibrary:[\s\S]{0,80}?_index = 3')
            .hasMatch(shell),
        isTrue,
      );
      expect(
        RegExp(r'case AppDestination\.localStatistics:[\s\S]{0,80}?_index = 1')
            .hasMatch(shell),
        isTrue,
      );
      expect(
        RegExp(r'case AppDestination\.accountSync:[\s\S]{0,80}?_index = 2')
            .hasMatch(shell),
        isTrue,
      );
      expect(
        RegExp(r'case AppDestination\.overlaySettings:[\s\S]{0,80}?_index = 4')
            .hasMatch(shell),
        isTrue,
      );
    });

    test('每个根页面都用统一骨架（PetLifePage）承载标题区', () {
      final List<String> files = <String>[
        'ui/mobile/mobile_home_page.dart',
        'ui/pages/usage_stats_page.dart',
        'ui/pages/account_sync_page.dart',
        'ui/pages/asset_library_page.dart',
        'ui/pages/settings_page.dart',
      ];
      for (final String file in files) {
        final String source = readLib(file);
        expect(source, contains('PetLifePage('), reason: '$file 没有使用统一页面骨架');
        expect(source, contains('PetLifeCard('), reason: '$file 没有使用统一卡片');
        // 不允许硬编码粉色（必须来自统一主题对象）。
        expect(
          source.toUpperCase().contains('0xFFF24D96'),
          isFalse,
          reason: '$file 硬编码了强调色，应该从 PetLifeTheme.of(context) 取',
        );
      }
    });
  });

  group('首页状态卡数据绑定', () {
    StateSnapshot snapshotWith({EmotionAsset? asset, String? characterName}) {
      final CharacterModel? character = characterName == null
          ? null
          : CharacterModel(
              id: 'c-1',
              packId: 'pack-1',
              ownerId: 'owner',
              internalName: 'maya',
              displayName: characterName,
              enabled: true,
              createdAt: DateTime(2026, 9, 29),
              updatedAt: DateTime(2026, 9, 29),
            );
      return StateSnapshot(
        state: SystemState.focused,
        trigger: StateTrigger.init,
        reason: '测试',
        startedAt: DateTime(2026, 9, 29),
        currentCharacter: character,
        resolution: AssetResolution(
          asset: asset,
          level: asset == null
              ? FallbackLevel.builtinPlaceholder
              : FallbackLevel.stateAsset,
          reason: '测试',
        ),
        nextAllowedChangeAt: null,
        lastDecisionNote: '',
        manualAssetId: null,
      );
    }

    EmotionAsset assetWith(String emotion) => EmotionAsset(
          id: 'a-1',
          characterId: 'c-1',
          emotionName: emotion,
          variantName: '0',
          filePath: '/tmp/a.webp',
          fileHash: 'h',
          mimeType: 'image/webp',
          fileSize: 1024,
          width: 320,
          height: 480,
          frameCount: 1,
          isAnimated: false,
          hasAlpha: true,
          enabled: true,
          validationStatus: ValidationStatus.valid,
          createdAt: DateTime(2026, 9, 29),
        );

    PetLifePetStatusView view({
      String? characterName = 'Maya',
      String? emotion = 'happy',
      String? nativeStateLabel,
      bool overlaySupported = true,
      OverlayRuntimeState? runtime,
      String app = '音乐',
      bool autoState = true,
      SyncStatus syncStatus = SyncStatus.success,
      int pending = 0,
    }) =>
        PetLifePetStatusView.from(
          snapshot: snapshotWith(
            characterName: characterName,
            asset: emotion == null ? null : assetWith(emotion),
          ),
          overlaySupported: overlaySupported,
          overlayRuntime: runtime,
          nativeStateLabel: nativeStateLabel,
          foregroundAppLabel: app,
          autoStateEnabled: autoState,
          syncStatus: syncStatus,
          pendingCount: pending,
        );

    test('角色名 / 情绪 / 前台应用来自既有数据', () {
      final PetLifePetStatusView v = view();
      expect(v.characterName, 'Maya');
      expect(v.emotionLabel, 'happy');
      expect(v.foregroundAppLabel, '音乐');
    });

    test('没有角色时显示「还没有角色」，不显示空字符串', () {
      expect(view(characterName: null).characterName, '还没有角色');
    });

    test('情绪优先当前素材，其次原生状态标签，最后状态引擎描述', () {
      expect(view(emotion: 'happy', nativeStateLabel: '专注').emotionLabel, 'happy');
      expect(view(emotion: null, nativeStateLabel: '专注').emotionLabel, '专注');
      expect(view(emotion: null).emotionLabel, SystemState.focused.descriptionZh);
    });

    test('自动状态切换开关如实反映设置', () {
      expect(view(autoState: true).autoStateLabel, '自动状态切换：已开启');
      expect(view(autoState: false).autoStateLabel, '自动状态切换：已关闭');
      expect(view(autoState: false).autoStateEnabled, isFalse);
    });

    test('悬浮服务状态：不支持 / 读取中 / 未运行 / 已隐藏 / 运行中', () {
      expect(
        view(overlaySupported: false).serviceLabel,
        '悬浮服务：本平台不支持',
      );
      expect(view(runtime: null).serviceLabel, '悬浮服务：读取中…');

      OverlayRuntimeState runtime({bool running = true, bool hidden = false}) =>
          _runtimeState(serviceRunning: running, hidden: hidden);

      expect(
        view(runtime: runtime(running: false)).serviceState,
        OverlayServiceState.stopped,
      );
      expect(
        view(runtime: runtime(hidden: true)).serviceState,
        OverlayServiceState.hidden,
      );
      expect(
        view(runtime: runtime()).serviceState,
        OverlayServiceState.running,
      );
    });

    test('同步状态：有待同步记录时必须带出条数', () {
      expect(view(pending: 0).syncLabel, '同步：${SyncStatus.success.labelZh}');
      expect(
        view(pending: 7).syncLabel,
        contains('待同步 7 条'),
      );
      expect(view(pending: 7).syncState, SyncVisualState.success);
      expect(
        view(syncStatus: SyncStatus.failed).syncState,
        SyncVisualState.neutral,
      );
    });
  });

  group('设置页分组（需求 §2.6 的七组）', () {
    test('恰好七组，顺序与标题符合需求', () {
      expect(PetLifeSettingsSection.values, hasLength(7));
      expect(
        PetLifeSettingsSection.values
            .map((PetLifeSettingsSection s) => s.title)
            .toList(),
        <String>[
          '桌宠',
          '外观与主题',
          '状态联动',
          '账户与同步',
          '权限',
          '高级',
          '诊断',
        ],
      );
    });

    test('每组都有说明文案（不是裸标题）', () {
      for (final PetLifeSettingsSection s in PetLifeSettingsSection.values) {
        expect(s.subtitle.trim(), isNotEmpty);
      }
    });

    test('设置页按枚举顺序渲染分组，且每组是一张独立圆角卡片', () {
      final String source = readLib('ui/pages/settings_page.dart');
      expect(
        source,
        contains('in PetLifeSettingsSection.values'),
        reason: '分组顺序必须来自唯一真相枚举',
      );
      // 每组都要经过 _group（标题 + PetLifeCard），不允许散装灰色设置行。
      for (final PetLifeSettingsSection s in PetLifeSettingsSection.values) {
        expect(
          source,
          contains('PetLifeSettingsSection.${s.name}'),
          reason: '设置页缺少「${s.title}」分组',
        );
      }
    });

    test('主色与强调色是两个独立的配置区（各自可改、各自可恢复默认）', () {
      final String source = readLib('ui/pages/settings_page.dart');
      expect('主色'.allMatches(source).isNotEmpty, isTrue);
      expect(source, contains('title: \'主色\''));
      expect(source, contains('title: \'强调色\''));
      // 两个独立的持久化入口，互不覆盖。
      expect(source, contains('setThemePrimaryColor'));
      expect(source, contains('setThemeAccentColor'));
      expect(source, contains('resetThemeColors'));
    });
  });

  group('Windows 不受影响（本轮增量的硬边界）', () {
    test('Windows 已切换到同一套新主题，但 Android 侧代码没有被改动', () {
      final String shell = readLib('app/app_shell.dart');
      // 两个平台共用同一套主题生成器（Windows 同步新视觉那轮之后）。
      expect(shell, contains('buildPetLifeThemeData'));
      expect('buildPetLifeThemeData'.allMatches(shell).length, 2);
      // 桌面侧只多一个字体参数，不再有独立的旧主题分支。
      expect(shell, contains("desktop ? 'Microsoft YaHei' : null"));
      expect(shell.contains('0xFF4A7EBB'), isFalse,
          reason: '旧的深蓝色 seed 应已随 Windows 同步新视觉一并移除');
    });

    test('Android 外壳与页面没有被 Windows 增量波及', () {
      // 移动端外壳不引用任何桌面专属文件。
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      expect(shell.contains('desktop/'), isFalse);
      expect(shell.contains('window_manager'), isFalse);
      // 桌面导航组件本身不含平台分支（因此不会污染 Android 编译单元）。
      final String widgets = readLib('ui/widgets/petlife/petlife_desktop.dart');
      expect(widgets.contains('package:window_manager'), isFalse);
      expect(widgets.contains('Platform.isWindows'), isFalse);
    });

    test('桌面专属实现没有泄漏到 Android 编译单元（回归平台隔离）', () {
      // platform_isolation_test 已经全量扫描；这里再钉一次本轮新增的目录边界。
      for (final String dir in <String>['ui/mobile/', 'ui/theme/', 'ui/widgets/petlife/']) {
        final Directory d = Directory(p.join(root, 'lib', dir));
        if (!d.existsSync()) continue;
        for (final File f in d.listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart')) continue;
          final String source = f.readAsStringSync();
          expect(source.contains('package:window_manager'), isFalse);
          expect(source.contains('package:tray_manager'), isFalse);
          expect(source.contains('package:ffi/'), isFalse);
        }
      }
    });

    test('悬浮桌宠 / 轮盘逻辑没有被改动（关键文件仍然存在且被引用）', () {
      expect(File(p.join(root, 'lib', 'platform', 'overlay_pet.dart')).existsSync(),
          isTrue);
      expect(File(p.join(root, 'lib', 'menu', 'wheel_menu_geometry.dart')).existsSync(),
          isTrue);
      expect(File(p.join(root, 'lib', 'ui', 'overlay_pet_controller.dart')).existsSync(),
          isTrue);
      // Android 外壳仍然装配轮盘菜单动作与悬浮控制器（功能未减）。
      final String shell = readLib('ui/mobile/mobile_shell.dart');
      expect(shell, contains('OverlayMenuActionExecutor'));
      expect(shell, contains('OverlayPetController('));
      expect(shell, contains('_loadStateMapping'));
    });
  });
}

/// 构造一个只为测试用的 [OverlayRuntimeState]（只设置本测试关心的两个字段）。
OverlayRuntimeState _runtimeState({
  required bool serviceRunning,
  required bool hidden,
}) =>
    OverlayRuntimeState(
      supported: true,
      serviceRunning: serviceRunning,
      windowAttached: serviceRunning,
      enabled: true,
      hidden: hidden,
      overlayGranted: true,
      notificationsGranted: true,
      assetId: null,
      displayedAssetId: null,
      isPlaceholder: false,
      lastLoadError: null,
      lastUpdatedAt: null,
      animatedFirstFrameOnly: false,
      visualType: 'static',
      animationFrameMode: 'loop',
      animationSupported: true,
      animationPlaying: false,
      animationPausedReason: null,
      decodeCode: null,
      windowVisible: serviceRunning && !hidden,
      attachedToWindow: serviceRunning,
      viewWidth: 100,
      viewHeight: 100,
      imageViewWidth: 100,
      imageViewHeight: 100,
      lastWindowError: null,
      lastWindowAction: 'none',
      visual: 'none',
      debugOverlayMode: false,
      characterId: null,
      mimeType: null,
      isAnimated: false,
      frameCount: 1,
      animationDurationMs: 0,
      scale: 1,
      snapEnabled: true,
      snapEdge: 'none',
      snapOrientation: 'none',
      touchThrough: false,
      hideOnLockScreen: true,
      fixedAssetMode: false,
      xRatio: 0,
      yRatio: 0,
      petWidth: 100,
      petHeight: 100,
      gestureState: 'idle',
      menuState: 'closed',
      menuButtonCount: 0,
      lastMenuAction: null,
      menuLevel: 'none',
      menuActiveIndex: -1,
      menuAnimation: 'none',
      menuGestureOwner: 'pet',
      menuThemeId: 'p3p-pink',
      menuPerformance: '',
      menuOpenDiagnostics: '',
      lastMenuActionPlaceholder: false,
    );
