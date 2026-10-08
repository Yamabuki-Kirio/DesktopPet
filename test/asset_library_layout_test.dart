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

/// Phase 4A 真机缺陷三：**Android 素材库布局溢出**。
///
/// 根因是素材库在手机上仍用桌面布局：固定 260px 左栏 + 右侧素材网格，
/// 手机剩余宽度放不下，真机出现
/// `RIGHT OVERFLOWED BY 88 PIXELS` / `OVERFLOWED BY 134 PIXELS`。
///
/// 这里用真实 Widget 渲染，在各种宽度 / 横屏 / 字体放大下断言**没有 overflow**，
/// 并确认窄屏走纵向流程、宽屏保留分栏。
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

  Future<LibraryController> loadedLibrary(WidgetTester tester) async {
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

    final LibraryController library = await loadedLibrary(tester);
    await tester.pumpWidget(
      MaterialApp(
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
        // 窄屏必须走纵向流程：有"设为当前桌宠角色"按钮，而不是固定左栏。
        expect(find.text('设为当前桌宠角色'), findsOneWidget);
        // 素材卡片上的三个操作按钮必须都可见（曾经被挤出屏幕）。
        expect(find.byIcon(Icons.star_border), findsWidgets);
        expect(find.byIcon(Icons.delete_outline), findsWidgets);
      });
    }
  });

  testWidgets('横屏（780×360）：无 overflow，并回到宽屏分栏', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(780, 360));

    expect(tester.takeException(), isNull);
    // 780 >= 720 → 宽屏分栏：出现左侧"角色"树标题。
    expect(find.text('角色'), findsOneWidget);
  });

  testWidgets('窄窗口但支持文件夹导入：工具栏不得溢出', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(360, 780), folderImport: true);

    expect(tester.takeException(), isNull);
    expect(find.text('导入文件夹'), findsOneWidget);
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

  testWidgets('桌面宽屏（1280×800）：保留左右分栏，布局不退化', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(1280, 800));

    expect(tester.takeException(), isNull);
    // 宽屏：左侧作品包 / 角色树都在。
    expect(find.text('作品包'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Edgeworth'), findsOneWidget);
    // 窄屏才有的"设为当前桌宠角色"按钮在宽屏不出现（宽屏用角色行尾的播放按钮）。
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
