/// Windows 控制面板的**内部回退开关**（需求 §12）。
///
/// 用法：真机回归出现阻塞缺陷时，可以临时把控制面板切回
/// `lib/ui/desktop/legacy/` 里的旧页面实现，而不用回滚整个增量。
///
/// 规则（刻意设计成这样）：
/// * **默认关闭** —— 新界面才是默认路径；
/// * **不在普通设置页暴露** —— 它是排障开关，不是用户功能；
/// * **不允许"根据主题缺失静默回退"** —— 静默回退会让"Windows 看起来没变"
///   与"Windows 真的坏了"无法区分。回退必须由这个显式开关决定，
///   而新桌面外壳必须**明确装配** `PetLifeTheme`（见 `app/app_shell.dart`）。
/// * 验收稳定后再单独删除 legacy 代码。
///
/// 打开方式（无需改代码）：
/// ```
/// flutter run -d windows --dart-define=petlife.legacyDesktopPanel=true
/// flutter build windows --release --dart-define=petlife.legacyDesktopPanel=true
/// ```
library;

/// `true` = 控制面板使用旧页面实现（`lib/ui/desktop/legacy/`）。
///
/// 默认 `false`。用 `--dart-define=petlife.legacyDesktopPanel=true` 临时打开。
const bool useLegacyDesktopControlPanel =
    bool.fromEnvironment('petlife.legacyDesktopPanel');

/// 回退开关的默认值（测试断言用，避免测试与代码各写一份字面量）。
const bool defaultUseLegacyDesktopControlPanel = false;
