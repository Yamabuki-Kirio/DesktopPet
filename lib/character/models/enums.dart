/// 作品包来源类型。
enum PackSourceType {
  /// 用户直接选择的文件夹。
  folder('folder'),

  /// 用户选择的若干单张/多张图片。
  files('files'),

  /// 用户导入的 ZIP 素材包。
  zip('zip'),

  /// 应用内置素材。
  builtin('builtin');

  const PackSourceType(this.wireName);

  final String wireName;

  static PackSourceType fromWire(String value) => PackSourceType.values.firstWhere(
        (PackSourceType t) => t.wireName == value,
        orElse: () => PackSourceType.folder,
      );
}

/// 素材校验状态。
enum ValidationStatus {
  /// 通过校验。
  valid('valid'),

  /// 校验失败（损坏 / 伪造扩展名 / 超限）。
  invalid('invalid'),

  /// 尚未校验（例如扫描中断）。
  unchecked('unchecked');

  const ValidationStatus(this.wireName);

  final String wireName;

  static ValidationStatus fromWire(String value) => ValidationStatus.values.firstWhere(
        (ValidationStatus s) => s.wireName == value,
        orElse: () => ValidationStatus.unchecked,
      );
}
