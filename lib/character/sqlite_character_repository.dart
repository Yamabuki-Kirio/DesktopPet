import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/ids.dart';
import '../core/logger.dart';
import '../core/paths.dart';
import '../database/app_database.dart';
import '../database/dao/asset_dao.dart';
import '../database/dao/character_dao.dart';
import '../database/dao/pack_dao.dart';
import '../database/dao/state_mapping_dao.dart';
import '../state_engine/system_state.dart';
import 'character_repository.dart';
import 'models/character_model.dart';
import 'models/character_pack.dart';
import 'models/emotion_asset.dart';
import 'models/enums.dart';
import 'models/state_mapping.dart';

/// 基于 SQLite 的素材库实现。
class SqliteCharacterRepository implements CharacterRepository {
  SqliteCharacterRepository._(
    this._database,
    this._packs,
    this._characters,
    this._assets,
    this._mappings,
  ) : _txnExecutor = null;

  /// 从全局数据库构建。
  factory SqliteCharacterRepository.fromDatabase(AppDatabase db) => SqliteCharacterRepository._(
        db.raw,
        PackDao(db.raw),
        CharacterDao(db.raw),
        AssetDao(db.raw),
        StateMappingDao(db.raw),
      );

  /// 事务作用域实例：所有 DAO 绑定到同一个 [Transaction]。
  ///
  /// [_database] 为 null 表示「已经在事务里」，因此不能再开事务。
  SqliteCharacterRepository._scoped(DatabaseExecutor executor)
      : _database = null,
        _txnExecutor = executor,
        _packs = PackDao(executor),
        _characters = CharacterDao(executor),
        _assets = AssetDao(executor),
        _mappings = StateMappingDao(executor);

  /// 底层连接；事务作用域实例为 null。
  final Database? _database;

  /// 事务作用域下的执行器；非事务实例为 null。
  final DatabaseExecutor? _txnExecutor;

  /// 需要「跨多张表原子写入」时统一走这里。
  ///
  /// 已有连接就自己开事务；已经处在事务里（导入流程 / 角色删除会这样调进来）
  /// 就直接在**外层事务**上执行 —— 嵌套开事务会死锁。
  Future<T> _inTransaction<T>(Future<T> Function(DatabaseExecutor exec) action) async {
    final Database? db = _database;
    if (db != null) {
      return db.transaction<T>((Transaction txn) => action(txn));
    }
    final DatabaseExecutor? exec = _txnExecutor;
    if (exec == null) {
      throw StateError('仓储既没有数据库连接，也不在事务中');
    }
    return action(exec);
  }

  final PackDao _packs;
  final CharacterDao _characters;
  final AssetDao _assets;
  final StateMappingDao _mappings;

  @override
  Future<T> transaction<T>(Future<T> Function(CharacterRepository repo) action) async {
    final Database? db = _database;
    if (db == null) {
      throw StateError('已处于事务中：SqliteCharacterRepository.transaction 不支持嵌套调用');
    }
    return db.transaction<T>(
      (Transaction txn) async => action(SqliteCharacterRepository._scoped(txn)),
    );
  }

  @override
  Future<LibrarySnapshot> loadSnapshot(String ownerId) async {
    final List<CharacterPack> packs = await _packs.listByOwner(ownerId);
    final List<CharacterModel> chars = await _characters.listByOwner(ownerId);
    final List<EmotionAsset> assets =
        await _assets.listByCharacters(chars.map((CharacterModel c) => c.id).toList());
    final List<StateMapping> mappings = <StateMapping>[];
    for (final CharacterModel c in chars) {
      mappings.addAll(await _mappings.listByCharacter(c.id));
    }
    return LibrarySnapshot(
      packs: packs,
      characters: chars,
      assets: assets,
      mappings: mappings,
    );
  }

  @override
  Future<List<CharacterPack>> listPacks(String ownerId) => _packs.listByOwner(ownerId);

  @override
  Future<List<CharacterModel>> listCharacters(String ownerId) => _characters.listByOwner(ownerId);

  @override
  Future<List<CharacterModel>> listCharactersInPack(String packId) => _characters.listByPack(packId);

  @override
  Future<CharacterModel?> findCharacter(String characterId) => _characters.findById(characterId);

  @override
  Future<List<EmotionAsset>> listRenderableAssets(String characterId) =>
      _assets.listByCharacter(characterId);

  @override
  Future<List<EmotionAsset>> listAllAssets(String characterId) =>
      _assets.listAllByCharacter(characterId);

  @override
  Future<EmotionAsset?> findAsset(String assetId) => _assets.findById(assetId);

  @override
  Future<void> setCharacterDefaultAsset(String characterId, String? assetId) async {
    await _characters.setDefaultAsset(characterId, assetId, DateTime.now());
    Loggers.character.info('设置角色默认图片: character=$characterId asset=${assetId ?? '<清空>'}');
  }

  @override
  Future<void> setCharacterEnabled(String characterId, bool enabled) async {
    await _characters.setEnabled(characterId, enabled, DateTime.now());
    Loggers.character.info('角色启用状态变更: character=$characterId enabled=$enabled');
  }

  @override
  Future<void> setAssetEnabled(String assetId, bool enabled) async {
    await _assets.setEnabled(assetId, enabled);
    Loggers.character.info('素材启用状态变更: asset=$assetId enabled=$enabled');
  }

  @override
  Future<void> setAssetFavorite(String assetId, bool favorite) async {
    await _assets.setFavorite(assetId, favorite);
    Loggers.character.info('素材收藏状态变更: asset=$assetId favorite=$favorite');
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    final EmotionAsset? asset = await _assets.findById(assetId);
    if (asset == null) return;

    // --- 数据库侧三步必须在**同一个事务**里（需求 §10.1）---
    // 顺序：先解除引用 → 再删素材行 → 最后清悬空默认图片。
    // 任一步失败整体回滚，绝不会留下"映射删了但素材还在"或反之的半完成状态。
    final int removedMappings = await _inTransaction<int>((DatabaseExecutor exec) async {
      final StateMappingDao mappings = StateMappingDao(exec);
      final AssetDao assets = AssetDao(exec);
      final CharacterDao characters = CharacterDao(exec);
      final int removed = await mappings.deleteReferencingAsset(assetId);
      await assets.deleteById(assetId);
      await characters.clearDefaultAssetByAssetId(assetId, DateTime.now());
      return removed;
    });

    // --- 文件删除**不可回滚**，因此放在事务提交之后 ---
    // 失败只记日志：数据库已经一致，用户看到的最多是"托管目录里留了个孤儿文件"，
    // 绝不会是坏数据或黑框（需求 §10.1 末句）。
    _deleteManagedFile(asset.filePath, assetId);
    Loggers.character.info(
      '素材已删除: id=$assetId file=${p.basename(asset.filePath)} 清理状态映射引用=$removedMappings',
    );
  }

  /// 只删除应用托管目录内的副本。
  ///
  /// 这是「用户原始素材不会被修改或删除」这条硬约束的最后一道防线：
  /// 任何不在 `AppPaths.assetsRoot` 下的路径一律拒绝删除并记录警告。
  void _deleteManagedFile(String path, String assetId) {
    if (!AppPaths.isInitialized) return;
    final String root = p.normalize(AppPaths.instance.assetsRoot.path);
    final String target = p.normalize(path);
    if (!p.isWithin(root, target)) {
      Loggers.character.warning(
        '拒绝删除托管目录之外的路径（已跳过）: asset=$assetId path=$target',
      );
      return;
    }
    try {
      final File f = File(target);
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) {
      Loggers.character.warning('托管副本删除失败: $target', e, st);
    }
  }

  @override
  Future<void> deleteCharacter(String characterId) async {
    final List<EmotionAsset> assets = await _assets.listAllByCharacter(characterId);

    // 数据库侧三步（清映射 → 清素材 → 删角色）在**同一个事务**里，
    // 避免留下"角色没了但映射还在"这种会让原生拿到失效 characterId 的中间态。
    await _inTransaction<void>((DatabaseExecutor exec) async {
      await StateMappingDao(exec).deleteByCharacter(characterId);
      await AssetDao(exec).deleteByCharacter(characterId);
      await CharacterDao(exec).deleteById(characterId);
    });

    // 文件删除不可回滚，放在提交之后；失败只记日志。
    for (final EmotionAsset a in assets) {
      _deleteManagedFile(a.filePath, a.id);
    }
    Loggers.character.info('角色已删除: id=$characterId，清理素材 ${assets.length} 个');
  }

  @override
  Future<void> deletePack(String packId) async {
    final List<CharacterModel> chars = await _characters.listByPack(packId);
    for (final CharacterModel c in chars) {
      await deleteCharacter(c.id);
    }
    await _packs.deleteById(packId);
    Loggers.character.info('作品包已删除: id=$packId，清理角色 ${chars.length} 个');
  }

  @override
  Future<List<StateMapping>> listMappings(String characterId) =>
      _mappings.listByCharacter(characterId);

  @override
  Future<Map<SystemState, List<StateMapping>>> groupedMappings(String characterId) =>
      _mappings.groupedByState(characterId);

  @override
  Future<void> replaceMappingsForState(
    String characterId,
    SystemState state,
    List<StateMapping> mappings,
  ) async {
    await _mappings.replaceForState(characterId, state, mappings);
    Loggers.character.info(
      '状态映射更新: character=$characterId state=${state.wireName} 候选数=${mappings.length}',
    );
  }

  @override
  Future<void> clearMappingsForState(String characterId, SystemState state) async {
    await _mappings.replaceForState(characterId, state, const <StateMapping>[]);
    Loggers.character.info('状态映射已清空（恢复自动）: character=$characterId state=${state.wireName}');
  }

  // ---------------------------------------------------------------------------
  // Phase 4C-6A.1：状态素材映射编辑器
  // ---------------------------------------------------------------------------

  @override
  Future<void> setStateAssetMapping(
    String characterId,
    SystemState state,
    String assetId,
  ) async {
    final EmotionAsset asset = await _requireOwnedAsset(characterId, assetId);
    await _mappings.setExplicitForState(
      characterId,
      state,
      _explicitMapping(characterId, state, asset),
    );
    Loggers.character.info(
      '状态素材映射已设置: character=$characterId state=${state.wireName} '
      'asset=$assetId（${asset.emotionName}/${asset.variantName}）',
    );
  }

  @override
  Future<List<StateAssignmentChange>> assignAssetToStates(
    String characterId,
    String assetId,
    Set<SystemState> states,
  ) async {
    final EmotionAsset asset = await _requireOwnedAsset(characterId, assetId);

    return _inTransaction<List<StateAssignmentChange>>((DatabaseExecutor exec) async {
      final StateMappingDao mappings = StateMappingDao(exec);
      final List<StateMapping> existing = await mappings.listByCharacter(characterId);

      // 每个状态当前的**显式素材**（跳过情绪绑定行）。
      final Map<SystemState, String> explicit = <SystemState, String>{};
      for (final StateMapping m in existing) {
        final String? id = m.assetId;
        if (id == null) continue;
        explicit.putIfAbsent(m.systemState, () => id);
      }

      final List<StateAssignmentChange> changes = <StateAssignmentChange>[];
      for (final SystemState state in SystemState.values) {
        final String? current = explicit[state];
        final bool wantAssign = states.contains(state);
        final bool pointsHere = current == assetId;

        if (wantAssign && !pointsHere) {
          await mappings.setExplicitForState(
            characterId,
            state,
            _explicitMapping(characterId, state, asset),
          );
          changes.add(StateAssignmentChange(
            state: state,
            previousAssetId: current,
            assigned: true,
          ));
        } else if (!wantAssign && pointsHere) {
          // 只解除"指向本素材"的那一条，**不**动该状态的其它候选
          // （导入可能给同一状态写了多条情绪绑定，它们不归本次操作管）。
          for (final StateMapping m in await mappings.listByState(characterId, state)) {
            if (m.assetId == assetId) await mappings.deleteById(m.id);
          }
          changes.add(StateAssignmentChange(
            state: state,
            previousAssetId: assetId,
            assigned: false,
          ));
        }
      }
      return changes;
    });
  }

  @override
  Future<List<SystemState>> statesReferencingAsset(String assetId) async {
    final List<StateMapping> rows = await _mappings.listReferencingAsset(assetId);
    final List<SystemState> out = <SystemState>[];
    for (final StateMapping m in rows) {
      if (!out.contains(m.systemState)) out.add(m.systemState);
    }
    return out;
  }

  /// 取出素材并校验它**属于该角色**（跨角色素材一律拒绝 —— 需求 §5.1 / §7）。
  Future<EmotionAsset> _requireOwnedAsset(String characterId, String assetId) async {
    final EmotionAsset? asset = await _assets.findById(assetId);
    if (asset == null) {
      throw ArgumentError.value(assetId, 'assetId', '素材不存在（可能已被删除）');
    }
    if (asset.characterId != characterId) {
      throw ArgumentError.value(assetId, 'assetId', '不允许使用其它角色的素材');
    }
    return asset;
  }

  /// 构造编辑器口径的显式映射行。
  ///
  /// `emotionName` 刻意留空：这是**精确到图片**的绑定，不该顺带引入一条
  /// "按情绪匹配"的候选（那会让回退链第 2 级匹配到别的图）。
  StateMapping _explicitMapping(String characterId, SystemState state, EmotionAsset asset) {
    final DateTime now = DateTime.now();
    return StateMapping(
      id: Ids.explicitStateMappingId(characterId, state.wireName),
      characterId: characterId,
      systemState: state,
      assetId: asset.id,
      weight: 1,
      priority: state.priority,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<LibraryStats> stats(String ownerId) async {
    final LibrarySnapshot snap = await loadSnapshot(ownerId);
    int animated = 0;
    int invalid = 0;
    int disabled = 0;
    for (final EmotionAsset a in snap.assets) {
      if (a.isAnimated) animated++;
      if (a.validationStatus == ValidationStatus.invalid) invalid++;
      if (!a.enabled) disabled++;
    }
    return LibraryStats(
      packCount: snap.packs.length,
      characterCount: snap.characters.length,
      assetCount: snap.assets.length,
      animatedCount: animated,
      staticCount: snap.assets.length - animated,
      invalidCount: invalid,
      disabledCount: disabled,
    );
  }

  @override
  Future<void> upsertAsset(EmotionAsset asset) => _assets.upsert(asset);

  @override
  Future<void> upsertAssets(List<EmotionAsset> assets) => _assets.upsertAll(assets);

  @override
  Future<CharacterPack> ensurePack({
    required String ownerId,
    required String name,
    required PackSourceType sourceType,
    String? sourcePath,
  }) async {
    final CharacterPack? existing = await _packs.findByOwnerAndName(ownerId, name);
    final DateTime now = DateTime.now();
    if (existing != null) {
      final String? newPath = sourcePath ?? existing.sourcePath;
      if (existing.sourcePath != newPath || existing.sourceType != sourceType) {
        await _packs.upsert(existing.copyWith(
          sourceType: sourceType,
          sourcePath: newPath,
          updatedAt: now,
        ));
      }
      return (await _packs.findById(existing.id))!;
    }
    final CharacterPack pack = CharacterPack(
      id: Ids.packId(ownerId, name),
      ownerId: ownerId,
      name: name,
      sourceType: sourceType,
      sourcePath: sourcePath,
      createdAt: now,
      updatedAt: now,
    );
    await _packs.upsert(pack);
    Loggers.character.info('新建作品包: ${pack.name} (id=${pack.id}, source=${pack.sourceType.wireName})');
    return pack;
  }

  @override
  Future<CharacterModel> ensureCharacter({
    required String packId,
    required String ownerId,
    required String internalName,
    String? displayName,
  }) async {
    final List<CharacterModel> inPack = await _characters.listByPack(packId);
    for (final CharacterModel c in inPack) {
      if (c.internalName.toLowerCase() == internalName.toLowerCase()) {
        return c;
      }
    }
    final DateTime now = DateTime.now();
    final CharacterModel character = CharacterModel(
      id: Ids.characterId(packId, internalName),
      packId: packId,
      ownerId: ownerId,
      internalName: internalName,
      displayName: displayName ?? internalName,
      defaultAssetId: null,
      enabled: true,
      createdAt: now,
      updatedAt: now,
    );
    await _characters.upsert(character);
    Loggers.character.info('新建角色: ${character.displayName} (id=${character.id}, pack=$packId)');
    return character;
  }

  @override
  Future<void> touchPackSourcePath(String packId, String? sourcePath) async {
    await _packs.updateSourcePath(packId, sourcePath, DateTime.now());
  }
}
