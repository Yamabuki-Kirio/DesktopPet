/// 轻量结果类型，避免用异常表达“可预期的失败”。
///
/// 素材导入是典型的“部分成功”场景：一个文件夹里可能有若干损坏文件，
/// 我们既要报告失败原因，又不能让整批导入失败。
library;

/// 导入/校验失败的原因分类，便于 UI 展示与统计。
enum FailureKind {
  /// 扩展名不在允许列表内。
  unsupportedExtension,

  /// 真实格式与扩展名不符（伪造扩展名）。
  formatMismatch,

  /// 无法解码。
  undecodable,

  /// 尺寸超限。
  dimensionTooLarge,

  /// 像素总量超限。
  tooManyPixels,

  /// 文件体积超限。
  fileTooLarge,

  /// 帧数超限。
  tooManyFrames,

  /// 文件不存在或不可读。
  unreadable,

  /// ZIP 安全校验未通过（路径穿越等）。
  unsafeArchive,

  /// 无有效内容（例如全透明空图）。
  emptyContent,

  /// 其他未归类错误。
  unknown,
}

/// 失败信息。
class Failure {
  const Failure(this.kind, this.message, {this.detail});

  final FailureKind kind;
  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// 成功/失败结果。
sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final T value) => value,
        Err<T>() => null,
      };

  Failure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final Failure failure) => failure,
      };
}

class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}

/// 批量结果：成功项 + 失败项，附带统计。
class BatchResult<T> {
  BatchResult({required this.succeeded, required this.failed});

  final List<T> succeeded;
  final List<FailedItem> failed;

  int get total => succeeded.length + failed.length;

  bool get hasFailures => failed.isNotEmpty;
}

/// 批量中单个失败项。
class FailedItem {
  const FailedItem({required this.path, required this.failure});

  final String path;
  final Failure failure;
}
