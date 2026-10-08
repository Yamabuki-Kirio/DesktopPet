# 29 - Phase 4 测试与验收报告（Phase 4A）

> 范围：**Phase 4A**（Android 工程与跨平台基础）。
> Phase 4B / 4C / 4D 未实施，本文不把它们写成已完成。

## 1. 结论摘要

| 项目 | 结果 |
|---|---|
| Android 工程生成 | ✅ `android/`（已恢复为当前 Flutter SDK 模板的官方版本矩阵） |
| 平台编译隔离 | ✅ 静态契约测试通过（详见 §3.2） |
| 数据库 / 设备信息 / 文件导入适配 | ✅ 已实现并有测试（§3.3） |
| **Android Keystore 凭据存储** | ✅ **已实现**：原生 MethodChannel + AndroidKeyStore + AES/GCM/NoPadding（§2.3） |
| Android Material 外壳（底部导航五页） | ✅ 已实现（真机验收项见 §4） |
| 服务端接受 `android` 设备 | ✅ 已放宽并新增测试（§3.4） |
| Flutter 自动化测试（Windows 宿主） | ✅ **443 通过 + 1 跳过** |
| 服务端 pytest | ⚠️ **188 通过 / 1 失败**（既有用例的时间相关缺陷，与本次改动无关，见 §3.5） |
| `flutter analyze` | ✅ `No issues found!` |
| Windows Release 构建 | ✅ 通过（在**独立干净构建目录**验证，见 §2.2） |
| **Debug APK** | ✅ **已产出**，含全部 ABI（§2.1；已按第五轮真机缺陷修复后重建） |
| 真机：安装 / 启动 / 建库 / 主页 | ✅ **已通过**（用户真机确认，见 §4.0.2） |
| 真机：登录 / Android 设备注册 / 同步 / 图片选择导入 | ✅ **已通过**（同上） |
| 真机：素材导入弹窗（情绪名称留空）、设备改名弹窗 | ✅ **已通过**（`_dependents.isEmpty` 修复后真机复验确认，见 §4.0.3） |
| 真机：ZIP 导入 | ❌ 真机必然失败 → ✅ 已修复 → ⏳ **待真机复验**（§3.2.1 / §4.0.3） |
| 真机：导入角色后「设为当前桌宠角色」 | ⏳ 激活/持久化/重启已通过，**桌宠页面未立即更新** → ✅ 已修复 → ⏳ **待真机复验**（§3.2.2 / §4.0.4） |
| 真机：Android 素材库布局溢出 | ❌ 真机出现 overflow → ✅ 已修复 → ⏳ **待真机复验**（同上） |
| 真机：Android 多选图片只导入一张 | ❌ 选 3 张只进 1 张（**SQLite 级联删除导致数据丢失**）→ ✅ 已修复 → ⏳ **待真机复验**（§3.2.3 / §4.0.5） |
| **Phase 4A 是否全部完成** | ❌ **未完成**：上述各项真机复验通过前不宣布完成 |

## 2. 构建产物与实测

### 2.1 Debug APK（✅ 已产出）

```
build/app/outputs/flutter-apk/app-debug.apk
```

| 项 | 值 |
|---|---|
| 路径 | `build/app/outputs/flutter-apk/app-debug.apk` |
| 文件大小 | 188,980,750 B（180.23 MB） |
| SHA-256 | `45482097D261A3E856008A478E3B74308CEBF50621436902EAB96EDF1367C6B0` |
| 构建时间 | 2026-09-29 17:34:23（**第五轮真机缺陷修复后重建**；历史值：PRAGMA `FCF30859…` → `AC863476…`、对话框 `7FE046C2…`、第三轮 `C00B941E…`、第四轮 `AF57468F…`） |
| 构建耗时 | 11.6 s（Gradle 任务 `assembleDebug`；热缓存） |
| <br> | **注意**：本次必须让 Gradle 走本地镜像，见 §2.4（`download.flutter.io` 在本机 HTTPS 被重置） |
| applicationId | `asia.akechi.petlife` |
| versionCode / versionName | 1 / 0.1.0 |
| minSdk / targetSdk / compileSdk | **24 / 36 / 36** |
| ABI（`native-code`） | `arm64-v8a`、`armeabi-v7a`、`x86_64` |
| launchable-activity | `asia.akechi.petlife.MainActivity` |
| label | `PetLife` |
| 内容校验 | `assets/flutter_assets/kernel_blob.bin` 中可检索到 `dialogs/device_edit_dialog.dart`、`dialogs/asset_import_form_dialog.dart`、`dialogs/text_input_dialog.dart` 与校验文案片段（`不能为空` / `个字符`），证明打包的是修复后的代码 |

**合并后 manifest 的权限（`aapt2 dump badging`，共 2 条）**

| 权限 | 来源 | 判定 |
|---|---|---|
| `android.permission.INTERNET` | 本仓库 `AndroidManifest.xml` 显式声明 | ✅ Phase 4A 唯一需要的能力 |
| `asia.akechi.petlife.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | **AGP/androidx 自动注入**（Android 13+ 注册非导出广播接收器用，签名级、仅限本应用自身） | ✅ 不是采集/悬浮窗类能力，也不是系统权限 |

> 需求禁止的 5 类权限（Usage Access / 悬浮窗 / 无障碍 / 读取通知 / 存储全盘访问）
> **一条都没有出现**。注意：仓库里的源 manifest 仍然只写了 1 条 `INTERNET`
> （`test/platform_isolation_test.dart` 断言的就是它），第 2 条是构建期由
> 依赖的 manifest 合并进来的，无法也不应该手写进源文件。

**APK 内容核验**：解包后在 `classes10.dex` 中检索到以下符号，证明原生实现确实被打进了包
（而不是只存在于源码里）：

```
asia.akechi.petlife/credential_store     ← MethodChannel 通道名
PetLifeCredentialStore                   ← 原生实现类
AndroidKeyStore                          ← KeyStore provider
AES/GCM/NoPadding                        ← 加密算法
setRandomizedEncryptionRequired          ← 强制随机 IV
```

### 2.2 Windows Release 构建（✅ 回归通过）

| 项 | 值 |
|---|---|
| 构建命令 | `flutter build windows --release --no-pub` |
| 构建目录 | **`%TEMP%\petlife_win_regress_20260929_4`**（源码的干净副本，见下方说明） |
| 结果 | ✅ `√ Built build\windows\x64\runner\Release\petlife.exe` |
| 耗时 | 冷构建 365.8 s |
| `petlife.exe` | 92,160 B，2026-09-29 17:42:23，SHA-256 `EFA2FC21F37A40F0A1AA939FA90C671B9C84F57760547D9E8F6FA4CC93BEC8EA` |
| `data\app.so` | 8,143,752 B，2026-09-29 17:41:46，SHA-256 `E6198935E42210609AB83F79F6A7E3EE2037FFE2B1D0BEA83114AAC49854C06D` |

> **为什么不在仓库目录里构建**：本机有 **24 个残留的 `petlife.exe` 进程**在运行
> （最早的起于 09-27），它们锁住了 `build\windows\x64\runner\Release\petlife.exe`，
> 在仓库目录里直接构建会稳定报
> `LINK : fatal error LNK1104: 无法打开文件 ...petlife.exe`。
> 这些进程在本会话内**无法终止**（Access denied）。
> 按需求要求，**没有**用"把被锁 exe 改名"的方式绕过 —— 改为把源码复制到
> `%TEMP%\petlife_win_regress`（不含 `build/`、`.dart_tool/`）做一次**干净构建**，
> 产物即上表。仓库内的 `build\windows\...` 未被本步骤写入任何额外文件。

> 过程中还发现并修复过一条**真实回归**（累计到本轮）：引入 `flutter_secure_storage`
> 后，它在 Windows 侧要编译一个依赖 ATL（`atlstr.h`）的 C++ 插件，
> 本机 VS Build Tools 未安装 ATL → Windows Release 构建直接失败。
> 处理：**移除该依赖**，Android Keystore 改为自建 MethodChannel（§2.3）。

### 2.3 Android Keystore 凭据后端（✅ 本轮实现）

| 文件 | 作用 |
|---|---|
| `android/app/src/main/kotlin/asia/akechi/petlife/PetLifeCredentialStore.kt` | AndroidKeyStore 生成不可导出 AES-256 密钥；`AES/GCM/NoPadding`；每次写入由系统生成随机 IV；`SharedPreferences` 只存 `v1:<IV>:<密文>` 信封 |
| `android/app/src/main/kotlin/asia/akechi/petlife/MainActivity.kt` | 注册 `asia.akechi.petlife/credential_store`，在单线程池上执行读/写/删，结果回主线程 |
| `lib/platform/android/android_keystore_credential_store.dart` | Dart 侧 `CredentialStore` 实现，负责错误码 → 明确异常的映射 |
| `lib/platform/android/android_credential_store.dart` | 工厂：**固定返回 Keystore 后端**，探测失败也**不降级为内存** |

安全要点（对应需求第 2 项 10 条）：

* 密钥材料留在 AndroidKeyStore 守护进程内，应用进程无法导出（`getEncoded()` 返回 null）；
* `setRandomizedEncryptionRequired(true)` —— 加密路径**不接受**调用方传入 IV；
* 解密失败 / 密钥失效 / 信封损坏一律抛 `CredentialStoreFailure`（错误码 `cipher_corrupt` / `key_invalid`），
  **绝不回退明文**、也**不返回猜测值**；
* 异常消息只含条目名与原因，不含令牌内容；
* Windows 完全不受影响：该 Kotlin 文件只被 Android 构建编译，Dart 侧也只有
  `AndroidCredentialStoreFactory` 会创建对应的通道对象。


### 2.4 Android 构建的网络约束与本地镜像（本轮新增，必须保留）

**现象**：`flutter build apk --debug --no-pub` 长时间无任何输出，最后失败：

```text
Could not download armeabi_v7a_debug-1.0.0-af7e796e161ae0bb1ff0758c71a7105418bd9ded.jar
  (io.flutter:armeabi_v7a_debug:1.0.0-af7e796e...)
 > Could not get resource 'https://storage.googleapis.com/download.flutter.io/io/flutter/...'
   > Got socket exception during request. It might be caused by SSL misconfiguration
     > Connection reset
```

**根因**：Flutter 的 Gradle 插件用 `FLUTTER_STORAGE_BASE_URL`（默认
`https://storage.googleapis.com`）拼出 `…/download.flutter.io` 仓库，用来取 4 个引擎产物
（`flutter_embedding_debug` / `armeabi_v7a_debug` / `arm64_v8a_debug` / `x86_64_debug`）。
本机到该域名 **TCP 443 可连、但 HTTPS 请求被 reset**，于是 Gradle 卡在反复重试上
（表现就是"编译很慢"，其实是在等网络）。
`--offline` 也不能直接用：`files-2.1` 里虽然已有完整 jar（SHA1 与缓存目录名一致），
但模块**元数据**缓存不可用，会报 `No cached version available for offline mode`。

**处理（不修改仓库任何源码）**：把本地 Gradle 缓存里的 4 个产物导出为
`file://` 协议的 Maven 仓库，再用环境变量让插件指向它：

```powershell
# 1) 导出到 C:\petlife_offline_mirror\download.flutter.io\io\flutter\<module>\<version>\
#    来源：%USERPROFILE%\.gradle\caches\modules-2\files-2.1\io.flutter\<module>\<version>\<sha1>\
#    需要的模块：flutter_embedding_debug / armeabi_v7a_debug / arm64_v8a_debug / x86_64_debug
#    每个模块都需要 .jar 与 .pom

# 2) 构建时设置（Flutter 会据此把仓库地址改成 file://）
$env:FLUTTER_STORAGE_BASE_URL = 'file:///C:/petlife_offline_mirror'
& 'C:\src\flutter\bin\flutter.bat' build apk --debug --no-pub
# → √ Built build\app\outputs\flutter-apk\app-debug.apk   （15.0 s）
```

**必须遵守的构建纪律**（本轮踩过的坑）：

* Android 与 Windows **顺序构建**，不要并发 —— 会互相争用磁盘与 Gradle/Flutter 缓存；
* 每次 Windows 回归使用**新的**临时目录，不要"一边递归删旧目录、一边跑 Gradle"；
* 构建中途不要强杀 `dart/java` 进程，否则 Gradle 元数据缓存会残留不一致状态
  （本轮强杀后就出现过 `No cached version available for offline mode`）。

## 3. 自动化测试

### 3.1 全量结果

```powershell
flutter analyze --no-pub      # No issues found!
flutter test --no-pub         # 443 通过 / 1 跳过
cd server; .\.python\python.exe -m pytest -q   # 188 通过 / 1 失败（见 §3.5）
```

跳过的那一项是 `test/e2e_real_server_test.dart`（需要真实服务端地址，
由 `PETLIFE_E2E_STAGE` 环境变量显式开启，属既有约定）。

### 3.2 新增：平台隔离与能力（Phase 4A 的核心契约）

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/platform_isolation_test.dart` | 6 | 桌面专属依赖只出现在平台层/桌面 UI/装配点；`Platform.is*` 只在平台层；Android 编译单元零桌面依赖；装配点确实认识两个平台；窗口/托盘为中立接口；Android 只声明 INTERNET；签名材料被 gitignore |
| `test/platform_capabilities_test.dart` | 11 | Android 能力表（无窗口/托盘/采集/代理探测/进程指标/悬浮窗/文件夹导入，需要使用情况访问权限）；Windows 能力表全部保留；两端数据库后端名不同 |
| `test/platform_database_test.dart` | 4 | Android 后端是 sqflite（非 FFI）且 `configure()` 安全；`AppDatabase` 走注入后端打开；**共享 Schema 的 13 张表与版本号一致**；默认后端=当前平台 |
| `test/android_keystore_credential_store_test.dart` | 19 | **通道合约**（方法名/参数名/通道名与 Kotlin 常量一致）；写/读/覆盖/删/幂等/多条目隔离；**密文不含明文**（含任意 6 字符片段扫描）与**同明文两次写入 IV 不同**；错误码映射（`key_invalid` / `cipher_corrupt` / 未知码）；通道未注册时报明确错误；**Kotlin 源码静态契约**（AndroidKeyStore、AES/GCM/NoPadding、256 位、`setRandomizedEncryptionRequired(true)`、加密路径无 IV、`putString` 只写信封不写 secret） |
| `test/android_credential_store_test.dart` | 8 | **Android 工厂选 Keystore 后端**（且不是内存后端）；通道不可用时仍不降级；后端满足读写删契约；**Windows 工厂仍选原有三级降级链**（且不是 Keystore）；两个装配点各绑自己的工厂；探针协议与清理 |
| `test/device_environment_test.dart` | 4 | 宿主默认为 windows/x64；切到 Android 环境后 platform/arch/model 全部就绪；`DeviceRegistration` 带机型且与 Windows 平台不同；服务端架构白名单包含 Android ABI |
| `test/mobile_ui_test.dart` | 5 | 未采集时的说明文案（含"什么还能用"与"下一步"）；已采集时文案与图标切换；Android 能力驱动该文案；素材导入只保留 ZIP |
| `test/database_pragma_test.dart` | 7 | **真机启动缺陷的回归保护**：用真实 SQLite 实测各 PRAGMA 的结果集特性（`journal_mode` 有结果行、`synchronous` / `foreign_keys` 无）；模拟 Android 严格 `execute()` 复现真机约束并通过（含反向验证替身确实会拒绝旧写法）；扫描 `lib/**` 断言没有"有结果集"的 PRAGMA 交给 `execute()` |
| `test/dialog_lifecycle_test.dart` | 22 | **真机对话框缺陷的回归保护**：素材导入弹窗 8 项（情绪/角色/作品包留空、全部填写、取消、连续开-关-再开、退场中销毁父页面、父页面先销毁再关弹窗）；设备编辑弹窗 9 项（改名/改型号保存、型号留空可存、名称留空与超 128 字符报错且不关闭、128 边界可存、取消、连续开-关、两种销毁时序）；通用文本输入弹窗 2 项；静态审计 2 项（审计器自检 + `lib/` 全量扫描）。每个用例在退场动画跑完后断言无 FlutterError、无残留动画 |

本轮新增 **24 项**：`android_keystore_credential_store_test.dart` 全新 19 项，
`android_credential_store_test.dart` 由 3 项扩到 8 项（+5）。
加上后续为开机自启新增的 41 项、为 PRAGMA 真机缺陷新增的 7 项、
为对话框真机缺陷新增的 22 项、
为**第三轮真机缺陷**（ZIP / 角色激活 / 手机布局）新增的 27 项、
为**第四轮真机缺陷**（桌宠页面不刷新 / 多选只导入一张）新增的 12 项、
为**第五轮真机缺陷**（SQLite 级联删除导致导入数据丢失）新增的 10 项，
合计 **443 = 原有 300 + 24 + 41 + 7 + 22 + 27 + 12 + 10**，与 `flutter test` 输出一致。

### 3.2.1 第三轮真机缺陷的回归测试（新增 27 项）

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/asset_import_zip_test.dart` | 12 | **统一导入路由器**：`ZipImportRequest` 必须进 `ZipAssetImporter`、文件/文件夹进 `DefaultAssetImporter`、进度回调透传；`DefaultAssetImporter` 的 ZIP 防御分支不再暴露内部类名；**Android SAF 临时副本**（只有 bytes → 复制到应用私有临时目录且可读、可清理；有真实 path → 直接使用且不标临时；两者都没有 → 明确报错）；**真实 ZIP 端到端**（真实 WebP + 真实 SQLite：多个角色/多个情绪正确建立、`original_file_path` 为 `zip://`、损坏 ZIP 不暴露内部类名、路径穿越被 `unsafeArchive` 中止、不存在路径给出可理解原因）；**单图导入 + 勾选「设为默认图片」→ 新角色具备合法 `default_asset_id`** |
| `test/asset_library_activation_test.dart` | 6 | 引擎未启动时激活首个角色会 `start` 并立即生效；引擎已启动时激活新角色 → `StateEngine.currentCharacter` **立即**变化；「选择列表项目」≠「设为当前桌宠角色」；激活状态**重启后恢复**（`lastCharacterId`/`defaultCharacterId` 落库 + 新控制器读出「使用中」）；无可用素材的角色**禁止激活**并给出原因；**设置默认素材后桌宠立即刷新**（`refresh()` 重载角色默认图片） |
| `test/asset_library_layout_test.dart` | 9 | 手机竖屏 **320 / 360 / 393 / 412 px** 均无 `RenderFlex` overflow 且操作按钮可见；横屏 780×360 无 overflow 并回到宽屏分栏；窄窗口 + 支持文件夹导入时工具栏不溢出；`textScaleFactor` **1.3 / 1.5** 无 overflow；桌面宽屏 1280×800 保留左右分栏、布局不退化 |

### 3.2.2 第四轮真机缺陷的回归测试（新增 12 项）

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/pet_character_switch_test.dart` | 4 | **单元**：仅 `setCharacter()`（系统状态不变、因此**没有** `StateChangeEvent`）也必须让渲染器立即换素材；同一素材的重复快照不重复 `display`（去重、不重启动画）；经 `LibraryController.activateCharacter()` 激活后立即生效，重启后仍是该角色。**Widget**：只 `pumpWidget` 一次，`角色 A → B` 后 `PetLayerPainter` 的图层立即变成 B 的素材，且页面因监听 `stateEngine.snapshots` 而重建 |
| `test/image_import_multi_select_test.dart` | 8 | **物化**：真实路径直接使用且不标临时；只有 bytes → 复制到临时目录并**保留原始文件名与扩展名**（`saf://` 来源）；混合选择 3 张（含 1 张无路径）必须 3 张全部物化，不丢文件；既无路径也无 bytes → 带原因进 `rejected`（不静默跳过）。**导入**：普通文件名 + 指定角色时 3 张生成 3 条**不同**素材（不再互相覆盖，变体取原始文件名 `a`/`b`/`c`）；重复导入同一批仍 3 条且 ID 不变（稳定、非随机）；单张导入 `variant` 仍为 `default`（既有 ID 规则不变）；临时副本的来源记为 `saf://`，索引里不出现会被清理的临时路径 |

### 3.2.3 第五轮真机缺陷的回归测试（新增 10 项，真实 SQLite + 真实外键）

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/asset_cascade_import_test.dart` | 10 | **前置条件**：`PRAGMA foreign_keys` 确实为 1（否则级联回归会假通过）。**父表 upsert**：`PackDao.upsert` 更新作品包后角色与素材都还在；`CharacterDao.upsert` 更新角色后素材还在；`repository.ensurePack` 反复改写 `source_path` 后原角色与 3 张素材仍在；**反向验证**：真正删除作品包时级联仍然生效（证明外键是"武装"的，上面的通过不是因为外键没开）。**端到端**：3 张图片 + 同一角色名 → 报告 新增 3 / 数据库确认 3，SQL 直查 `COUNT(*)` 也是 3；关闭并重新打开数据库后仍是 3；重复导入仍是 3 且 ID 不变（报告显示"更新 3"）；SAF 临时副本（不同 `originalSource`）与普通路径混用不丢数据且来源标注正确；文件选择导入的作品包来源为 `files` 且 `source_path` 为空 |

> **反向验证已执行**：把 `PackDao.upsert` 临时改回 `ConflictAlgorithm.replace`，
> 该组测试立刻失败并给出
> 「更新作品包把角色级联删掉了（INSERT OR REPLACE 缺陷）」，确认这组测试真的能拦住该缺陷。

### 3.3 复用的既有覆盖（未改动）

以下既有测试在 Phase 4A 之后全部继续通过，证明"没有破坏 Windows 功能"：

* 活动采集与统计：`activity_*_test.dart`、`usage_analytics_test.dart`
* 数据库与迁移：`activity_migration_test.dart`、`sync_migration_v3_test.dart`、`settings_persistence_test.dart`
* 同步与安全：`sync_engine_test.dart`、`sync_outbox_test.dart`、`sync_security_test.dart`、`auth_relogin_race_test.dart`
* 代理：`proxy_client_test.dart`、`proxy_settings_test.dart`
* 素材与桌宠：`asset_import_integration_test.dart`、`pet_animation_repaint_test.dart`、`state_engine_test.dart`、`webp_container_test.dart`
* 界面：`ai_access_card_test.dart`

### 3.4 服务端新增测试

| 用例 | 覆盖 |
|---|---|
| `test_devices.py::test_register_android_device_alongside_windows` | 同一账户下 Android 与 Windows **并存**；`platform=android` 与 `architecture=arm64-v8a` 均被接受；两条设备记录 ID 不同 |
| `test_devices.py::test_invalid_architecture_is_rejected` | 架构白名单生效（`mips` → 422） |

服务端同时放宽了两处白名单（`app/schemas/device.py`）：
`PLATFORM_CHOICES` = windows/android/macos/linux；
`ARCHITECTURE_CHOICES` 增加 `arm64-v8a` / `armeabi-v7a` / `x86_64`。
**不改数据库结构、不改统计口径、不改同步协议。**

### 3.5 服务端 1 项失败：既有用例的时间相关缺陷（**不是本轮引入**）

```
FAILED tests/test_mcp_tools.py::test_tool_stops_working_after_key_revoked
       - assert 0 == 1800
```

**根因（已定位到具体代码）**：`tests/test_integration_stats.py` 的 `seed_usage()` 把
"今天 30 分钟 code"灌在 **UTC 零点**：

```python
def _today_start() -> datetime:
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
```

而查询用的是**本地时区**（`period=today&tz_offset_minutes=480`，即 UTC+8）。
本地"今天"的起点在 UTC 上是**前一天的 16:00**。
因此当本机本地时间落在 **00:00–08:00（UTC+8）** 时，
"UTC 零点"的数据落在本地今天的窗口**之外**，查询结果自然是 0。

复现时间：本次运行发生在本地 **01:20 左右** → 必然失败。
在本地时间 08:00 之后重跑就会通过（此前记录的 "189 passed" 也是在白天跑的）。

**结论与处理**：这是测试自身的时区缺陷，**与 Phase 4A 的任何改动无关**
（本轮没有改动 `server/` 下任何文件）。本轮**没有**顺手改它 ——
修法应当是让 `seed_usage()` 与查询使用同一个时区基准，
属于服务端测试的独立修复项，需单独确认后提交。因此这里的结论是
"**服务端测试未全绿**"，而不是"通过"。

## 4. 真机人工验收（⏳ 待执行）

### 4.0 首次真机尝试：**失败**（已修复，待复验；**不计为通过**）

2026-09-29 首次在真机上安装运行，**启动即崩在数据库创建阶段**：

```
DatabaseException:
Queries can be performed using SQLiteDatabase query or rawQuery methods only.

SQL:
PRAGMA journal_mode = WAL
```

* **根因**：`AppDatabase.open` 的 `onOpen` 用 `execute()` 执行了
  `PRAGMA journal_mode = WAL`。这条语句**会返回一行**（生效后的模式），
  而 Android 的 `execSQL` 底层只接受"不返回数据"的语句；
  Windows 的 FFI 后端对此宽容，所以该缺陷在 Windows 上一直没暴露。
* **修复**：改用 `rawQuery()` 并校验返回值确实为 `wal`；
  `PRAGMA synchronous = NORMAL` 经实测无结果集，继续用 `execute()`。
  详见 [31-Android数据库启动失败与PRAGMA兼容性.md](31-Android数据库启动失败与PRAGMA兼容性.md)。
* **影响面**：**Phase 4A 的真机验收没有一条通过**。修复只是消除了启动阻塞，
  下面 16 步仍需在真机上重新走一遍才能判定。

> 也就是说：本次记录的是**一次真机失败**，不是"真机验收通过"。
> 结论表 §1 与本节都按此口径书写。

### 4.0.1 为什么剩下的复验要由用户完成

需求里"APK 能够安装并启动 / 登录现有账户成功 / 注册为 Android 独立设备 /
重启后仍保持登录 / 手动同步成功"这 5 条**必须**有 Android 设备才能验证。
**开发机侧**没有可用设备：

| 检查 | 结果 |
|---|---|
| `adb devices` | 空的（无真机连接） |
| 本机 AVD | 无 |
| `system-images` | 无（未安装任何系统镜像） |
| Windows Hypervisor Platform（WHPX） | **Disabled**（启用需要管理员权限 + 重启） |
| AEHD / HAXM 加速驱动 | 未安装（安装同样需要管理员权限） |

即：**开发机既没有真机，也无法启动模拟器**，所以修复后的复验只能由用户在自己的设备上完成。

### 4.0.2 第二轮真机反馈（2026-09-29）：启动链路通过，两个弹窗崩溃

PRAGMA 修复后的 APK 再次上真机，**第一轮的启动阻塞已解除**，以下各项**已确认真机通过**：

| # | 项目 | 结果 |
|---|---|---|
| 1 | APK 安装与启动 | ✅ 通过 |
| 2 | SQLite 数据库创建 | ✅ 通过（PRAGMA 修复生效） |
| 3 | 进入移动端主页 | ✅ 通过 |
| 4 | 登录现有账户 | ✅ 通过 |
| 5 | Android 设备注册 | ✅ 通过 |
| 6 | 数据同步 | ✅ 通过 |
| 7 | 图片选择与基础导入 | ✅ 通过（选文件、走导入流程正常） |

同时发现**两个必现崩溃**（同一句断言）：

| # | 操作 | 结果 |
|---|---|---|
| 8 | 素材库 → 导入图片 → **情绪名称留空** → 导入 | ❌ `'_dependents.isEmpty': is not true.` |
| 9 | 账户与同步 → 修改本机 → 改设备名称 → 保存 | ❌ 同一句断言 |

* **根因**：两处都在**调用方**创建 `TextEditingController`，并在
  `await showDialog(...)` 返回后立刻 `dispose()`。而 `Navigator.pop` 会立刻完成那个
  Future，弹窗 Element 却要等退场动画结束才 unmount —— 控制器在控件仍然依赖它的时候
  被销毁，触发 `InheritedElement.debugDeactivated()` 里的
  `assert(_dependents.isEmpty)`（`framework.dart:6281`）。
* **修复**：把三个弹窗提取为独立 `StatefulWidget`，控制器由弹窗自己的 State
  创建/销毁，调用方只接收不可变结果对象；并补上调用方的 `mounted` 保护。
  详见 [32-对话框生命周期与控制器归属.md](32-对话框生命周期与控制器归属.md)。
* **状态**：❌→✅ **已修复并真机复验通过**（见 §4.0.3）。
  8、9 两项至此**计为通过**。

### 4.0.3 第三轮真机反馈（2026-09-29）：弹窗通过、发现三个新缺陷

**已确认真机通过**（`_dependents.isEmpty` 修复后的 APK）：

| # | 项目 | 结果 |
|---|---|---|
| 8 | 素材库 → 导入图片 → **情绪名称留空** → 导入 | ✅ 通过（不再崩溃，成功导入） |
| 9 | 账户与同步 → 修改本机 → 改设备名称 → 保存 | ✅ 通过 |

同时真机发现**三个新缺陷**，本轮已全部修复，但**修复后尚未复验**：

| # | 真机现象 | 根因 | 修复 |
|---|---|---|---|
| A | ZIP 导入必然失败，提示「ZIP 导入请使用 ZipAssetImporter」 | `AppServices` 同时暴露 `importer` 与 `zipImporter`，而素材库页面固定调用 `widget.services.importer`，`ZipImportRequest` 被送进只认文件的 `DefaultAssetImporter` | 新增 `AssetImportRouter` 作为**唯一入口**，按请求类型分派；`AppServices` 不再暴露两个导入器；Android SAF 只有 bytes 时先落地到应用私有临时文件并在导入后清理；失败原因改为用户可读（§3.2.1） |
| B | 角色 `maya` 导入成功后，点「设为当前桌宠角色」无效果 | `LibraryController.activateCharacter()` 只做了 `selectCharacter()` + `refresh()`，而 `refresh()` 只重载**已绑定**的角色，从不切换状态引擎 | `activateCharacter()` 真正调用 `stateEngine.setCharacter()` / 未启动时 `start()`，并持久化 `defaultCharacterId` / `lastCharacterId` / 当前素材；素材库显示「使用中」；成功后切回桌宠页并提示（§3.2.1） |
| C | 素材库在手机上出现 `RIGHT OVERFLOWED BY 88 PIXELS` / `OVERFLOWED BY 134 PIXELS` | 手机仍用桌面布局：固定 260px 左栏 + 右侧网格，剩余宽度放不下 | 用 `LayoutBuilder` 做响应式：≥720px 保留左右分栏，窄屏改纵向流程（作品包下拉 → 角色横向选择 → 「设为当前桌宠角色」→ 素材网格 1～2 列）；导入结果卡片默认只显示摘要、可展开明细；卡片操作按钮改为固定 32×32 紧凑布局（§3.2.1） |

**状态**：A / B / C 三项均为 ⏳ **修复后待真机复验**。
在它们复验通过之前，Phase 4A **不算全部完成**，本文不把这三项写成已完成。

### 4.0.4 第四轮真机反馈（2026-09-29）：两个新问题

上一轮修复后的 APK 再次上真机复验：A（ZIP 导入）与 C（素材库布局）**未再报告问题**；
B（角色激活）**部分通过** —— 激活、持久化、重启恢复都正常，但**桌宠页面没有立即更新**，
必须完全重启应用才显示新角色。同时发现新问题 D。

| # | 真机现象 | 根因 | 修复 |
|---|---|---|---|
| B′ | 点「设为当前桌宠角色」提示成功，返回桌宠页仍是旧角色；重启后才正常 | `PetPresenter` 只订阅 `stateEngine.events`（状态切换事件），而 `DefaultStateEngine` **只在 `previousState != _state` 时才发事件**；"只换角色、不换状态"于是没有任何事件 → 渲染器继续持有旧素材。（桌宠页本身在监听 `stateEngine.snapshots`，但它重建时渲染器里仍是旧图层，因此看不到新角色） | `PetPresenter` 额外订阅 `stateEngine.snapshots`，按 `currentAsset.id` 去重后重渲染；桌宠页显式使用快照参数，不再读 `snapshot.value` |
| D | 「导入多张图片」选了 3 张，结果只导入 1 张 | 两个独立成因叠加：① 页面用 `whereType<String>()` 过滤 `PlatformFile`，把 Android SAF 里 `path == null` 的文件**静默丢弃**；② 一批普通文件名（`a.png`/`b.png`/`c.png`）在指定角色后得到完全相同的 (角色, 情绪, 变体)，而 `assetId` 由这三者确定性生成 → **后导入的覆盖前面的** | 选择与物化统一交给平台 Provider（返回 `SelectedImportFile`：本地路径 + 原始文件名 + 是否临时）；导入器只对**同批内确实冲突**的文件生成稳定变体（原始文件名，同名再挂内容哈希），单张导入 ID 规则不变；选择数/取得内容数/成功数/跳过原因全部展示 |

**状态**：B′ 与 D 均为 ⏳ **修复后待真机复验**，Phase 4A 仍**不算全部完成**。

### 4.0.5 第五轮真机反馈（2026-09-29）：多选导入的数据丢失是 SQLite 级联删除

上一轮修复后真机复验 D（多选图片导入）：**明确填写同一个角色名 `Maya`、
报告显示成功 3 个，素材库最终仍只有 1 个**。这不是界面筛选，也不是角色拆分 ——
是**真实数据库数据丢失**。

**根因（客户端 SQLite 数据层）**：

* 表关系是 `character_packs → character_models → emotion_assets`，后两级都是 `ON DELETE CASCADE`；
* `PackDao.upsert` / `CharacterDao.upsert` 用的是 `ConflictAlgorithm.replace`
  （= `INSERT OR REPLACE`）。SQLite 的 REPLACE **不是 UPDATE，而是先 DELETE 冲突行再 INSERT**；
* `ingestBytes()` 逐文件调用 `ensurePack(sourcePath: p.dirname(originalPath))`：
  三张图片的父目录不同 → 第二张就触发一次"更新作品包" → **REPLACE 删除 pack →
  级联删除角色与第一张素材** → 重新插入 pack → 写第二张…… 最终只剩最后一张。

| # | 修复 | 说明 |
|---|---|---|
| 1 | **父表禁用 REPLACE** | `PackDao.upsert` / `CharacterDao.upsert` 改为显式 `UPDATE`，未命中才 `INSERT`（`abort`），`created_at` 在更新时保持不变。全项目复查：其余使用 REPLACE 的表（`emotion_assets` / `state_mappings` / `local_settings` / `daily_usage` / `sync_state` / `tracking_settings` / `activity_*` / `applications` / `account_session_state`）都**没有**外键子表，不会触发级联删除 |
| 2 | **多文件导入不再逐文件改写 pack 来源** | 来源由**批次**决定：文件选择导入 `PackSourceType.files` + `sourcePath = null`；文件夹导入 `folder` + 真实目录；ZIP `zip` + ZIP 路径。父实体（pack / character）整批只 ensure 一次（`ImportScope` 缓存） |
| 3 | **整批一个事务** | 多文件导入与 ZIP 导入都改为「批次一个事务」，任一失败整批回滚并报"已回滚：数据库未写入任何素材"；文件夹导入因文件数可能上千，保留"一个文件一个事务"（避免长时间持有写锁），但父实体缓存跨文件复用 |
| 4 | **报告区分处理/新增/更新，并以数据库为准** | `ImportReport` 新增 `parsedCount / insertedCount / updatedCount / confirmedCount / consistencyIssues`，界面显示「成功解析 · 新增 · 更新 · 数据库确认 · 失败」；写完后重新查询 `listAllAssets()` 核对，不一致时显示 **「导入一致性校验失败：处理 N 个文件，但数据库仅保存 M 个素材。」** 并弹红色提示，绝不再报"成功 N 个" |

**状态**：D 的修复为 ⏳ **待真机复验**，Phase 4A 仍**不算全部完成**。

### 4.1 安装与启动

> **修复后的复验请务必先卸载/清数据**：设备上可能残留崩溃前建了一半的库
> （`PRAGMA journal_mode` 失败发生在建库之后，文件已存在但日志模式未生效）。
> 不清理也能启动，但"数据库创建"这一步就验证不到了。

```powershell
adb uninstall asia.akechi.petlife     # 或：系统设置 → 应用 → PetLife → 存储 → 清除数据
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

| # | 步骤 | 预期 |
|---|---|---|
| 0 | **先卸载旧版或清除应用数据** | 确保走完整的"首次建库"路径（本次修复点就在这里） |
| 1 | 首次启动 | 不弹任何权限申请；**能完成数据库创建并进入「桌宠」页**（上一版就是死在这一步） |
| 2 | 观察 | 底部五个入口：桌宠 / 使用统计（本机）/ 账户与同步 / 素材库 / 设置 |
| 3 | 桌宠页 | 无素材时显示占位图；有平台说明"这一版还没有启用应用使用时长采集" |
| 4 | 设置 → 诊断（若可见） | `platform_name=android`、`device_architecture=arm64-v8a`（或实机 ABI）、`database_backend` 含 sqflite |
| 5 | 日志（可选） | 出现 `journal_mode = wal（WAL 已启用）`；若显示"未能切到 WAL"，功能仍正常，仅性能退化 |

### 4.2 登录与设备

| # | 步骤 | 预期 |
|---|---|---|
| 5 | 账户与同步 → 填服务端地址 + 邮箱密码 → 登录 | 显示"登录成功…"，不出现"需要重新登录" |
| 6 | 同一账户在 Windows 客户端看设备列表 | **多出一台** Android 设备，platform 显示 android、型号为机型名 |
| 7 | Android「使用统计」页 | 能看到 Windows 客户端已上传的数据 |
| 8 | 点「立即同步」 | 状态变「同步成功」 |
| 9 | 杀掉应用再打开 | 仍是已登录状态（凭据在 Keystore），不需要重新登录 |

### 4.3 素材与桌宠（Phase 4A 范围内）

| # | 步骤 | 预期 |
|---|---|---|
| 10 | 素材库 → 导入 ZIP 素材包 → 选一个 ZIP | 导入成功，列表出现角色 |
| 11 | 观察工具栏 | **没有**"导入文件夹"与"按路径导入"按钮 |
| 12 | 桌宠页 | 显示刚导入的角色；双击进入素材库 |
| 13 | 与 Windows 对比 | 同一角色在两个平台的渲染一致（同一套 `PetRenderer`） |

### 4.4 不该发生的事（反向验证）

| # | 检查 | 预期 |
|---|---|---|
| 14 | 系统设置 → 应用 → PetLife → 权限 | 只有"网络"；**没有**"使用情况访问" |
| 15 | 授权使用情况访问 | 应无法授予（本版未申请），且应用内不出现相关引导 |
| 16 | 长时间使用 | 本机不产生新的使用记录（`activity_segments` 不增长） |

### 4.5 第四轮修复的人工复验步骤（B′ / D）

> 安装新 APK 后（建议先卸载或清除数据，避免残留旧库）：
> `adb uninstall asia.akechi.petlife` → `adb install -r build\app\outputs\flutter-apk\app-debug.apk`

**B′ 桌宠页面运行时刷新（换角色立即生效）**

| # | 步骤 | 预期 |
|---|---|---|
| 1 | 素材库 → 选中角色 A → 「设为当前桌宠角色」 | 提示「已设为当前桌宠角色」，并自动切回「桌宠」页 |
| 2 | 观察桌宠图片与「当前角色」 | **立即**显示角色 A（不需要重开应用、不需要切页） |
| 3 | 回素材库 → 选中角色 B → 「设为当前桌宠角色」 | 再次切回桌宠页 |
| 4 | 观察 | **立即**显示角色 B；「当前角色」同步变为 B |
| 5 | 素材库 → 给角色 B 设置默认素材（星标） | 桌宠立即按新默认素材刷新 |
| 6 | 完全杀掉应用再打开 | 仍是角色 B（持久化 + 重启恢复未被破坏） |

**D 多选图片导入**

| # | 步骤 | 预期 |
|---|---|---|
| 7 | 准备 3 张**普通文件名**的图片（如 `a.png` / `b.png` / `c.png`）并放进手机可通过 SAF 选到的位置 | — |
| 8 | 素材库 → 「导入多张图片」→ 一次选中 3 张 → 填角色名（情绪留空）→ 导入 | 结果卡片显示「选择 3 张，取得内容 3 张 · 成功导入 3 个 · 跳过/失败 0 个」 |
| 9 | 观察素材库 | 该角色下有 **3 条不同素材**（变体为 `a` / `b` / `c`），不是 1 条 |
| 10 | 再导入同一批 3 张 | 仍是 3 条（不产生重复，也不互相覆盖） |
| 11 | 「导入单张图片」选 1 张 | 正常导入，素材 `variant` 仍为 `default` |
| 12 | 选一个系统读不出内容的文件（或断网/权限受限的提供者） | 明确提示「N 张无法读取」并列出文件名与原因，**不静默跳过** |
| 13 | 导入结束后查看应用私有 `tmp/` 目录 | 本次产生的 `picked_*` 临时副本已被清理；用户原始图片仍在原位置 |

### 4.6 第五轮修复的人工复验步骤（SQLite 级联删除导致的数据丢失）

> 安装新 APK 后**务必先卸载或清除应用数据**（旧库里的素材可能已被上一次的级联删除清空，
> 不复验不到"导入后数据还在"这一点）：
> `adb uninstall asia.akechi.petlife` → `adb install -r build\app\outputs\flutter-apk\app-debug.apk`

| # | 步骤 | 预期 |
|---|---|---|
| 1 | 准备 3 张**不同内容**的图片（`a.png` / `b.png` / `c.png`，可放在不同目录以复现"父目录不同"） | — |
| 2 | 素材库 → 「导入多张图片」→ 一次选中 3 张 → **明确填写同一个角色名 `Maya`**（情绪留空）→ 导入 | 结果卡片显示「选择 3 张，取得内容 3 张 · 成功解析 3 个 · 新增 3 个 · 更新 0 个 · 数据库确认 3 个 · 失败 0 个」 |
| 3 | 观察素材库 | 显示 `Maya · 3 个素材`，并能同时看到 **3 张素材卡片**（不是 1 张） |
| 4 | 完全关闭应用（杀进程）再打开 | 仍然是 3 个 |
| 5 | 再导入同样这 3 张 | 仍显示 3 个，报告为「新增 0 个 · 更新 3 个 · 数据库确认 3 个」，不新增重复也不丢数据 |
| 6 | 把 3 张图片放进一个**文件夹**，改用「导入文件夹」 | 同样得到 3 个素材，作品包来源标记为文件夹 |
| 7 | 导入一个 ZIP（内含多角色/多情绪） | 素材齐全；若报告与数据库不一致，必须出现红色「导入一致性校验失败」提示 |
| 8 | 若出现任何「一致性校验失败」提示 | 说明仍存在数据丢失，请把提示原文与 `logs/petlife.log` 一起反馈 —— **不允许把它当成成功** |

### 4.7 已知的"必须一直保持"的不变量

* **父表禁止 `INSERT OR REPLACE`**：`character_packs` / `character_models` 上的
  `upsert` 必须是真正的 UPDATE-else-INSERT；新增带外键子表的表时同样适用
  （回归测试：`test/asset_cascade_import_test.dart`）。
* **导入报告以数据库为准**：任何导入路径都必须给出"新增/更新/数据库确认"，
  并对不上时报「导入一致性校验失败」。

## 5. 已知限制与未完成项

| 项 | 状态 | 归属 |
|---|---|---|
| 应用使用时长采集、授权引导、前台服务与通知 | 未实现 | Phase 4B |
| Android 空闲指标口径（无 `GetLastInputInfo` 等价物） | 未实现（口径已在 docs/27 定稿） | Phase 4B |
| 应用内桌宠的完整交互（缩放 / 拖动 / 素材选择打磨） | 仅基础展示 | Phase 4C |
| 系统悬浮窗桌宠 | 未实现 | Phase 4D |
| Android 文件夹导入（SAF 目录树） | 未实现（需要 Kotlin 原生通道；Phase 4A 已具备写原生代码的能力） | Phase 4B |
| 整壳 Widget 测试（`MobileShell`） | 未做 | 见下方说明 |
| Release APK / 正式签名 | 未产出（release 仍用 debug 签名，**不可上架**） | 需要人工提供密钥库（docs/28 §5） |
| 真机安装与启动链路 | ✅ 已通过（安装 / 启动 / 建库 / 主页 / 登录 / 设备注册 / 同步 / 图片选择） | §4.0.2 |
| 真机素材导入弹窗、设备改名弹窗 | ✅ **真机复验通过**（`_dependents.isEmpty` 已修复） | §4.0.3 / docs/32 |
| 真机 ZIP 导入 | ❌→✅ 已修复（统一导入路由器 + Android 临时副本）→ ⏳ **待真机复验** | §3.2.1 / §4.0.3 |
| 真机「设为当前桌宠角色」（引擎层） | ✅ 激活 / 持久化 / 重启恢复已真机通过 | §4.0.4 |
| 真机桌宠页面运行时刷新（换角色立即生效） | ❌→✅ 已修复（`PetPresenter` 订阅 `stateEngine.snapshots`）→ ⏳ **待真机复验** | §3.2.2 / §4.0.4 |
| 真机 Android 素材库布局 | ❌→✅ 已修复（响应式：宽屏分栏 / 窄屏纵向）→ ⏳ **待真机复验** | §3.2.1 / §4.0.3 |
| 真机 Android 多选图片导入 | ❌→✅ 已修复（**SQLite 父表禁 REPLACE** + 批次事务 + 数据库核对 + 稳定变体消歧）→ ⏳ **待真机复验** | §3.2.2 / §3.2.3 / §4.0.4 / §4.0.5 |
| 父表 `INSERT OR REPLACE` 与 `ON DELETE CASCADE` 的数据丢失风险 | ✅ 已消除（`character_packs` / `character_models` 改为真正的 UPSERT）+ 回归测试 + 反向验证 | §4.7 |
| Android 上 `execute()` 与 PRAGMA 的兼容性 | ✅ 已修复 + 回归测试 | docs/31 |
| 弹窗控制器归属（`_dependents.isEmpty`） | ✅ 已修复 + 回归测试 + 静态审计 | docs/32 |
| 服务端测试全绿 | 未达成（1 项既有用例的时间相关缺陷，§3.5） | 服务端测试的独立修复项 |
| iOS | 不做 | 需求明确 |

**关于 Android Keystore（本轮已按需求实现，此处只留结论）**：
不再依赖 `flutter_secure_storage`（它在 Windows 侧需要 ATL，会让 Windows Release 构建失败），
改为项目内 Kotlin + MethodChannel 自建：AndroidKeyStore 生成不可导出 AES-256 密钥、
`AES/GCM/NoPadding`、每次写入随机 IV、`SharedPreferences` 只存 `v1:IV:密文` 信封。
**Android 侧不再有内存后端**：工厂固定返回 Keystore 后端，
连探测失败也不降级（宁可明确报错，也不制造"重启后仍登录"的假象）。
Windows 侧的三级降级链**原样保留**（有测试断言）。

**关于"整壳 Widget 测试"**：`MobileShell` 会在启动时拉起采集定时器与同步引擎、
并在构建期读数据库。这与 `testWidgets` 的 fake-async 契约直接冲突
（测试结束时必然留下 pending Timer，报错信息还会盖掉真正的断言失败）。
本阶段改为测试可独立覆盖的展示组件（`MobilePlatformNotice`）与能力表，
整壳行为放在 §4 的真机验收里逐条确认。
Phase 4B 引入采集后，会为采集器/引擎提供测试替身，届时再补整壳测试。

## 6. 两处有意的行为变化（Windows 侧）

1. **`PetView` 不再直接调用 `window_manager`**，改为注入 `PetHost`。
   副作用：控制面板里的「实时预览」不再能拖动真实窗口
   （此前会误拖整个桌宠窗口，属于缺陷）。
2. **`DeviceRegistration.modelName`**：Windows 上仍为 null（与 Phase 2 一致），
   Android 上会带机型。

除此之外，Windows 的实现均为「原样搬移到 `lib/platform/windows/`」，逻辑未改，
且 394 项测试全部通过。

> 本轮对话框修复动到了**共享 UI 层**（`asset_library_page` / `account_sync_page` /
> `usage_stats_page`）与新增的 `lib/ui/dialogs/`，Windows 与 Android 共用同一份代码，
> 因此两端都受益；已用 Windows Release 构建 + 全量测试回归确认无影响。

> 本次 PRAGMA 修复动到了**共享层** `lib/database/app_database.dart`，
> 但它只影响"打开数据库时如何设置 WAL"这一处，且已用 Windows Release 构建 +
> 全量测试回归确认无影响（§2.2 / §3.1）。

## 7. 本次实测记录

| 项 | 值 |
|---|---|
| 版本矩阵比对 | 与同一 Flutter SDK 生成的临时项目逐文件 `Compare-Object`：`settings.gradle.kts` / `build.gradle.kts` / `gradle.properties` **IDENTICAL**；`app/build.gradle.kts` 仅差 applicationId/namespace 与注释；`gradle-wrapper.properties` 仅差 distributionUrl 镜像（同版本） |
| `flutter clean` / `pub get` | exit 0 |
| `flutter analyze --no-pub` | `No issues found!`（exit 0） |
| `flutter test --no-pub` | `443 通过 / 1 跳过`（exit 0） |
| `flutter build apk --debug --no-pub` | exit 0（**须先设 `FLUTTER_STORAGE_BASE_URL=file:///C:/petlife_offline_mirror`**，见 §2.4）；`app-debug.apk` 188,980,750 B @ 2026-09-29 17:34:23，SHA-256 `45482097D261A3E856008A478E3B74308CEBF50621436902EAB96EDF1367C6B0`（第五轮真机缺陷修复后重建） |
| 级联删除回归反向验证 | ✅ 把 `PackDao.upsert` 临时改回 `ConflictAlgorithm.replace` 后，`asset_cascade_import_test` 立即失败并报「更新作品包把角色级联删掉了」；改回真正 UPSERT 后全部通过 |
| APK 权限（`aapt2 dump badging`） | `INTERNET` + 自动注入的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`；**无**采集/悬浮窗/无障碍/通知读取/全盘存储 |
| APK 版本与 ABI | minSdk 24 / targetSdk 36 / compileSdk 36；`arm64-v8a` + `armeabi-v7a` + `x86_64` |
| APK 内容核验 | `classes10.dex` 含 `asia.akechi.petlife/credential_store`、`PetLifeCredentialStore`、`AndroidKeyStore`、`AES/GCM/NoPadding`、`setRandomizedEncryptionRequired`；`kernel_blob.bin` 含三个新弹窗组件与 PRAGMA / 校验相关文案 |
| Windows Release 构建 | ✅ exit 0（在 `%TEMP%\petlife_win_regress_20260929_4` 干净目录；冷构建 365.8 s）；`petlife.exe` 92,160 B @ 17:42:23 SHA-256 `EFA2FC21F37A40F0A1AA939FA90C671B9C84F57760547D9E8F6FA4CC93BEC8EA`；`data\app.so` 8,143,752 B @ 17:41:46 SHA-256 `E6198935E42210609AB83F79F6A7E3EE2037FFE2B1D0BEA83114AAC49854C06D` |
| 仓库目录直接构建 Windows Release | ❌ `LNK1104`（被 24 个运行中的 `petlife.exe` 锁住，无法终止）→ 改用干净目录验证，**未**改名被锁产物 |
| Android 构建的联网失败 | ❌→✅ `download.flutter.io` 在本机 HTTPS 被 reset，Gradle 卡在重试；改为 `file://` 本地镜像后 15.0 s 构建成功（§2.4） |
| 构建顺序纪律 | ✅ Android 与 Windows 顺序构建；Windows 每次用**新**临时目录；不再并发争用磁盘与 Gradle 缓存（§2.4） |
| 服务端 `pytest -q` | **188 通过 / 1 失败**（189 项；失败项为既有时间相关缺陷，§3.5） |
| 真机（用户设备） | ✅ 启动链路 7 项通过；✅ 两个弹窗（情绪留空 / 设备改名）真机复验通过；✅ 角色激活的引擎层（切换 / 持久化 / 重启恢复）真机通过；⏳ ZIP 导入、素材库布局、桌宠页面运行时刷新、**Android 多选图片导入（SQLite 级联删除已修复）** 已修复，**待真机复验**（§4.0.2 ~ §4.0.5，复验步骤见 §4.5 / §4.6） |

