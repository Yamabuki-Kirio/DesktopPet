import 'models/activity_enums.dart';

/// 内置应用分类规则。
///
/// 规则只认**规范化后的可执行文件名**（`app_key`），不认窗口标题——
/// 需求「七、应用分类」明确禁止仅凭窗口标题猜测（尤其是游戏）。
/// 用户手工设定的分类永远优先于这里的任何一条。
const Map<String, AppCategory> kBuiltInCategoryRules = <String, AppCategory>{
  // --- 开发 ---
  'code': AppCategory.development,
  'code - insiders': AppCategory.development,
  'devenv': AppCategory.development,
  'idea64': AppCategory.development,
  'pycharm64': AppCategory.development,
  'rider64': AppCategory.development,
  'clion64': AppCategory.development,
  'goland64': AppCategory.development,
  'webstorm64': AppCategory.development,
  'phpstorm64': AppCategory.development,
  'datagrip64': AppCategory.development,
  'studio64': AppCategory.development,
  'sublime_text': AppCategory.development,
  'notepad++': AppCategory.development,
  'cursor': AppCategory.development,
  'zed': AppCategory.development,
  'neovim': AppCategory.development,
  'nvim': AppCategory.development,
  'gvim': AppCategory.development,
  'android studio': AppCategory.development,
  'eclipse': AppCategory.development,
  'xbtoa': AppCategory.development,
  // 终端也算开发工具（日常主力场景）。
  'windowsterminal': AppCategory.development,
  'wt': AppCategory.development,
  'cmd': AppCategory.development,
  'powershell': AppCategory.development,
  'pwsh': AppCategory.development,

  // --- 生产力 ---
  'winword': AppCategory.productivity,
  'excel': AppCategory.productivity,
  'powerpnt': AppCategory.productivity,
  'onenote': AppCategory.productivity,
  'outlook': AppCategory.productivity,
  'msaccess': AppCategory.productivity,
  'wps': AppCategory.productivity,
  'et': AppCategory.productivity,
  'wpp': AppCategory.productivity,
  'notion': AppCategory.productivity,
  'obsidian': AppCategory.productivity,
  'typora': AppCategory.productivity,
  'acrobat': AppCategory.productivity,
  'acrord32': AppCategory.productivity,
  'sumatrapdf': AppCategory.productivity,
  'foxitpdfreader': AppCategory.productivity,
  'notepad': AppCategory.productivity,
  'mspaint': AppCategory.productivity,
  'photoshop': AppCategory.productivity,
  'illustrator': AppCategory.productivity,
  'figma': AppCategory.productivity,
  'blender': AppCategory.productivity,

  // --- 社交 / 通信 ---
  'telegram': AppCategory.social,
  'discord': AppCategory.social,
  'wechat': AppCategory.social,
  'weixin': AppCategory.social,
  'qq': AppCategory.social,
  'tim': AppCategory.social,
  'dingtalk': AppCategory.social,
  'feishu': AppCategory.social,
  'lark': AppCategory.social,
  'whatsapp': AppCategory.social,
  'signal': AppCategory.social,
  'skype': AppCategory.social,
  'zoom': AppCategory.social,
  'teams': AppCategory.social,
  'ms-teams': AppCategory.social,
  'line': AppCategory.social,

  // --- 浏览器 ---
  'chrome': AppCategory.browser,
  'msedge': AppCategory.browser,
  'firefox': AppCategory.browser,
  'iexplore': AppCategory.browser,
  'brave': AppCategory.browser,
  'opera': AppCategory.browser,
  'vivaldi': AppCategory.browser,
  'chromium': AppCategory.browser,
  'arc': AppCategory.browser,
  '360se': AppCategory.browser,
  '360chrome': AppCategory.browser,
  'qqbrowser': AppCategory.browser,

  // --- 系统 ---
  'explorer': AppCategory.system,
  'taskmgr': AppCategory.system,
  'regedit': AppCategory.system,
  'control': AppCategory.system,
  'systemsettings': AppCategory.system,
  'settings': AppCategory.system,
  'conhost': AppCategory.system,
  'searchhost': AppCategory.system,
  'startmenuexperiencehost': AppCategory.system,
  'shellexperiencehost': AppCategory.system,
  'runtimebroker': AppCategory.system,
  'dllhost': AppCategory.system,
  'lockapp': AppCategory.system,
  'securityhealthsystray': AppCategory.system,
  'taskhostw': AppCategory.system,
  'sihost': AppCategory.system,

  // --- 娱乐 ---
  'potplayer': AppCategory.entertainment,
  'potplayermini64': AppCategory.entertainment,
  'vlc': AppCategory.entertainment,
  'mpv': AppCategory.entertainment,
  'mpc-hc64': AppCategory.entertainment,
  'mpc-be64': AppCategory.entertainment,
  'spotify': AppCategory.entertainment,
  'neteasemusic': AppCategory.entertainment,
  'cloudmusic': AppCategory.entertainment,
  'qqmusic': AppCategory.entertainment,
  'kugou': AppCategory.entertainment,
  'foobar2000': AppCategory.entertainment,
  'wmplayer': AppCategory.entertainment,
  'music.ui': AppCategory.entertainment,
  'video.ui': AppCategory.entertainment,
  'bilibili': AppCategory.entertainment,
  'iqiyi': AppCategory.entertainment,
  'youku': AppCategory.entertainment,
  'tencentvideo': AppCategory.entertainment,
  'photos': AppCategory.entertainment,
  'microsoft.photos': AppCategory.entertainment,

  // --- 游戏：已知进程（不依赖窗口标题）---
  'steam': AppCategory.gaming,
  'steamwebhelper': AppCategory.gaming,
  'epicgameslauncher': AppCategory.gaming,
  'battle.net': AppCategory.gaming,
  'riotclientservices': AppCategory.gaming,
  'riotclient': AppCategory.gaming,
  'valorant': AppCategory.gaming,
  'leagueclient': AppCategory.gaming,
  'league of legends': AppCategory.gaming,
  'dota2': AppCategory.gaming,
  'cs2': AppCategory.gaming,
  'gta5': AppCategory.gaming,
  'cyberpunk2077': AppCategory.gaming,
  'witcher3': AppCategory.gaming,
  'genshinimpact': AppCategory.gaming,
  'yuanhen': AppCategory.gaming,
  'starrail': AppCategory.gaming,
  'minecraft': AppCategory.gaming,
  'hl2': AppCategory.gaming,
  'eldenring': AppCategory.gaming,
  'hades': AppCategory.gaming,
};

/// 路径特征：命中即认为是游戏安装位置。
///
/// 这是「Steam 安装信息或进程路径特征」的落点，比猜测窗口标题可靠得多。
const List<String> kGamePathMarkers = <String>[
  r'\steamapps\common\',
  r'\steamapps\',
  r'\steam\steamapps\',
  r'\epic games\',
  r'\gog galaxy\games\',
  r'\gog games\',
  r'\riot games\',
  r'\battle.net\',
  r'\xboxgames\',
  r'\games\',
  r'\game\',
  r'\ubisoft game launcher\games\',
];

/// 默认排除的应用（不记录使用时长）。
///
/// `petlife` 是需求「八、排除规则」明确要求排除的自身进程；
/// 其余是「无有效进程信息的系统瞬时窗口」在实现上的一种兜底——
/// 它们通常一闪而过，记录下来只会污染统计。
const Set<String> kBuiltInExcludedAppKeys = <String>{
  'petlife',
};

/// 分类来源，用于诊断与「人工优先」的可解释性。
enum ClassificationSource {
  /// 用户手工设定。
  userOverride('用户设定'),

  /// 内置规则命中。
  builtInRule('内置规则'),

  /// 安装路径特征命中（游戏为主）。
  pathHeuristic('路径特征'),

  /// 未命中任何规则。
  fallback('默认归类');

  const ClassificationSource(this.labelZh);

  final String labelZh;
}

/// 分类结果。
class ClassificationResult {
  const ClassificationResult({
    required this.category,
    required this.source,
    required this.excluded,
  });

  final AppCategory category;
  final ClassificationSource source;

  /// 是否应排除记录（含内置排除与用户排除）。
  final bool excluded;

  @override
  String toString() =>
      'ClassificationResult(${category.wireName}, ${source.labelZh}, excluded=$excluded)';
}

/// 应用分类器。
///
/// 纯函数式：不访问数据库、不访问系统，因此可以被单元测试穷举覆盖。
/// 应用库的读写由 [ApplicationRepository] 负责。
class ApplicationClassifier {
  const ApplicationClassifier();

  /// 判定分类与是否排除。
  ///
  /// 优先级（严格按需求「七」）：
  /// 1. 用户手工分类（`existing.userOverridden`）；
  /// 2. 内置进程名规则；
  /// 3. 安装路径特征（游戏）；
  /// 4. 归入 `other`。
  ///
  /// 排除判定与分类相互独立：即使分类命中了规则，只要在排除名单里就不记录。
  ClassificationResult classify({
    required String appKey,
    String? executablePath,
    bool? userOverridden,
    AppCategory? userCategory,
    bool userExcluded = false,
  }) {
    final String key = appKey.toLowerCase();
    final bool excluded = userExcluded || kBuiltInExcludedAppKeys.contains(key);

    // 1. 人工设定永远优先。
    if (userOverridden == true && userCategory != null) {
      return ClassificationResult(
        category: userCategory,
        source: ClassificationSource.userOverride,
        excluded: excluded,
      );
    }

    // 2. 内置规则。
    final AppCategory? rule = kBuiltInCategoryRules[key];
    if (rule != null) {
      return ClassificationResult(
        category: rule,
        source: ClassificationSource.builtInRule,
        excluded: excluded,
      );
    }

    // 3. 路径特征（游戏安装目录）。
    if (looksLikeGamePath(executablePath)) {
      return ClassificationResult(
        category: AppCategory.gaming,
        source: ClassificationSource.pathHeuristic,
        excluded: excluded,
      );
    }

    // 4. 无法确定时归入 other，绝不猜测。
    return ClassificationResult(
      category: AppCategory.other,
      source: ClassificationSource.fallback,
      excluded: excluded,
    );
  }
}

/// 可执行文件路径是否落在已知的游戏安装目录特征里。
bool looksLikeGamePath(String? executablePath) {
  if (executablePath == null || executablePath.isEmpty) return false;
  final String lower = executablePath.toLowerCase();
  for (final String marker in kGamePathMarkers) {
    if (lower.contains(marker)) return true;
  }
  return false;
}

/// 是否属于内置排除的应用。
bool isBuiltInExcluded(String? appKey) =>
    appKey != null && kBuiltInExcludedAppKeys.contains(appKey.toLowerCase());
