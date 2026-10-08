import 'package:path/path.dart' as p;

/// 从文件名解析出的素材信息。
class ParsedAssetName {
  const ParsedAssetName({
    required this.packName,
    required this.characterName,
    required this.emotionName,
    required this.variantName,
    required this.extension,
    required this.sourceFileName,
  });

  /// 作品包名（取自所在文件夹名）。
  final String packName;

  /// 角色名（第一个下划线之前的部分）。
  final String characterName;

  /// 情绪名（中间所有部分的组合，允许包含下划线）。
  final String emotionName;

  /// 变体名；文件名末尾没有纯数字时为 `default`。
  final String variantName;

  /// 小写扩展名，不含点。
  final String extension;

  /// 原始文件名（含扩展名），用于展示与排错。
  final String sourceFileName;

  bool get isDefaultVariant => variantName == defaultVariantName;

  /// 情绪名的展示形式：`Bench_Thinking` -> `Bench Thinking`。
  String get emotionDisplay =>
      emotionName.replaceAll('_', ' ').trim().isEmpty ? defaultVariantName : emotionName.replaceAll('_', ' ');

  /// 规范化的存储文件名：`<Character>_<Emotion>_<variant>.<ext>`。
  ///
  /// 无序号的文件保持无序号（不强行补 `_default`），这样重新扫描同一批文件时
  /// 生成的托管文件名是稳定的，不会因为往返转换而漂移。
  String canonicalFileName() {
    final String base = isDefaultVariant
        ? '${characterName}_$emotionName'
        : '${characterName}_${emotionName}_$variantName';
    return '$base.$extension';
  }

  @override
  String toString() =>
      'ParsedAssetName(pack=$packName, character=$characterName, emotion=$emotionName, variant=$variantName, ext=$extension)';
}

/// 无序号文件使用的变体标记。
const String defaultVariantName = 'default';

/// 无法解析出情绪名时使用的占位情绪名。
const String fallbackEmotionName = 'default';

/// 文件名解析器（需求 4.2）。
///
/// 默认命名格式：`角色名_情绪名_可选序号.扩展名`
///
/// 解析规则：
/// 1. 第一个下划线前的内容是角色名。
/// 2. 末尾纯数字部分是变体序号。
/// 3. 中间所有部分组合为情绪名。
/// 4. 没有序号时，变体标记为 `default`。
/// 5. 文件夹名称作为作品包名称。
/// 6. 情绪名称可以包含下划线。
///
/// 设计目标：**必须直接兼容用户已有的素材文件夹**，不要求改名、不要求写配置文件。
class AssetFilenameParser {
  const AssetFilenameParser();

  /// 解析单个文件名。
  ///
  /// [packName] 通常传入素材所在文件夹名。
  ParsedAssetName parse(String fileName, {required String packName}) {
    final String extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final String stem = p.basenameWithoutExtension(fileName);

    // 去掉 BOM / 首尾空白，Windows 下常见。
    final String normalizedStem = stem.replaceAll('\uFEFF', '').trim();

    final List<String> rawSegments = normalizedStem.split('_');
    // 丢弃空片段（如 `Maya__Angry`、`Maya_`），避免产生空情绪名。
    final List<String> segments =
        rawSegments.map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();

    if (segments.isEmpty) {
      // 例如文件名为 `_.webp` 这种极端情况。
      return ParsedAssetName(
        packName: packName,
        characterName: _sanitize(packName),
        emotionName: fallbackEmotionName,
        variantName: defaultVariantName,
        extension: extension,
        sourceFileName: fileName,
      );
    }

    final String characterName = segments.first;

    // 规则 2：末尾纯数字 = 变体序号。只取最后一段，因此 `Angry_2_1` 的变体是 1、情绪是 Angry_2。
    String variant = defaultVariantName;
    List<String> middle = segments.sublist(1);
    if (middle.isNotEmpty && _isPureNumber(middle.last)) {
      variant = middle.last;
      middle = middle.sublist(0, middle.length - 1);
    }

    // 规则 3 / 6：中间部分用下划线重新拼回，保留作者写的下划线。
    final String emotion =
        middle.isEmpty ? fallbackEmotionName : middle.join('_');

    return ParsedAssetName(
      packName: packName,
      characterName: characterName,
      emotionName: emotion,
      variantName: variant,
      extension: extension,
      sourceFileName: fileName,
    );
  }

  /// 从完整路径解析（自动取上一级目录名作为作品包名）。
  ParsedAssetName parsePath(String filePath, {String? packNameOverride}) {
    final String folder = p.basename(p.dirname(filePath));
    return parse(
      p.basename(filePath),
      packName: packNameOverride ?? (folder.isEmpty ? 'Imported' : folder),
    );
  }

  /// 判断是否为纯数字（支持前导零，如 `01`）。
  bool _isPureNumber(String value) =>
      value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value);

  String _sanitize(String raw) {
    final String cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'Unknown' : cleaned;
  }

  /// 反向构造文件名，供「另存为托管副本」使用。
  static String buildFileName({
    required String characterName,
    required String emotionName,
    required String variantName,
    required String extension,
  }) {
    final String base = variantName == defaultVariantName
        ? '${characterName}_$emotionName'
        : '${characterName}_${emotionName}_$variantName';
    return '$base.$extension';
  }
}
