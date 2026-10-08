/// `app_key` 的规范化规则。
///
/// 需求「六、应用标识」要求 `app_key` 稳定，且第一版**不使用窗口标题**作为主键。
/// Windows 下取可执行文件名并做小写化 + 去扩展名处理，得到与安装路径无关的稳定键。
library;

/// 把可执行文件名规范化为 `app_key`。
///
/// 规则：
/// - 只取路径最后一段（去掉目录）；
/// - 统一小写；
/// - 去掉 `.exe` 后缀，避免同一应用因后缀写法差异产生两个键；
/// - 去掉首尾空白；空串返回 null（宁可不记录，也不写虚假应用名）。
String? normalizeAppKey(String? executablePathOrName) {
  if (executablePathOrName == null) return null;
  final String trimmed = executablePathOrName.trim();
  if (trimmed.isEmpty) return null;

  // 同时兼容 Windows 的 `\` 与 POSIX 的 `/`，便于测试在任意平台跑。
  final int sep = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  final String base = sep >= 0 ? trimmed.substring(sep + 1) : trimmed;
  if (base.isEmpty) return null;

  final String lower = base.toLowerCase();
  final String withoutExt =
      lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
  return withoutExt.isEmpty ? null : withoutExt;
}

/// 从可执行文件名推断一个人类可读的展示名（去掉扩展名、保留原始大小写）。
///
/// 仅在没有更好来源时使用；用户可随时在统计页改写 display_name。
String displayNameFromExecutable(String executablePathOrName) {
  final int sep = executablePathOrName.lastIndexOf(RegExp(r'[\\/]'));
  final String base =
      sep >= 0 ? executablePathOrName.substring(sep + 1) : executablePathOrName;
  if (base.toLowerCase().endsWith('.exe')) {
    return base.substring(0, base.length - 4);
  }
  return base;
}
