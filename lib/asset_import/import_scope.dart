import '../character/character_repository.dart';
import '../character/models/character_model.dart';
import '../character/models/character_pack.dart';
import '../character/models/enums.dart';

/// 一次导入批次的写入范围。
///
/// 每条职责都对应一个真实缺陷，改动前请先读完：
///
/// 1. **整批共用一个事务**：原先"一个文件一个事务"，于是任一文件失败都可能让
///    报告（"成功 3 个"）与数据库实际内容不一致。现在多文件导入整批提交；
/// 2. **父实体整批只 ensure 一次**：`character_packs` / `character_models` 上
///    有 `ON DELETE CASCADE` 子表，反复 upsert 父实体既浪费又危险（见
///    [PackDao.upsert] 的说明），这里用内存缓存保证同一批次内只访问一次；
/// 3. **来源信息由批次决定**：不再逐文件用 `p.dirname(originalPath)` 改写
///    `pack.source_path` —— 那正是历史缺陷的触发器（改写 → upsert → 级联删除）；
/// 4. **不嵌套事务**：事务作用域的实例由 [ImportScope.run] 提供，
///    [withRepository] 用于"每文件一个事务"的场景（文件夹导入），此时父实体缓存
///    仍然是跨文件复用的。
class ImportScope {
  ImportScope._(
    this.repository,
    this._ownerId,
    this._sourceType,
    this._sourcePath,
    this._packs,
    this._characters,
  );

  /// 本批次使用的仓库（可能是事务作用域实例）。
  final CharacterRepository repository;

  final String _ownerId;
  final PackSourceType _sourceType;
  final String? _sourcePath;

  final Map<String, CharacterPack> _packs;
  final Map<String, CharacterModel> _characters;

  /// 作品包来源类型（由**批次**决定，而不是按文件猜）。
  PackSourceType get sourceType => _sourceType;

  /// 作品包来源路径（批次级；文件选择导入为 null）。
  String? get sourcePath => _sourcePath;

  /// 不使用批次事务（每文件一个事务）的普通范围。
  factory ImportScope.plain({
    required CharacterRepository repository,
    required String ownerId,
    required PackSourceType sourceType,
    String? sourcePath,
  }) =>
      ImportScope._(
        repository,
        ownerId,
        sourceType,
        sourcePath,
        <String, CharacterPack>{},
        <String, CharacterModel>{},
      );

  /// 在**单个事务**中执行一整批写入。
  ///
  /// [body] 收到的 [ImportScope] 已绑定事务；在其中**不得**再调用
  /// `repository.transaction`（会抛 `StateError`）。
  static Future<T> run<T>({
    required CharacterRepository repository,
    required String ownerId,
    required PackSourceType sourceType,
    String? sourcePath,
    required Future<T> Function(ImportScope scope) body,
  }) {
    return repository.transaction(
      (CharacterRepository tx) => body(ImportScope._(
        tx,
        ownerId,
        sourceType,
        sourcePath,
        <String, CharacterPack>{},
        <String, CharacterModel>{},
      )),
    );
  }

  /// 换一个写入仓库（例如"每文件一个事务"），**父实体缓存继续复用**。
  ImportScope withRepository(CharacterRepository repo) => ImportScope._(
        repo,
        _ownerId,
        _sourceType,
        _sourcePath,
        _packs,
        _characters,
      );

  String get ownerId => _ownerId;

  /// 取得（必要时创建）作品包；同一批次内同名只访问一次数据库。
  Future<CharacterPack> pack(String name) async {
    final CharacterPack? cached = _packs[name];
    if (cached != null) return cached;
    final CharacterPack created = await repository.ensurePack(
      ownerId: _ownerId,
      name: name,
      sourceType: _sourceType,
      sourcePath: _sourcePath,
    );
    _packs[name] = created;
    return created;
  }

  /// 取得（必要时创建）角色；同一批次内同一 (包, 角色名) 只访问一次数据库。
  Future<CharacterModel> character({
    required String packId,
    required String internalName,
  }) async {
    final String key = '$packId\u0000${internalName.toLowerCase()}';
    final CharacterModel? cached = _characters[key];
    if (cached != null) return cached;
    final CharacterModel created = await repository.ensureCharacter(
      packId: packId,
      ownerId: _ownerId,
      internalName: internalName,
    );
    _characters[key] = created;
    return created;
  }
}
