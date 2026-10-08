import 'package:flutter/foundation.dart';

import '../character/character_repository.dart';
import '../character/models/character_model.dart';
import '../character/models/character_pack.dart';
import '../character/models/emotion_asset.dart';
import '../character/models/state_mapping.dart';
import '../core/logger.dart';
import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import '../state_engine/state_engine.dart';
import '../state_engine/system_state.dart';

/// 素材库的内存视图。
///
/// UI 只与它交互：它负责从仓库拉取快照、维护当前选中的作品包/角色，
/// 并在写操作后刷新 + 通知状态引擎重新解析素材。
///
/// 两个**必须分开**的动作（Phase 4A 真机缺陷）：
/// * `select*` —— 只是"在列表里选中"，纯 UI 状态，**不**影响桌宠；
/// * [activateCharacter] —— "设为当前桌宠角色"，必须真正切换状态引擎并持久化。
///
/// 之前 `activateCharacter` 只调了 `selectCharacter` + `refresh()`，
/// 而 `refresh()` 只会重载**已经绑定的**角色，于是点播放按钮毫无效果。
class LibraryController extends ChangeNotifier {
  LibraryController({
    required CharacterRepository repository,
    required String ownerId,
    StateEngine? stateEngine,
    SettingsController? settings,
  })  : _repository = repository,
        _ownerId = ownerId,
        _stateEngine = stateEngine,
        _settings = settings;

  final CharacterRepository _repository;
  final String _ownerId;

  /// 状态引擎（可选：仅用于 [activateCharacter]，测试可省略）。
  final StateEngine? _stateEngine;

  /// 设置控制器（可选）。
  ///
  /// 暴露出来的原因：状态素材映射页需要读写"自动状态联动"开关，
  /// 而它只依赖本控制器 —— 不需要把整个 `AppServices` 塞进页面。
  SettingsController? get settings => _settings;

  /// 设置控制器（可选：仅用于持久化"当前桌宠角色"）。
  final SettingsController? _settings;

  LibrarySnapshot? _snapshot;
  bool _loading = false;
  String? _selectedPackId;
  String? _selectedCharacterId;

  /// 当前**正在用作桌宠**的角色（与 [selectedCharacterId] 是两个概念）。
  String? _activeCharacterId;

  String? _lastError;

  /// 写操作完成后触发的钩子（由外壳注入，用来让状态引擎 refresh）。
  Future<void> Function()? onLibraryMutated;

  LibrarySnapshot? get snapshot => _snapshot;

  bool get isLoading => _loading;

  String? get lastError => _lastError;

  String? get selectedPackId => _selectedPackId;

  String? get selectedCharacterId => _selectedCharacterId;

  /// 当前桌宠正在使用的角色（"使用中"标记据此显示）。
  String? get activeCharacterId => _activeCharacterId;

  CharacterModel? get selectedCharacter =>
      _snapshot?.characterById(_selectedCharacterId);

  List<EmotionAsset> get selectedCharacterAssets =>
      _selectedCharacterId == null
          ? const <EmotionAsset>[]
          : (_snapshot?.assetsOf(_selectedCharacterId!) ?? const <EmotionAsset>[]);

  List<EmotionAsset> get selectedRenderableAssets =>
      selectedCharacterAssets.where((EmotionAsset a) => a.isRenderable).toList(growable: false);

  List<String> get selectedEmotions =>
      selectedCharacter == null ? const <String>[] : _snapshot!.emotionsOf(selectedCharacter!.id);

  /// 任意角色的全部素材（含被禁用与损坏项）。
  ///
  /// 状态映射编辑器可能作用于**非当前选中**的角色（例如从设置页直接进入），
  /// 因此不能再依赖"选中的角色"那一对 getter。
  List<EmotionAsset> assetsFor(String characterId) =>
      _snapshot?.assetsOf(characterId) ?? const <EmotionAsset>[];

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _snapshot = await _repository.loadSnapshot(_ownerId);
      _lastError = null;

      // 校正选中项：选中的包/角色被删掉时自动回落到第一个。
      final LibrarySnapshot? snap = _snapshot;
      if (snap != null) {
        if (snap.packs.isEmpty) {
          _selectedPackId = null;
          _selectedCharacterId = null;
        } else {
          if (_selectedPackId == null ||
              !snap.packs.any((CharacterPack p) => p.id == _selectedPackId)) {
            _selectedPackId = snap.packs.first.id;
          }
          final List<CharacterModel> chars = snap.charactersOf(_selectedPackId!);
          if (_selectedCharacterId == null ||
              !chars.any((CharacterModel c) => c.id == _selectedCharacterId)) {
            _selectedCharacterId = chars.isEmpty ? null : chars.first.id;
          }
        }
        _reconcileActiveCharacter(snap);
      }
    } catch (e, st) {
      _lastError = e.toString();
      Loggers.character.warning('加载素材库失败', e, st);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 写操作后调用：刷新 + 通知状态引擎。
  Future<void> mutated() async {
    await load();
    await onLibraryMutated?.call();
  }

  void selectPack(String packId) {
    if (_selectedPackId == packId) return;
    _selectedPackId = packId;
    final List<CharacterModel> chars = _snapshot?.charactersOf(packId) ?? <CharacterModel>[];
    _selectedCharacterId = chars.isEmpty ? null : chars.first.id;
    notifyListeners();
  }

  void selectCharacter(String characterId) {
    if (_selectedCharacterId == characterId) return;
    _selectedCharacterId = characterId;
    notifyListeners();
  }

  /// 切换当前主角色（**真正**设为当前桌宠角色）。
  ///
  /// 与 [selectCharacter] 的区别：后者只是列表选中项，前者会：
  /// 1. 校验角色存在且有可渲染素材（否则拒绝并返回原因）；
  /// 2. 调用状态引擎切换角色（未启动时直接 `start`）；
  /// 3. 持久化 `defaultCharacterId` / `lastCharacterId` 与当前素材，
  ///    使应用重启后仍使用该角色；
  /// 4. 触发 [onLibraryMutated]，让桌宠立即刷新。
  ///
  /// 返回 null 表示成功，否则返回**给用户看的原因**。
  Future<String?> activateCharacter(String characterId) async {
    final LibrarySnapshot? snap = _snapshot;
    if (snap == null) return '素材库尚未加载完成，请稍后重试';

    final CharacterModel? character = snap.characterById(characterId);
    if (character == null) return '角色不存在（可能已被删除）';

    final List<EmotionAsset> renderable = snap
        .assetsOf(characterId)
        .where((EmotionAsset a) => a.isRenderable)
        .toList(growable: false);
    if (renderable.isEmpty) {
      return '「${character.displayName}」没有可用素材（全部损坏或已禁用），'
          '无法设为当前桌宠角色';
    }

    // 先选中，让界面立刻反映"当前角色"。
    selectCharacter(characterId);

    // 1) 真正切换状态引擎。
    final StateEngine? engine = _stateEngine;
    if (engine != null) {
      if (engine.isRunning) {
        await engine.setCharacter(characterId);
      } else {
        await engine.start(ownerId: _ownerId, characterId: characterId);
      }
    }

    // 2) 持久化，保证重启后仍使用该角色。
    final SettingsController? settings = _settings;
    if (settings != null) {
      final String assetId = engine?.snapshot.currentAsset?.id ??
          character.defaultAssetId ??
          renderable.first.id;
      await settings.setDefaultCharacter(characterId);
      await settings.rememberSelection(
        characterId: characterId,
        state: engine?.snapshot.state,
        assetId: assetId,
        manualAssetId: engine?.snapshot.manualAssetId,
      );
    }

    _activeCharacterId = characterId;
    notifyListeners();

    // 3) 让桌宠按新角色重新解析素材（引擎已切换时 refresh 幂等）。
    await onLibraryMutated?.call();
    Loggers.character.info(
      '已设为当前桌宠角色: ${character.displayName}（可用素材 ${renderable.length} 个）',
    );
    return null;
  }

  Future<void> setDefaultAsset(String characterId, String? assetId) async {
    await _repository.setCharacterDefaultAsset(characterId, assetId);
    await mutated();
  }

  Future<void> setAssetEnabled(String assetId, bool enabled) async {
    await _repository.setAssetEnabled(assetId, enabled);
    await mutated();
  }

  Future<void> deleteAsset(String assetId) async {
    await _repository.deleteAsset(assetId);
    await mutated();
  }

  Future<void> deleteCharacter(String characterId) async {
    await _repository.deleteCharacter(characterId);
    if (_selectedCharacterId == characterId) _selectedCharacterId = null;
    if (_activeCharacterId == characterId) _activeCharacterId = null;
    await mutated();
  }

  Future<void> deletePack(String packId) async {
    await _repository.deletePack(packId);
    if (_selectedPackId == packId) _selectedPackId = null;
    await mutated();
  }

  /// 当前角色的状态映射（按状态分组）。
  Future<Map<SystemState, List<StateMapping>>> mappingsOf(String characterId) =>
      _repository.groupedMappings(characterId);

  Future<void> replaceMappings(
    String characterId,
    SystemState state,
    List<StateMapping> mappings,
  ) async {
    await _repository.replaceMappingsForState(characterId, state, mappings);
    await mutated();
  }

  Future<void> clearMappings(String characterId, SystemState state) async {
    await _repository.clearMappingsForState(characterId, state);
    await mutated();
  }

  // ---------------------------------------------------------------------------
  // Phase 4C-6A.1：状态素材映射编辑器
  //
  // 三个写操作都走 [mutated]：它先重载素材库，再触发 [onLibraryMutated]
  // （Android 外壳里 = 状态引擎 refresh）→ 快照变化 → `OverlayPetController`
  // 自动 buildOverlayStateMapping + revision+1 + 下发原生（需求 §8 的链路）。
  // ---------------------------------------------------------------------------

  /// 把某状态设为**唯一一条显式素材**。
  Future<void> setStateAssetMapping(
    String characterId,
    SystemState state,
    String assetId,
  ) async {
    await _repository.setStateAssetMapping(characterId, state, assetId);
    Loggers.character.info('state_mapping_saved state=${state.wireName} asset=$assetId');
    await mutated();
  }

  /// 解除某状态的显式素材（恢复回退）。
  Future<void> clearStateAssetMapping(String characterId, SystemState state) async {
    await _repository.clearMappingsForState(characterId, state);
    Loggers.character.info('state_mapping_removed state=${state.wireName}');
    await mutated();
  }

  /// 反向分配：把某素材分配给一组状态（整批一个事务）。
  ///
  /// 返回实际发生的变更；没有变化时不触发刷新（避免无意义的下发）。
  Future<List<StateAssignmentChange>> assignAssetToStates(
    String characterId,
    String assetId,
    Set<SystemState> states,
  ) async {
    final List<StateAssignmentChange> changes =
        await _repository.assignAssetToStates(characterId, assetId, states);
    if (changes.isNotEmpty) await mutated();
    return changes;
  }

  /// 收藏 / 取消收藏素材。
  Future<void> setAssetFavorite(String assetId, bool favorite) async {
    await _repository.setAssetFavorite(assetId, favorite);
    await mutated();
  }

  /// 引用了某素材的状态（删除素材前提示用）。
  Future<List<SystemState>> statesReferencingAsset(String assetId) =>
      _repository.statesReferencingAsset(assetId);

  /// 让"使用中"标记与真实情况一致。
  ///
  /// * 首次加载时从设置里恢复（`lastCharacterId` → `defaultCharacterId`）；
  /// * 角色被删除或换了库时清空，避免显示一个并不存在的"使用中"。
  void _reconcileActiveCharacter(LibrarySnapshot snap) {
    if (_activeCharacterId == null) {
      final AppSettings? settings = _settings?.settings;
      _activeCharacterId = settings?.lastCharacterId ?? settings?.defaultCharacterId;
    }
    if (_activeCharacterId != null &&
        !snap.characters.any((CharacterModel c) => c.id == _activeCharacterId)) {
      _activeCharacterId = null;
    }
  }
}
