import 'enums.dart';

/// 作品包（对应一个素材来源，例如 `Ace Attorney` 文件夹）。
class CharacterPack {
  const CharacterPack({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.sourceType,
    this.sourcePath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String name;
  final PackSourceType sourceType;

  /// 用户原始来源路径。
  ///
  /// 只读引用——用于「重新扫描」与展示来源，应用**永不**写入或删除该路径下的文件。
  final String? sourcePath;

  final DateTime createdAt;
  final DateTime updatedAt;

  CharacterPack copyWith({
    String? name,
    PackSourceType? sourceType,
    String? sourcePath,
    DateTime? updatedAt,
  }) =>
      CharacterPack(
        id: id,
        ownerId: ownerId,
        name: name ?? this.name,
        sourceType: sourceType ?? this.sourceType,
        sourcePath: sourcePath ?? this.sourcePath,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'owner_id': ownerId,
        'name': name,
        'source_type': sourceType.wireName,
        'source_path': sourcePath,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static CharacterPack fromMap(Map<String, Object?> m) => CharacterPack(
        id: m['id']! as String,
        ownerId: m['owner_id']! as String,
        name: m['name']! as String,
        sourceType: PackSourceType.fromWire(m['source_type']! as String),
        sourcePath: m['source_path'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at']! as int),
      );
}
