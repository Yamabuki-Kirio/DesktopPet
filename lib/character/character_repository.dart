import '../state_engine/system_state.dart';
import 'models/character_model.dart';
import 'models/character_pack.dart';
import 'models/emotion_asset.dart';
import 'models/enums.dart';
import 'models/state_mapping.dart';

/// 素材库一次性快照，供 UI 渲染，避免逐层查询。
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.packs,
    required this.characters,
    required this.assets,
    required this.mappings,
  });

  final List<CharacterPack> packs;
  final List<CharacterModel> characters;
  final List<EmotionAsset> assets;
  final List<StateMapping> mappings;

  bool get isEmpty => packs.isEmpty;

  List<CharacterModel> charactersOf(String packId) =>
      characters.where((CharacterModel c) => c.packId == packId).toList(growable: false);

  List<EmotionAsset> assetsOf(String characterId) =>
      assets.where((EmotionAsset a) => a.characterId == characterId).toList(growable: false);

  /// 某角色下的情绪名列表（去重，按字典序）。
  List<String> emotionsOf(String characterId) {
    final Set<String> names = <String>{};
    for (final EmotionAsset a in assetsOf(characterId)) {
      names.add(a.emotionName);
    }
    final List<String> sorted = names.toList()..sort();
    return sorted;
  }

  Map<SystemState, List<StateMapping>> mappingsOf(String characterId) {
    final Map<SystemState, List<StateMapping>> grouped = <SystemState, List<StateMapping>>{};
    for (final StateMapping m in mappings) {
      if (m.characterId != characterId) continue;
      grouped.putIfAbsent(m.systemState, () => <StateMapping>[]).add(m);
    }
    return grouped;
  }

  EmotionAsset? assetById(String? id) {
    if (id == null) return null;
    for (final EmotionAsset a in assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  CharacterModel? characterById(String? id) {
    if (id == null) return null;
    for (final CharacterModel c in characters) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// 素材库读取统计（诊断 / 日志用）。
class LibraryStats {
  const LibraryStats({
    required this.packCount,
    required this.characterCount,
    required this.assetCount,
    required this.animatedCount,
    required this.staticCount,
    required this.invalidCount,
    required this.disabledCount,
  });

  final int packCount;
  final int characterCount;
  final int assetCount;
  final int animatedCount;
  final int staticCount;
  final int invalidCount;
  final int disabledCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'packs': packCount,
        'characters': characterCount,
        'assets': assetCount,
        'animated': animatedCount,
        'static': staticCount,
        'invalid': invalidCount,
        'disabled': disabledCount,
      };
}

/// 反向分配时的一条变更（需求 §6：提交前要能把"谁变成了什么"列清楚）。
class StateAssignmentChange {
  const StateAssignmentChange({
    required this.state,
    required this.previousAssetId,
    required this.assigned,
  });

  final SystemState state;

  /// 变更前该状态的显式素材（null = 之前没有显式素材）。
  final String? previousAssetId;

  /// true = 本次把它设成了目标素材；false = 本次解除了它对目标素材的引用。
  final bool assigned;
}

/// 角色与素材的统一访问入口。
///
/// 抽象出来的目的（需求十一）：阶段 2 接入服务端同步时，
/// 只需新增一个 `RemoteCharacterRepository`（或装饰器）而**不改动业务逻辑**。
abstract interface class CharacterRepository {
  /// 读取整个素材库快照。
  Future<LibrarySnapshot> loadSnapshot(String ownerId);

  Future<List<CharacterPack>> listPacks(String ownerId);

  Future<List<CharacterModel>> listCharacters(String ownerId);

  Future<List<CharacterModel>> listCharactersInPack(String packId);

  Future<CharacterModel?> findCharacter(String characterId);

  /// 渲染用素材（enabled + valid）。
  Future<List<EmotionAsset>> listRenderableAssets(String characterId);

  /// 素材库页面用素材（含禁用与损坏）。
  Future<List<EmotionAsset>> listAllAssets(String characterId);

  Future<EmotionAsset?> findAsset(String assetId);

  Future<void> setCharacterDefaultAsset(String characterId, String? assetId);

  Future<void> setCharacterEnabled(String characterId, bool enabled);

  Future<void> setAssetEnabled(String assetId, bool enabled);

  /// 收藏 / 取消收藏素材（Phase 4C-6A.1，v5 新增列）。
  Future<void> setAssetFavorite(String assetId, bool favorite);

  /// 删除素材：删除数据库记录 + **托管目录内**的副本。
  ///
  /// 用户原始文件（`original_file_path`）永不删除。
  ///
  /// Phase 4C-6A.1 起，数据库侧的三步（清映射引用 → 删素材行 → 清悬空默认图片）
  /// 在**同一个事务**内完成；文件删除放在事务提交之后（文件系统不可回滚），
  /// 失败只记日志 —— 绝不留下"删了映射却还在用"或反之的半完成状态。
  Future<void> deleteAsset(String assetId);

  Future<void> deleteCharacter(String characterId);

  /// 删除作品包：删除数据库记录 + 托管目录；用户原始目录保持不动。
  Future<void> deletePack(String packId);

  Future<List<StateMapping>> listMappings(String characterId);

  Future<Map<SystemState, List<StateMapping>>> groupedMappings(String characterId);

  Future<void> replaceMappingsForState(
    String characterId,
    SystemState state,
    List<StateMapping> mappings,
  );

  /// 移除某状态的全部映射（用于「恢复自动状态切换」）。
  Future<void> clearMappingsForState(String characterId, SystemState state);

  // ---------------------------------------------------------------------------
  // Phase 4C-6A.1：状态素材映射编辑器
  // ---------------------------------------------------------------------------

  /// 把某状态设为**唯一一条显式素材映射**（编辑器口径：一个状态一张图）。
  ///
  /// 会在**一个事务**内 upsert 目标行并清掉该状态的其它候选行。
  /// 校验：素材必须存在、且**属于该角色**，否则抛 [ArgumentError]。
  Future<void> setStateAssetMapping(
    String characterId,
    SystemState state,
    String assetId,
  );

  /// 批量反向分配：把 [assetId] 分配给 [states]。
  ///
  /// * 勾选的状态 → 设为该素材，并**覆盖该状态原有映射**
  ///   （需求 §6 原文："勾选后覆盖该状态原有映射"；含导入生成的情绪候选）；
  /// * 取消勾选**且当前正指向该素材**的状态 → 仅解除它对**本素材**的引用，
  ///   该状态里其它候选（例如桌面编辑器另外追加的情绪绑定）不受影响；
  /// * 其它状态一律不动；整批在**一个事务**内完成。
  ///
  /// 返回实际发生的变更清单（供 UI 展示变更摘要）。
  Future<List<StateAssignmentChange>> assignAssetToStates(
    String characterId,
    String assetId,
    Set<SystemState> states,
  );

  /// 引用了某素材的状态列表（删除素材前提示用户用）。
  Future<List<SystemState>> statesReferencingAsset(String assetId);

  Future<LibraryStats> stats(String ownerId);

  /// 新增/更新素材（导入流程调用）。
  Future<void> upsertAsset(EmotionAsset asset);

  Future<void> upsertAssets(List<EmotionAsset> assets);

  // ---------------------------------------------------------------------------
  // 导入流程需要的写入接口。
  // 之所以放在 Repository 而不是让导入器直接碰 DAO：
  // 阶段 2 换成服务端仓库时，这些语义（幂等 ensure）必须保持一致。
  // ---------------------------------------------------------------------------

  /// 按 (ownerId, name) 幂等地取得或创建作品包。
  Future<CharacterPack> ensurePack({
    required String ownerId,
    required String name,
    required PackSourceType sourceType,
    String? sourcePath,
  });

  /// 按 (packId, internalName) 幂等地取得或创建角色。
  Future<CharacterModel> ensureCharacter({
    required String packId,
    required String ownerId,
    required String internalName,
    String? displayName,
  });

  /// 更新作品包的来源路径（再次导入同一包时刷新）。
  Future<void> touchPackSourcePath(String packId, String? sourcePath);

  /// 在**单个数据库事务**中执行一组写入。
  ///
  /// 为什么需要它：导入一张素材时，「确保 pack 存在 → 确保 character 存在 →
  /// 写入 asset 记录」必须构成一个原子单元。否则中途失败会留下
  /// **没有任何素材的孤儿 pack / character**，而且它们会带着合法 ID 留在库里，
  /// 后续重新导入时被 `ensurePack` / `ensureCharacter` 当作「已存在」直接复用。
  ///
  /// 这条路径不是理论风险：缺陷 D-01 中 `Ids.assetId()` 抛异常时，
  /// pack 与 character 就已经提交，只是恰好因为 ID 在 INSERT 之前生成才没落库。
  ///
  /// 实现约定：
  /// - [action] 收到的是**事务作用域**的仓库，只用于读写，不可在其中再次调用 [transaction]。
  /// - [action] 抛出任何异常都会回滚整批写入，并原样向上抛出。
  /// - 服务端仓库（阶段 2）无法提供跨请求事务时，应改为「整批提交 + 幂等重试」，
  ///   但**不能**悄悄降级成逐条写入。
  Future<T> transaction<T>(Future<T> Function(CharacterRepository repo) action);
}
