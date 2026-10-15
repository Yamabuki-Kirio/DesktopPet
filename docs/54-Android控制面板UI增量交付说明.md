# 54 - Android 控制面板 UI 增量交付说明

本轮把 Android 控制面板从"偏系统设置页的灰白界面"改造为
**白色主色 + P3P 粉强调色**、P3P 图形语言 + Animeko 信息层级 + Kazumi 卡片布局的
统一二次元工具型 UI。

**没有改动**：悬浮桌宠窗口逻辑、轮盘几何与手势、当前应用识别、使用统计算法、
数据库结构、同步协议、服务端、Windows UI、素材包格式、菜单业务动作 ID。

> ⚠ **关于「Windows UI 不受影响」的修正（本轮补做）**
> 使用统计 / 账户与同步 / 素材库 / 设置这四个页面类**同时被 Windows 控制面板复用**
> （`lib/ui/desktop/control_panel.dart`）。第一版改造直接重写了这四个类，
> 而桌面外壳刻意沿用改造前的主题（**没有**装 `PetLifeTheme` 扩展），
> 于是共享页面在 Windows 上会回落到新主题的默认"白 + 粉"调色板 ——
> 这等于悄悄改了 Windows 外观，违反硬边界。
>
> 修正方式（不新增任何开关、不改桌面外壳一行）：
> 把改造前的实现原样保留在 `lib/ui/desktop/legacy/`，四个共享页面在
> **"当前主题没有 `PetLifeTheme` 扩展"** 时直接委托过去：
>
> ```dart
> if (PetLifeTheme.maybeOf(context) == null) {
>   return LegacyUsageStatsPage(...);   // 桌面：改造前的实现
> }
> ```
>
> 判定依据由**主题**给出而不是调用方传参 —— 少传一处就会漏改平台，
> 而主题只有一处装配点。`test/desktop_legacy_pages_test.dart` 固化这条边界。
> 已逐字节核对：四个 legacy 文件与改造前的源码**完全一致**
> （仅类名加 `Legacy` 前缀 + 相对导入深度修正）。

---

## 一、交付物

| 交付物 | 路径 |
| --- | --- |
| Android 测试 APK | `build/app/outputs/flutter-apk/app-debug.apk`（181.6 MB，release 签名用 debug key，可直接安装） |
| 新的公共设计系统 | `lib/ui/theme/`、`lib/ui/widgets/petlife/` |
| Windows 回落实现（与改造前逐字节一致） | `lib/ui/desktop/legacy/` |
| 原创 APK adaptive icon + 启动页 | `android/app/src/main/res/mipmap-*`、`drawable-*`、`values-v31/` |
| 图标生成脚本（可复现） | `tools/make_app_icon.py` |
| 自动化测试 | `test/theme_system_test.dart`、`test/petlife_design_system_test.dart`、`test/mobile_root_pages_test.dart`、`test/app_icon_assets_test.dart`、`test/desktop_legacy_pages_test.dart` |
| 本说明 | `docs/54-Android控制面板UI增量交付说明.md` |

---

## 二、新设计系统结构

### 1. 设计令牌（唯一真相）

`lib/ui/theme/design_tokens.dart` —— 只有常量，不含业务逻辑：

* `PetLifeColors`：默认主色 `#FFFFFF`、默认强调色 `#F24D96`、
  主要文字 `#2A1530`、次要文字 `#6F6170`、危险 `#E5484D`、
  成功 `#27A866`、警告高光 `#FFD42A`；
* `PetLifeRadii`：大卡片 20 / 普通卡片 16 / 按钮 14 / 输入框 14 / 弹窗 24 / 标签胶囊；
* `PetLifeSpacing`：页面 16 / 卡片内 16 / 卡片间 12 / 分组间 20 / 最小触摸 48；
* `PetLifeDurations`：页面切换 200ms、卡片出现 180ms、导航胶囊 200ms、
  按压 90ms、主题切换 240ms、弹窗 220ms；
* `PetLifeText`：页面标题 22 / 卡片标题 17 / 重要数据 30~34 / 正文 15 / 说明 12.5。

### 2. 主题生成器

`lib/ui/theme/petlife_theme.dart`：

* `PetLifePalette.resolve(primary, accent, brightness)`
  把**主色**（页面背景 / 顶部栏 / 卡片表面 / 底部导航表面 / 弹窗表面）与
  **强调色**（按钮 / 选中态 / 图标高亮 / 图表 / 进度条 / 开关 / 焦点边框）
  分别展开成完整调色板；次级背景由"强调色 5% 叠在主色上"派生（白底≈`#FFF7FB`）；
* `petLifeReadableOn` / `petLifeEnsureReadable`：按 WCAG 对比度**自动**挑文字色，
  主色是白色时用 `#2A1530`、主色是深色时用近白色，强调色上优先白字、
  达不到 3.0 对比度就自动换深色 —— 因此**不会出现白字白底或同色按钮**；
* `buildPetLifeThemeData`：把调色板注入 `ThemeData`（含圆角、控件、弹窗、
  输入框、Switch/Slider/Checkbox/SegmentedButton、SnackBar 等全部控件样式）；
* `PetLifeTheme`（`ThemeExtension`）带 `lerp`：主题切换是颜色渐变，不整页闪白。

页面通过 `PetLifeTheme.of(context)` 取色，**禁止硬编码**（有测试静态拦截）。

### 3. 公共组件

`lib/ui/widgets/petlife/`：

* `petlife_components.dart`：`PetLifeCard`（普通/大/选中/斜切角/强调条）、
  `PetLifeSectionTitle`、主/次/危险按钮、`PetLifeTag`、`PetLifeStatusDot`、
  `PetLifeStat`、`PetLifeProgressBar`、`PetLifeKeyValue`、
  `PetLifeSettingRow` / `PetLifeSwitchRow` / `PetLifeActionRow` / `PetLifeSliderRow`、
  `PetLifeEmptyState`、`PetLifeErrorState`、`PetLifeLoading`、`PetLifePillSelector`；
* `petlife_page.dart`：`PetLifePage`（标题区 + 内容区）、`PetLifeHeaderAction`、
  `PetLifePageSwitcher`（200ms 淡入 + 轻微上移，用 `IndexedStack` 保留页面状态）；
* `petlife_nav.dart`：`PetLifeBottomNav`（强调色胶囊**平移**选中，200ms）；
* `petlife_decor.dart`：P3P 装饰（低透明度斜切块 + 放射线、短黄色高光线、
  斜切角、不规则分组标记、卡片出现动画），**全部包在 `IgnorePointer` 里**；
* `petlife_color_picker.dart`：预设 + 自定义（HSL 滑杆 + 十六进制）+ 恢复默认；
  取消自定义**不修改**当前主题。

---

## 三、五个根页面：新旧对照

| 页面 | 改造前 | 改造后 |
| --- | --- | --- |
| 外壳 | `NavigationBar`（Material 默认）+ `#F4F6F9` 背景 + 无标题区 | 统一 `PetLifePage` 标题区（22sp 粗体左对齐 + P3P 短线/黄色高光）+ 强调色胶囊底部导航 + 200ms 页面切换 + 状态栏/导航栏配色跟随主题 |
| **桌宠首页** | 320px 高的桌宠预览 + 一堆 `键：值` 行 + 两个按钮 | 「当前桌宠状态卡」（角色缩略图 / 角色名 / 情绪 / 当前前台应用 / 自动状态切换 / 悬浮服务 / 同步）→「四个快捷操作」（显示·隐藏桌宠 / 切换状态 / 更换角色 / 素材库，全部接真实动作）→「今日陪伴」（今日使用时长、当前状态、最近同步、最近 7 天小型趋势图） |
| **使用统计** | 顶部工具条 + 6 张灰白卡片 + 密集 `Table` 列表 | 三个清晰区域：今日概览卡（大号主数字 + 次级指标网格）→ 应用排行（图标 + 名称 + 时长 + 横向进度条，**点击展开**现有明细：应用标识 / 段次数 / 占比 / 改名 / 改分类 / 排除）→ 时间线（时间节点圆点 + 竖线，保留日期切换、本机·云端与设备筛选）；分类统计与记录管理保留为独立卡片；空数据用插画式空状态 |
| **账户与同步** | 若干灰白 `Card` + 大量 `_kv` 行 | 分组卡片：账户信息（含红色「退出登录」）→ 同步状态（当前同步状态 / 待上传 / 最近同步时间 / 最近上传 / 最近下载 / 连续失败 / 最近同步结果）→ **「立即同步」强调色主按钮**（保留引擎 `_inFlight` 防重入 + 按钮禁用，结束后回读真实状态与摘要）→ 当前设备与设备管理（撤销 = 红色 + 二次确认）→ AI 访问 → 网络连接 → 隐私说明 |
| **素材库** | 4 个导入按钮 + 路径输入框 + 左栏 260px 树 + 小卡片（star/eye/more/delete 图标行） | 统一操作栏（一个「导入」入口 + 刷新 + 筛选，**不会横向溢出**）→ 底部弹窗收拢文件夹/多图/单图/ZIP/按路径导入 → 手机顶部筛选（作品包下拉 + 角色胶囊 + 「设为当前桌宠角色」+ 搜索），宽屏保留左侧作品包/角色树 → **两列大卡片**（突出人物预览，状态名/帧数/尺寸为次要信息；收藏、使用中、更多菜单收进卡片底部操作区；删除走红色二次确认；当前使用素材用强调色描边 + 对勾 + 「使用中」标签）→ 空状态给「导入素材」主按钮 |
| **设置** | `_section` 灰色小标题 + `SwitchListTile` / `ListTile` 连续堆叠 | 七个**独立圆角卡片**分组（`lib/ui/pages/settings_sections.dart` 是唯一真相）：桌宠 / 外观与主题 / 状态联动 / 账户与同步 / 权限 / 高级 / 诊断；外观与主题里有**两个独立**的配色区（主色、强调色）+ 明暗模式 + 实时预览 + 恢复默认 |

### 主题与配色（需求 §3）

* 主色与强调色是**两个独立字段**：`ui.primaryColor`、`ui.accentColor`
  （`AppSettings` + `SettingsController.setThemePrimaryColor` / `setThemeAccentColor`），
  改一个绝不覆盖另一个；
* 明暗模式 `ui.themeMode`（`light` / `dark` / `system`，默认 `light`，
  保证"默认一眼可判定为白色主题"）；
* 非法值（手改数据库 / 旧版本残留）安全回落默认值，不抛异常。

### APK 图标与启动页

* 原创图标：白色圆角方形底 + 粉色放射环 + 中央爪印（无文字、无角色）；
* adaptive icon 前景/背景分层：背景 = `@color/ic_launcher_background`（白），
  前景 = `ic_launcher_foreground.png`（内容全部落在 108dp 画布的中央 66dp 安全圆内，
  圆形 / 方形 / 水滴形启动器都不会裁掉）；
* 启动页：白色背景 + 中央新图标 + 下方 `PetLife` + 一条粉色加载线；
  API < 31 用 `launch_background.xml`，API 31+ 用系统启动页
  （`windowSplashScreenAnimatedIcon` + `windowSplashScreenBrandingImage`，
  动画 200ms，不播放长时间动画）。
* 全部由 `tools/make_app_icon.py` 生成，可复现。

---

## 四、验证结果

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!** |
| `flutter test` | **1542 passed / 0 failed（1 skipped）**；改造前基线为 1452 passed |
| `flutter build apk --debug` | **成功**：`build/app/outputs/flutter-apk/app-debug.apk` |
| Android 定向 Widget 测试 | 素材库窄屏(320/360/393/412)/横屏/宽屏/1.3×/1.5× 无溢出；导航五入口；首页状态卡绑定；设置七组；图标资源完整性 |
| Windows 边界回归 | 四个共享页面在"无 `PetLifeTheme` 扩展"时必须委托给 `Legacy*`；legacy 实现不依赖新设计系统 |

新增/调整的测试：

* 新增 `test/theme_system_test.dart`（29 项）：默认值、主色/强调色独立修改与落盘、
  8 组"对抗性"配色 × 明暗两种模式的可读性、非法值回落、ThemeData 生成与插值；
* 新增 `test/petlife_design_system_test.dart`（15 项）：设计令牌区间、
  底部导航（五入口 / 点击回调 / 胶囊移动 / 1.5 倍字体不溢出）、
  卡片与控件、页面骨架与状态保留；
* 新增 `test/mobile_root_pages_test.dart`（18 项）：五根入口契约、轮盘跳转下标、
  首页状态卡数据绑定、设置七组、Windows 不受影响；
* 新增 `test/app_icon_assets_test.dart`（13 项）：adaptive icon 分层、
  5 档密度尺寸、前景透明底与安全圆、启动页两种路径、
  **图标不再含旧版蓝色**；
* 新增 `test/desktop_legacy_pages_test.dart`（13 项）：**Windows 边界回归** ——
  主题装载与否是新旧 UI 的唯一开关、四个共享页面都有桌面回落守卫、
  legacy 实现不掺入新设计系统且保留改造前的视觉特征、桌面外壳调用点一行未改；
* 调整 `test/asset_library_layout_test.dart`：断言从旧布局（star/delete 图标行、
  260px 左栏文案）更新为新布局，但**保留**"任何宽度/字体倍率都不得溢出"的核心契约，
  并新增"手机两列 / 宽屏更多列"的断言；
* 调整 `test/startup_registration_test.dart`：开关组件由 `SwitchListTile`
  改为 `Switch`（设计系统统一控件），断言的真实行为（以系统实况为准、失败回滚）不变。

业务回归：`flutter test` 全量通过说明同步、统计口径、素材导入、状态映射、
设备管理、权限与开机自启等既有行为未被破坏；`platform_isolation_test` 继续通过，
桌面专属依赖没有泄漏到 Android 编译单元。

---

## 五、未完成项 / 待你在真机验收

1. **五个根页面真机截图**：未完成。
   本机 `crmeb_api35` 模拟器无法启动 ——
   `emulator -accel-check` 返回 *"Android Emulator hypervisor driver is not installed"*，
   x86_64 AVD 强制要求硬件加速，因此模拟器路径不可用。
   APK 已构建完成，请用真机安装后截图。
2. **360dp / 412dp / 平板 / 1.5 倍字体真机验收**：未完成（同上）。
   自动化层已覆盖 320/360/393/412、780×360 横屏、1280×800 宽屏与 1.3×/1.5× 字体，
   均无 RenderFlex 溢出、无文字截断；但"真机截图 + 肉眼验收"仍需你完成。
3. 以下项目**本轮刻意未做**（避免超出增量边界）：
   * 云端统计子页（`CloudStatisticsPage`）内部视觉未按新设计系统重排 ——
     它已有 30+ 条精确文案断言，本轮只改它外层的胶囊切换与卡片工具栏，
     以避免无关回归；如需统一，可下一轮单独做；
   * Windows 控制面板视觉未变（本轮硬边界）；
   * 自定义颜色的取色盘是 HSL 滑杆 + 十六进制输入，没有做色环控件。
