import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../character/models/emotion_asset.dart';
import '../../character/models/enums.dart';
import '../schema.dart';

/// `emotion_assets` 数据访问。
///
/// 注意 [listByCharacter] 的默认行为：**只返回 `enabled = 1` 且 `validation_status = 'valid'`**
/// 的素材用于渲染；素材库页面则通过 [listAllByCharacter] 拿到全部（含被禁用/损坏项）以便展示。
class AssetDao {
  AssetDao(this._db);

  /// 用 [DatabaseExecutor] 而不是 [Database]，以便在事务内复用。
  final DatabaseExecutor _db;

  Future<void> upsert(EmotionAsset asset) async {
    await _db.insert(
      DbSchema.tableAssets,
      asset.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(List<EmotionAsset> assets) async {
    if (assets.isEmpty) return;
    final Batch batch = _db.batch();
    for (final EmotionAsset a in assets) {
      batch.insert(DbSchema.tableAssets, a.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<EmotionAsset?> findById(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAssets,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : EmotionAsset.fromMap(rows.first);
  }

  /// 渲染用：仅可用素材。
  Future<List<EmotionAsset>> listByCharacter(String characterId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAssets,
      where: "character_id = ? AND enabled = 1 AND validation_status = 'valid'",
      whereArgs: <Object?>[characterId],
      orderBy: 'emotion_name ASC, variant_name ASC',
    );
    return rows.map(EmotionAsset.fromMap).toList(growable: false);
  }

  /// 素材库页面用：全部素材，含被禁用与校验失败项。
  Future<List<EmotionAsset>> listAllByCharacter(String characterId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAssets,
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
      orderBy: 'emotion_name ASC, variant_name ASC',
    );
    return rows.map(EmotionAsset.fromMap).toList(growable: false);
  }

  /// 一次取回多个角色的素材，避免 N+1 查询。
  Future<List<EmotionAsset>> listByCharacters(List<String> characterIds) async {
    if (characterIds.isEmpty) return const <EmotionAsset>[];
    final String placeholders = List<String>.filled(characterIds.length, '?').join(',');
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAssets,
      where: 'character_id IN ($placeholders)',
      whereArgs: characterIds,
      orderBy: 'emotion_name ASC, variant_name ASC',
    );
    return rows.map(EmotionAsset.fromMap).toList(growable: false);
  }

  Future<List<EmotionAsset>> listByEmotion(String characterId, String emotionName) async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAssets,
      where: "character_id = ? AND emotion_name = ? AND enabled = 1 AND validation_status = 'valid'",
      whereArgs: <Object?>[characterId, emotionName],
      orderBy: 'variant_name ASC',
    );
    return rows.map(EmotionAsset.fromMap).toList(growable: false);
  }

  Future<int> countByCharacter(String characterId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbSchema.tableAssets} WHERE character_id = ?',
      <Object?>[characterId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 统计损坏素材数量（日志与诊断需要）。
  Future<int> countByValidation(String ownerId, ValidationStatus status) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      '''
SELECT COUNT(*) AS c FROM ${DbSchema.tableAssets} a
JOIN ${DbSchema.tableCharacters} c ON c.id = a.character_id
WHERE c.owner_id = ? AND a.validation_status = ?
''',
      <Object?>[ownerId, status.wireName],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> setEnabled(String assetId, bool enabled) async {
    await _db.update(
      DbSchema.tableAssets,
      <String, Object?>{'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object?>[assetId],
    );
  }

  /// 设置收藏标记（Phase 4C-6A.1，v5 新增列）。
  ///
  /// 只改这一列，不触碰 `enabled` / `validation_status` —— 收藏是**用户偏好**，
  /// 与"能不能渲染"完全无关。
  Future<void> setFavorite(String assetId, bool favorite) async {
    await _db.update(
      DbSchema.tableAssets,
      <String, Object?>{'favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object?>[assetId],
    );
  }

  Future<void> updateValidation(
    String assetId,
    ValidationStatus status,
    String? error,
  ) async {
    await _db.update(
      DbSchema.tableAssets,
      <String, Object?>{
        'validation_status': status.wireName,
        'validation_error': error,
      },
      where: 'id = ?',
      whereArgs: <Object?>[assetId],
    );
  }

  Future<void> deleteById(String id) async {
    await _db.delete(DbSchema.tableAssets, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> deleteByCharacter(String characterId) async {
    await _db.delete(
      DbSchema.tableAssets,
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
    );
  }
}
