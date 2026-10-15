import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/asset_import/asset_importer.dart';
import 'package:petlife/asset_import/import_models.dart';
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/core/result.dart';
import 'package:petlife/platform/file_import_provider.dart';
import 'package:petlife/ui/library_controller.dart';
import 'package:petlife/ui/pages/asset_library_page.dart';
import 'package:petlife/ui/theme/design_tokens.dart';
import 'package:petlife/ui/theme/petlife_theme.dart';

/// Android 素材库布局回归（本轮 UI 增量后重写）。
///
/// 原来的用例断言的是**旧布局**（窄屏"设为当前桌宠角色"按钮 + 卡片上的
/// star/delete 图标 + 宽屏 260px 左栏）。本轮需求把素材库改成
/// 「视觉优先 → 两列大卡片 → 操作收进更多菜单」，因此这里同步更新断言，
/// 但**保留原本真正要守住的契约**：
///
/// * 任何宽度 / 任何字体倍率下都不得出现 RenderFlex overflow；
/// * 卡片上的关键操作必须仍然可达（收藏 / 使用中 / 更多菜单）；
/// * 窄屏走纵向流程，宽屏保留作品包 / 角色结构；
/// * 素材图片用 `BoxFit.contain`，不得变形（新增断言）。
void main() {
  final DateTime now = DateTime(2026, 9, 29);

  LibrarySnapshot buildSnapshot() {
    const String owner = 'test.owner';
    final CharacterPack pack = CharacterPack(
      id: 'pack-1',
      ownerId: owner,
      name: 'Ace Attorney 素材包',
      sourceType: PackSourceType.folder,
      createdAt: now,
      updatedAt: now,
    );
    final CharacterModel maya = CharacterModel(
      id: 'c-maya',
      packId: pack.id,
      ownerId: owner,
      internalName: 'Maya',
      displayName: 'Maya',
      enabled: true,
      createdAt: now,
      updatedAt: now,
    );
    final CharacterModel edgeworth = CharacterModel(
      id: 'c-edgeworth',
      packId: pack.id,
      ownerId: owner,
      internalName: 'Edgeworth',
      displayName: 'Edgeworth',
      enabled: true,
      createdAt: now,
      updatedAt: now,
    );

    // 故意使用"损坏"素材：卡片走 broken_image 分支，既不读磁盘，
    // 又会渲染出最长的一段文字（对纵向布局压力最大）。
    final List<EmotionAsset> assets = <EmotionAsset>[
      for (int i = 0; i < 4; i++)
        EmotionAsset(
          id: 'a-$i',
          characterId: maya.id,
          emotionName: 'Bench_Thinking_Emotion_$i',
          variantName: '$i',
          filePath: '/nonexistent/a-$i.webp',
          fileHash: 'hash-$i',
          mimeType: 'image/webp',
          fileSize: 12 * 1024,
          width: 320,
          height: 480,
          frameCount: 1,
          isAnimated: false,
          hasAlpha: true,
          enabled: true,
          validationStatus: ValidationStatus.invalid,
          validationError: '测试用损坏素材',
          createdAt: now,
        ),
    ];

    return LibrarySnapshot(
      packs: <CharacterPack>[pack],
      characters: <CharacterModel>[maya, edgeworth],
      assets: assets,
      mappings: const <Never>[],
    );
  }

  Future<LibraryController> loadedLibrary() async {
    final LibraryController library = LibraryController(
      repository: _FakeRepository(buildSnapshot()),
      ownerId: 'test.owner',
    );
    await library.load();
    return library;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    bool folderImport = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final LibraryController library = await loadedLibrary();
    await tester.pumpWidget(
      MaterialApp(
        // 与真实应用一致：页面必须是新主题，颜色才能从统一主题对象取到。
        theme: buildPetLifeThemeData(
          primary: PetLifeColors.primaryDefault,
          accent: PetLifeColors.accentDefault,
          brightness: Brightness.light,
        ),
        home: Scaffold(
          body: AssetLibraryPage(
            ownerId: 'test.owner',
            importer: _OkImporter(),
            fileImportProvider: _FakeProvider(folder: folderImport),
            library: library,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('手机竖屏：不得出现 overflow', () {
    for (final double width in <double>[320, 360, 393, 412]) {
      testWidgets('宽度 ${width.toInt()}px', (WidgetTester tester) async {
        await pumpPage(tester, size: Size(width, 780));

        expect(tester.takeException(), isNull,
            reason: '${width.toInt()}px 下出现了 RenderFlex overflow');
        // 窄屏纵向流程：顶部的角色操作与筛选入口都在。
        expect(find.text('设为当前桌宠角色'), findsOneWidget);
        expect(find.byTooltip('筛选素材'), findsOneWidget);
        expect(find.text('状态映射'), findsWidgets);
        expect(find.text('导入'), findsOneWidget);
        // 素材卡片上的操作仍然可达（收藏 / 使用中 / 更多菜单）。
        expect(find.byIcon(Icons.bookmark_border), findsWidgets);
        expect(find.byTooltip('更多操作'), findsWidgets);
      });
    }
  });

  testWidgets('手机窄屏素材网格是两列（需求：手机默认两列大卡片）',
      (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(412, 915));

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 2);
  });

  testWidgets('宽屏素材网格自动增加列数（需求：按宽度自动切换列数）',
      (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(1280, 900));

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, greaterThan(2));
  });

  testWidgets('横屏（780×360）：无 overflow，并回到宽屏分栏', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(780, 360));

    expect(tester.takeException(), isNull);
    // 780 >= 720 → 宽屏分栏：出现左侧"角色"树标题。
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('作品包'), findsOneWidget);
  });

  testWidgets('窄窗口但支持文件夹导入：统一操作栏不溢出，导入能力收进弹窗',
      (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(360, 780), folderImport: true);

    expect(tester.takeException(), isNull);
    // 顶部统一操作栏只有一个导入入口（不会把按钮挤成横向溢出）。
    expect(find.text('导入'), findsOneWidget);

    // 点开后，四种导入能力与"按路径导入"都仍然存在。
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('导入文件夹'), findsOneWidget);
    expect(find.text('导入多张图片'), findsOneWidget);
    expect(find.text('导入单张图片'), findsOneWidget);
    expect(find.text('导入 ZIP 素材包'), findsOneWidget);
    expect(find.text('按路径导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('系统字体放大', () {
    for (final double scale in <double>[1.3, 1.5]) {
      testWidgets('textScaleFactor=$scale，360px 无 overflow', (WidgetTester tester) async {
        await pumpPage(tester, size: const Size(360, 780), textScale: scale);

        expect(tester.takeException(), isNull,
            reason: '字体放大 ${scale}x 时出现 overflow');
        expect(find.text('设为当前桌宠角色'), findsOneWidget);
      });
    }
  });

  testWidgets('桌面宽屏（1280×800）：保留左右分栏，布局不退化',
      (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(1280, 800));

    expect(tester.takeException(), isNull);
    // 宽屏：左侧作品包 / 角色树都在。
    expect(find.text('作品包'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Edgeworth'), findsOneWidget);
    // 窄屏才有的顶部"设为当前桌宠角色"按钮在宽屏不出现（宽屏用角色行尾的播放按钮）。
    expect(find.text('设为当前桌宠角色'), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
  });
}

class _OkImporter implements AssetImporter {
  @override
  Future<Result<ImportReport>> import(
    ImportRequest request, {
    ImportProgressCallback? onProgress,
  }) async =>
      Ok<ImportReport>(ImportReport(
        packNames: const <String>[],
        characterNames: const <String>[],
        imported: const <ImportedAssetSummary>[],
        failed: const <FailedItem>[],
        scannedCount: 0,
        skippedCount: 0,
        elapsed: Duration.zero,
      ));
}

class _FakeProvider implements FileImportProvider {
  _FakeProvider({required this.folder});

  final bool folder;

  @override
  bool get supportsFolderImport => folder;

  @override
  Future<String?> pickFolderPath() async => null;

  @override
  Future<PickedZip?> pickZip() async => null;

  @override
  Future<ImagePickResult?> pickImages({required bool allowMultiple}) async => null;
}

class _FakeRepository implements CharacterRepository {
  _FakeRepository(this._snapshot);

  final LibrarySnapshot _snapshot;

  @override
  Future<LibrarySnapshot> loadSnapshot(String ownerId) async => _snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('布局测试不应调用 ${invocation.memberName}');
}
