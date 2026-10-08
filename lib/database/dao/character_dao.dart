import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../character/models/character_model.dart';
import '../schema.dart';

/// `character_models` 数据访问。
class CharacterDao {
  CharacterDao(this._db);

  /// 用 [DatabaseExecutor] 而不是 [Database]，以便在事务内复用。
  final DatabaseExecutor _db;

  /// 写入角色（真正的 UPSERT，**绝不能用 `INSERT OR REPLACE`**）。
  ///
  /// 与 [PackDao.upsert] 同理：`emotion_assets.character_id` 与
  /// `state_mappings.character_id` 都是 `ON DELETE CASCADE`，
  /// 一次 `REPLACE` 就会把该角色的全部素材与状态映射级联删除。
  Future<void> upsert(CharacterModel character) async {
    final Map<String, Object?> values = character.toMap();
    final Map<String, Object?> updateValues = Map<String, Object?>.of(values)
      ..remove('id')
      ..remove('created_at');

    final int updated = await _db.update(
      DbSchema.tableCharacters,
      updateValues,
      where: 'id = ?',
      whereArgs: <Object?>[character.id],
    );
    if (updated == 0) {
      await _db.insert(
        DbSchema.tableCharacters,
        values,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }

  Future<CharacterModel?> findById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableCharacters,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : CharacterModel.fromMap(rows.first);
  }

  Future<List<CharacterModel>> listByPack(String packId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableCharacters,
      where: 'pack_id = ?',
      whereArgs: <Object?>[packId],
      orderBy: 'internal_name ASC',
    );
    return rows.map(CharacterModel.fromMap).toList(growable: false);
  }

  Future<List<CharacterModel>> listByOwner(String ownerId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableCharacters,
      where: 'owner_id = ?',
      whereArgs: <Object?>[ownerId],
      orderBy: 'created_at ASC',
    );
    return rows.map(CharacterModel.fromMap).toList(growable: false);
  }

  Future<void> setDefaultAsset(String characterId, String? assetId, DateTime updatedAt) async {
    await _db.update(
      DbSchema.tableCharacters,
      <String, Object?>{
        'default_asset_id': assetId,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[characterId],
    );
  }

  Future<void> setEnabled(String characterId, bool enabled, DateTime updatedAt) async {
    await _db.update(
      DbSchema.tableCharacters,
      <String, Object?>{
        'enabled': enabled ? 1 : 0,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[characterId],
    );
  }

  Future<void> rename(String characterId, String displayName, DateTime updatedAt) async {
    await _db.update(
      DbSchema.tableCharacters,
      <String, Object?>{
        'display_name': displayName,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[characterId],
    );
  }

  /// 清空所有把 [assetId] 当作默认图片的引用。
  ///
  /// 删除素材时必须调用，否则回退链第 3 级会指向一个已不存在的素材。
  Future<int> clearDefaultAssetByAssetId(String assetId, DateTime updatedAt) async {
    return _db.update(
      DbSchema.tableCharacters,
      <String, Object?>{
        'default_asset_id': null,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      },
      where: 'default_asset_id = ?',
      whereArgs: <Object?>[assetId],
    );
  }

  Future<void> deleteById(String id) async {
    await _db.delete(DbSchema.tableCharacters, where: 'id = ?', whereArgs: <Object?>[id]);
  }
}
