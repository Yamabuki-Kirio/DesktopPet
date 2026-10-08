import 'enums.dart';

/// 素材项：一张静态图片或一个动态图片。
///
/// 静态与动态共用同一套结构（只有 [isAnimated] / [frameCount] 不同），
/// 因此素材管理、状态映射、角色切换流程完全一致——这是需求 4.1 的硬要求。
class EmotionAsset {
  const EmotionAsset({
    required this.id,
    required this.characterId,
    required this.emotionName,
    required this.variantName,
    required this.filePath,
    this.originalFilePath,
    required this.fileHash,
    required this.mimeType,
    required this.fileSize,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.isAnimated,
    required this.hasAlpha,
    required this.enabled,
    required this.validationStatus,
    this.validationError,
    required this.createdAt,
    this.animationDurationMs = 0,
    this.favorite = false,
  });

  final String id;
  final String characterId;

  /// 情绪名，例如 `Angry` / `Bench_Thinking`。允许包含下划线。
  final String emotionName;

  /// 变体名，无序号时为 `default`。
  final String variantName;

  /// 应用托管目录中的绝对路径（渲染与哈希都基于此）。
  final String filePath;

  /// 用户原始路径。删除素材时**只删托管副本**，该路径下的文件永不触碰。
  final String? originalFilePath;

  final String fileHash;
  final String mimeType;
  final int fileSize;
  final int width;
  final int height;
  final int frameCount;
  final bool isAnimated;
  final bool hasAlpha;
  final bool enabled;
  final ValidationStatus validationStatus;
  final String? validationError;
  final DateTime createdAt;

  /// 一轮动画的总时长（毫秒）。静态图为 0。
  ///
  /// 由 WebP 容器头解析得到（ANMF 各帧 duration 之和）。
  /// 需求「五、素材显示」要求普通状态切换时尽量等当前动画播完一轮，依赖此值。
  final int animationDurationMs;

  /// 是否被用户收藏（Phase 4C-6A.1，v5 新增列）。
  ///
  /// 收藏**只影响回退链的先后**（[FallbackChain] 里"角色收藏素材"一级），
  /// 不改变素材是否可用、也不参与同步。
  final bool favorite;

  bool get isValid => validationStatus == ValidationStatus.valid;

  /// 是否可用于渲染。
  bool get isRenderable => enabled && isValid;

  EmotionAsset copyWith({
    String? emotionName,
    String? variantName,
    bool? enabled,
    ValidationStatus? validationStatus,
    String? validationError,
    bool clearValidationError = false,
    bool? favorite,
  }) =>
      EmotionAsset(
        id: id,
        characterId: characterId,
        emotionName: emotionName ?? this.emotionName,
        variantName: variantName ?? this.variantName,
        filePath: filePath,
        originalFilePath: originalFilePath,
        fileHash: fileHash,
        mimeType: mimeType,
        fileSize: fileSize,
        width: width,
        height: height,
        frameCount: frameCount,
        isAnimated: isAnimated,
        hasAlpha: hasAlpha,
        enabled: enabled ?? this.enabled,
        validationStatus: validationStatus ?? this.validationStatus,
        validationError: clearValidationError ? null : (validationError ?? this.validationError),
        createdAt: createdAt,
        animationDurationMs: animationDurationMs,
        favorite: favorite ?? this.favorite,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'character_id': characterId,
        'emotion_name': emotionName,
        'variant_name': variantName,
        'file_path': filePath,
        'original_file_path': originalFilePath,
        'file_hash': fileHash,
        'mime_type': mimeType,
        'file_size': fileSize,
        'width': width,
        'height': height,
        'frame_count': frameCount,
        'is_animated': isAnimated ? 1 : 0,
        'has_alpha': hasAlpha ? 1 : 0,
        'enabled': enabled ? 1 : 0,
        'validation_status': validationStatus.wireName,
        'validation_error': validationError,
        'created_at': createdAt.millisecondsSinceEpoch,
        'animation_duration_ms': animationDurationMs,
        'favorite': favorite ? 1 : 0,
      };

  static EmotionAsset fromMap(Map<String, Object?> m) => EmotionAsset(
        id: m['id']! as String,
        characterId: m['character_id']! as String,
        emotionName: m['emotion_name']! as String,
        variantName: m['variant_name']! as String,
        filePath: m['file_path']! as String,
        originalFilePath: m['original_file_path'] as String?,
        fileHash: m['file_hash']! as String,
        mimeType: m['mime_type']! as String,
        fileSize: m['file_size']! as int,
        width: m['width']! as int,
        height: m['height']! as int,
        frameCount: m['frame_count']! as int,
        isAnimated: (m['is_animated']! as int) != 0,
        hasAlpha: (m['has_alpha']! as int) != 0,
        enabled: (m['enabled']! as int) != 0,
        validationStatus: ValidationStatus.fromWire(m['validation_status']! as String),
        validationError: m['validation_error'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']! as int),
        animationDurationMs: (m['animation_duration_ms'] as int?) ?? 0,
        // v5 之前写入的行没有这一列（理论上只会出现在"迁移尚未执行"的异常库上），
        // 读到 null 时按"未收藏"处理，绝不抛异常。
        favorite: ((m['favorite'] as int?) ?? 0) != 0,
      );
}
