# 55 - Windows 控制面板 UI 同步（增量）交付说明

把 Windows 控制面板同步到 Android 已验收的视觉体系：
**白色默认主色 + P3P 粉强调色 + 圆角卡片 + 清晰信息层级**，
布局按桌面习惯（左侧导航 + 顶部栏），不照搬手机底部导航。

**没有改动**：悬浮桌宠窗口、双窗口固定层级、RegionCoordinator、固定画布、
轮盘几何与动画、左键/右键菜单、桌宠拖动、控制面板定位算法、托盘菜单、
开机自启、使用统计采集、同步协议、数据库、服务端、Android UI。

---

## 一、关键架构决策

### 1. Windows 与 Android 共用同一套主题生成器

`app/app_shell.dart` 现在只有**一条**主题管线，两个平台都走
`buildPetLifeThemeData`；桌面侧只多一个字体参数（微软雅黑），
并显式关闭卡片进场动画（`cardEntranceAnimated: false`，需求 §9 禁止桌面端
"逐卡片依次播放"）。

旧的深蓝色 seed（`0xFF4A7EBB`）与「Windows 沿用旧主题」的分支已删除。

### 2. 回退改为**显式开关**（取消静默回退）

上一轮（只做 Android 时）的边界做法是：「桌面主题没有 `PetLifeTheme`
扩展 → 共享页面静默回退到 legacy」。本轮 Windows 也要新 UI，这条规则必须取消 ——
否则"看起来没变"与"真的坏了"无法区分。

现在：

```dart
// lib/ui/desktop/desktop_panel_flags.dart
const bool useLegacyDesktopControlPanel =
    bool.fromEnvironment('petlife.legacyDesktopPanel');   // 默认 false
```

* 默认 `false`（新界面是默认路径）；
* 不在设置页暴露；
* 打开方式：`flutter build windows --release --dart-define=petlife.legacyDesktopPanel=true`；
* `ControlPanel` 按开关选择新实现或 `lib/ui/desktop/legacy/` 的旧实现；
* 四个共享页面里**不再有任何** legacy 引用或 `PetLifeTheme.maybeOf(...) == null` 判断
  （有测试静态拦截）。

验收稳定后可单独删除 `lib/ui/desktop/legacy/`。

---

## 二、新增的桌面布局组件（`lib/ui/widgets/petlife/petlife_desktop.dart`）

| 组件 | 作用 |
| --- | --- |
| `PetLifeDesktopScaffold` | 顶部栏 + 左侧导航 + 内容区 + 可选底部状态条 |
| `PetLifeDesktopNavigationRail` | 左侧导航：完整（200px）/ 仅图标（76px），当前项强调色胶囊 |
| `PetLifeDesktopTopNavigation` | 窗口 < 900px 时自动切换的顶部紧凑导航（横向可滚动，不溢出） |
| `PetLifeDesktopToolbar` | 顶部栏：应用图标 + 标题 + 当前页面标签 + 同步状态标签 + 动作 |
| `PetLifeDesktopContentWidth` | 内容最大宽度约束（默认 1440，设置页 1040），超出后居中 |
| `PetLifeDesktopBreakpoints` | 断点与尺寸常量（唯一真相） |

这些组件**只处理布局**：导航入口、标题、状态标签、动作按钮都由调用方传入；
不 import `window_manager`（标题栏拖拽通过 `onTitleBarDrag` 回调注入），
因此 `platform_isolation_test` 的"桌面专属依赖不泄漏到 Android 编译单元"继续通过。

页面宿主用**懒加载的 IndexedStack**：切走的页面不销毁（保留滚动与筛选状态），
但只构建访问过的页面 —— 打开控制面板不会一次性拉起七个页面的数据库查询。

---

## 三、七个页面的接入

| # | 页面 | 接入方式 |
| --- | --- | --- |
| 0 | 素材库 | 直接启用新页面（宽屏保留作品包/角色树 + 自适应列数素材卡） |
| 1 | 状态映射 | **视觉适配**：状态=圆角卡片，当前生效状态强调色描边 + 对勾；素材选择改为大预览缩略图（16dp 圆角）；缺失素材用明确错误卡；按钮统一 |
| 2 | 状态调试器 | **视觉适配**：宽屏两栏（左触发工具 / 右状态详情），窄屏堆叠；状态、来源、规则、稳定时间分组；日志/决策文本用等宽可复制区域；状态机与触发参数未动 |
| 3 | 使用统计 | 直接启用新页面；宽屏 ≥1180 时**应用排行与时间线双栏**，窄屏单栏；内容宽度由外壳约束 |
| 4 | 账户与同步 | 直接启用新卡片式页面（宽屏下卡片不会拉伸到整窗） |
| 5 | 设置 | 直接启用七组圆角卡片；内容宽度收窄到 1040 |
| 6 | 诊断 | **视觉适配**：分组改为 权限 / 数据库与存储 / 同步 / 运行环境 / 网络与代理 / 使用统计采集 / 性能与资源 / 当前渲染 / 错误与日志；正常=绿色标签，异常=原因+操作入口；日志为可复制可滚动等宽区域 |

顺带修复的两个真实缺陷：

1. **`PetLifeTag` 文字不可见**：自定义颜色标签把 `color.withValues(alpha: 0.12)`
   直接当背景去算对比度，而 `computeLuminance()` 忽略 alpha → 文字被推向白色。
   现象就是 Windows 顶部栏的同步状态标签渲染成**一只空胶囊**。
   修法：先 `Color.alphaBlend` 合成成不透明色再算对比度。已加回归测试。
2. **`DiagnosticsPage` 缺少 Scaffold**：Android 从设置页 push 进来时没有 AppBar /
   返回按钮。现在非内嵌模式自带 `Scaffold + AppBar`，内嵌模式（控制面板）只渲染内容。

---

## 四、验证结果

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!** |
| `flutter test` | **1578 passed / 0 failed**（1 skipped）；本轮开始前基线 1542 |
| `flutter build windows --release` | **成功**（`data/app.so` 与源码一致） |
| 分发 ZIP | `build/windows/PetLife-windows-x64-0.1.0.zip`（13.86 MB，20 个条目） |
| Android APK（debug） | **成功**（缓存修复同样影响 Android，已一并重建） |

新增测试：

* `test/windows_control_panel_test.dart`（43 项）：七个导航入口与顺序、
  当前项强调色胶囊、点击回调、仅图标模式、窄窗口顶部导航、桌面外壳结构、
  **页面切换保留状态**、懒加载、顶部栏高度/动作/窄窗逐步收起/拖拽回调、
  内容宽度（1440 居中 / 设置页 1040）、1024×720 / 1280×720 / 1366×768 /
  1920×1080 / 2560×1440 无溢出、**Windows 缩放 100%/125%/150%**、
  系统字体 1.5 倍、主色/强调色即时更新、桌面关闭卡片进场动画；
* `test/desktop_legacy_pages_test.dart`（13 项，已按新架构重写）：
  桌面外壳明确装配 `PetLifeTheme`、回退开关默认关闭且由 `--dart-define` 驱动、
  共享页面不再有静默回退、legacy 实现保留且不依赖新设计系统、
  **Android 侧不受影响**、**`panel_layout` 定位算法与冻结模块未被改动**、
  控制面板除标题栏拖拽外不调用任何窗口/Region API；
* `test/petlife_design_system_test.dart` 新增 1 项：自定义颜色标签的可读性回归。

冻结回归由既有 1500+ 用例继续覆盖（轮盘几何 / Region / 右键菜单 / 区域所有权 /
固定画布 / 窗口几何守卫等），本轮全绿。

---

## 六、追加修复：缓存写入失败不再伪装成「云端统计失败」

真机现象（用户报告）：使用统计 → 云端 显示

```
云端统计刷新失败：SqfliteFfiException(sqlite_error: 8, SqliteException(8):
while executing statement, attempt to write a readonly database (code 8))
Causing statement: UPDATE cloud_statistics_cache SET ...
parameters: <完整的云端统计 JSON>
```

参数里已经带着**完整的云端统计 JSON**，说明网络请求与解析都成功了 ——
失败发生在之后写本地缓存那一步。但界面把它显示成了"云端统计失败"。

### 根因

`CloudStatisticsController._runRefresh` 里，缓存写入与网络请求在**同一个 `try`**：

```dart
_summary = summary; _timeline = timeline;   // 数据已经拿到
await _cache.saveSummary(...);              // ← 这里抛 SQLite code 8
await _cache.saveTimeline(...);
_status = loaded;
} catch (e) {                               // 被当成云端失败
  _errorMessage = '云端统计刷新失败：$e';
  _status = offlineCache / error;
}
```

于是"缓存坏了"被谎报成"云端失败"，用户会去重试网络，而真正的问题在本地
磁盘 / 多实例争用（截图脚本反复强杀 PetLife，把同一个 db 及其 WAL/SHM 留在异常状态）。

### 修法（最小改动）

* 缓存写入抽成 `_saveToCacheQuietly(...)`，**任何异常都不抛出**，只记日志并返回提示文本；
* 摘要与时间线**各自独立 try/catch**：一个失败不连累另一个，能留多少缓存就留多少；
* 控制器新增 `cacheWarning`（与 `errorMessage` 严格区分）：

  | 字段 | 含义 | 界面 |
  | --- | --- | --- |
  | `errorMessage` | **没拿到**云端数据（网络 / 解析 / 登录失效） | 红色错误卡 + 重试 |
  | `cacheWarning` | 数据**已拿到并正在展示**，只是缓存没写成功 | 黄色提示条，**不给重试** |

* 状态仍然是 `loaded`、`isOfflineData` 仍然是 `false`（展示的确实是刚拿到的新数据）；
* 设备列表与时间段的缓存写入同样改成尽力而为，不再占用各自的失败语义；
* 日志保留**完整**的底层错误（含 statement / parameters），便于定位只读库与 WAL 争用。

### 新增测试（`test/cloud_statistics_controller_test.dart`，4 项）

1. 缓存写入抛 SQLite code 8 时：仍然展示本次云端数据、`status == loaded`、
   `isOfflineData == false`、`errorMessage == null`、`cacheWarning` 含"本地缓存保存失败"；
2. 只有网络 / 解析失败才算云端失败（`errorMessage` 仍会设置，且此时没有缓存警告）；
3. 缓存恢复后再次刷新，警告被清除、数据仍是最新；
4. 缓存写入失败的完整 SQLite 错误（`readonly database` / `code 8`）确实写进了日志。

### 运维建议（与代码修复无关的环境问题）

`petlife.db` / `petlife.db-wal` / `petlife.db-shm` **不要单独删除 WAL**（可能丢未合并数据）。
建议：停掉所有截图脚本与 PetLife 实例 → 重启 Windows 彻底释放 SQLite 句柄 →
用 Release 包单独启动 → 再打开「使用统计 → 云端」。

---

## 七、交付物

* Windows 新控制面板源码（`lib/ui/desktop/control_panel.dart` +
  `lib/ui/desktop/control_panel_destinations.dart` + `lib/ui/widgets/petlife/petlife_desktop.dart`）
* Windows 专属页面视觉接入（状态映射 / 状态调试器 / 诊断）
* 桌面外壳与导航组件（见 §二）
* 主题与双配色支持（与 Android 同一套生成器 + 设置页配色区）
* Legacy 回退开关（`lib/ui/desktop/desktop_panel_flags.dart`）
* 自动化测试（见 §四）
* **Windows Release 完整目录**：`build/windows/x64/runner/Release/`
* **Windows 完整 ZIP 分发包**：`build/windows/PetLife-windows-x64-0.1.0.zip`
* 截图（`build/screenshots/windows/`）：
  * `1920x1080_素材库.png`
  * `1920x1080_设置.png`
  * `1366x768_账户与同步.png`
  * `1024x720_诊断.png`
  * `1024x720_状态映射.png`
* 截图工具（可复现）：`tool/screenshot_panel.dart` + `tool/capture_panel_shots.ps1`

---

## 八、未完成项 / 需要你处理

1. **「使用统计」页截图待重拍**：现有那张（`待重拍_使用统计_云端子页旧视觉.png`）
   拍到的是**云端子页**（持久化设置停在该子页），并且页面里显示了
   `attempt to write a readonly database` 的报错 —— 那是同时存在两个 PetLife
   实例争用同一个 SQLite 文件的产物，不是本轮改动引入的。
   请在本机单独运行控制面板、手动切到「使用统计 → 本机」后自行补一张。
   我未继续重试的原因是你已指示停止截图验收。
2. **100% / 125% / 150% 缩放验收记录**：自动化层已用
   `physicalSize` + `devicePixelRatio` 覆盖（125% → 逻辑宽 819px 自动切顶部紧凑导航），
   但**没有**在真实 Windows 显示缩放设置下逐个切过。需要你在系统设置里改缩放后确认。
3. **Android 与 Windows 并排对照截图**：未完成（需要可运行的 Android 设备；
   本机模拟器因缺少 hypervisor 驱动无法启动）。
4. **云端统计子页内部视觉**：仍为旧视觉。规格 §6 允许本轮保留，仅要求外层统一
   （已满足：外层是本机/云端胶囊切换 + 卡片工具栏）。
5. **源码尚未提交**：本轮全部改动仍在工作区，请自行 `git add` / 提交。
6. `lib/ui/desktop/legacy/` 与回退开关按规格暂时保留，验收稳定后再单独删除。
