/// 角色（例如 `Maya`）。
class CharacterModel {
  const CharacterModel({
    required this.id,
    required this.packId,
    required this.ownerId,
    required this.internalName,
    required this.displayName,
    this.defaultAssetId,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String packId;
  final String ownerId;

  /// 从文件名解析出的角色名，例如 `Maya`。用于回查素材，不随用户改名变化。
  final String internalName;

  /// 展示名，默认等于 [internalName]，用户可改。
  final String displayName;

  /// 角色默认图片。
  ///
  /// 回退链的第 3 级：「角色默认图片」。为 null 时直接跳到第 4 级。
  final String? defaultAssetId;

  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  CharacterModel copyWith({
    String? displayName,
    String? defaultAssetId,
    bool clearDefaultAsset = false,
    bool? enabled,
    DateTime? updatedAt,
  }) =>
      CharacterModel(
        id: id,
        packId: packId,
        ownerId: ownerId,
        internalName: internalName,
        displayName: displayName ?? this.displayName,
        defaultAssetId: clearDefaultAsset ? null : (defaultAssetId ?? this.defaultAssetId),
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'pack_id': packId,
        'owner_id': ownerId,
        'internal_name': internalName,
        'display_name': displayName,
        'default_asset_id': defaultAssetId,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static CharacterModel fromMap(Map<String, Object?> m) => CharacterModel(
        id: m['id']! as String,
        packId: m['pack_id']! as String,
        ownerId: m['owner_id']! as String,
        internalName: m['internal_name']! as String,
        displayName: m['display_name']! as String,
        defaultAssetId: m['default_asset_id'] as String?,
        enabled: (m['enabled']! as int) != 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}
