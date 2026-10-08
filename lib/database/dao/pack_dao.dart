import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../character/models/character_pack.dart';
import '../schema.dart';

/// `character_packs` 数据访问。
class PackDao {
  PackDao(this._db);

  /// 用 [DatabaseExecutor] 而不是 [Database]：这样同一个 DAO 既能在普通连接上工作，
  /// 也能被传入 [Transaction]，从而让「一次导入=一个事务」成为可能。
  final DatabaseExecutor _db;

  /// 写入作品包（真正的 UPSERT，**绝不能用 `INSERT OR REPLACE`**）。
  ///
  /// 为什么这条约束是硬的：SQLite 的 `REPLACE` 不是 UPDATE，而是
  /// **先 DELETE 冲突行、再 INSERT**。而 `character_models.pack_id` 上带
  /// `ON DELETE CASCADE`，于是"更新一次作品包"会把该包下的**全部角色与素材
  /// 级联删除**。真机缺陷就是这么发生的：多选导入时每个文件都用一个不同的
  /// `source_path` 调用 `ensurePack` → 触发 upsert → 前一张素材被删 → 最终只剩最后一张。
  ///
  /// 因此这里显式区分 UPDATE / INSERT，并在更新时保持 `created_at` 不变。
  /// 万一真的撞上 `UNIQUE(owner_id, name)`（理论上不会，ID 由 owner+name 确定性生成），
  /// `abort` 会直接抛出并让整批回滚 —— 宁可失败，也不静默覆盖。
  Future<void> upsert(CharacterPack pack) async {
    final Map<String, Object?> values = pack.toMap();
    final Map<String, Object?> updateValues = Map<String, Object?>.of(values)
      ..remove('id')
      ..remove('created_at');

    final int updated = await _db.update(
      DbSchema.tablePacks,
      updateValues,
      where: 'id = ?',
      whereArgs: <Object?>[pack.id],
    );
    if (updated == 0) {
      await _db.insert(
        DbSchema.tablePacks,
        values,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }

  Future<CharacterPack?> findById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tablePacks,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : CharacterPack.fromMap(rows.first);
  }

  Future<CharacterPack?> findByOwnerAndName(String ownerId, String name) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tablePacks,
      where: 'owner_id = ? AND name = ?',
      whereArgs: <Object?>[ownerId, name],
      limit: 1,
    );
    return rows.isEmpty ? null : CharacterPack.fromMap(rows.first);
  }

  Future<List<CharacterPack>> listByOwner(String ownerId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tablePacks,
      where: 'owner_id = ?',
      whereArgs: <Object?>[ownerId],
      orderBy: 'created_at ASC',
    );
    return rows.map(CharacterPack.fromMap).toList(growable: false);
  }

  Future<void> updateSourcePath(String id, String? sourcePath, DateTime updatedAt) async {
    await _db.update(
      DbSchema.tablePacks,
      <String, Object?>{
        'source_path': sourcePath,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteById(String id) async {
    await _db.delete(DbSchema.tablePacks, where: 'id = ?', whereArgs: <Object?>[id]);
  }
}
