import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../character/models/state_mapping.dart';
import '../../state_engine/system_state.dart';
import '../schema.dart';

/// `state_mappings` 数据访问。
class StateMappingDao {
  StateMappingDao(this._db);

  /// 用 [DatabaseExecutor] 而不是 [Database]：既能是普通连接，也能是事务。
  final DatabaseExecutor _db;

  Future<void> upsert(StateMapping mapping) async {
    await _db.insert(
      DbSchema.tableStateMappings,
      mapping.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(List<StateMapping> mappings) async {
    if (mappings.isEmpty) return;
    final Batch batch = _db.batch();
    for (final StateMapping m in mappings) {
      batch.insert(
        DbSchema.tableStateMappings,
        m.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<StateMapping>> listByCharacter(String characterId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableStateMappings,
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
      orderBy: 'system_state ASC, created_at ASC',
    );
    return rows.map(StateMapping.fromMap).toList(growable: false);
  }

  /// 某角色全部映射，按系统状态分组。
  Future<Map<SystemState, List<StateMapping>>> groupedByState(String characterId) async {
    final List<StateMapping> all = await listByCharacter(characterId);
    final Map<SystemState, List<StateMapping>> grouped = <SystemState, List<StateMapping>>{};
    for (final StateMapping m in all) {
      grouped.putIfAbsent(m.systemState, () => <StateMapping>[]).add(m);
    }
    return grouped;
  }

  Future<List<StateMapping>> listByState(String characterId, SystemState state) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableStateMappings,
      where: 'character_id = ? AND system_state = ?',
      whereArgs: <Object?>[characterId, state.wireName],
      orderBy: 'created_at ASC',
    );
    return rows.map(StateMapping.fromMap).toList(growable: false);
  }

  /// 用一批新的候选替换某状态的现有配置（避免出现「中间态空映射」）。
  ///
  /// 事务策略：先删后插必须原子。
  /// - 持有普通连接（[Database]）时，自己开一个事务；
  /// - 已经处在事务里（导入流程会把整批写入包进一个事务）时**直接执行**，
  ///   原子性由外层事务负责 —— 嵌套开事务会死锁。
  Future<void> replaceForState(
    String characterId,
    SystemState state,
    List<StateMapping> mappings,
  ) async {
    final DatabaseExecutor executor = _db;
    if (executor is Database) {
      final Database database = executor;
      await database.transaction(
        (Transaction txn) => _replaceOn(txn, characterId, state, mappings),
      );
      return;
    }
    await _replaceOn(executor, characterId, state, mappings);
  }

  Future<void> _replaceOn(
    DatabaseExecutor db,
    String characterId,
    SystemState state,
    List<StateMapping> mappings,
  ) async {
    await db.delete(
      DbSchema.tableStateMappings,
      where: 'character_id = ? AND system_state = ?',
      whereArgs: <Object?>[characterId, state.wireName],
    );
    if (mappings.isEmpty) return;
    final Batch batch = db.batch();
    for (final StateMapping m in mappings) {
      batch.insert(
        DbSchema.tableStateMappings,
        m.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 把某状态设为**唯一一条显式主素材**（Phase 4C-6A.1 状态映射编辑器）。
  ///
  /// 与 [replaceForState] 的区别（为什么编辑器不能直接用后者）：
  /// * [replaceForState] 是"删光该状态全部候选 → 重新插入"，
  ///   语义上允许 0..N 条候选（导入流程按情绪铺映射时会写入多条）；
  /// * 编辑器口径是**"一个状态一张图"**，因此这里在**一个事务**内
  ///   先把目标行 upsert 进去，**再删掉同状态的其它行** ——
  ///   任何一个环节失败都整体回滚，旧映射原样保留。
  ///
  /// 刻意不用 `INSERT OR REPLACE`：它是"先 DELETE 再 INSERT"，
  /// 一旦将来有表引用 `state_mappings`，就会静默级联删除子行。
  Future<void> setExplicitForState(
    String characterId,
    SystemState state,
    StateMapping mapping,
  ) async {
    final DatabaseExecutor executor = _db;
    if (executor is Database) {
      await executor.transaction(
        (Transaction txn) => _setExplicitOn(txn, characterId, state, mapping),
      );
      return;
    }
    // 已在事务里：原子性由外层事务负责（嵌套开事务会死锁）。
    await _setExplicitOn(executor, characterId, state, mapping);
  }

  Future<void> _setExplicitOn(
    DatabaseExecutor db,
    String characterId,
    SystemState state,
    StateMapping mapping,
  ) async {
    final int updated = await db.update(
      DbSchema.tableStateMappings,
      mapping.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[mapping.id],
    );
    if (updated == 0) {
      await db.insert(DbSchema.tableStateMappings, mapping.toMap());
    }
    await db.delete(
      DbSchema.tableStateMappings,
      where: 'character_id = ? AND system_state = ? AND id <> ?',
      whereArgs: <Object?>[characterId, state.wireName, mapping.id],
    );
  }

  /// 引用了某素材的全部映射（删除素材前用它给出"该素材正被以下状态使用"）。
  Future<List<StateMapping>> listReferencingAsset(String assetId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableStateMappings,
      where: 'asset_id = ?',
      whereArgs: <Object?>[assetId],
      orderBy: 'system_state ASC',
    );
    return rows.map(StateMapping.fromMap).toList(growable: false);
  }

  /// 删除引用了某素材的全部映射（删除素材时必须在**同一事务**内调用）。
  Future<int> deleteReferencingAsset(String assetId) => _db.delete(
        DbSchema.tableStateMappings,
        where: 'asset_id = ?',
        whereArgs: <Object?>[assetId],
      );

  Future<void> deleteById(String id) async {
    await _db.delete(DbSchema.tableStateMappings, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> deleteByCharacter(String characterId) async {
    await _db.delete(
      DbSchema.tableStateMappings,
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
    );
  }
}
