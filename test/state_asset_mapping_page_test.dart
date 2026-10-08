import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/core/ids.dart';
import 'package:petlife/state_engine/system_state.dart';
import 'package:petlife/ui/library_controller.dart';
import 'package:petlife/ui/pages/state_asset_mapping_page.dart';

/// Phase 4C-6A.1：状态素材映射编辑器的界面行为与响应式布局
///（对应需求 §4 / §5 / §6 / §13 / §16.3）。
void main() {
  const String ownerId = 'test.owner';
  const String packId = 'pack-1';
  const String mayaId = 'char-maya';
  const String otherId = 'char-edgeworth';

  late Directory tmp;
  late _FakeRepository repo;
  late LibraryController library;

  String assetIdOf(String emotion) => Ids.assetId(mayaId, emotion, 'default');

  CharacterPack pack() => CharacterPack(
        id: packId,
        ownerId: ownerId,
        name: '测试包',
        sourceType: PackSourceType.folder,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  CharacterModel character(String id, String name) => CharacterModel(
        id: id,
        packId: packId,
        ownerId: ownerId,
        internalName: name,
        displayName: name,
        enabled: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  EmotionAsset asset({
    required String characterId,
    required String emotion,
    String variant = 'default',
    bool animated = false,
    bool enabled = true,
    ValidationStatus status = ValidationStatus.valid,
    bool fileExists = true,
  }) {
    final String path = p.join(tmp.path, '$characterId-$emotion-$variant.webp');
    final File file = File(path);
    if (fileExists) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(<int>[1, 2, 3]);
    }
    return EmotionAsset(
      id: Ids.assetId(characterId, emotion, variant),
      characterId: characterId,
      emotionName: emotion,
      variantName: variant,
      filePath: path,
      fileHash: 'hash-$emotion',
      mimeType: 'image/webp',
      fileSize: 2048,
      width: 128,
      height: 128,
      frameCount: animated ? 6 : 1,
      isAnimated: animated,
      hasAlpha: true,
      enabled: enabled,
      validationStatus: status,
      createdAt: DateTime(2026),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(440, 1200),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await library.load();
    await tester.pumpWidget(
      MaterialApp(
        home: StateAssetMappingPage(library: library, characterId: mayaId),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('petlife_mapping_ui');
    repo = _FakeRepository(
      packs: <CharacterPack>[pack()],
      characters: <CharacterModel>[
        character(mayaId, 'Maya'),
        character(otherId, 'Edgeworth'),
      ],
      assets: <EmotionAsset>[
        asset(characterId: mayaId, emotion: 'Default'),
        asset(characterId: mayaId, emotion: 'Thinking'),
        asset(characterId: mayaId, emotion: 'Cheerful', animated: true),
        asset(characterId: mayaId, emotion: 'Broken', status: ValidationStatus.invalid),
        asset(characterId: mayaId, emotion: 'Gone', fileExists: false),
        // 另一个角色的素材：**绝不允许**出现在选择器里。
        asset(characterId: otherId, emotion: 'Angry'),
      ],
    );
    library = LibraryController(repository: repo, ownerId: ownerId);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('状态卡片按固定顺序展示，并同时给出中文名与 wire value', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(find.text('默认'), findsOneWidget);
    expect(find.text('default'), findsOneWidget);
    expect(find.text('专注'), findsOneWidget);
    expect(find.text('focused'), findsOneWidget);
    expect(find.text('游戏'), findsOneWidget);

    // §4.2 固定顺序：default → focused → … 不按数据库返回序。
    final double defaultY = tester.getTopLeft(find.text('default')).dy;
    final double focusedY = tester.getTopLeft(find.text('focused')).dy;
    final double gamingY = tester.getTopLeft(find.text('游戏')).dy;
    expect(defaultY, lessThan(focusedY));
    expect(focusedY, lessThan(gamingY));
  });

  testWidgets('已映射与"回退"必须能被区分（不把回退伪装成已设置）', (WidgetTester tester) async {
    await library.setStateAssetMapping(mayaId, SystemState.focused, assetIdOf('Thinking'));
    await pumpPage(tester);

    expect(find.text('已映射'), findsOneWidget, reason: 'focused 是显式映射');
    expect(find.text('回退 · 任意可用素材'), findsWidgets, reason: '其余状态走回退');
    // 回退文案里必须点明不是用户设置的。
    expect(find.textContaining('未设置素材'), findsWidgets);
  });

  testWidgets('映射的素材文件丢失时给出"文件丢失"，而不是当成正常映射', (WidgetTester tester) async {
    await library.setStateAssetMapping(mayaId, SystemState.focused, assetIdOf('Gone'));
    await pumpPage(tester);

    expect(find.text('文件丢失'), findsOneWidget);
    expect(find.textContaining('文件不在磁盘上'), findsOneWidget);
  });

  testWidgets('映射的素材被禁用时给出"映射已失效"', (WidgetTester tester) async {
    final EmotionAsset disabled = repo.assets.firstWhere(
      (EmotionAsset a) => a.emotionName == 'Broken',
    );
    await library.setStateAssetMapping(mayaId, SystemState.focused, disabled.id);
    await pumpPage(tester);

    expect(find.text('映射已失效'), findsOneWidget);
    expect(find.textContaining('被禁用或校验未通过'), findsOneWidget);
  });

  testWidgets('窄屏 360dp + 字体放大 1.3 时不溢出（§13）', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(360, 900), textScale: 1.3);
    expect(tester.takeException(), isNull, reason: '360dp / 1.3x 下出现溢出');
  });

  testWidgets('横屏（720×400）时不溢出', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(720, 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('清除映射必须先确认；清除 default 时额外说明会影响其它未映射状态', (WidgetTester tester) async {
    await library.setStateAssetMapping(mayaId, SystemState.defaultState, assetIdOf('Default'));
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(TextButton, '清除').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('清除「默认」的素材映射？'), findsOneWidget);
    expect(find.textContaining('角色收藏素材'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();

    expect(repo.mappingsFor(mayaId, SystemState.defaultState), isEmpty);
  });

  testWidgets('选择器只显示当前角色的素材，且不可用素材被标注', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '选择素材').first);
    await tester.pumpAndSettle();

    expect(find.text('为「默认」选择素材'), findsOneWidget);
    // 素材名在状态卡片上也会出现（回退结果），因此断言必须限定在**选择器的网格**里。
    final Finder grid = find.byType(GridView);
    expect(grid, findsOneWidget);
    Finder inGrid(String text) => find.descendant(of: grid, matching: find.text(text));

    expect(inGrid('Default / default'), findsOneWidget);
    expect(inGrid('Thinking / default'), findsOneWidget);
    // 另一个角色的素材不得出现（需求 §5.1）。
    expect(inGrid('Angry / default'), findsNothing);
    expect(find.text('Angry / default'), findsNothing);
    // 损坏素材可见，但标注为不可用。
    expect(inGrid('不可用'), findsOneWidget);
    // 动态素材要有明确标识。
    expect(inGrid('动态'), findsOneWidget);
  });

  testWidgets('点击素材只是查看；必须点"设为素材"才写库（§5.3）', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '选择素材').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thinking / default'));
    await tester.pumpAndSettle();

    // 只是查看：还没有写入任何映射。
    expect(repo.mappingsFor(mayaId, SystemState.defaultState), isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '设为「默认」素材'));
    await tester.pumpAndSettle();

    final List<StateMapping> written = repo.mappingsFor(mayaId, SystemState.defaultState);
    expect(written.length, 1);
    expect(written.single.assetId, assetIdOf('Thinking'));
  });

  testWidgets('不可用素材的"设为素材"按钮必须禁用（不能把坏素材写进映射）',
      (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, '选择素材').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Broken / default'));
    await tester.pumpAndSettle();

    final FilledButton setAsState = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '设为「默认」素材'),
    );
    expect(setAsState.onPressed, isNull);
  });

  testWidgets('反向分配：勾选状态后显示变更摘要，保存写入（§6）', (WidgetTester tester) async {
    // 对话框里有 11 个状态，给一个足够高的视口，避免"点到了对话框外面"。
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await library.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showAssignStatesDialog(
                  ctx,
                  library: library,
                  characterId: mayaId,
                  assetId: assetIdOf('Thinking'),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('分配给状态'), findsOneWidget);
    // 初始没有勾选，摘要为空。
    expect(find.text('（没有变更）'), findsOneWidget);

    // 勾选「社交」。
    await tester.ensureVisible(find.text('社交（social）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('社交（social）'));
    await tester.pumpAndSettle();
    expect(find.text('变更摘要'), findsOneWidget);
    expect(find.textContaining('社交：未设置 → 本素材'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(repo.mappingsFor(mayaId, SystemState.social).length, 1);
    expect(repo.mappingsFor(mayaId, SystemState.social).single.assetId, assetIdOf('Thinking'));
  });

  testWidgets('角色不存在时给出明确空状态而不是白屏', (WidgetTester tester) async {
    await library.load();
    await tester.pumpWidget(
      MaterialApp(
        home: StateAssetMappingPage(library: library, characterId: 'not-a-character'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('角色不存在'), findsOneWidget);
  });
}

/// 内存仓库替身：只实现映射编辑器用到的读写。
class _FakeRepository implements CharacterRepository {
  _FakeRepository({
    required this.packs,
    required this.characters,
    required this.assets,
  });

  final List<CharacterPack> packs;
  final List<CharacterModel> characters;
  final List<EmotionAsset> assets;
  final List<StateMapping> mappings = <StateMapping>[];

  List<StateMapping> mappingsFor(String characterId, SystemState state) => mappings
      .where((StateMapping m) => m.characterId == characterId && m.systemState == state)
      .toList(growable: false);

  @override
  Future<LibrarySnapshot> loadSnapshot(String ownerId) async => LibrarySnapshot(
        packs: packs,
        characters: characters,
        assets: assets,
        mappings: List<StateMapping>.from(mappings),
      );

  @override
  Future<void> setStateAssetMapping(
    String characterId,
    SystemState state,
    String assetId,
  ) async {
    final EmotionAsset asset = assets.firstWhere((EmotionAsset a) => a.id == assetId);
    if (asset.characterId != characterId) {
      throw ArgumentError.value(assetId, 'assetId', '不允许使用其它角色的素材');
    }
    mappings.removeWhere(
      (StateMapping m) => m.characterId == characterId && m.systemState == state,
    );
    mappings.add(StateMapping(
      id: Ids.explicitStateMappingId(characterId, state.wireName),
      characterId: characterId,
      systemState: state,
      assetId: assetId,
      weight: 1,
      priority: state.priority,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ));
  }

  @override
  Future<void> clearMappingsForState(String characterId, SystemState state) async {
    mappings.removeWhere(
      (StateMapping m) => m.characterId == characterId && m.systemState == state,
    );
  }

  @override
  Future<void> setAssetFavorite(String assetId, bool favorite) async {
    final int i = assets.indexWhere((EmotionAsset a) => a.id == assetId);
    if (i >= 0) assets[i] = assets[i].copyWith(favorite: favorite);
  }

  @override
  Future<List<SystemState>> statesReferencingAsset(String assetId) async {
    final Set<SystemState> out = <SystemState>{};
    for (final StateMapping m in mappings) {
      if (m.assetId == assetId) out.add(m.systemState);
    }
    return out.toList(growable: false);
  }

  @override
  Future<List<StateAssignmentChange>> assignAssetToStates(
    String characterId,
    String assetId,
    Set<SystemState> states,
  ) async {
    final List<StateAssignmentChange> changes = <StateAssignmentChange>[];
    for (final SystemState state in SystemState.values) {
      final List<StateMapping> current = mappingsFor(characterId, state);
      final bool pointsHere = current.any((StateMapping m) => m.assetId == assetId);
      if (states.contains(state) && !pointsHere) {
        changes.add(StateAssignmentChange(
          state: state,
          previousAssetId: current.isEmpty ? null : current.first.assetId,
          assigned: true,
        ));
        await setStateAssetMapping(characterId, state, assetId);
      } else if (!states.contains(state) && pointsHere) {
        mappings.removeWhere(
          (StateMapping m) =>
              m.characterId == characterId && m.systemState == state && m.assetId == assetId,
        );
        changes.add(StateAssignmentChange(
          state: state,
          previousAssetId: assetId,
          assigned: false,
        ));
      }
    }
    return changes;
  }

  @override
  Future<void> setCharacterDefaultAsset(String characterId, String? assetId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未实现 ${invocation.memberName}');
}
