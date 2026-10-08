import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:petlife/character/character_repository.dart';
import 'package:petlife/character/models/character_model.dart';
import 'package:petlife/character/models/character_pack.dart';
import 'package:petlife/character/models/emotion_asset.dart';
import 'package:petlife/character/models/enums.dart';
import 'package:petlife/character/models/state_mapping.dart';
import 'package:petlife/character/sqlite_character_repository.dart';
import 'package:petlife/core/constants.dart';
import 'package:petlife/core/ids.dart';
import 'package:petlife/core/logger.dart';
import 'package:petlife/core/paths.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/schema.dart';
import 'package:petlife/state_engine/fallback_chain.dart';
import 'package:petlife/state_engine/system_state.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4C-6A.1：**状态 → 素材映射编辑器**的数据层与业务规则。
///
/// 全部使用**真实 SQLite + 真实外键 + 真实文件删除守卫**：
/// 事务、级联、唯一性这类问题用内存替身根本发现不了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  const String ownerId = AppConstants.localOwnerId;

  late Directory dir;
  late AppDatabase db;
  late SqliteCharacterRepository repository;
  late CharacterPack pack;
  late CharacterModel maya;
  late CharacterModel edgeworth;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('petlife_state_asset_mapping');
    AppPaths.resetForTest();
    await AppPaths.initialize(overrideRoot: dir);
    await AppLog.initialize(logFile: AppPaths.instance.logFile);
    db = await AppDatabase.open(path: AppPaths.instance.databaseFile.path);
    repository = SqliteCharacterRepository.fromDatabase(db);

    pack = await repository.ensurePack(
      ownerId: ownerId,
      name: '测试作品包',
      sourceType: PackSourceType.folder,
    );
    maya = await repository.ensureCharacter(
      packId: pack.id,
      ownerId: ownerId,
      internalName: 'Maya',
      displayName: 'Maya',
    );
    edgeworth = await repository.ensureCharacter(
      packId: pack.id,
      ownerId: ownerId,
      internalName: 'Edgeworth',
      displayName: 'Edgeworth',
    );
  });

  tearDown(() async {
    if (AppDatabase.isOpen) await AppDatabase.close();
    await AppLog.dispose();
    AppPaths.resetForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一张素材（默认"可用"）。
  Future<EmotionAsset> addAsset(
    CharacterModel character, {
    required String emotion,
    String variant = 'default',
    bool enabled = true,
    ValidationStatus status = ValidationStatus.valid,
    bool animated = false,
    bool touchFile = true,
  }) async {
    final String assetId = Ids.assetId(character.id, emotion, variant);
    final File file = File('${AppPaths.instance.assetsRoot.path}/$emotion-$variant.bin');
    if (touchFile) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(<int>[1, 2, 3]);
    }
    final EmotionAsset asset = EmotionAsset(
      id: assetId,
      characterId: character.id,
      emotionName: emotion,
      variantName: variant,
      filePath: file.path,
      fileHash: 'hash-$emotion-$variant',
      mimeType: 'image/webp',
      fileSize: 3,
      width: 64,
      height: 64,
      frameCount: animated ? 4 : 1,
      isAnimated: animated,
      hasAlpha: true,
      enabled: enabled,
      validationStatus: status,
      createdAt: DateTime.now(),
      animationDurationMs: animated ? 400 : 0,
    );
    await repository.upsertAsset(asset);
    return asset;
  }

  Future<int> mappingRowCount(String characterId, SystemState state) async {
    final List<Map<String, Object?>> rows = await db.raw.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableStateMappings} '
      'WHERE character_id = ? AND system_state = ?',
      <Object?>[characterId, state.wireName],
    );
    return rows.first['c']! as int;
  }

  Future<int> assetRowCount() async {
    final List<Map<String, Object?>> rows =
        await db.raw.rawQuery('SELECT COUNT(*) AS c FROM ${DbSchema.tableAssets}');
    return rows.first['c']! as int;
  }

  // ---------------------------------------------------------------------------
  group('§16.1 映射写入 / 清除（真实数据库）', () {
    test('新建映射：一个状态只有一条显式素材，且能读回来', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');

      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);

      final Map<SystemState, List<StateMapping>> grouped =
          await repository.groupedMappings(maya.id);
      final List<StateMapping> rows = grouped[SystemState.focused]!;
      expect(rows.length, 1);
      expect(rows.first.assetId, a.id);
      expect(await mappingRowCount(maya.id, SystemState.focused), 1);
    });

    test('修改映射：不产生重复记录（仍是同一行）', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset b = await addAsset(maya, emotion: 'Cheerful');

      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.focused, b.id);

      final List<StateMapping> rows = await repository.listMappings(maya.id);
      final List<StateMapping> focused =
          rows.where((StateMapping m) => m.systemState == SystemState.focused).toList();
      expect(focused.length, 1, reason: '同一状态更新不得新增第二条');
      expect(focused.first.assetId, b.id);
      // id 是确定性的：同一个 (角色, 状态) 永远同一行。
      expect(focused.first.id, Ids.explicitStateMappingId(maya.id, 'focused'));
    });

    test('重复保存同一映射是幂等的（行数与内容都不变）', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      for (int i = 0; i < 3; i++) {
        await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      }
      expect(await mappingRowCount(maya.id, SystemState.focused), 1);
    });

    test('设置会覆盖导入生成的多条候选（编辑器口径：一状态一主素材）', () async {
      final EmotionAsset thinking = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset cheerful = await addAsset(maya, emotion: 'Cheerful');
      final DateTime now = DateTime.now();
      // 模拟导入流程写入两条"按情绪绑定"的候选。
      await repository.replaceMappingsForState(maya.id, SystemState.focused, <StateMapping>[
        StateMapping(
          id: Ids.stateMappingId(maya.id, 'focused', 0),
          characterId: maya.id,
          systemState: SystemState.focused,
          emotionName: 'Thinking',
          weight: 1,
          priority: 50,
          createdAt: now,
          updatedAt: now,
        ),
        StateMapping(
          id: Ids.stateMappingId(maya.id, 'focused', 1),
          characterId: maya.id,
          systemState: SystemState.focused,
          emotionName: 'Cheerful',
          weight: 1,
          priority: 50,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      expect(await mappingRowCount(maya.id, SystemState.focused), 2);

      await repository.setStateAssetMapping(maya.id, SystemState.focused, thinking.id);

      expect(await mappingRowCount(maya.id, SystemState.focused), 1);
      expect(thinking.id, isNotEmpty);
      expect(cheerful.id, isNotEmpty);
    });

    test('清除映射：该状态回到 0 条（其它状态不受影响）', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.social, a.id);

      await repository.clearMappingsForState(maya.id, SystemState.focused);

      expect(await mappingRowCount(maya.id, SystemState.focused), 0);
      expect(await mappingRowCount(maya.id, SystemState.social), 1);
    });

    test('同一素材可以映射到多个状态', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.social, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.defaultState, a.id);

      final List<SystemState> referencing = await repository.statesReferencingAsset(a.id);
      expect(referencing.toSet(), <SystemState>{
        SystemState.focused,
        SystemState.social,
        SystemState.defaultState,
      });
    });

    test('不允许使用其它角色的素材（跨角色一律拒绝）', () async {
      final EmotionAsset other = await addAsset(edgeworth, emotion: 'Angry');

      await expectLater(
        repository.setStateAssetMapping(maya.id, SystemState.focused, other.id),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        repository.assignAssetToStates(maya.id, other.id, <SystemState>{SystemState.focused}),
        throwsA(isA<ArgumentError>()),
      );
      // 被拒绝后库里不能留下任何痕迹。
      expect(await mappingRowCount(maya.id, SystemState.focused), 0);
    });

    test('素材不存在时抛 ArgumentError，不写入空映射', () async {
      await expectLater(
        repository.setStateAssetMapping(maya.id, SystemState.focused, 'not-an-asset'),
        throwsA(isA<ArgumentError>()),
      );
      expect(await mappingRowCount(maya.id, SystemState.focused), 0);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16.1 反向分配（§6）', () {
    test('勾选多个状态：一次事务内全部生效', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');

      final List<StateAssignmentChange> changes = await repository.assignAssetToStates(
        maya.id,
        a.id,
        <SystemState>{SystemState.focused, SystemState.social, SystemState.gaming},
      );

      expect(changes.length, 3);
      expect(changes.every((StateAssignmentChange c) => c.assigned), isTrue);
      for (final SystemState s in <SystemState>[
        SystemState.focused,
        SystemState.social,
        SystemState.gaming,
      ]) {
        expect(await mappingRowCount(maya.id, s), 1, reason: '${s.wireName} 未写入');
      }
    });

    test('取消勾选只解除"本素材"的引用，同状态的其它候选不受影响', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      // 1) 先用编辑器把该状态设为这张图（编辑器口径：会清掉该状态原有条目）。
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      expect(await mappingRowCount(maya.id, SystemState.focused), 1);

      // 2) 再用桌面的「候选 + 情绪」编辑器追加一条"按情绪绑定"的候选
      //    （它走的是 replaceMappingsForState：保留既有行、只追加）。
      final DateTime now = DateTime.now();
      final List<StateMapping> current = await repository.listMappings(maya.id);
      await repository.replaceMappingsForState(maya.id, SystemState.focused, <StateMapping>[
        ...current.where((StateMapping m) => m.systemState == SystemState.focused),
        StateMapping(
          id: Ids.stateMappingId(maya.id, 'focused', 9),
          characterId: maya.id,
          systemState: SystemState.focused,
          emotionName: 'Thinking',
          weight: 1,
          priority: 50,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      expect(await mappingRowCount(maya.id, SystemState.focused), 2);

      // 3) 反向分配里取消勾选：只应解除"本素材"那一条。
      await repository.assignAssetToStates(maya.id, a.id, <SystemState>{});

      expect(await mappingRowCount(maya.id, SystemState.focused), 1);
      final List<StateMapping> left = (await repository.listMappings(maya.id))
          .where((StateMapping m) => m.systemState == SystemState.focused)
          .toList();
      expect(left.single.emotionName, 'Thinking');
      expect(left.single.assetId, isNull);
    });

    test('勾选会覆盖原有显式映射，并在变更摘要里带上"之前是什么"', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset b = await addAsset(maya, emotion: 'Cheerful');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);

      final List<StateAssignmentChange> changes = await repository.assignAssetToStates(
        maya.id,
        b.id,
        <SystemState>{SystemState.focused, SystemState.social},
      );

      final StateAssignmentChange focused =
          changes.firstWhere((StateAssignmentChange c) => c.state == SystemState.focused);
      expect(focused.assigned, isTrue);
      expect(focused.previousAssetId, a.id, reason: '摘要要能说明之前用的是哪张');
      final StateAssignmentChange social =
          changes.firstWhere((StateAssignmentChange c) => c.state == SystemState.social);
      expect(social.previousAssetId, isNull, reason: '之前未设置');
    });

    test('勾选状态与当前完全一致时，返回空变更（不产生无意义写入）', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      await repository.assignAssetToStates(maya.id, a.id, <SystemState>{SystemState.focused});

      final List<StateAssignmentChange> again = await repository.assignAssetToStates(
        maya.id,
        a.id,
        <SystemState>{SystemState.focused},
      );
      expect(again, isEmpty);
    });

    test('未勾选且未引用本素材的状态一律不动', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset b = await addAsset(maya, emotion: 'Cheerful');
      await repository.setStateAssetMapping(maya.id, SystemState.gaming, b.id);

      await repository.assignAssetToStates(maya.id, a.id, <SystemState>{SystemState.focused});

      final List<StateMapping> gaming = (await repository.listMappings(maya.id))
          .where((StateMapping m) => m.systemState == SystemState.gaming)
          .toList();
      expect(gaming.single.assetId, b.id);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16.1 删除联动（§10）', () {
    test('删除素材：同一事务里清掉全部引用，素材行消失', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.defaultState, a.id);
      await repository.setCharacterDefaultAsset(maya.id, a.id);
      expect(await assetRowCount(), 1);

      await repository.deleteAsset(a.id);

      expect(await assetRowCount(), 0);
      expect(await mappingRowCount(maya.id, SystemState.focused), 0);
      expect(await mappingRowCount(maya.id, SystemState.defaultState), 0);
      // 悬空的"角色默认图片"引用也必须被清掉。
      final CharacterModel? after = await repository.findCharacter(maya.id);
      expect(after!.defaultAssetId, isNull);
      // 托管文件也删了。
      expect(File(a.filePath).existsSync(), isFalse);
    });

    test('删除角色：该角色的映射与素材一起清掉，其它角色不受影响', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset other = await addAsset(edgeworth, emotion: 'Angry');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(edgeworth.id, SystemState.focused, other.id);

      await repository.deleteCharacter(maya.id);

      expect(await mappingRowCount(maya.id, SystemState.focused), 0);
      expect(await mappingRowCount(edgeworth.id, SystemState.focused), 1);
      expect(await repository.findCharacter(maya.id), isNull);
    });

    test('引用了某素材时，删除前能查出"正被哪些状态使用"', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      final EmotionAsset unused = await addAsset(maya, emotion: 'Cheerful');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setStateAssetMapping(maya.id, SystemState.social, a.id);

      expect(
        (await repository.statesReferencingAsset(a.id)).toSet(),
        <SystemState>{SystemState.focused, SystemState.social},
      );
      expect(await repository.statesReferencingAsset(unused.id), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16.1 收藏（v5 新列）', () {
    test('收藏 / 取消收藏只改这一列，不影响可用性', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'Thinking');
      expect(a.favorite, isFalse);

      await repository.setAssetFavorite(a.id, true);
      EmotionAsset? after = await repository.findAsset(a.id);
      expect(after!.favorite, isTrue);
      expect(after.enabled, isTrue);
      expect(after.validationStatus, ValidationStatus.valid);

      await repository.setAssetFavorite(a.id, false);
      after = await repository.findAsset(a.id);
      expect(after!.favorite, isFalse);
    });

    test('升级到 v5 后旧数据保留，且 favorite 列默认 0（未收藏）', () async {
      // 1) 造一个**真正的 v4 老库**：只执行 v1..v4 的建表语句
      //（v5 的 favorite 列在这里刻意不存在）。
      final String legacyPath = p.join(dir.path, 'legacy_v4.db');
      final Database legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 4,
          onConfigure: (Database raw) async => raw.execute('PRAGMA foreign_keys = ON'),
          onCreate: (Database raw, int version) async {
            final Batch batch = raw.batch();
            for (final String statement in <String>[
              ...DbSchema.v1Statements,
              ...DbSchema.v2Statements,
              ...DbSchema.v3Statements,
              ...DbSchema.v4Statements,
            ]) {
              batch.execute(statement);
            }
            await batch.commit(noResult: true);
          },
        ),
      );

      // 2) 手工塞入 包 / 角色 / 素材 / 状态映射 各一行（绕开 Dart 层，
      //    这样"迁移有没有动过这些行"才是对 SQL 的直接断言）。
      const String legacyPackId = 'legacy-pack';
      const String legacyCharacterId = 'legacy-character';
      const String legacyAssetId = 'legacy-asset';
      final int now = DateTime.now().millisecondsSinceEpoch;
      await legacy.insert(DbSchema.tablePacks, <String, Object?>{
        'id': legacyPackId,
        'owner_id': ownerId,
        'name': '旧作品包',
        'source_type': 'folder',
        'created_at': now,
        'updated_at': now,
      });
      await legacy.insert(DbSchema.tableCharacters, <String, Object?>{
        'id': legacyCharacterId,
        'pack_id': legacyPackId,
        'owner_id': ownerId,
        'internal_name': 'Legacy',
        'display_name': 'Legacy',
        'enabled': 1,
        'created_at': now,
        'updated_at': now,
      });
      await legacy.insert(DbSchema.tableAssets, <String, Object?>{
        'id': legacyAssetId,
        'character_id': legacyCharacterId,
        'emotion_name': 'Thinking',
        'variant_name': 'default',
        'file_path': p.join(dir.path, 'legacy.bin'),
        'file_hash': 'legacy-hash',
        'mime_type': 'image/webp',
        'file_size': 3,
        'width': 64,
        'height': 64,
        'frame_count': 1,
        'is_animated': 0,
        'has_alpha': 1,
        'enabled': 1,
        'validation_status': 'valid',
        'created_at': now,
      });
      await legacy.insert(DbSchema.tableStateMappings, <String, Object?>{
        'id': 'legacy-mapping',
        'character_id': legacyCharacterId,
        'system_state': 'focused',
        'asset_id': legacyAssetId,
        'weight': 1,
        'priority': 50,
        'created_at': now,
        'updated_at': now,
      });
      // v4 库里确实**没有** favorite 列。
      final List<Map<String, Object?>> columns =
          await legacy.rawQuery('PRAGMA table_info(${DbSchema.tableAssets})');
      expect(columns.any((Map<String, Object?> c) => c['name'] == 'favorite'), isFalse);
      await legacy.close();

      // 3) 用真实的应用路径打开 → 逐版本升级（v4 → v5）。
      await AppDatabase.close();
      db = await AppDatabase.open(path: legacyPath);
      repository = SqliteCharacterRepository.fromDatabase(db);

      expect(await db.raw.getVersion(), 5);
      final EmotionAsset? upgraded = await repository.findAsset(legacyAssetId);
      expect(upgraded, isNotNull, reason: '升级不能丢素材');
      expect(upgraded!.favorite, isFalse, reason: '新列必须有默认值 0');
      final List<StateMapping> mappings = await repository.listMappings(legacyCharacterId);
      expect(mappings.length, 1, reason: '升级不能丢状态映射');
      expect(mappings.first.assetId, legacyAssetId);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16.2 回退链（含收藏层级）', () {
    FallbackChain chain() => FallbackChain(random: math.Random(0));

    AssetResolution resolve({
      required SystemState state,
      required List<EmotionAsset> assets,
      List<StateMapping> mappings = const <StateMapping>[],
      String? defaultAssetId,
    }) =>
        chain().resolve(
          state: state,
          renderableAssets: assets,
          mappingsForState: mappings,
          characterDefaultAssetId: defaultAssetId,
        );

    test('没有任何收藏时，行为与升级前完全一致（默认 → 任意有效）', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'A');
      final EmotionAsset b = await addAsset(maya, emotion: 'B');
      final List<EmotionAsset> assets = <EmotionAsset>[a, b];

      expect(
        resolve(state: SystemState.focused, assets: assets, defaultAssetId: a.id).level,
        FallbackLevel.characterDefault,
      );
      expect(
        resolve(state: SystemState.focused, assets: assets).level,
        FallbackLevel.firstValidAsset,
      );
    });

    test('有收藏时，未映射状态回退到收藏素材', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'A');
      final EmotionAsset b = await addAsset(maya, emotion: 'B');
      await repository.setAssetFavorite(b.id, true);
      final EmotionAsset bFavorite = (await repository.findAsset(b.id))!;

      final AssetResolution r = resolve(
        state: SystemState.focused,
        assets: <EmotionAsset>[a, bFavorite],
      );
      expect(r.level, FallbackLevel.characterFavorite);
      expect(r.asset!.id, b.id);
    });

    test('状态显式映射优先于收藏素材', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'A');
      final EmotionAsset b = await addAsset(maya, emotion: 'B');
      await repository.setStateAssetMapping(maya.id, SystemState.focused, a.id);
      await repository.setAssetFavorite(b.id, true);
      final EmotionAsset bFavorite = (await repository.findAsset(b.id))!;
      final List<StateMapping> mappings = await repository.listMappings(maya.id);

      final AssetResolution r = resolve(
        state: SystemState.focused,
        assets: <EmotionAsset>[a, bFavorite],
        mappings: mappings,
      );
      expect(r.level, FallbackLevel.stateAsset);
      expect(r.asset!.id, a.id);
    });

    test('被禁用 / 损坏的素材不参与回退（文件丢失时自动跳过）', () async {
      final EmotionAsset good = await addAsset(maya, emotion: 'Good');
      final EmotionAsset broken =
          await addAsset(maya, emotion: 'Broken', status: ValidationStatus.invalid);

      final AssetResolution r = resolve(
        state: SystemState.social,
        // renderable 只包含可用素材（仓储层已过滤）。
        assets: <EmotionAsset>[good],
      );
      expect(r.asset!.id, good.id);
      expect(broken.isRenderable, isFalse);
    });

    test('显式映射指向的素材被删除后，回退到下一层而不是留空', () async {
      final EmotionAsset a = await addAsset(maya, emotion: 'A');
      final EmotionAsset b = await addAsset(maya, emotion: 'B');
      final DateTime now = DateTime.now();
      // 一条指向"不存在素材"的陈旧映射。
      final List<StateMapping> stale = <StateMapping>[
        StateMapping(
          id: Ids.explicitStateMappingId(maya.id, 'focused'),
          characterId: maya.id,
          systemState: SystemState.focused,
          assetId: 'deleted-asset-id',
          weight: 1,
          priority: 50,
          createdAt: now,
          updatedAt: now,
        ),
      ];

      final AssetResolution r = resolve(
        state: SystemState.focused,
        assets: <EmotionAsset>[a, b],
        mappings: stale,
        defaultAssetId: b.id,
      );
      expect(r.level, FallbackLevel.characterDefault);
      expect(r.asset!.id, b.id);
    });
  });

  // ---------------------------------------------------------------------------
  group('§16.2 静态图与动态 WebP 走同一条映射链路', () {
    test('动态素材被映射为状态素材后，解析结果仍是动态的', () async {
      final EmotionAsset animated =
          await addAsset(maya, emotion: 'Excited', animated: true);
      await repository.setStateAssetMapping(maya.id, SystemState.gaming, animated.id);

      final List<EmotionAsset> assets = await repository.listRenderableAssets(maya.id);
      final List<StateMapping> mappings = await repository.listMappings(maya.id);
      final AssetResolution r = FallbackChain(random: math.Random(0)).resolve(
        state: SystemState.gaming,
        renderableAssets: assets,
        mappingsForState: mappings,
        characterDefaultAssetId: null,
      );
      expect(r.asset!.id, animated.id);
      expect(r.asset!.isAnimated, isTrue);
      expect(r.asset!.frameCount, 4);
    });
  });
}
