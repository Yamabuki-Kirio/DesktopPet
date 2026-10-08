# 35 - Phase 4C：Android 系统级悬浮桌宠

> 范围：**Android 系统级悬浮窗**（`TYPE_APPLICATION_OVERLAY` + 前台服务 + 原生 View）。
> 本文件按阶段推进记录：**4C-1、4C-2、4C-3A、4C-3B、4C-4 均已通过真机验收并封版；
> 4C-5（状态联动）已实现 → 首轮真机复验发现"前台应用识别失败"（缺陷 C）→ 已修复，
> 待真机复验；4C-5.1（Android 本机使用统计）审计完成、待实施**。
> （§6 = 第一轮 0×0 缺陷；§7 = 第二轮可见性失败 + 诊断模式 + 状态机加固 + 第三轮 stop/show 竞态修复；
> §8 = 4C-3A 拖动/边界/吸附/位置持久化/大小调整；§9 = 4C-3B 圆盘菜单框架；
> §10 = 4C-4 动态 WebP 播放；§11 = 4C-5 状态联动；§12 = 4C-5.1 Android 本机使用统计），
> 4C-6 ~ 4C-7 见 §13。
> 与 Phase 4B 的 `34-Phase4B云端统计服务端.md` 相互独立：本阶段**不改服务端**。

## 0. 稳定基线声明

| 基线 | 提交内容 | 真机验收 | 结论 |
|---|---|---|---|
| **4C-2** | Phase 4C-2 全部代码（含 §6/§7 三轮修复） | 2026-09-29 用户确认通过 | **已封版**（后续阶段不得回退其行为） |
| **4C-3A** | 拖动 / 屏幕边界 / 贴边吸附 / 相对位置持久化 / 横竖屏分屏重算 / 大小调整 | 2026-09-29 用户确认通过（§8.9） | **已封版** |
| **4C-3B** | 圆盘菜单框架（双窗口 + 首次挂载竞态修复，§9 / §9.10） | 2026-09-30 用户确认通过 | **已封版** |
| **4C-4** | 动态 WebP 播放（API 分级 + 生命周期门控，§10） | 2026-09-30 用户确认通过 | **已封版，作为 4C-5 的稳定基线** |

4C-4 真机验收结论（用户确认，8 项全部通过）：

1. Android 真机可以播放动态 WebP；
2. 动画可以持续循环；
3. 静态 PNG 和静态 WebP 没有退化；
4. 拖动、吸附和大小调整正常；
5. 开关双窗口圆盘菜单不会导致桌宠抽动；
6. 隐藏、显示、锁屏、解锁和停止服务正常；
7. 静态与动态素材切换正常；
8. 没有发现黑框、重复实例或明显资源泄漏。

**4C-4 基线信号**：APK SHA256 `6889E0FE5B52994E7A4D5103A65855E68F0D2BE9F754497624D6A709C8B0E15F`
（189,132,117 B，2026-09-30 00:40:42；已另存为 `petlife-4C-4-6889E0FE.apk`）。

4C-3B 真机验收结论（用户确认，8 项全部通过）：

1. 冷启动后首次显示桌宠成功；
2. 不需要切换诊断模式才能显示；
3. 不再出现"服务运行但窗口未成功添加"；
4. 菜单改为双窗口后，打开和关闭菜单不再导致桌宠抽动；
5. 菜单关闭后不存在透明触摸拦截；
6. 拖动、吸附、大小调整正常；
7. 隐藏、显示、停止、锁屏和切换应用正常；
8. 始终只有一个桌宠窗口和最多一个菜单窗口。

**4C-3B 基线信号**：APK SHA256 `BD9B9C1E2B38A5B69AE9C6EDDA864D3B0F15DD9D3868476151C763997BE0008F`
（189,129,867 B，2026-09-30 00:16:26；已另存为 `petlife-4C-3B-BD9B9C1E.apk`）。

4C-3A 真机验收结论（用户确认，11 项全部通过）：

1. 桌宠可正常拖动；2. 快速拖动与慢速拖动均正常；3. 屏幕边界限制正常；
4. 左右贴边吸附正常；5. 隐藏 / 停止服务 / 重启应用后位置可恢复；
6. 横竖屏与分屏后坐标恢复正常；7. 50%~200% 大小调整正常；8. 调整大小后素材不变形；
9. 切换素材后位置与大小正常；10. 连续拖动无闪烁、无消失、无重复实例；
11. 原有显示 / 隐藏 / 停止 / 通知栏控制无退化。

**4C-3A 基线信号**：APK SHA256 `D3F37AC7E44C908BC7D40AAA7E413C879287F73155207FE445F5486433989DC1`
（189,128,281 B，2026-09-29 22:46:08）。

4C-2 真机验收结论（用户确认）：

1. 洋红诊断方块可稳定显示；
2. 切换桌面及其他应用后仍然显示；
3. 内置图片与用户导入图片均正常显示；
4. 隐藏、重新显示、停止服务后重新显示均正常；
5. 不再出现黑框一闪或悬浮窗自动消失。

**封版信号**：APK SHA256 `1272A3FB270D457D3BA9226C411DB1451B249511C731CAC27B6FA6E2531C5443`
（189,129,161 B，2026-09-29 22:10:24）。

**后续阶段必须遵守的基线约束**（不得退化）：

* 不得重构已通过验收的素材导入、图片解析与悬浮服务主体；
* 不得重新引入 `show/hide/stop` 竞态；
* 所有 `WindowManager` 操作继续在主线程串行；
* 任何时刻最多一个悬浮桌宠 View；
* 诊断模式保留但默认关闭，仅用于开发排错。

## 1. 审计结论（编码之前的事实）

| 项 | 结论 |
|---|---|
| 1. minSdk / targetSdk | **24 / 36**（`compileSdk = flutter.compileSdkVersion` = 36，`targetSdk = flutter.targetSdkVersion` = 36） |
| 2. 包名与 Flutter 嵌入 | `asia.akechi.petlife`，`MainActivity : FlutterActivity`，`flutterEmbedding = 2` |
| 3. 素材保存目录 | `<ApplicationSupport>/PetLife/assets/<ownerId>/<packSlug>/<characterSlug>/<file>`；Android 上 `ApplicationSupport = /data/user/0/asia.akechi.petlife/files`，**数据库里存的是绝对路径**（`EmotionAsset.filePath`） |
| 4. 静态图片格式 | `png / webp / jpeg(jpg) / gif`；`DefaultAssetValidator` 用 magic bytes 判真实格式，并检查"扩展名与真实格式一致"与资源上限 |
| 5. 动态 WebP 解码方 | **Flutter `dart:ui` 的 `ui.instantiateImageCodec`**（Skia/libwebp），由 `PetFrameController` 逐帧绘制；**原生层没有现成动画解码器**（4C-4 需按 API 版本决定用 `AnimatedImageDrawable`(API 28+) 还是引入本地实现） |
| 6. 素材相关持久化字段 | `character.defaultCharacterId` / `character.defaultAssetId` / `state.lastCharacterId` / `state.lastState` / `state.lastAssetId` / `state.manualAssetId` / `window.scale` |
| 7. 素材变化的通知链路 | `StateEngine.snapshots`（`ValueListenable<StateSnapshot>`）→ `StateSnapshot.currentCharacter` / `resolution.asset` / `manualAssetId`；`PetPresenter` 监听并去重后调 `renderer.display` |
| 8. 是否已有 MethodChannel | **已有**：`asia.akechi.petlife/credential_store`（`MainActivity` 注册 + `android_keystore_credential_store.dart` 封装）。本阶段新增 `asia.akechi.petlife/overlay` |
| 9. APK 是否多 ABI | **是**：单文件通用包，含 `arm64-v8a` + `armeabi-v7a` + `x86_64`（未配置 `abiFilters`/splits，故体积约 180 MB） |
| 10. 厂商后台限制提示 | **尚无**；`lib/ui/mobile/` 只有 `mobile_shell.dart` 与 `mobile_platform_notice.dart`（后者只说明"是否在采集"）。4C-6 新增 |

## 2. 架构（与需求第三节一致）

```
Flutter 设置页（OverlayPetCard）
        │ MethodChannel  asia.akechi.petlife/overlay
        ▼
PetOverlayBridge（权限 / 状态 / 转发）
        │ Intent（只带"做什么"，不带数据）      SharedPreferences
        ▼                                        ▲
PetOverlayService（前台服务 · 通知 · 屏幕开关）─┘
        │
        ▼
PetOverlayManager ── WindowManager.addView / updateViewLayout / removeView
        │
        ▼
PetOverlayView（4C-1 为占位 View；4C-2/4C-4 换成素材 ImageView / 动画 Drawable）
```

**不用悬浮 Activity 模拟桌宠**，也不用"在前台服务里再起一个完整 FlutterEngine"：
首版是原生 View，内存更低、插件不会重复注册、应用 UI 进程重建时更易恢复。

## 3. 4C-1 已完成内容（权限与原生服务骨架）

### 3.1 Manifest

新增权限（**精确 5 条**，由 `test/platform_isolation_test.dart` 锁死）：

```xml
android.permission.INTERNET                      <!-- Phase 2 已有 -->
android.permission.SYSTEM_ALERT_WINDOW           <!-- 显示在其他应用上层，唯一来源 -->
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_SPECIAL_USE
android.permission.POST_NOTIFICATIONS
```

服务声明：

```xml
<service android:name=".overlay.PetOverlayService"
    android:exported="false"
    android:stopWithTask="false"
    android:foregroundServiceType="specialUse">
    <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
        android:value="persistent_user_enabled_desktop_pet_overlay" />
</service>
```

* `specialUse` 的理由：targetSdk 36 要求前台服务声明类型，而"常驻桌宠悬浮窗"不属于
  `mediaProjection` / `location` / `dataSync` 等任何既有类型；
* `stopWithTask="false"`：从最近任务划掉 PetLife **不**停止悬浮桌宠
  （产品规则：由用户在通知栏或设置页显式停止）；
* **没有**申请：`PACKAGE_USAGE_STATS`、无障碍、定位、`RECEIVE_BOOT_COMPLETED`、
  `REQUEST_INSTALL_PACKAGES`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`、`QUERY_ALL_PACKAGES`。

### 3.2 Kotlin 新增文件

`android/app/src/main/kotlin/asia/akechi/petlife/overlay/`

| 文件 | 职责 |
|---|---|
| `OverlayActions.kt` | 指令枚举 + **状态机**（纯函数）+ Intent/PendingIntent 常量 |
| `PetOverlayStore.kt` | SharedPreferences 持久化（位置锚点、缩放、吸附、穿透、锁屏、当前素材） |
| `PetOverlayManager.kt` | `OverlayGeometry`（纯几何计算）+ WindowManager 增删改（单窗口、幂等） |
| `PetOverlayView.kt` | 悬浮 View（4C-1 占位：圆角半透明 + 状态文字） |
| `OverlayNotification.kt` | 通知渠道 `petlife_overlay` + 常驻通知（显示/隐藏、打开 PetLife、停止） |
| `PetOverlayService.kt` | 前台服务：生命周期、单实例、屏幕开关、持久化恢复、`START_STICKY` |
| `PetOverlayBridge.kt` | MethodChannel 处理：13 个方法（含 `openAppDetails`） |
| `MainActivity.kt`（改） | 注册通道 + 转发 `onRequestPermissionsResult`；资源 `res/drawable/ic_petlife_overlay.xml` |

关键实现选择：

* **窗口类型按 API 分支**：`TYPE_APPLICATION_OVERLAY`(26+) / `TYPE_PHONE`(24-25) —— minSdk 24 必须兼容；
* **默认不加 `FLAG_NOT_TOUCHABLE`**（加了就没法拖动）；触摸穿透只有用户显式开启时才加；
* **权限现场复查**：`Settings.canDrawOverlays` 每次调用前都查，绝不把"打开过设置页"当成已授权；
* **停止是唯一会移除服务的指令**；"隐藏"只 `removeView`，服务与通知继续（隐藏 ≠ 停止）；
* **权限被撤销时自动回到"未运行"**，不留下"显示在跑但窗口不存在"的假状态；
* 通知的 `PendingIntent` 全部 `FLAG_IMMUTABLE` + 固定 requestCode（避免重复通知堆出多个入口）。

### 3.3 Dart 新增文件

| 文件 | 职责 |
|---|---|
| `lib/platform/overlay_pet.dart` | 契约 `AndroidOverlayPet` + 模型（`OverlayPetConfig` / `OverlayPetSettings` / `OverlayPermissionState` / `OverlayRuntimeState`）+ `UnsupportedOverlayPet` |
| `lib/platform/android/android_overlay_pet.dart` | MethodChannel 实现（通道 `asia.akechi.petlife/overlay`，错误翻译） |
| `lib/ui/widgets/overlay_pet_card.dart` | 设置页「悬浮桌宠」卡片（权限状态 + 授权 + 显示/隐藏/停止） |
| `lib/platform/platform_services_contract.dart`（改） | 新增 `AndroidOverlayPet get overlayPet` |
| `lib/platform/android/android_platform_services.dart`（改） | 返回 `AndroidOverlayPetBridge`；`supportsFloatingPet: true` |
| `lib/platform/windows/windows_platform_services.dart`（改） | 返回 `UnsupportedOverlayPet`（Windows 不加载任何悬浮窗逻辑） |
| `lib/ui/pages/settings_page.dart`（改） | 按 `supportsFloatingPet` 显示/隐藏整个分区 |

**配置校验（Dart 侧，送到原生之前）**：角色/素材 ID 非空、缩放 0.5~2.0、
MIME 白名单、非负动画参数、`schemaVersion == 1`、禁止 `..`、必须位于应用私有素材根目录下、
文件必须存在。任一不满足就抛 `OverlayConfigException`，**绝不把坏配置送进原生**。

### 3.4 通道协议

| 方法 | 参数 | 返回 |
|---|---|---|
| `isSupported` | — | `bool` |
| `getPermissionStatus` | — | `{supported, overlayGranted, notificationsGranted, notificationsRequired}` |
| `requestOverlayPermission` | — | 同上（**当前**状态，通常仍是 false） |
| `requestNotificationPermission` | — | 同上（等系统回调后返回真实结果） |
| `start` | `OverlayPetConfig?`（null = 用原生已存配置） | `OverlayRuntimeState` |
| `show` / `hide` / `stop` | — | `OverlayRuntimeState` |
| `updatePet` | `OverlayPetConfig` | `OverlayRuntimeState` |
| `updateSettings` | `OverlayPetSettings` | `OverlayRuntimeState` |
| `getState` | — | `OverlayRuntimeState` |
| `openBatterySettings` / `openAppDetails` | — | `null` |

`OverlayRuntimeState` 字段：`supported / serviceRunning / windowAttached / enabled / hidden /
overlayGranted / notificationsGranted / characterId / assetId / mimeType / isAnimated /
frameCount / animationDurationMs / scale / snapEnabled / snapEdge / snapOrientation /
touchThrough / hideOnLockScreen / fixedAssetMode / xRatio / yRatio`，
以及 4C-3A 追加的 `petWidth / petHeight / gestureState`。

> 命名说明（4C-3A 起为与需求词汇一致）：`anchorX/anchorY` → **`xRatio/yRatio`**
> （相对**可用区域**的比例），`snapToEdge` → **`snapEnabled`**，
> 新增 `snapEdge`（left/right/none）与 `snapOrientation`。

### 3.5 权限流程

1. 设置页「悬浮桌宠」→ 点「授权悬浮窗」→ `Settings.ACTION_MANAGE_OVERLAY_PERMISSION`；
2. 系统页里手动允许 → 返回应用 → `didChangeAppLifecycleState(resumed)` 触发**重新检查**；
   卡片上还有「重新检查权限与状态」按钮可手动刷新；
3. 未授权时点「显示悬浮桌宠」→ **不启动服务**，只提示"未获得悬浮窗权限"；
4. Android 13+ 才显示「授权通知」按钮；通知权限被拒绝不影响悬浮桌宠运行，
   但通知栏不会有控制入口（卡片会说明这一点）。

## 4. 4C-2 已完成内容（显示真实静态素材）

### 4.1 Flutter：状态引擎 → 原生（`lib/ui/overlay_pet_controller.dart`）

`OverlayPetController` 监听 `stateEngine.snapshots`，把
`currentCharacter` + `currentAsset` 翻译成 `OverlayPetConfig` 并下发：

| 时机 | 落点 |
|---|---|
| 点击角色「使用」、素材收藏/默认、导入后设为默认、状态引擎切换素材、手动锁定、素材被禁用/删除 | 状态引擎推出新快照 → 监听回调 → `syncNow()` |
| 应用启动后恢复 | `MobileShell` 建立控制器时 `attach()` → `_initialSync()`（先读原生状态，再决定是否下发） |
| 悬浮服务重新启动（START_STICKY） | 原生侧用**已校验并持久化**的配置自行恢复；Flutter 侧下次快照变化照常 `updatePet` |

* **去重**：只有 `characterId / assetId / filePath / mimeType / isAnimated`
  五个字段拼成的签名变化才下发 —— 相同素材不重复通知、更不重复解码；
* **不发非法配置**：素材为空、文件已删除、路径越界等情况在 Dart 侧就拦下，
  只把原因显示给用户（`素材文件不存在（file_missing）`）；
* **服务未运行时不发**：等用户点「显示悬浮桌宠」时随 `start(config)` 一起带过去，
  避免"从后台启动服务"（Android 12+ 限制）；
* **不覆盖用户调过的外观**：下发素材时沿用原生当前回报的 `scale` / `snapEnabled`，
  不会因为同步素材而把大小重置。

### 4.2 原生：校验后再加载

`PetOverlayConfig.kt`（配置 + 校验 + 纯逻辑策略）与 `PetImageLoader.kt`（解码与生命周期）：

| 校验（需求第三节 12 条） | 错误码 |
|---|---|
| `schemaVersion == 1` | `unsupported_schema` |
| `characterId` / `assetId` / `filePath` 非空 | `empty_character_id` / `empty_asset_id` / `empty_file_path` |
| 路径含 `..` 段 | `path_traversal` |
| 规范化后必须位于 `<filesDir>/PetLife/assets` 之内（= 不允许任意外部路径） | `outside_private_root` |
| 文件必须存在 / 必须是普通文件 | `file_missing` / `not_a_regular_file` |
| 文件大小 ≤ 64 MiB | `file_too_large` |
| MIME 在白名单（`image/png`、`image/jpeg`、`image/webp`；**GIF 明确不支持**） | `unsupported_mime` |
| 扩展名与 MIME 必须对应（jpg/jpeg 都接受） | `mime_extension_mismatch` |
| 图片尺寸上限（单边 ≤ 16384、像素 ≤ 64 MP，在"只读边界"阶段检查） | `image_too_large` |
| 无法读取边界 / 解码失败 | `bounds_failed` / `decode_failed` |

**只有校验通过才会写入 SharedPreferences**，因此"服务重建后恢复最后一个**有效**素材"天然成立。

加载（`AndroidBitmapDecoder` + `PetImageLoader`）：

* `inJustDecodeBounds` **只读边界** → 卡维度上限 → `ImageSampling.inSampleSize`
  按 2 的幂采样（策略：**绝不缩到小于目标尺寸**）→ `ARGB_8888` 解码（保留透明通道）；
* 解码在后台线程，回调回主线程；
* **新图成功后才 `recycle` 旧图**（失败时旧图原样保留）；
* `OverlayRequestGuard` 保证"旧请求不得覆盖新素材"；
* 窗口隐藏后再显示时，把**内存里那张图直接贴回新窗口**，不重复解码；
* `dispose()` 释放 Bitmap 并作废在途请求（顺序：先摘窗口、再释放 Bitmap）。

### 4.3 动态 WebP 在 4C-2 的口径

`BitmapFactory` 只解出**第一帧**（不循环、不逐帧读文件、不启动任何 Flutter 解码器），
并且**显式标注**：

* 悬浮窗左下角显示 `动态·第一帧` 角标；
* 日志固定输出：`动态素材当前显示第一帧，完整动画将在 4C-4 实现`；
* `getState` 返回 `animatedFirstFrameOnly` 与 `animatedFirstFrameNotice`，设置页照此显示。

> 这一条刻意做成"看得见的限制"，避免出现"看起来支持动画"的假象（需求第四节明确禁止）。

### 4.4 回退链

```
加载失败 → 保持当前已显示素材（不动 Bitmap）
        → 当前没有素材（或素材已被删除）→ 内置占位内容（"等待素材"/"素材加载失败"/"加载中…"）
```

单张素材失败**不会停止前台服务**，只写日志 + 把 `code: message` 回传 Flutter。

### 4.5 状态反馈（`getState` 新增字段）

`displayedAssetId` / `isPlaceholder` / `lastLoadError` / `lastUpdatedAt` /
`animatedFirstFrameOnly` / `animatedFirstFrameNotice`。

设置页「悬浮桌宠」卡片现在显示：

```
悬浮窗权限：已授权
通知权限：未授权
悬浮桌宠：运行中
当前悬浮素材：Maya / idle / a
素材加载状态：正常
```

失败时显示 `素材加载状态：失败：decode_failed: 图片解码失败`（并保留上一张图）。

## 5. 验证结果

```
flutter analyze --no-pub   → No issues found! (4.5s)
flutter test --no-pub      → 573 passed, 1 skipped, 0 failed（4C-3A：569 → 4C-3B：573）
gradlew testDebugUnitTest  → BUILD SUCCESSFUL；140 tests / 0 failures（4C-3A：98 → 4C-3B：140）
connectedDebugAndroidTest  → 未执行（无设备/无 AVD，见下）
```

| 测试类（Kotlin / JVM） | 项数 | 覆盖 |
|---|---|---|
| `OverlayStateMachineTest` | 11 | start/show/hide/toggle/stop 幂等、update 不改状态、指令解析 |
| `OverlayPositioningTest`（4C-3A） | 15 | 左右/上下边界夹取、桌宠大于可用区域的降级、xRatio/yRatio 往返、除零保护、竖屏→横屏恢复、改大小后坐标修正、左右吸附、可用区域不可信时不限制、非法 scale/ratio 恢复默认、吸附边序列化 |
| `OverlayGestureTest`（4C-3A） | 13 | touchSlop 以内=点击、超过=拖动、slop 边界、拖动后松手不点击、长按不算点击、窗口未附着时不进拖动、ACTION_CANCEL 清理、多指介入取消、HIDDEN/STOPPED 不再接受手势、slop 非法退化 |
| `OverlayGeometryTest`（4C-3A 扩展） | 9 | 缩放区间、长边不超过屏幕短边、按宽高比分配（横长/竖长）、极端宽高比夹取、短边下限等比放大、超出可用区域等比缩小、可用区域不可信时退化 |
| `OverlayMenuGeometryTest`（4C-3B） | 22 | 左右展开方向、吸附边优先、上下修正、四个角、横屏、分屏窄窗口降级、不重叠、触摸下限、非法数量、槽位唯一性、窗口扩展不动桌宠、恢复后相对位置不变 |
| `OverlayMenuStateMachineTest`（4C-3B） | 10 | 单击开关、动画收敛、动画取消收敛、forceClose 立即关闭、幂等关闭、窗口占用判定、实例隔离 |
| `OverlayMenuGestureTest`（4C-3B） | 10 | 单击开关菜单、拖动不开菜单、多指不开菜单、CANCEL 收敛、菜单打开时拖动先关菜单、未附着拒绝更新 |
| `OverlayWindowSpecTest` | 4 | 24-25 用 `TYPE_PHONE`、26+ 用 `TYPE_APPLICATION_OVERLAY`、标志位与触摸穿透 |
| `OverlayVisibilityTest` | 13 | 尺寸永不为 0、加载中仍可见、失败显示占位、成功后才撤占位、路径错误/空 Bitmap 不清旧图、hidden→show 恢复、start 重置 hidden、快速切换最后一次胜出 |
| `OverlayDebugModeTest` | 5 | 诊断模式优先级与文案、48dp 下限、固定 200dp/(80dp,160dp) 几何、小屏夹取（坐标夹取已迁到 `OverlayPositioningTest`） |
| `OverlayPrivateRootsTest` | 3 | 候选根必须"任一命中即通过"、根外仍拒绝、多根仍拒 `..` |
| `PetOverlayConfigValidationTest` | 12 | 12 条校验逐条打靶（含 GIF 拒绝、扩展名/MIME 不匹配、动态素材标记） |
| 其余（`OverlayPathPolicyTest` / `OverlayPathInsideTest` / `OverlayImageLimitsTest` / `ImageSamplingTest` / `OverlayRequestGuardTest`） | 13 | 路径白名单与 `..` 逃逸、尺寸上限、2 的幂采样、请求序号守卫 |

| 测试文件（Dart） | 项数 | 覆盖 |
|---|---|---|
| `test/overlay_pet_test.dart` | 32 | 配置模型/校验、状态解析（窗口诊断、诊断模式、位置/尺寸/手势、**4C-3B 菜单状态**）、非 Android 实现、MethodChannel 协议（含 `snapEnabled`/`xRatio`/`yRatio`）、滑块区间与步长、百分比映射、缺字段安全默认值 |
| `test/overlay_pet_controller_test.dart` | 24 | 配置生成与去重、角色/素材变化、空素材不发、文件删除不发、回退、手动锁定、动画标记、加载状态反馈、窗口诊断、诊断模式开关、非 Android 不写通道、4C-3A 大小滑块（setScale 不重置其它开关 / resetScale / previewScale 不抛错 / setScale 失败上抛） |

| 产物 | 路径 | 大小 | 修改时间 | SHA256 |
|---|---|---|---|---|
| Android Debug APK（**4C-3B 复验版②：双窗口 + 首次挂载修复，请用这个**） | `petlife/build/app/outputs/flutter-apk/app-debug.apk` | 189129867 B（180.37 MB） | 2026-09-30 00:16:26 | `BD9B9C1E2B38A5B69AE9C6EDDA864D3B0F15DD9D3868476151C763997BE0008F` |
| Android Debug APK（4C-3B 复验版①：单窗口原子提交，抽动未根治） | 同上（历史） | 189129867 B | 2026-09-29 23:46:53 | `0980424C453ACB6569BCEF085F6B37CD3ADDEEA9091E3F756A011A60F5E043FC` |
| Android Debug APK（4C-3B 首版，有抽动缺陷） | 同上（历史） | 189129867 B | 2026-09-29 23:18:51 | `58521EB98B86A8DA6F880DA3828BA7D5B543FEB3C6E623035FD39E04EA6A8535` |
| Android Debug APK（4C-3A 封版基线） | 同上（历史） | 189128281 B | 2026-09-29 22:46:08 | `D3F37AC7E44C908BC7D40AAA7E413C879287F73155207FE445F5486433989DC1` |
| Android Debug APK（4C-2 封版基线） | 同上（历史） | 189129161 B | 2026-09-29 22:10:24 | `1272A3FB270D457D3BA9226C411DB1451B249511C731CAC27B6FA6E2531C5443` |
| Android Debug APK（4C-2 第二轮） | 同上（历史） | 189120851 B | 2026-09-29 21:35:45 | `366ADA52566C8716882DFBDF9119A50F51A67436B15DBD8EB789DA5E0ECC878F` |
| Windows Release | `petlife/build/windows/x64/runner/Release/petlife.exe` | 92160 B | 2026-09-29 21:13:31（`data/app.so` 21:37:51） | — |

额外核对（不是"看着像成功"）：

* 合并后的 Manifest 确实含 4 条新权限与 `specialUse` 服务声明；
* APK 的 `classes*.dex` 命中本轮新增原生代码：`setDebugOverlay`、`PetLifeOverlay`、
  `addView settled(post)`、`debugTopLeftPx`、`丢弃过期命令`、`minWindowPx`；
* APK 的 `assets/flutter_assets/kernel_blob.bin`（UTF-8）命中本轮新增 UI 文案：
  `诊断模式（洋红方块）`、`已附着窗口`、`最近窗口操作`、`不读取任何素材与历史位置`；
* 第三轮新增的 `classes12.dex`（UTF-8）命中本轮新代码：
  `已被新实例接管`、`检测到旧服务实例尚未销毁`、`stopSelfResult 被忽略`、
  `stopSelfResult 生效`、`sendGuarded`、`不取消通知`；
* **4C-3A 的 dex 证据**：命中日志事件与持久化键
  `gesture.drag.start` / `gesture.drag.end` / `gesture.click` /
  `position.persist` / `position.clamp` / `snap.start` / `snap.end` /
  `size.update` / `config.changed` / `overlay.x_ratio` / `overlay.snap_edge` /
  `落到确定状态`；
* **4C-3A 的 UI 证据**：`kernel_blob.bin` 命中 `大小`、`恢复默认`（按钮文案）、
  `吸附边`、`手势状态`、`相对位置`、`50% ~ 200%`；
* **Windows 的 `data/app.so` 查不到这些字符串属于预期**：AOT 在 Windows 目标上会把
  `Platform.isAndroid` 分支（`MobileShell` → `SettingsPage(overlay:)` → `OverlayPetCard`
  → `AndroidOverlayPetBridge.fromMap`）整棵剪掉。功能等价性由 Dart 测试保证
  （`Windows 平台不暴露悬浮窗能力，也不会加载 Android 实现`）。
  清掉 `.dart_tool/flutter_build` 后重建，`app.so` mtime 已正常推进（21:37:51）。

### 未自动验证（**不宣称通过**）

* **真实解码**：PNG / JPG / 静态 WebP 的实际像素、透明通道、采样后的尺寸 —— 
  JVM 单测**没有 Bitmap 可用**，不做假；
* **Bitmap 生命周期**：新图成功后释放旧图、失败保留旧图、`dispose` 释放 —— 同样依赖真机 Bitmap；
* **仪器测试**：`gradlew connectedDebugAndroidTest` **未执行** —— 
  本机 `adb devices` 无设备、`emulator -list-avds` 无可用 AVD。按需求"没有设备时明确报告阻塞，不能写成通过"，
  这里如实标注为阻塞，并给出下面的真机验收步骤；
* 悬浮窗在真实设备上的观感（透明背景、角标位置、快速切换的最终结果）。

### 4C-2 真机验收步骤（人工执行）

生成新 APK 后依次验收：

1. 选一张 **PNG** 素材 → 悬浮窗立即显示该图（背景透明，不应有灰色方块）；
2. 选一张 **JPG** 素材 → 立即更新；
3. 选一张**静态 WebP** → 立即更新；
4. 透明背景正常（能看到桌面/浏览器内容透出）；
5. 在 3 张素材之间**快速切换** → 最终显示**最后选中**的那一张（不得停在中间那张）；
6. 返回桌面、打开浏览器、打开 Telegram → 仍显示正确素材；
7. 停止悬浮桌宠 → 再次「显示悬浮桌宠」→ 恢复**最后那张**素材；
8. **删除当前素材** → 不崩溃；悬浮窗或回退到角色默认素材、或显示占位内容，设置页给出原因；
9. **动态 WebP** → 只显示第一帧，且左下角有「动态·第一帧」角标、设置页写明"完整动画将在 4C-4 实现"；
10. 权限、通知、单实例功能继续正常（4C-1 的验收项不得退化）。

## 6. 4C-2 真机缺陷修复：悬浮窗完全不可见

### 6.1 现象与根因

真机验收现象：服务能启动、通知栏正常，**但选了 PNG 之后悬浮窗完全不可见**；
4C-1 的占位方块此前是能看到的。

根因（一句话）：**`PetOverlayView.onMeasure` 只调 `setMeasuredDimension`，没有调用 `super.onMeasure`**，
于是 `FrameLayout` 从不测量子 View → `ImageView` 的 `measuredWidth/Height` 恒为 0 →
`onLayout` 把它摆成 0×0。4C-1 之所以"看起来正常"，是因为那时可见的是**父 View 的背景方块**
（子 TextView 其实也一直是 0×0，只是没人注意）；4C-2 为了让透明通道正常，在成功贴图后执行了
`background = null`，唯一的可见元素被去掉，窗口就彻底看不见了。

```
onMeasure 不调 super
  → ImageView measured = 0×0
  → 成功贴图后 background = null
  → 服务在跑、通知在，窗口却完全不可见
```

### 6.2 修复内容（对应需求十条）

| # | 要求 | 落点 |
|---|---|---|
| 一.1/5/8 | 根 View 永远有非零尺寸 | `OverlayGeometry.MIN_VIEW_PX=32` + `safeViewSize()`；`setDesiredSize` 写 `minimumWidth/Height` |
| 一.2 | 加载前/失败/占位都不为 0×0 | 尺寸计算不再可能返回 0（密度或屏幕指标为 0 时兜底） |
| 一.3/4 | 不依赖空 ImageView 的 `WRAP_CONTENT` | `WindowManager.LayoutParams(size, size, …)` 显式尺寸 |
| 一.6 | ImageView 铺满 | `MATCH_PARENT × MATCH_PARENT` + `FIT_CENTER`（不拉伸、保持比例） |
| 一.7 | 成功贴图后才撤占位 | `setBitmap(bitmap)` 内：先 `setImageBitmap` → 再 `applyVisual(asset)` 撤底 |
| 一.8 | 失败要恢复可见占位 | `OverlayVisualPolicy` 决策 + `refreshVisual()` 重画占位底 |
| 二 | hidden 持久化 | `start`/`show` 一律把 `hidden=false` 写回（状态机保证），日志显式打印 `hidden=false` |
| 三 | 窗口诊断 | `getState` 新增 `windowVisible / viewWidth / viewHeight / imageViewWidth / imageViewHeight / lastWindowError / visual` |
| 四 | 素材配置核对 | 服务逐条打印 `characterId/assetId/mime/animated/fileExists/fileSize/canonicalPath/allowedRoot/insideRoot/targetSize` |
| 五 | 路径根目录 | 允许根 = `<filesDir>/PetLife/assets`，与 Flutter `AppPaths.assetsRoot` 同源；失败只报错、保留窗口与占位 |
| 六 | 解码校验 | bounds>0、采样≥1、二次解码非空、后台解码主线程设图、旧请求不覆盖、成功后才放旧图、设置后 `requestLayout()+invalidate()` |
| 七 | 永远可见的错误占位 | 非 asset 状态一律画**半透明填充 + 不透明描边**的占位底，文案 `等待素材/加载中…/素材加载失败` |
| 八 | 统一日志标签 | `OverlayLog`，标签固定 **`PetLifeOverlay`**，覆盖 onCreate/onStartCommand/权限/show-hide/addView 结果/布局尺寸/配置/路径/bounds/decode/setBitmap |

新增/修改的原生文件：`PetOverlayView.kt`（`OverlayVisual` + `OverlayVisualPolicy` + 正确 `onMeasure`）、
`PetOverlayManager.kt`（`safeViewSize`、诊断字段、`postAfterLayout`、`updateViewLayout` 后 requestLayout）、
`PetOverlayService.kt`（可见状态驱动、诊断发布、日志）、`PetOverlayBridge.kt`（诊断字段）、
`OverlayActions.kt`（`OverlayLog`）。

Dart 侧：`OverlayRuntimeState` 增加 `windowVisible/viewWidth/viewHeight/imageViewWidth/imageViewHeight/lastWindowError/visual`
与 `windowMissing / hasZeroSizedWindow / windowSummary`；设置页新增
`窗口：已挂载/未挂载`、`显示：可见/不可见`、`尺寸：W × H（素材 W × H）`，
窗口缺失时直接显示 **"悬浮服务正在运行，但窗口未成功添加"**。

### 6.3 真机复验命令

```powershell
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
# 然后：启动悬浮桌宠 → 选择 PNG → 等待 5 秒 → 保存日志
```

日志里应能看到成对的证据链：
`service.onCreate → addView ok type=288x288 → layout settled view=288x288 image=0x0
→ receive config … fileExists=true insideRoot=true → decode ok bitmap=… → setBitmap ok view=288x288 image=288x288`。

### 4C-2 真机复验步骤（人工执行，修复后）

新 APK 先按这个顺序验收：

1. **未选择素材**时出现**可见占位图**（半透明底 + 蓝色描边 + "等待素材"）；
2. 选择 **PNG** → 占位图被角色图片替换；
3. **图片加载失败**时显示错误占位（"素材加载失败"），而不是完全消失；
4. 设置页显示 **窗口：已挂载 288×288**、**显示：可见**、**素材加载状态：正常**（尺寸非 0）；
5. 点击 **隐藏** → 悬浮窗消失、通知仍在；
6. 点击 **显示** → 悬浮窗恢复；
7. 点击 **停止服务** → 窗口与通知都消失；
8. **重复启动**（连点显示 / 杀掉应用再显示）仍只有一个窗口；
9. 3 张素材快速切换 → 最终显示最后选择的那一张；
10. 权限、通知、单实例功能继续正常（4C-1 的验收项不得退化）。

若第 1/2 步仍不可见，请抓日志：
`adb logcat -c` → `adb logcat -s PetLifeOverlay:* AndroidRuntime:E` → 启动悬浮桌宠 → 选 PNG → 等 5 秒。

## 7. 第二轮真机失败：诊断能力与状态机加固

### 7.1 真机现象

1. 悬浮窗权限已授予；2. 通知栏正常；3. 点「显示桌宠」**无任何可见变化**；
4. 「停止服务」后再「显示桌宠」，**偶尔闪现一个黑色矩形**然后消失。

第 4 点说明 `addView` 至少偶尔成功 —— 问题在"创建之后立刻被摘掉 / 尺寸为 0 /
或根本没走到创建"。因此本轮**不再猜**，而是把系统改造成"可判定"，并同时消除所有已知可能因。

### 7.2 排查与修复（对应需求的五步）

| 需求 | 落地 |
|---|---|
| 第一步 完整生命周期日志 | 统一标签 **`PetLifeOverlay`**；每条命令分配递增 `commandId`，并记录 `instanceId`（区分"同一实例"与"服务被重建"）、`startId`、线程名、`intentNull`、`guarded`、`issuedAt`；`onCreate / onStartCommand / onDestroy / onTaskRemoved`；`showOverlay/hideOverlay/stopOverlay` 的入口与出口；每次 `addView / updateViewLayout / removeView` 都带**调用方与原因**；`addView` 后用 `view.post {}` 再记一次真实尺寸/附着状态/可见性；`PetOverlayView.dump()` 输出 `size/measured/min/desired/visibility/alpha/scale/attached/shader/image/hasImage/debug`；`PetOverlayManager.dump()` 输出 `LP(width,height,x,y,type,flags,format,gravity,alpha) + screen + density + thread + mainThread`；所有异常打完整堆栈 |
| 第二步 不依赖素材的诊断窗口 | 新增 `debugOverlayMode`：固定 200dp、位置固定 (80dp,160dp)、**不透明洋红** + 白字 `PetLife Overlay`、不读数据库/Flutter 状态/图片、不做动画、不恢复历史坐标、不自动移除、`FLAG_NOT_FOCUSABLE`、`PixelFormat.TRANSLUCENT`。设置页新增开关（**无需重新打包即可在真机上切换**） |
| 第三步 show/hide/stop 状态机 | 所有 `WindowManager` 操作都在**主线程**串行（并记录线程断言）；`attach` 幂等（已挂载只更新，不重复 `addView`）；`hide` 只摘窗口、不停服务；`stop` 摘窗口→清引用→`stopForeground`→`stopSelf`→状态 `STOPPED`；**STOP 之后重新 show 必定新建 View**（`manager.view` 已置空，不复用 detached View）；桥发起的命令带 `issuedAt`，比已应用命令更旧的**受守卫**命令直接丢弃（通知动作不参与守卫，避免"点了停止停不掉"）；`onDestroy` 记录原因；**复查结果：Dart 侧不存在任何在 `onPause/onStop` 里自动 hide 的代码**（全库仅 `windows_window_controller.dart` 有 `.hide()`，与悬浮窗无关） |
| 第四步 尺寸/位置/透明 | 尺寸下限 `max(48dp, 32px)`；坐标强制 `clampTopLeft` 进屏幕；根 View 与 ImageView 都是 `MATCH_PARENT` + `FIT_CENTER`；每次刷新显式归位 `visibility=VISIBLE / alpha=1f / scaleX=scaleY=1f`；`LP.alpha=1f`、`format=TRANSLUCENT`；asset 状态才撤占位底；非 asset 状态**一定有可见底**；诊断/失败/占位一律不允许"全透明窗口" |
| 第五步 逐层恢复 | 已按 A→H 的顺序准备好：A 洋红诊断框（本轮可验）→ B/C 静态素材 → D/E 尺寸与位置 → F 透明背景 → G 隐藏/显示/停止/重启 → H 拖动缩放 |

**同时修掉的重大嫌疑（可解释"完全没有可见变化"）**：

1. **START 不再因配置不合格而静默不启动**。旧逻辑"校验失败就不启动"会让用户看到
   "什么都没发生"。现在：配置不合格**照样显示**（沿用上一次有效素材，或显示可见的错误占位），
   只把原因记进日志与设置页。
2. **私有根目录改成一组候选**：`<filesDir>/PetLife/assets` **或** `<dataDir>/PetLife/assets`。
   `path_provider` 的 `getApplicationSupportDirectory()` 在不同版本/厂商上映射不一致，
   旧的单根判定会把**所有素材**判为越界 → 窗口永远没有内容。两者都是应用私有目录，
   因此安全边界（"只加载应用私有目录"）没有被放宽，并记录命中的根。

### 7.3 真机复验与抓日志

```powershell
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
# 打开设置 → 悬浮桌宠 → 打开「诊断模式（洋红方块）」→ 点「显示悬浮桌宠」→ 等 30 秒 → 保存日志
```

* **洋红方块稳定 30 秒** → 窗口/命令/时序链路是好的，问题在素材解析或绘制 → 关掉诊断模式走 B~F；
* **洋红方块仍不可见** → 直接看日志里 `addView ok/failed`、`layout settled view=…`、
  `removeView reason=…`、`service.onDestroy reason=…`，即可判定是
  Service 生命周期、命令乱序，还是 LP 尺寸/坐标问题。

### 7.4 验收对照（需求"验收要求"）

| 要求 | 本轮状态 |
|---|---|
| 显示→隐藏→显示 20 次 | **待真机执行**（已加串行状态机 + 幂等 attach + commandId 日志） |
| 显示→停止→显示 20 次不闪黑框 | **待真机执行**（第三轮新增 `stopSelfResult(startId)`，见 §7.5） |
| 显示后停留 5 分钟不消失 | **待真机执行**（`START_STICKY` + 不主动移除；`onDestroy` 会记原因） |
| 切桌面/浏览器/Telegram 仍显示 | **待真机执行**（4C-1 已验证过窗口层级能力） |
| 永远只有一个悬浮 View | 由 `attach` 幂等 + 单窗口字段保证（Kotlin 单测覆盖幂等） |
| PNG 失败显示错误占位 | 已实现（`OverlayVisualPolicy.failure`），Kotlin 单测覆盖 |
| 日志无"show 后无原因的 removeView" | 已实现（每次 `removeView` 都带 reason），**待真机日志确认** |
| analyze / test / unit test 通过 | ✅ 见 §5 |

### 7.5 第三轮：`stop` 绕过状态机导致的 show/stop 乱序

**根因（代码级，可读可验证）**：`PetOverlayBridge` 的 `stop` 用的是裸的
`PetOverlayService.stopNow()` → `context.stopService()`，它**完全绕过** `OverlayStateMachine`：

1. 不会调用 `stopEverything()` → 窗口不是"立刻"摘掉，而是等 `onDestroy`；
2. `destroyReason` 保持 `"unspecified"` → 日志把"用户点了停止"记成
   `system-or-unknown`，**诊断信息是错的**（直接违反验收第 7 条的可判定性）；
3. 这条 `stopService` 与随后的 `startForegroundService` 之间**没有顺序保证**，
   于是出现"新窗口 `addView` 成功后，旧的停止请求才把服务 `onDestroy` 掉"的顺序 ——
   真机上就是**黑框一闪而过**。

**改动**（3 处，全部在原生层，Dart 侧零改动）：

| 文件 | 改动 |
|---|---|
| [PetOverlayBridge.kt](file:///c:/Users/Administrator/WorkBuddy/DesktopPet/petlife/android/app/src/main/kotlin/asia/akechi/petlife/overlay/PetOverlayBridge.kt) | `stop` / `hide` / `updatePet` / `updateSettings` / `setDebugOverlay` 一律改走**受守卫命令通道** `sendGuarded()`；只有服务确实没在跑时才退化为 `stopService()` |
| [PetOverlayService.kt](file:///c:/Users/Administrator/WorkBuddy/DesktopPet/petlife/android/app/src/main/kotlin/asia/akechi/petlife/overlay/PetOverlayService.kt) | ① `applyCommand(command, commandId, startId)` 贯穿 `startId`；② `stopEverything()` 把 `stopSelf()` 换成 **`stopSelfResult(startId)`** —— 只要之后又来了一条新的 `start`，系统就按 `lastStartId` 忽略这次停止，服务存活、窗口不受影响；③ 新增 `activeInstance` 守卫：**旧实例的 `onDestroy` 不得取消新实例的通知、不得清空静态诊断状态、不得覆写 `publishDiagnostics`**；④ 窗口可见命令前置 `ensureForeground()`，覆盖"停止被忽略、服务已退出前台"的中间态 |
| [OverlayActions.kt](file:///c:/Users/Administrator/WorkBuddy/DesktopPet/petlife/android/app/src/main/kotlin/asia/akechi/petlife/overlay/OverlayActions.kt) | 无改动；`EXTRA_GUARDED` 的语义不变（通知动作仍不参与守卫，避免"点了停止停不掉"） |

**为什么这样就不会再闪**：

* STOP 与 SHOW 现在都走 `onStartCommand`，在**主线程严格串行**，不再有
  "AMS 异步销毁"与"新窗口创建"交错；
* 即使两者交错，`stopSelfResult(startId)` 会让旧的停止请求**失效**（服务不销毁），
  于是不存在"show 之后无原因的 `onDestroy`/`removeView`"。

### 7.6 本机构建环境（两条必需的环境变量）

本机 Gradle 默认 `java user.home` 解析为 `C:\`，会去用不存在的 `C:\.gradle` 并卡死；
另外 Flutter 引擎产物仓库 `https://storage.googleapis.com/download.flutter.io`
在本环境 **TLS 握手不通过**（`download.flutter.io` 直连同样失败），
而 `:app:compileDebugKotlin` 必须解析 `io.flutter:armeabi_v7a_debug` 等引擎产物，
因此不设变量时会表现为"挂住但 CPU 不涨、日志无输出"。可用的运行方式：

```powershell
$env:GRADLE_USER_HOME = "$env:USERPROFILE\.gradle"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"   # 只换下载源，不改版本号
.\gradlew.bat --stop
.\gradlew.bat testDebugUnitTest --console=plain --stacktrace --no-daemon
```

`FLUTTER_STORAGE_BASE_URL` 由 Flutter 插件自己读取
（`FlutterPlugin.kt`：`getenv(FLUTTER_STORAGE_BASE_URL) ?: "https://storage.googleapis.com"`），
镜像上的 `armeabi_v7a_debug-1.0.0-af7e796e…jar` 与本地缓存**字节数一致**（114,678,130 B）。
这与 `android/build.gradle.kts` 里既有的"国内镜像优先、只替换下载源"是同一策略。

**本轮验证**：

```
flutter analyze --no-pub   → No issues found! (4.7s)
flutter test --no-pub      → 559 passed, 1 skipped, 0 failed (22s)
gradlew testDebugUnitTest  → BUILD SUCCESSFUL；69 tests / 0 failures / 0 errors
```

## 8. Phase 4C-3A：拖动 / 边界 / 吸附 / 位置持久化 / 大小调整

> 状态：**已通过真机验收并封版（见 §8.9）**。4C-3B 见 §10。

### 8.1 设计说明（为什么这么做）

1. **位置一律"相对比例 + 可用区域"重算**，绝不把绝对像素当恢复依据 ——
   换分辨率、旋转、分屏、改尺寸后都不会跑出屏幕。
2. **可用区域不是屏幕宽高**：状态栏 / 导航栏 / 刘海挖孔都会吃可见区域，
   因此新增 `OverlayBounds` 作为唯一几何基准。
3. **窗口尺寸由素材宽高比决定**（4C-2 之前是正方形）：长边 = `96dp × density × scale`
   夹进 `[48dp, 320dp]`，短边按比例算，短边不足时**等比放大长边**（不变形）。
4. **拖动只 `updateViewLayout`**，不写盘、不 removeView/addView、不新建 View；
   只有松手（或贴边动画结束）才持久化一次。
5. **改大小不重建服务**：走 `updateViewLayout`；已贴边的桌宠按**边对齐**重算坐标，
   所以"贴右边缘 → 调大"不会向屏幕外扩张。
6. **竞态防护沿用 4C-2 的成果**：命令仍走受守卫通道、`stopSelfResult(startId)`、
   `activeInstance` 守卫、主线程串行。

### 8.2 修改文件列表

| 文件 | 类型 | 说明 |
|---|---|---|
| `.../overlay/OverlayGeometry.kt` | **新增** | `OverlayBounds` / `OverlaySize` / `OverlaySnapEdge` / `OverlayGeometry`（由 `PetOverlayManager.kt` 迁入并扩展）/ `OverlayPetSize` / `OverlayPositionCalculator` |
| `.../overlay/OverlayGesture.kt` | **新增** | `OverlayGestureState` / `OverlayGestureEffect` / `OverlayGestureMachine` |
| `.../overlay/PetOverlayManager.kt` | 重写 | 边界解析、拖动/贴边动画、宽高比尺寸、配置变化重算、`OverlayWindowHost` 回调 |
| `.../overlay/PetOverlayView.kt` | 修改 | `touchHandler` 转发触摸、`imageAspectRatio`、`setDesiredSize(OverlaySize)`、`onMeasure` 支持非正方形 |
| `.../overlay/PetOverlayStore.kt` | 修改 | `xRatio/yRatio/snapEnabled/snapEdge/snapOrientation` + `safeScale/safeRatio`；键名 `overlay.x_ratio` 等 |
| `.../overlay/PetOverlayService.kt` | 修改 | 实现 `OverlayWindowHost`、`ComponentCallbacks` 监听横竖屏/分屏、`onLoaded` 按宽高比重算、诊断字段 |
| `.../overlay/PetOverlayBridge.kt` | 修改 | 新字段读写（`snapEnabled`/`xRatio`/`yRatio`/`snapEdge`）、`runtimeState` 追加 `petWidth/petHeight/gestureState` |
| `lib/platform/overlay_pet.dart` | 修改 | 字段重命名 + `scaleStep` + `scalePercent`/`scaleSliderValue`/`snapEdgeLabelZh` |
| `lib/platform/android/android_overlay_pet.dart` | 不变 | 纯 map 透传，无需改动 |
| `lib/ui/overlay_pet_controller.dart` | 修改 | `setScale` / `resetScale` / `previewScale` |
| `lib/ui/widgets/overlay_pet_card.dart` | 修改 | 大小滑块（50%~200%，步长 10%，百分比，默认）+ 吸附边/手势/相对位置诊断行 |
| `OverlayPositioningTest.kt` / `OverlayGestureTest.kt` | **新增测试** | 见 §8.5 |
| `OverlayLogicTest.kt` / `OverlayVisibilityTest.kt` | 修改测试 | 适配新几何 API |

**未改动**（遵守基线约束）：素材导入、图片解析/解码、路径校验、`OverlayStateMachine`、
`PetImageLoader`、通知、服务端。

### 8.3 数据结构与状态机

**持久化（`SharedPreferences`，沿用现有 `PetOverlayStore`，不新增第二套存储）**

| 键 | 含义 | 默认 | 校验 |
|---|---|---|---|
| `overlay.scale` | 大小比例 | 1.0 | `safeScale`：NaN/Inf → 1.0，越界 → 夹到 `[0.5, 2.0]` |
| `overlay.x_ratio` | 横向相对位置 | 0.85 | `safeRatio`：NaN/Inf → 默认，越界 → 夹到 `[0,1]` |
| `overlay.y_ratio` | 纵向相对位置 | 0.30 | 同上 |
| `overlay.snap_edge` | 吸附边 | `none` | `left/right/none`，未知值 → `none` |
| `overlay.snap_enabled` | 自动贴边开关 | `true` | 布尔 |
| `overlay.snap_orientation` | 保存位置时的方向 | `unknown` | 仅诊断用；坐标永远按当前区域重算 |

`xRatio`/`yRatio` 的分母是 **`max(1, 可用区域 - 桌宠尺寸)`**（需求 2.4 的公式），
因此 `1.0` 正好贴住右/下边缘。

**几何工具（全部纯函数，可 JVM 单测）**

* `OverlayBounds(left, top, right, bottom)` + `isUsable`（不可信时**不做任何限制**，
  绝不把窗口夹到 0 号角落）；
* `OverlayPetSize.resolve(scale, density, aspectRatio, bounds)` → `OverlaySize`
  （长边 → 按宽高比分配 → 短边下限等比放大 → 长边上限 → 夹进可用区域 → 保证 > 0）；
* `OverlayPositionCalculator`：`clampTopLeft` / `topLeftFromRatio` / `ratioFromTopLeft` /
  `snapEdgeFor`（按中心点分左右）/ `snapTargetX` / `centerX`。

**手势状态机**

```
IDLE --DOWN--> PRESSING --移动>touchSlop--> DRAGGING --UP--> IDLE
                   |                                        ↑
                   +--UP(未超 slop 且 <=300ms)--> 单击 ------+
                   +--UP(超时/超 slop)---------> 取消 ------+
                   +--CANCEL-------------------> 取消 ------+
                   +--多指介入-----------------> SCALING（4C-3A 第一版不缩放，只取消手势）
HIDDEN / STOPPED：由服务生命周期驱动（hide → HIDDEN，stop → STOPPED），
                  进入后不再接受任何手势；每个**新窗口**都新建一台干净的机器（IDLE）。
MENU_OPEN：4C-3B 的圆盘菜单使用，本期不进入。
```

窗口不可更新（`isAttachedToWindow == false`）时，状态机**拒绝进入 DRAGGING**，
因此不可能对已摘掉的 View 调 `updateViewLayout`（`dragTo` 里还有第二层断言）。

### 8.4 手势冲突处理

| 场景 | 行为 |
|---|---|
| 单击（位移 ≤ touchSlop 且按下 ≤ 300ms） | 4C-3A 只记 `gesture.click` + 设置页可见；4C-3B 用于开关圆盘菜单 |
| 拖动（位移 > touchSlop） | 跟手移动窗口；松手才持久化 |
| 拖动后松手 | 只产生 `dragEnd`，**绝不**产生 `click` |
| 长按（未移动但超时） | 判定为取消（本期不定义长按功能） |
| 第二根手指 | 立即取消拖动/按下 → `SCALING`，不拖动、不点击（本期不实现双指缩放） |
| 动画进行中再次按下 | 贴边动画**立刻落到确定状态**（目标位）并持久化，然后开始新手势 |
| 拖动中窗口被隐藏/停止 | `ACTION_CANCEL` + `suspend(HIDDEN/STOPPED)`，动画取消，不再更新窗口 |
| 触摸穿透开启时 | 窗口带 `FLAG_NOT_TOUCHABLE`，收不到事件，因此**无法拖动**（需从设置页关闭穿透） |
| 拖动频率 | MOVE 逐帧日志**只在诊断模式**输出，正常模式不打印（避免性能下降） |

### 8.5 单元测试

```
gradlew testDebugUnitTest  → BUILD SUCCESSFUL
  OverlayPositioningTest        15（左右/上下边界、大于可用区域降级、ratio 往返、
                                    除零保护、竖屏→横屏、改大小后修正、左右吸附、
                                    不可信区域、非法 scale/ratio、吸附边序列化）
  OverlayGestureTest            13（slop 以内=点击、超过=拖动、slop 边界、拖动后不点击、
                                    长按不算点击、未附着不拖动、CANCEL 清理、多指取消、
                                    HIDDEN/STOPPED 拒收、slop 非法退化）
  OverlayGeometryTest            9（缩放区间、长边上限、宽高比分配、极端比例夹取、
                                    短边下限、超区域缩小、不可信区域）
  —— 合计 98 tests / 0 failures（4C-2 基线为 69）
flutter test --no-pub      → 569 passed, 1 skipped, 0 failed（基线 559）
  overlay_pet_test.dart              滑块区间/步长/百分比映射/位置尺寸手势字段解析/缺字段默认值/通道字段名
  overlay_pet_controller_test.dart   setScale 不重置其它开关 / resetScale / previewScale 不抛错 / setScale 失败上抛
flutter analyze --no-pub   → No issues found!
```

### 8.6 产物

| 项 | 值 |
|---|---|
| 路径 | `petlife/build/app/outputs/flutter-apk/app-debug.apk` |
| 大小 | 189,128,281 B（180.37 MB） |
| 修改时间 | 2026-09-29 22:46:08 |
| SHA256 | `D3F37AC7E44C908BC7D40AAA7E413C879287F73155207FE445F5486433989DC1` |

### 8.7 真机验收步骤（人工执行，对应需求"六、4C-3A 真机验收"）

```powershell
adb install -r petlife\build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

1. 显示悬浮桌宠；
2. 向任意方向拖动，确认**跟手**（无明显延迟、不跳动）；
3. 快速拖动与缓慢拖动均正常；
4. 拖到四个角，确认**不会完全移出**屏幕（状态栏/导航栏也压不住）；
5. 松手后确认正确**吸附左侧或右侧**（`snap.start` / `snap.end` 成对出现）；
6. 隐藏再显示 → 位置保持；
7. 停止服务后重新显示 → 位置保持；
8. 完全关闭并重新打开 PetLife → 位置保持；
9. 横竖屏切换 → 桌宠仍在可见区域（日志有 `config.changed` + `position.clamp`）；
10. 打开分屏 → 不会跑出窗口范围；
11. 大小调到 50% / 100% / 200% → 立即生效（日志有 `size.update`）；
12. 调整大小后素材**没有拉伸变形**（窗口按宽高比变化）；
13. 调整大小后位置仍合理（贴右边缘调大后仍在右侧，不越界）；
14. 连续拖动 50 次 → 不闪烁、不消失、不产生第二个桌宠；
15. 切换素材后，位置与大小仍然正确；
16. 隐藏 / 显示 / 停止 / 通知栏控制没有退化（4C-1、4C-2 验收项不得回退）。

日志排查要点：`gesture.down → gesture.drag.start → (MOVE, 仅诊断模式) → gesture.drag.end
→ snap.start → snap.end → position.persist`；任何 `removeView reason=…` 都必须有原因。

### 8.8 已知限制

* **双指缩放未实现**（需求允许延后）：第一版只做滑块；双指介入会被识别为
  `SCALING` 并取消手势，不会误拖动/误开菜单。
* **自动贴边开关没有 UI**：`overlay.snap_enabled` 已持久化（默认 `true`），
  但设置页开关留到 4C-6。
* **API 24~29 的可用区域是估算**：这些版本没有 `WindowMetrics.windowInsets`，
  退化为"屏幕尺寸 − 系统栏资源高度"，挖孔可能少算（30+ 用真实 insets，精确）。
* **触摸穿透与拖动互斥**：开启穿透后窗口收不到触摸（按定义如此）。
* **仪器测试未执行**：本机无 adb 设备、无可用 AVD，`connectedDebugAndroidTest` 仍为阻塞状态。

### 8.9 真机验收结果（2026-09-29）

用户确认 §8.7 的 11 项关键行为全部通过（拖动跟手、快慢拖动、边界限制、左右吸附、
隐藏/停止/重启后位置恢复、横竖屏与分屏坐标恢复、50%~200% 大小调整、素材不变形、
切换素材后位置与大小正确、连续拖动无闪烁/消失/重复实例、原有控制无退化）。

**4C-3A 基线 APK**：

| 项 | 值 |
|---|---|
| 路径 | `petlife/build/app/outputs/flutter-apk/app-debug.apk` |
| 大小 | 189,128,281 B（180.37 MB） |
| 修改时间 | 2026-09-29 22:46:08 |
| SHA256 | `D3F37AC7E44C908BC7D40AAA7E413C879287F73155207FE445F5486433989DC1` |

## 9. Phase 4C-3B：圆盘菜单框架

> 状态：**代码完成，单测与构建通过，等真机验收**。
> 本阶段**只做框架**：6 个占位槽位，点击只提示「功能尚未配置」，不定义任何业务功能。

### 9.1 窗口方案：**双窗口**（首版单窗口，真机复验后改为双窗口）

**首版用的是单窗口**（扩展同一个窗口 + 平移桌宠在窗口内的相对矩形），真机复验暴露出
"关闭菜单时桌宠抽动一下"：即使把几何参数一次性提交，窗口 Surface 位置与子 View 布局
仍是两条通道，真机上会在两者之间绘制一帧。**因此按需求改为双窗口降级方案**（见 §9.10）：

| 窗口 | 内容 | 菜单开关时的变化 |
|---|---|---|
| **桌宠窗口** `PetOverlayView` | 桌宠图片 / 占位 / 角标 | **LayoutParams 一个字段都不改** |
| **菜单窗口** `PetMenuView` | 6 个占位按钮（仅菜单打开期间存在） | 打开 `addView`、关闭 `removeView` |

这样"抽动"在结构上不可能发生：桌宠窗口的位置与尺寸与菜单无关。
代价是菜单窗口的透明区域会落在菜单窗口矩形内，处理方式见 §9.4。

实现方式：`PetOverlayView` 内部保留一层 `petContent`（桌宠内容层，恒铺满自己的窗口）；
按钮由 `PetMenuView` 在菜单窗口内按绝对坐标（边距）摆放 —— 不重写 `onLayout`，
也不改动 4C-2/4C-3A 已验证的桌宠渲染逻辑。

### 9.2 菜单数据模型与几何模型

**数据模型**（与业务解耦，`OverlayMenuCatalog`）：

| 字段 | 含义 |
|---|---|
| `id` | 槽位唯一 ID：`slot_1` … `slot_6` |
| `label` | 占位图标上的编号（本期用数字，**不用参考图任何美术**） |
| `contentDescription` | 无障碍描述："菜单项 N（功能尚未配置）" |
| `enabled` | 启用/禁用（禁用态：alpha 0.4 且不可点击，无障碍可识别） |

数量模型允许 **4~8**，`placeholderSlots(count)` 会把非法数量夹到区间内，
**不写死在 XML 布局**（按钮由几何按数量算出来）。

**几何模型**（全部纯函数，`OverlayMenu.kt`）：

* `OverlayRect`：整数矩形 + `union / contains / overlaps / translate / centered / isInside`；
* `OverlayMenuSpec`：按钮直径 44dp、最小触摸区 48dp、间距 12dp、与桌宠空隙 8dp；
* `OverlayMenuGeometry.compute(bounds, petRect, snapEdge, spec, itemCount)` →
  `OverlayMenuLayout(windowRect, petRectInWindow, items, placement)`。

算法（对应需求 §6/§7）：

| 步骤 | 规则 |
|---|---|
| 主方向 | 吸附左侧→向右；吸附右侧→向左；否则按桌宠中心点分左右 |
| 半径 | `max(不重叠所需半径, 不压住桌宠所需半径) × 1.06`，并夹进 `可用区域短边/2 − 按钮半径` |
| 角度 | 间隔 `150°/(n−1)` 夹到 `[18°, 45°]`（6 个槽位 → 30°/步，扇形 150°） |
| 上下修正 | 整环**整体垂直平移**（桌宠不动、按钮平移），保证不进入状态栏/导航栏 |
| 降级顺序 | 理想半径 → ×0.85 → ×0.7 → 备用方向 → 最小半径紧凑布局（`degraded=true`，按钮夹进可用区域） |
| 边界 | 按钮与窗口都必须完全落在 `OverlayBounds` 内；可用区域不可信时**不做限制**（只显示桌宠） |

**"桌宠不跳动"的数学保证**：`windowRect.origin + petRectInWindow.origin == petRect.origin`
（同尺寸），已由单测直接断言（§9.8 第 31/32 条）。

### 9.3 手势状态机与冲突处理

沿用 4C-3A 的状态机（**没有新增任何松散布尔量**），新增两个明确的转移：

```
IDLE --DOWN--> PRESSING --移动>touchSlop--> DRAGGING --UP--> IDLE
                   |                                        ↑
                   +--UP(有效单击)--> click --> MENU_OPEN --+
MENU_OPEN --再次单击(click)--> 关闭 --> IDLE
MENU_OPEN --移动>touchSlop--> DRAGGING（实现里先关菜单，再开始拖动）
MENU_OPEN --hide/stop/几何变化--> HIDDEN / STOPPED / IDLE
```

菜单自身状态另有一套明确状态（`OverlayMenuStateMachine`，纯函数）：

```
closed --toggle/open--> opening --animationFinished--> open
   ^                        |                            |
   |                        +--close--> closing <--------+
   +--animationFinished <----+                    forceClose：任何状态 → closed（立即）
animationCancelled：opening → open，closing → closed（绝不卡在中间态）
```

冲突规则（逐条对应需求 §3）：

| 场景 | 行为 |
|---|---|
| 单击桌宠 | `click` → **开关**菜单（开着就关、关着就开） |
| 拖动桌宠 | 位移超 slop → `dragStart` → **先关菜单**（立即缩回窗口）→ 再进入 4C-3A 拖动逻辑 |
| 松手 | 只产生 `dragEnd`，**绝不**补触发单击 |
| 多指 | 进 `SCALING` 并取消本轮手势，**不打开菜单**；松手也不补单击 |
| 长按 | 不定义功能，只判定为"取消"，不会弹出第二套菜单 |
| 动画中再次点击 | 状态机反向（opening+click → closing；closing+click → opening），只有一套动画 |
| 点击菜单按钮 | **按钮自己消费触摸**，不会触发桌宠拖动；动作后立即关菜单 |

### 9.4 透明区域的触摸处理（本阶段最高风险）

*菜单关闭时窗口 == 桌宠矩形*，透明区域最小；*菜单打开时窗口扩展到菜单矩形*，
其间的透明区域会落在我们的窗口内 —— 这是单窗口方案唯一的代价，处理方式是：

1. **只在菜单打开期间存在**（`menuState != closed` 才扩展窗口），关闭动画一结束立即缩回；
2. 落在**桌宠之外**的 `ACTION_DOWN` 立即判定为"外部点击" → 关闭菜单并**吞掉整轮手势**
   （用 `outsideTapActive` 标记，直到 `ACTION_UP/CANCEL`），因此不会拖动桌宠、也不会补触发单击；
3. **不使用全屏透明窗口**监听"点击任意位置"（需求明确禁止：那会阻塞其他应用）；
4. `hide / stop / 息屏 / 权限撤销 / 旋转 / 分屏 / 换素材 / 改大小 / detach` 一律**立即**关闭
   （`animate = false`），不等动画，避免透明区域被留下；
5. 关闭动画结束后才缩回窗口 —— 但这条只用于"用户主动点击关闭"这条路径，
   所有清理路径都走立即关闭。

### 9.5 生命周期清理（需求 §15）

| 事件 | 处理 | 日志 |
|---|---|---|
| `hide` | `closeMenu("hide", false)` → `detach(HIDDEN)` | `menu.close reason=hide` |
| `stop` | `closeMenu("stop", false)` → `detach(STOPPED)` → `stopSelfResult` | `menu.close reason=stop` |
| `onDestroy` | `detach("onDestroy")` 内部先 `resetMenuForGeometryChange` | `removeView reason=onDestroy` |
| `onTaskRemoved` | 不停服务、不动菜单 | — |
| 息屏 / 锁屏 | `closeMenu("screen-off", false)` | `menu.close reason=screen-off` |
| 权限被撤销 | 走 `stopEverything("overlay-permission-missing")` | `menu.close reason=stop` |
| 横竖屏 / 分屏 | `applySettings` → `resetMenuForGeometryChange` | `menu.configuration_changed` |
| 换素材 / 改大小 | 同上（`onLoaded`、滑块都走 `applySettings`） | `menu.configuration_changed` |
| View 脱离 / 实例失效 | `canUpdateMenuWindow(disposed, attached)` 一律拒绝窗口更新 | `menu.window.* 被拒绝` |
| 旧实例被替代 | 每实例各自持有 manager + View + 菜单状态，旧实例只动自己的 View | — |

`closeMenu` **幂等**：已经关闭时再关只打一行日志，不报错、不改状态。
`stopSelfResult` / `commandId` 守卫**完全没有被改动**（本阶段没碰命令通道）。

### 9.6 日志（沿用 `PetLifeOverlay`）

新增事件：`menu.request.open` / `menu.request.close` / `menu.request.toggle` /
`menu.open` / `menu.close` / `menu.layout` / `menu.action` / `menu.outside_tap` /
`menu.animation.start` / `menu.animation.end` / `menu.animation.cancel` /
`menu.window.expand` / `menu.window.restore` / `menu.configuration_changed`。

每行至少含：`instance` / `commandId`（命令路径）/ `gesture` / `menu` / 桌宠矩形 /
可用区域 / 菜单窗口矩形 / 展开方向 / 按钮数量 / 半径 / 关闭原因 / Window 是否附着。
**逐帧动画坐标只在诊断模式（洋红方块开关打开）时输出**。

### 9.7 自动验证结果

```
gradlew testDebugUnitTest  → BUILD SUCCESSFUL；156 tests / 0 failures（4C-3A 基线 98）
  OverlayMenuGeometryTest       22（方向/四角/横屏/分屏窄窗口/不重叠/触摸下限/
                                    降级/非法数量/槽位唯一性/放不下才换另一侧）
  OverlayMenuStateMachineTest   10（开关菜单/动画收敛/幂等关闭/forceClose/窗口占用判定）
  OverlayMenuGestureTest        10（单击开关、拖动不开菜单、多指、CANCEL、
                                    菜单打开时拖动先关菜单、未附着拒绝更新）
  OverlayMenuWindowTest         16（双窗口：开/关前后桌宠窗口矩形完全相同、左右/四角/
                                    各尺寸/横屏/分屏、四条关闭路径、反复开关 20 次、
                                    菜单窗口不压抓取区、不越界、按钮不重叠、
                                    无按钮不建窗口、每种窗口最多一个）—— 见 §9.10
flutter analyze --no-pub   → No issues found!（4.7s）
flutter test --no-pub      → 573 passed, 1 skipped, 0 failed（4C-3A 基线 569）
connectedDebugAndroidTest  → **因无设备阻塞**（本机无 adb 设备、无可用 AVD）
```

需求 §17 列出的 34 条里，31 条以纯逻辑单测覆盖；第 30/33 条以
`canUpdateMenuWindow` 与"实例隔离（两套状态机互不影响）"覆盖；
与真实 WindowManager 绑定部分（窗口是否真的缩回、下方应用是否真的恢复点击）
属于真机验收项，**不在这里宣称通过**。

### 9.8 产物

| 项 | 值 |
|---|---|
| 路径 | `petlife/build/app/outputs/flutter-apk/app-debug.apk` |
| 大小 | 189,129,867 B（180.37 MB） |
| 修改时间 | 2026-09-30 00:16:26 |
| SHA256 | `BD9B9C1E2B38A5B69AE9C6EDDA864D3B0F15DD9D3868476151C763997BE0008F` |

> 这是**含 §9.10 两项修复（问题 A 首次挂载竞态 + 问题 B 菜单改双窗口）**的版本，
> 4C-3B 真机复验请用这个。

进包核对（不是"看着像成功"）：

* `classes*.dex` 命中双窗口与诊断证据串：`menu.window.open`、
  `removeView reason=menu-window`、`menu.geometry.settled`、`menu-geometry-jitter`、
  `menu.configuration_changed`、`menu.outside_tap`、`本次几何提交被跳过`、
  `OverlayWindowSet`、`OverlayMenuWindows`、`placeCompactGrid`、`petGrabRect`、
  `功能尚未配置`；
* `assets/flutter_assets/kernel_blob.bin` 命中界面文案：`圆盘菜单`、`最近菜单操作`、
  `展开中`、`已展开`、`收起中`、`单击桌宠可展开`。

### 9.9 真机验收清单（需求 §21，共 30 步）

```powershell
adb install -r petlife\build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

> **0. 先做抽动复验**（§9.10）：桌宠分别放左/右/上/下/四个角，每处开-关菜单 20 次，
> 再用 50%/100%/200% 各重复；确认桌宠**完全静止**，并核对日志
> `menu.geometry.commit ... absoluteDelta=(0,0)`、`menu.geometry.settled ... delta=(0,0)`，
> 且**没有** `menu.geometry.reject` / `menu-geometry-jitter`。

1. 显示悬浮桌宠；2. 单击 → 菜单展开；3. 再次单击 → 菜单关闭；
4. 快速单击 20 次 → 不产生多套菜单；5. 轻微移动未超 touchSlop → 仍判为单击；
6. 拖动 → 不误开菜单；7. 菜单打开后拖动 → 菜单先关闭再移动；
8. 桌宠在左侧 → 向右展开；9. 桌宠在右侧 → 向左展开；
10. 四个角 → 菜单不越界；11. 横屏 → 不越界；12. 分屏 → 不越界；
13. 50%/100%/200% → 菜单仍正确定位；14. 按钮不重叠；15. 依次点击 6 个占位按钮；
16. 只提示「功能尚未配置」（Toast，设置页也会显示"最近菜单操作"）；
17. 点击菜单空白区域 → 菜单关闭；18. 菜单关闭后**操作下方应用** → 无透明区域拦截（**关键**）；
19. 菜单打开时点「隐藏」→ 桌宠与菜单一起消失；20. 重新显示 → 旧菜单不残留；
21. 菜单打开时「停止服务」→ 全部消失；22. 停止后重新显示 → 无黑框一闪；
23. 切换素材 → 菜单正常（会先关闭）；24. 横竖屏反复切换 → 无旧菜单残留；
25. 锁屏再解锁 → 无透明拦截区域；26. 打开浏览器/Telegram → 桌宠与菜单正常；
27. 连续运行 10 分钟；28. 桌宠不消失、不闪烁；29. 始终只有一个桌宠实例；
30. 通知栏控制（隐藏/显示/停止）无退化。

日志核对：`menu.open` ↔ `menu.close` 成对；`menu.window.expand` ↔ `menu.window.restore` 成对；
任何 `removeView` / `onDestroy` / `menu.close` 都必须带明确 reason。

### 9.10 真机复验失败与修复（问题 A 首次挂载竞态 / 问题 B 菜单改双窗口）

第二次真机复验发现两个**独立**问题，本轮分别修掉。

#### 问题 A：点「显示桌宠」提示"悬浮服务正在运行，但是窗口未成功添加"

**根因**（本轮引入的回归）：`applyCommand` 在**新建**窗口后立刻又调了一次 `applySettings`：

```kotlin
val created = manager.attach(store)   // attach 已经完整应用了 store
if (created) { manager.applySettings(store) }   // ← 多余，且致命
```

`addView` 返回时 View **不保证**已经走完 `onAttachedToWindow`，于是
`applySettings → applyPetWindowGeometry → canTouchWindow()` 判定"窗口未附着"而拒绝提交，
旧代码又把这种拒绝当成"窗口已失效"，直接 `detach("update-failed-detached")` ——
**刚创建出来的窗口被自己摘掉**，表现就是"服务在运行、窗口不见了"。
（切换诊断模式触发的是 UPDATE 分支，它只调 `attach` 不调 `applySettings`，所以窗口又回来了。）

**修复**：

1. 新建窗口时**不再**调 `applySettings`（`attach` 已经完整应用了 store）；
   只有复用已有窗口时才重新套用配置；
2. 提交被拒绝时**区分原因**：守卫拒绝（窗口尚未附着）只跳过本次提交、**绝不 detach**；
   只有 `updateViewLayout` 真抛异常且窗口确实已不在 WindowManager 上，才清理引用。

#### 问题 B：菜单关闭时桌宠仍然抽动

单窗口方案的"原子几何提交"在真机上没有根治：窗口矩形（Surface）与子 View 布局是两条通道，
真机上仍会在两者之间绘制一帧。**本轮按需求改为双窗口降级方案**。

**双窗口结构**：

| 窗口 | 内容 | 菜单开关时的变化 |
|---|---|---|
| **桌宠窗口**（`PetOverlayView`） | 桌宠图片/占位/角标 | **LayoutParams 一个字段都不改**（结构性保证零抽动） |
| **菜单窗口**（`PetMenuView`，仅在菜单打开期间存在） | 6 个占位按钮 | 打开时 `addView`、关闭时 `removeView` |

* 菜单窗口 = **按钮触摸矩形的包围盒**（只有按钮，不含桌宠）；
* 只在菜单打开期间存在；`hide / stop / 息屏 / 旋转 / 分屏 / 换素材 / 改大小 / detach` 一律
  立即 `removeView`，绝不留透明拦截区域；
* 每种窗口最多一个（数据结构 + `removeMenuWindow` 幂等 + attach 时防御性清理）；
* 所有 WindowManager 操作仍在主线程串行；命令通道（commandId / stopSelfResult / activeInstance）未被改动。

**几何随之调整**（双窗口独有的新约束）：

1. **菜单窗口绝不能压住桌宠的"抓取区"**（桌宠中心的 50% 方块）——
   否则桌宠中心会被菜单窗口截走触摸，导致点不中、拖不动。
   这是一个硬门槛，已由单测直接断言；
2. 为此把原来的"整环垂直平移"改成**旋转扇形中心角**（更符合需求 §7.2 的
   "角落优先对角方向"），并加入**更窄的弧长候选**（步长 30°→24°→18°）——
   弧越窄，包围盒越不容易盖住桌宠中心；
3. 四角场景下 6 个 48dp 按钮的扇形在数学上无法同时满足"不越界 + 不压抓取区"，
   因此实现需求 §7.3 降级阶梯的最后一级：**紧贴桌宠的 3×2 紧凑栅格**；
4. 最后兜底：最小半径扇形 + 夹进可用区域 + 把压住抓取区的按钮推开。

**下一帧诊断**（保留）：`menu.geometry.settled` 在开关菜单后的下一帧读取
`rootView.getLocationOnScreen()` 与桌宠内容层位置，双窗口下 `delta` 必须恒为 `(0,0)`。

**新增单测**：

* `OverlayMenuWindowTest`（16 项）：菜单打开/关闭前后桌宠窗口矩形**完全相同**、
  左/右/四角/50-100-200%/横屏/分屏都成立、四条关闭路径（动画取消/forceClose/外部点击/按钮点击）、
  反复开关 20 次、菜单窗口不压抓取区、菜单窗口在可用区域内、按钮不重叠、
  无按钮时不创建窗口、每种窗口最多一个、未附着或实例失效时拒绝提交；
* `OverlayMenuTest` / `OverlayMenuGeometryTest`（22 项）按新几何更新（含"放不下才换另一侧"）。

#### 真机复验步骤（已执行：2026-09-30 用户确认 8 项全部通过 → 4C-3B 封版）

```powershell
adb install -r petlife\build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

1. **先验问题 A**：冷启动 → 点「显示桌宠」→ 窗口必须**立即出现**（设置页不出现
   "窗口未成功添加"），日志里不得有 `update-failed-detached`；
2. **再验问题 B**：桌宠放左/右/上/下与四个角，每处**开-关菜单 20 次**，再用
   50%/100%/200% 各重复 → 桌宠必须**完全静止**；日志中每次 `menu.close` 后紧跟的
   `menu.geometry.settled` 必须 `delta=(0,0)`，且 **没有** `menu-geometry-jitter`；
3. 三种关闭方式（点桌宠 / 点菜单空白 / 点占位按钮）各试；
4. 菜单打开后**从桌宠中心拖动** → 应先关菜单再移动（抓取区保证）；
5. 横竖屏与分屏各重复一次；
6. 菜单关闭后确认下方应用可正常点击（无透明拦截）；
7. 确认始终只有一个桌宠实例、菜单不残留（`removeView reason=menu-window:*` 成对出现）。

### 9.11 已知限制

* **菜单按钮没有任何业务功能**：点击只提示「功能尚未配置」并记录日志（需求明令禁止自行定义功能）。
* **桌宠窗口与菜单窗口可以有小范围重叠**（扇形环绕桌宠时，包围盒会压住桌宠边缘一条窄带）：
  被盖住的只有桌宠边缘，**抓取区（中心 50% 方块）永不被压住**，因此始终能点中/拖动桌宠；
  四角场景改为紧贴桌宠的 3×2 紧凑栅格，此时完全不重叠。
* **极端窄的分屏下按钮触摸区可能相邻偏近**（已通过 `degraded=true` 标记并在日志中说明）。
* **外部点击只能覆盖"菜单窗口的矩形范围"**：Android 悬浮窗无法监听全屏点击，
  需求也明确禁止为此创建全屏透明窗口。
* **`enabled = false` 的渲染分支已实现并被单测覆盖，但 6 个占位槽位全部启用** ——
  真机验收要求"6 个按钮都能得到同一句提示"，真正启用禁用态要等 4C-6 定义业务槽位。
* **未做双击/长按手势**：长按当前只收敛为"取消"，不产生任何菜单。
* **仪器测试仍阻塞**（无设备/无 AVD）。

## 10. Phase 4C-4：动态 WebP 播放

> 目标：让悬浮桌宠**真正播放**用户导入的动态 WebP，而不是只显示第一帧。
> 本阶段**只做动态 WebP**：GIF / APNG / 视频 / Live2D 一律不加入（避免解码、生命周期与性能问题混在一起）。

### 10.1 基线前置动作

* 4C-3B 在 §0 标记为"真机验收通过"，并固化基线 APK
  `BD9B9C1E…BE0008F`（另存为 `petlife-4C-3B-BD9B9C1E.apk`）；
* 本阶段**不改动** 4C-3A 的拖动 / 吸附 / 大小持久化，也**不改动** 4C-3B 的双窗口菜单架构；
* 未进入 4C-5（状态联动），未给菜单槽位加业务功能。

### 10.2 平台分级策略（需求 §3）

| API | 解码方式 | 行为 |
|---|---|---|
| **28+** | `ImageDecoder.decodeDrawable` | 动态 WebP → `AnimatedImageDrawable`，**完整循环播放**，可 start/stop |
| **24~27** | `BitmapFactory` 解第一帧 + 读文件头判断动态 | **安全显示第一帧**，设置页如实提示"当前 Android 版本不支持原生动态 WebP 播放，正在显示第一帧" |

低版本**不假装支持动画**：口径由 `PetVisualKind.animatedFirstFrameFallback` 显式表达，
对外 `visualType` 仍是 `animated`，但 `animationFrameMode = first-frame-fallback`。

### 10.3 统一视觉模型（需求 §4）

新增 `PetVisual.kt`，把"多个 Bitmap 字段 + 松散布尔量"换成互斥的三态模型：

```kotlin
internal sealed class PetVisual {
    data class Static(drawable, width, height, source) : PetVisual()
    data class Animated(drawable, width, height, source) : PetVisual()
    data class Placeholder(reason: String?) : PetVisual()
}
```

**一处刻意偏离需求建议**：需求建议 `Animated(drawable: AnimatedImageDrawable)`，
这里把字段类型写成 `Drawable`。原因：`AnimatedImageDrawable` 是 API 28 才有的类，
而项目 `minSdk = 24`；把它写进字段类型会让 24~27 设备在加载本类时就要解析该类型。
播放/停止统一走 API 1 就有的 `Animatable` 接口，"是不是动态"由 `PetVisualKind` 显式表达。

同一时刻只有一个当前视觉对象；错误一律落到 `Placeholder`；切换视觉时**先停旧动画，再替换 Drawable**。

### 10.4 素材类型识别（需求 §5）

**不依赖扩展名**。判定顺序：路径在私有素材根内 → 文件存在 → 普通文件 → 大小上限 →
`ImageDecoder.decodeDrawable` → 按返回类型判定（`AnimatedImageDrawable` → 动态，否则静态）。
API 24~27 用 `AnimatedWebpHeader.looksAnimated()` 读文件头（`RIFF….WEBP` 且含 `ANIM` 块）
判断"这其实是动态素材"，只用于**低版本回退口径**，不参与 28+ 的类型判定。

### 10.5 解码线程与 requestId 防过期（需求 §6 / §13）

* 路径校验、文件读取、解码、尺寸与像素上限检查**全在后台线程**；
  替换 `ImageView.drawable`、start/stop 动画、更新 WindowManager 状态**在主线程**；
* 沿用 `PetImageLoader` 的既有单线程执行器（`Executors.newSingleThreadExecutor`），**不新建线程池**；
* `OverlayRequestGuard`（`begin() / isLatest() / invalidate()`）保证：
  ```
  请求 A 开始 → 请求 B 开始 → B 完成 → A 随后完成 → A 不得覆盖 B
  ```
  过期结果直接 `detachDrawable()` 并回调 `onStale`，绝不上屏；
* Service `dispose()` 之后后台结果不得再写入 View（`disposed` 短路）。

### 10.6 动画播放门控（需求 §10）

七条条件集中成 `AnimationGate.shouldAnimate()`，由 `syncAnimationPlayback(trigger, forceStop)`
**唯一入口**调用 `manager.syncAnimation()`（`start/stop` 不散落在各处）：

```
服务正在运行 && 窗口已附着 && 桌宠可见 && 屏幕解锁/亮屏
&& 当前视觉是 Animated && 未进入停止清理 && 当前实例仍然有效
```

不满足时 `blockedReason()` 给出可读原因（`view-detached` / `pet-hidden` / `screen-off` /
`visual-not-animated` / `stopping` / `service-not-running` / `service-instance-replaced`），
写入诊断字段 `animationPausedReason`。

### 10.7 生命周期（需求 §11）

| 事件 | 行为 |
|---|---|
| 显示 | 窗口 attached 后 `syncAnimationPlayback("show-attached")` → 开始播放 |
| 隐藏 | **先停动画**（`forceStop`）再摘窗口；**不释放**解码结果，方便再显示 |
| 重新显示 | 复用当前 Drawable（**不重复解码**），attached 后恢复播放 |
| 息屏/锁屏 | 立即 `forceStop`，记录 `animation.pause reason=screen-off`；不销毁视觉对象 |
| 解锁 | 按统一门控恢复，记录 `animation.resume reason=user-present` |
| 停止服务 | 关菜单 → 停动画 → 清 `ImageView.drawable` → 移除桌宠窗口 → 释放加载器 → 清视觉引用 → `stopForeground` → `stopSelfResult` |
| Service 销毁 | 幂等再次停动画；旧实例不得操作新实例的窗口/通知/动画 |

### 10.8 资源清理与循环策略（需求 §9 / §12）

* 动态素材 `repeatCount = AnimatedImageDrawable.REPEAT_INFINITE`（默认循环；不读素材自身一次性循环后就永久停）；
* 释放顺序：先从 `ImageView` 摘掉 → 再 `Animatable.stop()` → 再丢引用；
* **绝不调用 `Bitmap.recycle()`**（动态 Drawable 内部按帧管理解码结果，手动回收会崩；静态 Bitmap 交给 GC）；
* 同一 Drawable 不同时交给多个 ImageView。

### 10.9 自动验证结果

```
Kotlin 单测：179 项全部通过（4C-3B 基线 156 → +23）
  PetVisualTypePolicyTest 3 / AnimatedWebpHeaderTest 4 / AnimationGateTest 3
  PetVisualErrorTest 1 / PetVisualLoaderTest 12
Flutter analyze：No issues found!
Flutter test：582 通过 + 1 skipped（4C-3B 基线 573 → +9）
APK：app-debug.apk
  path   = C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build\app\outputs\flutter-apk\app-debug.apk
  size   = 189,132,117 B
  time   = 2026-09-30 00:40:42
  sha256 = 6889E0FE5B52994E7A4D5103A65855E68F0D2BE9F754497624D6A709C8B0E15F
```

`OverlayAssetTest` 中"动态素材只显示第一帧（4C-2 口径）"一条按 §18 更新为
"配置层保留动画声明 + 保留低版本回退文案"，旧提示 `ANIMATED_FIRST_FRAME_NOTICE`
（"完整动画将在 4C-4 实现"）已退役，替换为 `ANIMATED_FIRST_FRAME_FALLBACK_NOTICE`。

### 10.10 修改文件列表

| 文件 | 改动 |
|---|---|
| `android/.../overlay/PetVisual.kt` | **新增**：统一视觉模型 + 类型分级 + 播放门控 + 文件头识别 + 错误码 |
| `android/.../overlay/PetImageLoader.kt` | 重写：`AndroidPetVisualDecoder`（28+ `ImageDecoder` / 24~27 `BitmapFactory`）+ `PetImageLoader`（requestId 防过期 + 释放顺序） |
| `android/.../overlay/PetOverlayView.kt` | `showStatic/showAnimated/showErrorPlaceholder/clearVisual/startAnimationIfAllowed/stopAnimation` |
| `android/.../overlay/PetOverlayManager.kt` | 转发上述接口 + `syncAnimation(shouldPlay, reason)` |
| `android/.../overlay/PetOverlayService.kt` | `syncAnimationPlayback` 唯一入口 + 生命周期接线 + 6 个 4C-4 诊断字段 |
| `android/.../overlay/PetOverlayBridge.kt` | `getState` 追加 6 个只读字段；移除已退役的 `animatedFirstFrameNotice` |
| `android/.../overlay/PetOverlayConfig.kt` | 文档注释更新（配置层的动画声明不再等同于"只显示第一帧"） |
| `lib/platform/overlay_pet.dart` | 新增 6 个只读字段 + `visualTypeLabelZh` / `animationStateLabelZh` / `showsAnimationHint` |
| `lib/ui/widgets/overlay_pet_card.dart` | 新增「视觉类型」「播放状态」两行只读诊断 |
| `android/app/src/test/.../PetVisualTest.kt` | **新增** 23 项纯逻辑测试 |
| `test/overlay_pet_test.dart` | 新增「视觉与动画（4C-4）」9 项 |
| `test/overlay_pet_controller_test.dart` | 更新动态素材用例到 4C-4 口径 |
| `docs/35-Phase4C悬浮桌宠.md` | 本文件（§0 基线 + §10） |

### 10.11 真机验收步骤（需求 §25，人工执行）

```powershell
$env:GRADLE_USER_HOME = "$env:USERPROFILE\.gradle"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
adb install -r C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

**A. 静态回归**：选静态 PNG → 正常显示 → 拖动/吸附正常 → 50%/100%/200% 正常 →
圆盘菜单正常 → 隐藏/显示/停止正常。

**B. 动态 WebP 播放**：选一个确认多帧的动态 WebP → 显示悬浮桌宠 → **不再只显示第一帧** →
持续观察 ≥1 分钟 → 循环连续、无周期性黑框、无尺寸跳动、透明背景正确。

**C. 生命周期**：播放中隐藏 → 窗口消失且动画停止 → 再显示 → 动画恢复 →
锁屏 30 秒 → 解锁 → 正常恢复 → 停止服务 → 窗口/菜单/动画全部停止 → 再显示只一个实例。

**D. 交互**：播放中连续拖动 20 次 → 动画与拖动均正常 → 调整大小 → **不重新加载素材** →
开关菜单 20 次 → 动画不中断、菜单不抽动桌宠 → 点占位按钮只提示未配置。

**E. 切换素材**：按 `静态PNG → 动态WebP A → 静态WebP → 动态WebP B → 静态PNG` 快速切换 →
每次只显示最后选择的素材、旧动画立即停止、不回跳、无黑框、不产生多个桌宠、失败时显示明确占位。

**F. 性能观察**：动态播放 10 分钟记录 CPU/内存 → 隐藏 1 分钟确认 CPU 下降 →
连续切换动态素材 20 次确认内存无明显持续增长。

### 10.12 已知限制

* **API 24~27 只能显示第一帧**（无 `ImageDecoder`）；如需完整动画，必须作为独立子任务评估解码库
  （APK 体积 / ABI / 许可证 / 内存 / 与现有 `ImageView` 兼容性），本阶段**未引入任何第三方图片库**；
* **播放进度不保存**：隐藏后再显示允许从头播放（需求 §9 明确本阶段不要求）；
* **不提供播放速度调节与暂停按钮**；菜单**不增加**播放控制按钮；
* **本阶段只支持动态 WebP**：GIF / APNG / 视频 / Live2D 均未加入；
* **仪器测试仍阻塞**（本机 `adb devices` 无设备、无可用 AVD）：需求 §22 的 8 项
  `connectedDebugAndroidTest` 条目**未执行**，不得声称通过；真实 `ImageDecoder` /
  `AnimatedImageDrawable` 行为以真机验收为准。

### 10.13 真机验收结果（2026-09-30 用户确认通过）

用户确认 8 项全部通过（见 §0）：真机可播放动态 WebP、动画持续循环、静态 PNG/WebP 无退化、
拖动/吸附/大小正常、开关双窗口菜单不抽动桌宠、隐藏/显示/锁屏/解锁/停止正常、
静态与动态切换正常、无黑框/重复实例/明显资源泄漏。

本阶段**已封版**，基线 APK 另存为 `petlife-4C-4-6889E0FE.apk`。

## 11. Phase 4C-5：悬浮桌宠状态联动

> 目标：让 Android 悬浮桌宠按**项目现有状态体系**自动切换素材。
> 硬约束：**复用已有状态定义、分类规则、状态映射与回退链**，禁止建立第二套状态系统。

### 11.1 实施前审计（需求 §2 的 12 问）

| # | 问题 | 结论（以当前代码为准） |
|---|---|---|
| 1 | 现有标准状态列表 | `SystemState`（[system_state.dart](file:///c:/Users/Administrator/WorkBuddy/DesktopPet/petlife/lib/state_engine/system_state.dart)）共 **11 个**：`error / manual / concerned / tired / happy / gaming / focused / social / entertained / away / default`，带 `priority`（100…0） |
| 2 | 每个状态的内部 ID | 即 `wireName`：`error`(100)、`manual`(95)、`concerned`(90)、`tired`(80)、`happy`(70)、`gaming`(60)、`focused`(50)、`social`(40)、`entertained`(30)、`away`(20)、`default`(0) |
| 3 | 状态调试器的状态来源 | Dart `DefaultStateEngine`：调试器用 `force=true + immediate=true` 直接 `requestState`，可越过优先级与最短展示时长；`error/manual` 为紧急态 |
| 4 | 素材库状态映射保存位置 | SQLite 表 `state_mappings`（`StateMappingDao`）：`character_id + system_state + asset_id?/emotion_name? + weight + priority`；角色默认图存在 `characters.default_asset_id` |
| 5 | 默认状态 ID | `SystemState.defaultState.wireName == "default"` |
| 6 | 默认素材选择规则 | `FallbackChain`（[fallback_chain.dart](file:///c:/Users/Administrator/WorkBuddy/DesktopPet/petlife/lib/state_engine/fallback_chain.dart)）**5 级**：状态指定图片 → 状态指定情绪 → 角色默认图片 → 角色第一个有效素材 → 内置占位图；候选多于 1 个时按 `weight` 加权随机 |
| 7 | Windows 当前状态解析入口 | `ActivityTracker`（采样）→ `ActivityStateMapper.decide()`（纯函数：error→concerned→tired→away→分类）→ `StateEngine.requestState()`；分类走 `ApplicationClassifier` + `kBuiltInCategoryRules`（**进程名**规则） |
| 8 | Android 现有前台应用检测入口 | **不存在**：`AndroidPlatformServices.createForegroundAppProvider()` 返回 `UnavailableForegroundAppProvider`；全仓无 `UsageStatsManager` / `PACKAGE_USAGE_STATS` |
| 9 | Android 是否已有使用情况访问权限流程 | **不存在**（Manifest 里也没有该权限）；现有权限只有 `SYSTEM_ALERT_WINDOW` / 前台服务 / 通知 |
| 10 | Flutter 进程退出后状态计算是否还能运行 | **不能**：状态引擎、采集器、`FallbackChain` 全在 Dart 侧，依赖 Flutter 引擎存活；Android 悬浮服务（`stopWithTask=false`）会继续运行 → **原生必须自带状态判定与映射快照** |
| 11 | 哪些逻辑可以复用 | 状态 ID 与中文名、分类语义（8 类 `AppCategory`）、分类→状态映射规则、**加权随机 + 多级回退链**（原生侧直接复用 Flutter 算好的快照）、`PetVisual` / `PetImageLoader` / `OverlayRequestGuard` / `syncAnimationPlayback` |
| 12 | 哪些必须原生实现 | 前台包名读取（`UsageStatsManager`）、使用情况访问权限检查与跳转、**包名→分类**规则（Windows 用的是进程名，不能强行混用）、状态监听任务、**候选稳定性防抖**、原生映射快照持久化、原生手动覆盖 |

#### 审计发现的三处必须显式说明的偏差

1. **浏览器不映射为独立状态**：现有 `ActivityStateMapper._stateForCategory` 把
   `browser / system / other` 一律映射为 `default`，并在注释里写明"仅凭浏览器进程
   无法区分工作还是娱乐，强行映射会给出错误信息"。
   需求 §1 的示例提到"使用浏览器时切换到状态映射对应素材"——按 §1"不得自行发明新分类"，
   本阶段**沿用现有规则**（浏览器 → `default`），不新增浏览器专属状态。
2. **回退层级**：需求 §14 列 4 级，项目现有 `FallbackChain` 是 **5 级**（多一级"状态指定情绪"）。
   按"以当前代码为准"，快照由**既有 `FallbackChain` 直接算出**（含情绪级），
   原生侧只做"状态素材 → 角色默认 → 任一有效 → 占位"这一子集，不倒退已有能力。
3. **不复用 Dart 的"最短展示时长"（15 秒）**：Dart `StateDebouncer` 会要求
   "当前状态至少展示 15 秒"，直接搬到 Android 会造成一个硬冲突 ——
   需求 §25-B 的验收方式是"每个应用停留 **3~5 秒**，确认状态随之变化"，
   15 秒的最短展示会让验收永远等不到切换。
   本阶段的"不连跳"改由**候选稳定性（连续 2 次且 ≥1000ms）+ 快速切换抑制（400ms）**
   共同保证（两者参数与 Dart 保持一致），语义不打折。

### 11.2 原生侧实现

#### 状态 ID 与来源

* `PetStateId` 常量与 Dart 的 `SystemState.wireName` **逐字一致**（11 个），
  另加 `PetStateSource`：`manual-debug / foreground-app / idle / default / screen-off / unsupported`；
* 统一决策对象 `PetStateDecision(stateId, source, reason, foregroundPackage, decidedAt)`。

#### 前台应用检测（新增只读接口）

```kotlin
interface ForegroundAppSource { fun currentForegroundApp(): ForegroundAppSnapshot? }
data class ForegroundAppSnapshot(packageName: String, appLabel: String?, observedAt: Long)
```

* 实现 `AndroidForegroundAppSource`：`UsageStatsManager.queryEvents` 取最近 `MOVE_TO_FOREGROUND`；
* **只读包名与应用标签**，不读屏幕内容 / 输入 / 通知 / 聊天 / 文件 / 无障碍节点；
* 权限不足或异常时返回 null（不抛、不崩）。

#### 包名 → 分类（不伪装成 Windows 进程名）

新增 `AndroidAppCategoryRules`：输入统一为 `packageName`，
按项目既有 8 类 `AppCategory` 的 `wireName` 归类（用户自定义规则优先 → 包名前缀规则 → `other`）；
包名统一小写、去空白；桌面 / 输入法 / 系统设置显式归类为 `system`；PetLife 自身归 `system`
（避免"自己前台导致无限切换"）。
分类→状态的动作**逐条对齐** `ActivityStateMapper._stateForCategory`。

#### 防抖（对齐现有 `StateDebounce` 的参数）

* 候选状态需**连续 2 次**且持续 ≥ `stateStableMs`（1000ms，落在需求 800~1500ms 区间）才生效；
* 快速切换抑制 `rapidSwitchSuppressMs = 400ms`（与 Dart 一致）；
* **刻意不做最短展示时长**（原因见 §11.1 偏差 3）；
* 手动覆盖**不等**普通防抖；
* 显示桌宠后的首次检测、解锁后的首次检测走**快速路径**（跳过稳定性门槛，
  只保留快速切换抑制）—— 否则用户解锁后要盯着旧素材看一秒多才恢复（需求 §17.5）；
* 参数集中为常量，便于单测。

#### 映射快照与持久化

* `NativePetStateMapping(characterId, defaultAsset, stateAssets, revision)`；
* 通过 `PetOverlayStore`（**不新建第二套 SharedPreferences**）持久化：
  按**状态 ID 拆成独立键**（`overlay.state.<stateId>.asset_id/path/is_animated` +
  一个 `overlay.state.default_asset.*`），因为它们本来就是固定的 11 个 ——
  这样天然满足"有 schemaVersion / 有大小上限 / 严格解析 / 不保存素材二进制"，
  又不必引入 JSON 解析依赖（JVM 单测可直接打靶）；
* 写入是**单次原子提交**（一个 `Editor` 事务内先清后写，避免残留上一次的状态）；
* `revision` 单调递增，旧 revision 一律拒绝（`mapping_revision_stale`）；
  解析失败回退到**上一次有效版本**，绝不导致 Service 启动崩溃；
* 未知状态 ID 忽略并记日志，单个素材路径非法只丢该条（回退链自动顶上），
  **不拒绝整个服务**；
* 更新映射**不重建窗口、不重启服务、不影响菜单**。

#### 回退与切换

* 原生回退：状态素材 → 角色默认素材 → 角色任一有效素材 → 可见占位
  （`NativeAssetSelector`，语义与 Dart 5 级链一致；`characterId` 在快照里，
  因此"不跨角色回退"是结构性保证）；
* `assetId` 与当前相同 → 直接返回（不重复解码，需求 §15 第 3 步）；
* 否则更新 store 的素材字段后走 4C-4 的既有加载链路
  （`requestId` + `PetImageLoader` + `syncAnimationPlayback`），**不写第二套加载器**；
* 解码失败 → 错误占位，服务继续运行（沿用 4C-4 行为）。

#### 监听任务

* 单任务（`PetStatePoller` 内部只有一个 `Runnable`，`start()` 幂等），
  `post` / `remove` 由服务注入，因此 JVM 单测可以精确验证"不会叠加"；
* 服务运行且桌宠启用时每 `STATE_POLL_MS = 1500ms` 检测一次；
* 隐藏时降频到 `STATE_HIDDEN_POLL_MS = 5000ms`；锁屏时**完全停止**；
  解锁立即检测一次（快速路径）；停止服务 / onDestroy 取消任务并清空候选；
* 间隔下限 500ms（结构上不可能高于 2 次/秒）。

### 11.3 MethodChannel 扩展

在既有 `asia.akechi.petlife/overlay` 上新增（不改动已有方法语义）：

| 方法 | 作用 |
|---|---|
| `updateStateMapping` | 推送完整映射快照（revision 单调）；被拒绝时**不影响**服务运行 |
| `setManualState` | 手动覆盖到某个已有状态 ID（传 null = 恢复自动）；立即生效 |
| `getStateDiagnostics` | 只读状态诊断（当前状态/来源/前台包名/候选/映射版本/素材 ID/回退级别/使用情况访问权限） |
| `openUsageAccessSettings` | 跳到系统"使用情况访问"设置页（**只打开**，不反复弹窗） |

> 为什么没有单独的 `getUsageAccessStatus`：权限状态已经包含在 `getStateDiagnostics` 里，
> 少一个方法就少一处协议面（设置页一次往返即可拿到权限 + 状态）。
> `clearManualState` 由 `setManualState(null)` 表达，同样不新增方法。

### 11.4 Flutter 侧

* `AndroidOverlayPet` 接口 + `AndroidOverlayPetBridge` 增加上述方法；
* `OverlayStateDiagnostics` 只读模型（解析 + 中文文案：来源、自动联动、回退级别、无权限提示）；
* 新增 `buildOverlayStateMapping()`（`lib/platform/overlay_state_mapping.dart`）：
  **直接复用既有 `FallbackChain`** 逐状态解析，注入**固定随机种子**保证同样的库内容
  得到同一份快照；与角色默认素材结果相同的状态不写进快照（让原生的回退级别真实可读）；
* `OverlayPetController`：`refresh()` 顺带读诊断并**从原生已生效的 revision 续上计数器**
  （否则应用重启后会用更小的 revision 被整批拒绝）；`syncStateMapping()`
  按内容签名去重、服务未运行时不推送；`show()` 之后补推一次；`stop()` 清空两个签名；
* 非 Android 平台：`UnsupportedOverlayPet` 的诊断返回"不可用"，写操作抛错（安全降级）；
* 设置页新增「使用情况访问权限」行 + 授权入口、状态联动只读诊断、
  以及**手动覆盖下拉框**（复用现有 `SystemState`，含"自动（跟随前台应用）"）；
* 缺陷 C 修复后追加**前台识别诊断**行：应用识别来源、事件数（总数/前台/可用/统计）、
  最后一条事件包名、识别说明（失败原因）；AppOps 与"真实可读"不一致时单独给出提示。

### 11.5 自动验证结果

```
Kotlin 单测：248 项全部通过（4C-5 首版 229 → +19，全部为缺陷 C 修复新增）
  ForegroundAppResolverTest 18（缺陷 C 的 15 条场景 + 3 条补充）
  PetStateMonitorTest 12 / PetStatePollerTest 6 / PetStateDebouncerTest 8
  PetStateIdTest 3 / AndroidAppCategoryRulesTest 6 / AppCategoryStateMapperTest 2
  NativePetStateMappingParserTest 7 / NativeAssetSelectorTest 6 / PetMimeTest 1
Flutter analyze：No issues found!
Flutter test：614 通过 + 1 skipped（4C-5 首版 609 → +5，缺陷 C 诊断解析）
APK：app-debug.apk
  path   = C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build\app\outputs\flutter-apk\app-debug.apk
  size   = 189,155,982 B
  time   = 2026-09-30 02:01:25
  sha256 = 0D8A1260A49FEDF16AECE0A536AA9A26A257B6C3ED4FCC4086139EA2CFB37A0C
```

`platform_isolation_test.dart` 的"权限清单精确可控"用例按本轮需要**显式更新**：
`PACKAGE_USAGE_STATS` 从"明确禁止"名单移入允许集合（总数 5 → 6），
并顺带把断言从"按行包含"改成"正则解析真实声明"，以便支持跨行写法与精确计数；
无障碍 / 定位 / 自启动 / 安装未知应用 / 全量包可见性**仍然禁止**。

### 11.6 修改文件列表

| 文件 | 改动 |
|---|---|
| `android/.../overlay/PetState.kt` | **新增**：状态 ID/来源/分类规则/分类→状态/防抖/回退链/MIME/映射模型与解析/错误码 |
| `android/.../overlay/PetForegroundApp.kt` | **新增**：`ForegroundAppQuery`（查询抽象）+ `ForegroundAppResolver`（筛选/兜底/缓存，纯逻辑）+ `ForegroundCandidateSelector` + `ForegroundWindow` + `AndroidForegroundAppQuery` + `AndroidForegroundAppSource` + `UsageAccess` |
| `android/.../overlay/PetStateMonitor.kt` | **新增**：`PetStateMonitor`（纯判定 + 检测诊断/日志）+ `PetStatePoller`（单任务轮询） |
| `android/.../overlay/OverlayActions.kt` | `OverlayLog` 增加 `diagnosticsEnabled` 与 `debug()`（逐条事件只在诊断模式输出） |
| `android/.../overlay/PetOverlayStore.kt` | 映射快照持久化（按状态拆键、单次原子提交）+ 手动覆盖 |
| `android/.../overlay/PetOverlayService.kt` | 状态联动接线（生命周期/素材选择/诊断/手动覆盖）+ 前台识别 11 项诊断字段 |
| `android/.../overlay/PetOverlayBridge.kt` | 新增 4 个通道方法 + `stateDiagnostics()`（含前台识别诊断） |
| `android/app/src/main/AndroidManifest.xml` | 新增 `PACKAGE_USAGE_STATS`（`tools:ignore="ProtectedPermissions"`） |
| `android/app/src/test/.../PetStateTest.kt` | **新增** 68 项纯逻辑测试（含缺陷 C 的 `ForegroundAppResolverTest` 18 项） |
| `lib/platform/overlay_state_mapping.dart` | **新增**：状态 → 素材快照模型与构建器（复用 `FallbackChain`） |
| `lib/platform/overlay_pet.dart` | 新增 `OverlayStateDiagnostics`（含前台识别诊断）+ 4 个接口方法 + 非 Android 降级实现 |
| `lib/platform/android/android_overlay_pet.dart` | 4 个通道方法的实现 |
| `lib/ui/overlay_pet_controller.dart` | 映射下发（revision 续接/去重）+ 诊断刷新 + 手动覆盖转发 |
| `lib/ui/mobile/mobile_shell.dart` | 注入 `stateMappingLoader`（从数据库读素材与映射） |
| `lib/ui/widgets/overlay_pet_card.dart` | 使用情况访问权限行 + 状态诊断 + 前台识别诊断 + 手动覆盖下拉框 |
| `test/overlay_state_mapping_test.dart` | **新增** 7 项快照构建测试 |
| `test/overlay_pet_test.dart` | 新增「状态联动（4C-5）」16 项（含缺陷 C 诊断解析 5 项） |
| `test/overlay_pet_controller_test.dart` | 新增「状态映射下发与手动覆盖（4C-5）」9 项 |
| `test/platform_isolation_test.dart` | 权限白名单显式更新为 6 条并改为正则解析声明 |
| `docs/35-Phase4C悬浮桌宠.md` | 本文件（§0 基线 + §11） |

### 11.7 真机复验缺陷 C：前台应用识别失败（已修复）

**现象**（用户真机复验，2026-09-30）：Usage Access 已授权，但设置页「当前应用」始终为空、
桌宠状态始终为 `default`，分屏下也识别不到旁边的应用。
结论：故障位于**前台应用读取**这一层，尚未进入分类、状态映射与素材切换。

**根因（三处叠加）**：

1. **算法顺序错误（主因）**：原实现是"先在事件流里取最后一条 `MOVE_TO_FOREGROUND`，
   再判断它是不是 PetLife"。而"返回 PetLife 设置页"或"分屏里 PetLife 也在前台"时，
   最后一条事件就是 PetLife 自己 → 直接返回 null → 设置页显示"当前应用：-"、状态永远 `default`。
   正确做法是**先逐个过滤、再取最新**。
2. **只认一种事件类型**：只比较 `MOVE_TO_FOREGROUND`，没有显式处理 Android 10+ 的
   `ACTIVITY_RESUMED`（两者数值同为 1，但代码里看不出"两个都要认"）。
3. **查询窗口太短且没有兜底**：只查最近 60 秒、失败即返回 null；
   既没有 `queryUsageStats` 兜底，也没有"最近有效外部应用"缓存 →
   任何一次读不到就立刻掉回 `default`。

**修复**：

| 项 | 内容 |
|---|---|
| 算法 | `ForegroundCandidateSelector`：先按事件类型筛出前台候选 → **逐个过滤**（自身 / 空包名 / SystemUI / 输入法）→ 取时间戳最大的一条（"最后一个**有效外部**应用事件"） |
| 事件类型 | `MOVE_TO_FOREGROUND` 与 `ACTIVITY_RESUMED` **都显式比较** |
| 查询窗口 | 事件窗口 45 秒（≥30 秒）；使用统计兜底窗口 10 分钟 |
| 兜底 | 事件流无可用项 → `queryUsageStats` 按 `lastTimeUsed` 取最近的**有效外部**应用，标注 `source=usage-stats-fallback`（不伪装成精确事件） |
| 缓存 | 记录 `lastExternalPackage / label / eventTime`，有效期内继续使用（10 分钟），过期才回退 `default` |
| 分屏 | PetLife 自身的 RESUMED **不清空**已识别外部应用；原因记为 `last-event-is-self` / `split-screen-last-external` |
| 权限 | 判定改为"AppOps 允许 **或** 确实能读到使用数据"（个别 ROM 的 AppOps 口径不准），两者**分别上报**以便一眼看出差异 |
| 事件读取 | 每个事件用**新实例**（个别 ROM 的 `getNextEvent` 不覆盖对象全部字段，复用实例可能残留上一条数据） |
| 诊断 | 新增 11 个只读字段（检测来源 / 失败原因 / 事件计数 / 最后原始包名 / AppOps / 窗口 / 外部事件时间），设置页可见 |
| 日志 | `state.foreground.query / .event / .filtered / .detected / .fallback / .unavailable`；**逐条事件仅在诊断模式输出** |

**对应测试**（`ForegroundAppResolverTest`，逐条覆盖修复要求 §七的 15 条）：
两种事件常量都算前台事件 / 只有 `ACTIVITY_RESUMED` / 只有 `MOVE_TO_FOREGROUND` /
混合取最新 / 最后一条是 PetLife 时向前找 / 分屏 PetLife+Telegram 返回 Telegram /
SystemUI 是最后一条时向前找 / 输入法是最后一条时向前找 / 无新事件用缓存 /
缓存过期回退 default / `queryEvents` 为空用统计兜底并如实标注来源 / 未授权不查询 /
空包名跳过 / 乱序时间戳排序 / 分屏不清空外部应用；另有诊断字段完整性与
"AppOps 口径不准仍可用"两条补充用例。

> **在真机复验通过前，4C-5 不标记为通过，也不开始 Android 应用时长采集。**

### 11.8 真机验收步骤（需求 §25，人工执行）

```powershell
$env:GRADLE_USER_HOME = "$env:USERPROFILE\.gradle"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
adb install -r C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c
adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

**A. 权限**：先**不授权**使用情况访问 → 显示桌宠 → 确认用默认状态、设置页显示"未授权" →
点「去授权使用情况访问」进入系统页 → 授权后返回 → 确认"自动联动：运行中"。

**B. 应用联动**：依次切换 `桌面 → 浏览器 → Telegram → 游戏 → PetLife → 系统设置 → 未知应用`，
每个停留 3~5 秒，确认当前状态符合既有分类、素材自动切换、动态 WebP 自动播放、
无映射时用默认素材、**不快速连跳**、且**不改变桌宠位置与大小**。

**C. 防抖**：快速在两应用间来回切换 → 短暂状态不上屏；在目标应用稳定停留 →
只切换一次；在属于同一状态的多个应用间切换 → **不重复解码同一素材**。

**D. 手动覆盖**：在设置卡的手动覆盖里选一个已有状态 → 立即切换素材 →
切到别的应用 → 覆盖保持 → 选「自动（跟随前台应用）」→ 立即重新检测并切换。

**E. 生命周期**：联动运行时锁屏 30 秒 → 解锁 → 恢复正确状态；隐藏后切换应用 → 再显示 →
立即用当前状态；**完全关闭 PetLife 界面** → 切换其他应用 → 确认前台服务仍能自动联动；
停止服务 → 监听、动画、桌宠与菜单全部停止。

**F. 权限撤销**：联动运行中撤销使用情况访问 → 回桌面 → 不崩溃、回退默认状态、
设置页显示权限缺失 → 重新授权后恢复。

**G. 回归**：静态 PNG / 静态 WebP / 动态 WebP 正常；拖动 / 吸附 / 大小调整正常；
双窗口菜单正常且开关不抽动；不产生重复窗口与透明拦截区域。

**H. 缺陷 C 专项复验（本轮修复的验证顺序，必须按序执行）**：

```powershell
adb shell appops get asia.akechi.petlife GET_USAGE_STATS   # 1. 必须为 allow
adb logcat -c; adb logcat -s PetLifeOverlay:* AndroidRuntime:E
```

1. 确认 `GET_USAGE_STATS = allow`；
2. **全屏**打开 Telegram 停留 10 秒 → 日志必须出现 `state.foreground.detected`
   （设置页「应用识别」应显示"前台事件"、「事件数」总数 ≥1）；
3. 返回 PetLife → 「当前应用」**不能**变成"-"（应保留 Telegram，
   或显示"最近有效外部应用"并给出 `last-event-is-self` 说明）；
4. 全屏打开游戏停留 10 秒 → 「当前应用」应更新为游戏包名、状态变为 `gaming`；
5. **最后**再做分屏测试：分屏中 PetLife 旁边是 Telegram 时，
   应保留 Telegram（或最近有效外部应用），不得掉回"-"；
6. 上面 1~5 全部通过后，才继续测试分类、状态映射与素材切换。

若第 2 步日志里 `events=0`：把设置页的「诊断模式」打开再复现一次，
届时会输出 `state.foreground.event` 逐条事件，可直接看出是该 ROM 不上报事件
（则应走 `usage-stats-fallback`）还是包名/类型不符合预期。

### 11.9 已知限制（本阶段）

* **不实现空闲状态（`away`/`tired`/`concerned`/`happy`/`error`）**：Android 上没有可靠的
  用户空闲来源（`UnavailableIdleDetector`），也**不读取**任何使用时长统计来做"疲惫/担忧"判断 →
  按需求 §13"不要凭空实现"，本阶段只产出 `focused / gaming / social / entertained / default`
  这 5 个状态（+ `manual` 覆盖）。相关状态仍可由手动覆盖选中并正常显示素材；
* 不做移动 / 睡觉 / 自动位移动画（用户此前已明确不需要）；
* 浏览器 / 系统 / 未归类应用保持 `default` 状态（沿用现有分类规则，见 §11.1 偏差 1）；
* **不做"最短展示时长"**（见 §11.1 偏差 3），"不连跳"由候选稳定性 + 快速抑制保证；
* **手动覆盖入口放在悬浮桌宠设置卡里**（而不是桌面版状态调试器页面）：
  Android 用户看到的是原生悬浮窗，覆盖必须在原生侧生效；
  两者**复用同一个 `SystemState` 枚举**，没有第二套状态命名；
* **Flutter 与原生各自持有"当前状态"**：Android 上的 Dart 状态引擎拿不到前台应用
  （`UnavailableForegroundAppProvider`），因此桌面端 `StateSnapshot.state` 通常停在
  `default`，而原生侧按前台应用联动。设置页的「当前状态」一行显示的是**原生**的判定结果
  （这才是用户实际看到的那张图），「当前悬浮素材」一行仍来自 Dart 快照；
* **仪器测试仍阻塞**（本机 `adb devices` 无设备、无可用 AVD）：需求 §24 的 12 项
  `connectedDebugAndroidTest` 条目**未执行**，不得声称通过；
  真实的 `UsageStatsManager` 行为以真机验收为准。

## 12. Phase 4C-5.1：Android 本机使用统计采集与同步

> 起因：4C-5 修复版真机验收时发现——悬浮桌宠设置页能正确显示「当前前台应用」，
> 但**使用统计（本机）页面的「当前应用」仍为空**，且 Android 没有产生任何时长记录。
> 结论：前台检测链路已可用，问题在**统计模块未接入同一份前台应用快照**，
> 且**原生检测只驱动桌宠状态、没有写入现有 usage 会话数据**。
>
> **实施拆分（用户决策 2，选择 A）** —— 本阶段拆成两个可独立验收的增量：
> * **4C-5.1A**（本文 §12.4）：只修「使用统计」页当前应用显示，两页共用同一份快照，**先真机验收**；
> * **4C-5.1B**（本文 §12.6）：原生会话跟踪 + journal + 幂等导入 + Outbox/云同步 + 时间段列表。
> **4C-5.1A 未通过真机验收前，不得开始 4C-5.1B。**

### 12.1 实施前审计（需求 §2 的 15 问）

审计方式：对 Flutter 侧 `lib/activity_tracking/**`、`lib/database/**`、`lib/sync/**`、
`lib/ui/pages/usage_stats_page.dart` 与服务端 `petlife/server/**` 做只读检索与代码阅读。

| # | 问题 | 结论（文件:行） |
|---|---|---|
| 1 | 本地 usage 会话表与字段 | 表 **`activity_segments`**（`lib/database/schema.dart:117-130`）：`id(PK)`、`owner_id`、`device_local_id`、`app_key`、`app_name`、`process_name`、`started_at`、`ended_at`、`active_seconds`、`end_reason`、`sync_status(DEFAULT 'pending')`、`created_at`；索引 4 条（`:139/140/200/201`）；**除主键外无 UNIQUE**。配套表：`activity_checkpoints`(`:164-171`)、`daily_usage`(PK `owner_id+device_local_id+day_key`，`:174-186`)、`applications`(`:150-161`)、`tracking_settings`(`:189-197`)、`sync_outbox`(`:253-265`) |
| 2 | Windows「当前应用」显示入口 | `usage_stats_page.dart:268` → `ActivityTracker.currentAppDisplayName`(`activity_tracker.dart:78`) → `ActivitySegmentService.currentAppDisplayName`(`activity_segment_service.dart:118`，赋值点 `:466-467`) |
| 3 | Windows 会话开始 / 心跳 / 结束 | 开始 `ActivitySegmentService._openSegment`(`:549-584`)；心跳 `ActivityTracker._tickOnce`(`activity_tracker.dart:159-183`，2s 周期 `:111`) → `_tick`(`activity_segment_service.dart:260-348`) → `_flush`(`:628-666`)；结束 `_closeOpen`(`:586-615`) |
| 4 | 统计页 Controller / Repository / DAO | 页面 `usage_stats_page.dart`（无独立 Controller）；数据层 `UsageAnalyticsService`(`usage_analytics_service.dart:43/143/165`)；DAO `ActivityDao` / `DailyUsageDao` / `ApplicationDao` |
| 5 | 今日累计时长怎么算 | 设备级：Dart 内存累加 + 整行覆盖写（`_addDeviceUsage` `:361-392` → `DailyUsageDao.upsert`）；应用级：`ActivityDao.listOverlapping`(`activity_dao.dart:146-170`) + 按墙钟比例裁剪折算(`usage_analytics_service.dart:64-85`)；**没有 SQL 聚合** |
| 6 | 具体时间段怎么查 / 是否分页 | **本机统计页没有时间段列表**；本机唯一时间段查询 `ActivityDao.listOverlapping` 有 `limit=20000` 硬上限、无分页。带分页的时间段明细只在**云端**页（`cloud_statistics_page.dart:567-657` + `cloud_statistics_controller.dart:398-422`，游标分页） |
| 7 | 「当前应用」最终来自哪个 Provider | `ForegroundAppProvider`(`foreground_app_provider.dart:12-18`)；Windows=`Win32ForegroundAppProvider`(`windows/win32_providers.dart:16-24`)；**Android=`UnavailableForegroundAppProvider`**（`android_platform_services.dart:108-110`）；装配点 `app_scope.dart:382` |
| 8 | `platform` 字段如何保存 | **本地 usage 表里没有 `platform` 列**（全库检索无命中）；`platform` 只存在于设备注册上报（`device_info_provider.dart:44-55` → `api_client.dart:74`）与**服务端 `devices` 表** |
| 9 | `device_local_id` 如何写入 | **两套语义**：(a) 服务端身份用 UUID v4，存 `local_settings`，键 `sync.deviceLocalId`（`device_identity.dart:48-75`）；(b) 本地 usage 表恒写常量 `'desktop.local'`（`constants.dart:25` → `app_scope.dart:369/377/413`）。两者**不是同一个值** |
| 10 | session ID / 幂等键 | 段 ID = `Ids.segment(ownerId, deviceLocalId, appKey, startedAt)` 的 **UUID v5 确定性值**（`ids.dart:94-101`）；幂等靠 `activity_segments.id` 主键 + `ConflictAlgorithm.replace`（`activity_dao.dart:83`）。outbox 幂等键 `(entity_type, entity_key)` + 部分唯一索引（`schema.dart:271-272`） |
| 11 | `sync_outbox` 如何接收新会话 | `_notifySegment`(`activity_segment_service.dart:671-677`) → `LocalChangeSink`(`local_change_sink.dart:11-23`) → `OutboxChangeSink`(`outbox_change_sink.dart:26-29`) → `OutboxProducer.enqueueSegment`(`outbox_producer.dart:45-57`) → `SyncOutboxDao.enqueue`；`entity_type` ∈ `activity_segment / daily_usage / application`(`sync_models.dart:10-13`) |
| 12 | 服务端 usage 接口支持哪些字段 | `POST /api/v1/sync/push`（`api/v1/sync.py:31-46`）内 `activity_segments[]`（`schemas/sync.py:54-90`）：`id`(UUID) / `device_id`(UUID) / `app_key`(≤128，不含路径分隔符) / `category`(白名单) / `started_at` / `ended_at?` / `active_seconds`(0~172800) / `end_reason?`(≤32) / `created_at` / `updated_at`。**无 platform 字段**；platform 只挂在 `devices` 表（`models/device.py:47-49`，已支持 `android`，有测试）。幂等=`(user_id,id)` 复合主键 + LWW(`sync_service.py:254-284`) |
| 13 | Android 是否已有未接入的 SessionTracker | **没有**：`lib/activity_tracking/` 下无 android 目录；Dart 侧 `supportsSystemActivityTracking=false`；Kotlin 侧只有 4C-5 的 `ForegroundAppResolver`（**只读事件、不写任何记录**，`PetForegroundApp.kt:546-549`） |
| 14 | Flutter 退出后哪些 DB 接口不可用 | **全部 Dart 侧 DB 写入都不可用**：`AppServices.shutdown()` → `activityTracker.stop()`(`app_scope.dart:580`) → `AppDatabase.close()`(`:594`，`app_database.dart:177-187`)；此后所有 DAO 抛异常。采样定时器本身是 Dart `Timer`，引擎退出即停 |
| 15 | 原生如何暂存 Flutter 退出期间的会话 | **当前完全没有**（原生刻意不写 Flutter SQLite，见 `PetOverlayStore.kt:53-61` 的注释）→ 必须新增原生暂存队列 |

#### 审计发现的四处关键事实（决定了本阶段设计）

1. **服务端不需要修改**：`ActivitySegmentIn` 与平台无关，`devices.platform` 已支持 `android` 并有专门测试；
   会话记录通过 `device_id` 关联设备即可表达平台。
   （唯一差别：如果需要"按平台过滤会话"，服务端没有该查询参数——本阶段不需要。）
2. **本地 usage 表没有 `platform` 列**，且本地 `device_local_id` 恒为 `'desktop.local'` 常量。
   若 Android 会话也用 `'desktop.local'`，Windows 与 Android 的记录会在本地统计里**混在一起**，
   且与服务端"每台设备 device_local_id 唯一"的语义不一致。
3. **本机统计页当前没有"时间段列表"**，需求 §6 要求显示"具体使用时间段" → 需要新增（只查本机 `activity_segments`）。
4. **原生不能写 Flutter 的 SQLite**（双驱动 / schema 漂移 / 锁竞争的既有约束），
   因此 Flutter 退出期间的会话只能进**原生 journal**，再由 Flutter 幂等导入。

### 12.2 本阶段的设计决策（含对需求的两处偏离说明）

| 决策 | 内容 | 依据 |
|---|---|---|
| **单一检测来源** | `AndroidForegroundAppSource.read()` 是唯一入口，读取结果同时发布到**进程内共享快照** `ForegroundAppRegistry`；`PetStateMonitor`（状态）与 `AndroidUsageSessionTracker`（会话）与桥接（界面）**都只读这一份快照**；**不新增第二个轮询任务**（复用 `PetStatePoller`） | 需求 §1.3 / §3.1 / §4 |
| **采集器宿主** | 采集器挂在**现有悬浮前台服务**里（复用同一个 tick）。用户未开启悬浮桌宠时不会有使用统计 → **必须在统计页明示**，不伪装成独立采集 | 需求 §13 末段明确允许"暂时依赖悬浮前台服务，但要在 UI 提示" |
| **会话标识** | sessionId 由**原生生成并写入 journal**（UUID v4），同一段重放时 ID 不变 → Flutter 侧按 `id` 主键幂等导入；**不复用** Dart 的 UUID v5 算法（两端算法耦合没有收益，且原生无该命名空间常量） | 需求 §10.5 / §12 幂等 |
| **本地 device_local_id 按平台区分（用户决策 1，选择 B 但限范围）** | `ActivitySegmentService` / `UsageAnalyticsService` / `tracking_settings` 的 `deviceLocalId` 改为**依赖注入**（`app_scope.dart:381`）：Android = `DeviceIdentity` 持久化的稳定安装 UUID；Windows = 保持现有 `AppConstants.localDeviceId`（`desktop.local`）。**不再写死常量**。理由：让 Android 复用 `desktop.local` 会混淆设备来源，为后续跨设备统计埋坑。**范围限制**：本阶段不把 Windows 数据迁移到 UUID；本地 device_local_id 与服务端 `device_id`（`X-Device-Id` → `devices.id`）**语义分离，不混用**；平台信息仍挂在 `devices.platform` | 用户决策 1；审计第 9 条 |
| **旧数据一次性兼容迁移（绝不重复累计）** | Android 首次以新标识启动时，`_migrateLegacyDeviceRowsIfNeeded` 把早期写在 `desktop.local` 名下的行**只改 `device_local_id`**迁到新标识：`activity_segments` 直接改标识；`daily_usage` 用 `NOT EXISTS` 跳过目标行已存在的天（**绝不相加**）；Windows 一律不动；失败只记日志、不阻塞启动 | 用户决策 1「不能造成重复累计」 |
| **原生 journal 中的身份信息**（**偏离**） | journal 记录**不含** `owner_id` / `device_local_id`，由 Flutter 导入时补齐；理由是 ownerId 与设备身份只有 Dart 侧知道（登录态、`DeviceIdentity`），原生保存一份反而要额外下发与校验 | 需求 §9 建议包含 deviceLocalId；此处按"最小权限 + 避免双份真相"处理 |
| **桌面（launcher）与系统设置** | 按"复用现有规则"处理：与其他应用一样**计时**（分类 `system`），只有 **SystemUI / 输入法 / 权限控制器** 与 **PetLife 自身** 不进会话（与状态联动的过滤器完全同一份实现） | 需求 §8"桌面是否计时按现有规则" |
| **短碎片** | 会话时长 < 2 秒的段**丢弃**（记 `usage.session.discard`），避免大量 1 秒碎片 | 需求 §8 |
| **锁屏** | `ACTION_SCREEN_OFF` 立即结束当前会话（结束原因 `screen_off`），锁屏期间不累计；解锁后重新检测 | 需求 §6.5 |
| **暂停采集** | 复用现有 `tracking.paused`（`tracking_settings` 表 `tracking.paused`）；暂停时结束当前会话、不累计；**状态联动不受暂停影响**（解耦） | 需求 §13 |
| **时间段列表** | 本机统计页新增"今天的应用时间段"（本机 `activity_segments`，按开始时间倒序，限制条数）；进行中会话以"实时增量"呈现，不每秒落库 | 需求 §6 / §11 |

### 12.3 落地范围拆分（4C-5.1A / 4C-5.1B）

**4C-5.1A（已完成，见 §12.4）**：
1. `ForegroundAppRegistry`：进程内共享快照（packageName / appLabel / category / eventTime / detectedAt / source）+ 采集器运行状态；
2. 桥接 `getCurrentForegroundApp`（单一快照出口，17 字段）；
3. Flutter `CurrentActivityProvider`（`watch()` / `current()`）+ Windows / Android / Unsupported 三个实现；
4. 统计页「当前应用」改由该 Provider 提供（不再读 `ActivityTracker` 的 Windows 专用字段），并给出检测来源与状态文案；
5. 设备 ID 依赖注入（`resolveTrackingDeviceLocalId`）+ Android 侧 `desktop.local` → 稳定 UUID 的一次性兼容迁移。

**4C-5.1B（待 4C-5.1A 验收通过后开始）**：
6. `UsageSessionTracker`（纯逻辑）：状态机 `IDLE / TRACKING / PAUSED_SCREEN_OFF / PAUSED_BY_USER / STOPPED`、
   事件时间戳优先、最大会话时长、负时长/时间回退防护；
7. `UsageJournalStore`：`filesDir` 下有界、原子写入、带 `schemaVersion` 的单文件暂存队列（drain / ack / 损坏隔离）；
8. `PetOverlayService` 接入：复用同一 tick 驱动 tracker；`SCREEN_OFF` / 暂停 / `stop` / `onDestroy` 结束会话；
9. 桥接新增：`drainCompletedUsageSessions`、`acknowledgeUsageSessions`、`setUsageCollectionPaused`；
10. `AndroidUsageImportService`：drain → 校验 → `ActivityDao.insert`（幂等）→ 现有 outbox → ack；
11. 统计页新增「今天的应用时间段」区块 + 进行中会话实时增量；
12. 无权限 / 采集器未运行时给出明确文案与授权入口。

**测试与交付**：需求 §18 的 40 条 Kotlin 用例、§19 的 20 条 Flutter 用例、
§20 的服务端回归（协议不改，跑现有测试 + 增加 Android 平台输入用例）、
APK 构建、文档与记忆更新。

> **本阶段不动服务端、不动 4C-3B 菜单、不给菜单加业务功能。**

### 12.4 4C-5.1A 实现记录（已完成，待真机验收）

目标（用户决策 2）：**只修「使用统计」页的当前应用显示**，让设置页与统计页显示**同一个应用**，
两页共用现有 Android 前台快照 / EventChannel，**不新增第二个 `UsageStatsManager` 轮询器**。

#### 改动文件

| 层 | 文件 | 改动 |
|---|---|---|
| 原生 | `android/app/src/main/kotlin/asia/akechi/petlife/overlay/ForegroundAppRegistry.kt` | **新建**：进程内共享快照（`SharedForegroundApp` + `publish/setCollectorRunning/clear`），与 `PetForegroundApp.kt` 同包 |
| 原生 | `.../overlay/PetForegroundApp.kt` | `AndroidForegroundAppSource.read()` 在补标签后**发布到 `ForegroundAppRegistry`**（单一检测入口 = 单一发布点） |
| 原生 | `.../overlay/PetOverlayService.kt` | 采集器 start/stop 时同步 `setCollectorRunning(...)`；`onDestroy` 时 `clear()`；`OverlayLog.diagnosticsEnabled` 跟随 `debugOverlayMode` |
| 原生 | `.../overlay/PetOverlayBridge.kt` | 新增 `getCurrentForegroundApp`（返回 17 字段 Map，含 `available/failureReason/detectionSource/detectionReason/usageAccessAvailable/collectorRunning`）与 `failureReasonOf(...)`、`SNAPSHOT_STALE_MS` |
| Flutter | `lib/activity_tracking/current_activity_provider.dart` | **新建**：`CurrentActivity` 模型 + `CurrentActivityProvider` 接口 + `Unsupported*` + `pollCurrentActivity()`（订阅取消即停定时器） |
| Flutter | `lib/platform/android/android_current_activity_provider.dart` | **新建**：Android 读原生共享快照（1s 轮询既有通道） |
| Flutter | `lib/platform/windows/windows_current_activity_provider.dart` | **新建**：Windows 跟随既有 `ActivityTracker`（**不新增 Win32 轮询**） |
| Flutter | `lib/platform/overlay_pet.dart` | `OverlayPet` 新增 `currentActivity()`；`OverlayStateDiagnostics` 增 11 项前台识别诊断字段；`UnsupportedOverlayPet` 返回 `unsupported-platform-provider` |
| Flutter | `lib/platform/platform_services_contract.dart` | 新增 `createCurrentActivityProvider(...)`、`resolveTrackingDeviceLocalId(...)` |
| Flutter | `lib/platform/android/android_platform_services.dart` | 装配 Android Provider；`resolveTrackingDeviceLocalId → deviceIdentity.ensureDeviceLocalId()` |
| Flutter | `lib/platform/windows/windows_platform_services.dart` | 装配 Windows Provider；`resolveTrackingDeviceLocalId → AppConstants.localDeviceId` |
| Flutter | `lib/app/app_scope.dart` | 新增 `currentActivity` 字段 + `trackingDeviceLocalId`（**依赖注入**替代写死常量）+ `_migrateLegacyDeviceRowsIfNeeded(...)` |
| Flutter | `lib/database/dao/activity_dao.dart` | 新增 `migrateDeviceLocalId(from, to)`（只改标识） |
| Flutter | `lib/database/dao/daily_usage_dao.dart` | 新增 `migrateDeviceLocalId(from, to)`（`NOT EXISTS` 跳过冲突日，**绝不相加**） |
| Flutter | `lib/ui/pages/usage_stats_page.dart` | 「当前应用」改用 `CurrentActivityProvider`；显示「读取中…」/应用名/检测来源/状态提示；移除 Windows 专用 `tracker.isAvailable` 判断 |
| 测试 | `android/app/src/test/.../PetStateTest.kt` | 新增 `ForegroundAppResolverTest`(18) + `ForegroundAppRegistryTest`(6) |
| 测试 | `test/current_activity_provider_test.dart` | **新建**：模型解析 / 文案 / 降级 / `pollCurrentActivity` 共 13 项 |
| 测试 | `test/activity_device_migration_test.dart` | **新建**：设备标识迁移 3 项 |
| 测试 | `test/overlay_pet_controller_test.dart` | `FakeOverlayPet` 补 `currentActivity()` |
| 测试 | `test/platform_isolation_test.dart` | 权限白名单 5→6（新增 `PACKAGE_USAGE_STATS`，改为正则解析真实声明） |

#### 自动测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin 单测 `.\gradlew.bat testDebugUnitTest` | **BUILD SUCCESSFUL**：34 个测试类共 **254** 项，0 失败 0 跳过（含本轮新增 `ForegroundAppResolverTest` 18 + `ForegroundAppRegistryTest` 6） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **629 通过 / 1 跳过 / 0 失败** |
| `flutter build apk --debug --no-pub` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-5.1A-5CF019A1.apk`） |
| APK 大小 / 时间 | **189,174,114 B** / 2026-09-30 02:36:18 |
| APK SHA256 | `5CF019A102EE975E1599648304EB4D5EE822CF8832208D7DE8D1ADD3A4C16E3B` |

> **仪器测试仍阻塞**（本机无设备/无 AVD）：不声称通过，行为以真机验收为准。

#### 已知限制（本增量不解决）

* Android 本地 usage 表**没有 `platform` 列**：跨设备/跨平台区分由服务端 `devices.platform` 负责，
  本地按 `device_local_id` 区分（Android = 稳定 UUID，Windows = `desktop.local`）；
* 4C-5.1A **只做显示**：Android 此时仍**不产生时长记录**（会话采集在 4C-5.1B）；
* 前台识别依附悬浮前台服务：未开启悬浮桌宠时统计页会明示「未采集」。

### 12.5 4C-5.1A 真机验收步骤

前置：卸载旧版（或允许覆盖安装）→ 安装 `petlife-4C-5.1A-5CF019A1.apk`。

1. **授权**：`设置 → 应用 → 特殊应用权限 → 使用情况访问` 授予 PetLife；`设置 → 应用 → 悬浮窗` 允许。
2. **开启桌宠**：启动 PetLife → 开启悬浮桌宠（设置页应能显示「当前前台应用」）。
3. **两页一致（核心）**：打开浏览器 → 进入 `使用统计（本机）` 页 → 「当前应用」应显示**与设置页相同**的应用名，
   且标注检测来源（`前台事件` / `使用统计兜底` / `最近有效应用`）。
4. **切换更新**：切到 Telegram，停留 5~10 秒 → 两个页面都应在合理时间内（≈1 个轮询周期）变为 Telegram。
5. **异常场景文案**：
   * 回到桌面 → 显示 launcher 名（分类 `system`），**不应长期显示「-」**；
   * 撤销使用情况访问权限 → 显示「不可用」+ 提示「未授予使用情况访问权限」；
   * 关闭悬浮桌宠 → 显示「未采集」+ 提示「未开启悬浮桌宠」。
6. **回归检查（不得破坏）**：桌宠仍能按前台应用切换素材、拖拽/吸附/菜单/动态 WebP 正常、Windows 采集与云端筛选不受影响
   （Windows 数据仍在 `desktop.local` 名下，只有 Android 使用新 UUID）。

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

### 12.6 4C-5.1B 实施前审计（需求 §2）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 现有原生前台检测在哪、能否复用 | `AndroidForegroundAppSource.read()`（`PetForegroundApp.kt:631`）→ `ForegroundAppRegistry`（4C-5.1A）。会话采集**只读这份快照**，不新增第二个 `UsageStatsManager` 轮询器 |
| 2 | 采集时机从哪来 | `PetStatePoller`（`STATE_POLL_MS=1500` / 隐藏 5000）驱动的**同一个 tick**；窗口不可见时原先 `stateTick` 直接 return → 本节把"使用统计"提到可见性判断**之前**，隐藏期间也继续记录 |
| 3 | 本地 usage 表与字段 | `activity_segments`：`id(PK)` / `owner_id` / `device_local_id` / `app_key` / `app_name` / `process_name` / `started_at` / `ended_at` / `active_seconds` / `end_reason` / `sync_status` / `created_at` —— **字段齐全，无需改表** |
| 4 | 幂等键 | 段主键 `id`。原生 `session_id` + 本机 `device_local_id` 经 UUID v5 得到确定性 ID（`Ids.usageSession`），配 `INSERT OR IGNORE` |
| 5 | outbox 如何接收 | `OutboxProducer.buildPayloadFromRow` + `SyncOutboxDao.enqueue`；本阶段新增 `enqueueAllWith(exec, entries)`，让"业务行 + outbox"能在**同一事务**里提交 |
| 6 | 服务端协议是否需要改 | **不需要**。`activity_segments` 主键 `(user_id, id)` + LWW 已能去重（`server/app/models/activity.py:86-89`）；`devices.platform` 已支持 `android`；`app_key ≤128 且不含路径分隔符`，包名满足；`end_reason ≤32`，本阶段的取值最长 19 字符 |
| 7 | 本地设备 ID 参与哪些计算 | 只参与**本地归属**与幂等；上传时 `device_id` 由引擎注入服务端注册设备 ID（`X-Device-Id`），两者**语义分离**（决策 1） |
| 8 | Flutter 退出后能否写库 | 不能（`AppDatabase.close()`）→ 这正是必须有原生 journal 的原因 |
| 9 | 暂停开关在哪 | `tracking_settings.tracking.paused`（Flutter 权威）+ 本阶段新增原生 `PetOverlayStore.usageCollectionPaused`（服务在 Flutter 不在时也能一致） |

**审计结论：不需要任何数据模型变更（无 SQLite 迁移、无服务端迁移），因此按需求 §15.2 不暂停，直接进入实现。**

### 12.7 4C-5.1B 实现记录（已完成，待真机验收）

#### 12.7.1 改动文件

**原生（Kotlin）**

| 文件 | 改动 |
|---|---|
| `.../overlay/UsageSessions.kt` | **新建**：`UsageSessionEndReason`（7 个 wire 值）、`UsageSessionRecord`、`OpenUsageSession`、`UsageObservation`、`UsageSessionConfig`、`AndroidUsageSessionTracker`（纯逻辑状态机） |
| `.../overlay/UsageSessionJournal.kt` | **新建**：`filesDir/PetLife/usage_journal/` 下的暂存队列（`pending.jsonl` + `open.jsonl`）；制表符分隔 + 百分号转义（**不引 `org.json`**，保证可在 JVM 单测）；临时文件 + rename 原子写；条数上限 2000、损坏行隔离 |
| `.../overlay/UsageSessionRecorder.kt` | **新建**：状态机 + journal 的编排（启动恢复 `process_recovery`、定期写开放检查点、先落盘再算成功） |
| `.../overlay/PetOverlayService.kt` | 创建记录器并 `onServiceStarted`；`stateTick` 改为"先保证快照新鲜 → 喂一次观察 → 再做素材分支"（隐藏期间也统计）；息屏 / 停止 / 销毁 / 权限撤销四处收尾；新增 `usageRecorderOrNull()` 与 `USAGE_SNAPSHOT_MAX_AGE_MS` |
| `.../overlay/PetOverlayBridge.kt` | 新增 6 个方法：`getCurrentUsageSession` / `readPendingUsageSessions` / `acknowledgeUsageSessions` / `getUsageCollectorState` / `setUsageCollectionPaused` / `updateUsageIdentity`；桥侧自持一份 journal 句柄（**服务未运行时也能导入**） |
| `.../overlay/PetOverlayStore.kt` | 新增 `usage.paused` 与 `usage.device_local_id` 两个键 |

**Flutter**

| 文件 | 改动 |
|---|---|
| `lib/activity_tracking/android_usage_session.dart` | **新建**：`AndroidUsageSession`（严格解析）+ `UsageCollectorState` |
| `lib/activity_tracking/android_usage_import_service.dart` | **新建**：单任务互斥的幂等导入器（归属过滤 → 登记应用 → 构建行与 outbox → **一个事务**提交 → 事务成功后才确认） |
| `lib/activity_tracking/application_repository.dart` | 新增 `ensureSeenFromPlatform(...)`（显示名/分类由原生给出，**用户手工设定永远优先**） |
| `lib/activity_tracking/usage_analytics_service.dart` | 新增 `timeline(window)`（时间段列表）、`windowFor(range)`（界面与统计共用同一窗口）；`UsageOverview.deviceMetricsAvailable`；无设备级数据时用会话推出首末活跃 |
| `lib/activity_tracking/models/usage_stats.dart` | 新增 `UsageSegmentRow`；`UsageOverview.deviceMetricsAvailable` |
| `lib/core/ids.dart` | 新增 `Ids.usageSession(deviceLocalId, sessionId)` |
| `lib/database/dao/sync_outbox_dao.dart` | 新增 `enqueueAllWith(exec, entries)`（在调用方事务里入队） |
| `lib/platform/overlay_pet.dart` | 接口新增 5 个读/写方法 + `UnsupportedOverlayPet` 降级实现 |
| `lib/platform/android/android_overlay_pet.dart` | MethodChannel 实现（`readPendingUsageSessions` 单条解析失败即跳过，不中断整批） |
| `lib/sync/sync_engine.dart` | 新增可选 `beforePush` 钩子（推送前把原生 journal 补进库，需求 §7） |
| `lib/app/app_scope.dart` | 新增 `trackingDeviceLocalId` / `androidUsageImport`；`startActivityTracking` 先同步身份+暂停再导入；`saveTrackingSettings` 改用注入的设备标识**并同步暂停到原生**；新增 `importAndroidUsageSessions()` |
| `lib/ui/pages/usage_stats_page.dart` | 新增「使用时间段」卡片；概览按 `deviceMetricsAvailable` 如实降级；当前会话时长/采集状态/最近更新时间；生命周期恢复时导入+刷新 |
| `lib/ui/widgets/overlay_pet_card.dart` | 设置页新增「使用记录采集（Android）」诊断区（采集状态 / 当前会话 / 待导入 / 最近导入时间与错误） |
| `lib/ui/pages/settings_page.dart` | 传入 `services` |

**测试**

| 文件 | 内容 |
|---|---|
| `android/app/src/test/.../UsageSessionsTest.kt` | **新建**：`UsageSessionTrackerTest`（15）+ `UsageSessionJournalTest`（11） |
| `test/android_usage_import_test.dart` | **新建**：解析 / 确定性 ID / 导入 12 项 / 与原生对齐 3 项 = 19 项 |
| `test/usage_timeline_test.dart` | **新建**：时间段排序 / 跨午夜 / 进行中 / 设备过滤 / 日期边界 / 同窗口 / Android 无设备级指标 = 9 项 |
| `test/overlay_pet_controller_test.dart` | `FakeOverlayPet` 补 5 个新方法（供导入测试复用） |

#### 12.7.2 会话状态机（纯逻辑，可 JVM 单测）

```
观察（共享快照 → UsageObservation）
  ├─ 包名空（无权限 / 无事件 / 缓存过期） → 容错窗口 6s，超时按"最后一次可靠时间"结束（collector_unavailable）
  ├─ 与当前会话同包名                → 计入 [creditUpTo, now]（单次夹住 4.5s）
  ├─ 当前没有会话 + 可计入            → 立即开段（不延迟，避免白丢时间）
  ├─ 当前没有会话 + 桌面/系统界面       → 不记录（不计入普通应用时长）
  └─ 已有会话、但前台换成了别的应用      → 切换确认窗口 1.5s
         ├─ 候选被证伪（又回到原应用）→ 清除候选，从 creditUpTo 一次性补齐这段时间
         └─ 候选稳定 → 旧会话结束于"候选首次出现"时刻；
                       候选可计入则从该时刻开新段，否则（桌面/系统界面）只结束、不开新段
显式结束（不需要确认窗口）：熄屏 screen_off / 服务停止 service_stopped /
  暂停 collection_paused / 权限撤销 permission_revoked / 进程重启 process_recovery
丢弃规则：activeSeconds < 2 的碎片不写 journal（记 usage.session.discard）
```

**为什么结束时刻是"候选首次出现"而不是"确认时刻"**：新会话从候选首次出现起算，
若旧会话结束于确认时刻就会出现最多 1.5 秒的**重叠计数**；反之若旧会话停在最后一次
采样、新会话也停在最后采样，则会白丢一段时间。取"候选首次出现"是唯一自洽的切点。

#### 12.7.3 journal 格式与恢复

* 文件：`filesDir/PetLife/usage_journal/pending.jsonl`（已结束待导入）与 `open.jsonl`（进行中检查点）。
* 一行一条记录，**11 个字段固定顺序**，制表符分隔，`%`/`\t`/`\n`/`\r` 做百分号转义。
  不用 JSON 的原因：`org.json` 在 JVM 单测里是未实现的 Android 桩，会让这一层无法测试；
  字段全是扁平值，手写编解码更可控。
* **原子写**：先写 `*.tmp` 并 `fsync`，再 rename 覆盖 —— 写到一半崩溃不会破坏已有记录。
* **有界**：超过 2000 条丢弃最旧的（`usage.journal.trimmed`）。
* **隔离**：解析失败的行跳过并计数（`usage.journal.corrupt`），绝不阻塞其余导入。
* **恢复**：每 10 秒写一次 `open.jsonl`；服务重启读到它就按 `process_recovery` 关闭，
  结束时间取检查点里的最后一次可靠时间 —— **绝不把进程离线期间算成使用时长**。

#### 12.7.4 本地 ID 与服务端设备 ID 的映射

| 概念 | 取值 | 用途 |
|---|---|---|
| 本地 `device_local_id` | Android = `DeviceIdentity` 稳定安装 UUID；Windows = `desktop.local` | 本地归属 + 幂等（`uuidv5(device_local_id + session_id)`） |
| 原生 journal 的 `device_local_id` | Flutter 通过 `updateUsageIdentity` 下发并持久化 | 记录自描述；导入时若与本机不一致则跳过并确认（不污染本机统计） |
| 服务端 `device_id` | 引擎推送时注入（`X-Device-Id` → `devices.id`） | 云端归属；平台信息在 `devices.platform` |

三者**语义分离、不混用**；服务端**无需任何改动**。

#### 12.7.5 自动测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin `testDebugUnitTest` | **BUILD SUCCESSFUL**：36 个测试类共 **280** 项，0 失败（新增 `UsageSessionTrackerTest` 15 + `UsageSessionJournalTest` 11） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **658 通过 / 1 跳过 / 0 失败**（新增 19 + 9 项） |
| `flutter build apk --debug --no-pub` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-5.1B-33856514.apk`） |
| APK 大小 / 时间 | **189,212,984 B** / 2026-09-30 03:10:06 |
| APK SHA256 | `33856514148ABA3DA818E8089138DB7CC941BCDF6DE62AC4BB2FF0312D26E35E` |

#### 12.7.6 本机无法执行、必须真机/其他环境完成的验证（**不得声称通过**）

| 项 | 原因 |
|---|---|
| `connectedDebugAndroidTest`（仪器测试） | `adb devices` 无设备、`emulator -list-avds` 无可用 AVD |
| 真实 `UsageStatsManager` / `ACTION_SCREEN_OFF` 行为 | 只有真机能验证（JVM 里是未实现的桩） |
| 真机进程被杀后的 `process_recovery` | 需要系统级杀进程 |
| 服务端 pytest 回归 | 本机 `python` 只是 WindowsApps 执行别名占位（`python -c` 退出码 9009），**没有可用的 Python 环境**；协议未改，风险集中在既有 `sync` 用例 |

### 12.8 4C-5.1B 真机验收步骤

前置：安装 `petlife-4C-5.1B-33856514.apk`；授予**使用情况访问**与**悬浮窗**权限；开启悬浮桌宠。

1. **正常记录**：打开浏览器约 20 秒 → 切到 Telegram 约 15 秒 → 返回 PetLife。
2. **累计正确**：「使用统计（本机）」应能看到浏览器与 Telegram 各自有累计时长。
3. **时间段正确**：时间段列表出现两条记录，开始 / 结束时间与持续时长和实际操作一致；
   顺序为**时间倒序**；结束原因显示「切换到其他应用」（最后一条应为「使用中」）。
4. **无碎片**：连续快速切换 5~6 个应用，确认没有大量 1~2 秒的碎片记录。
5. **暂停**：点「暂停记录」→ 正常使用手机 10 秒 → 「暂停记录」期间时长**不再增长**；
   恢复后确认从**新会话**开始（不补算暂停期间）。
6. **飞机关屏**：熄屏 30 秒再解锁，确认没有把熄屏时间算成使用时长；会话被结束（原因「熄屏 / 锁屏」）。
7. **Flutter 关闭期间仍记录**：从最近任务划掉 PetLife（桌宠仍在）→ 切几个应用 → 重新打开 PetLife
   → 确认这段时间的记录被恢复并导入（设置页诊断区「待导入记录」应归零）。
8. **不重复累计**：反复打开统计页 / 反复点刷新 / 手动触发同步，确认同一个应用的时长**不翻倍**。
9. **断网补传**：开飞行模式使用几个应用 → 关闭飞行模式 → 等待同步完成
   → 在 Windows 端「云端统计」选择本 Android 设备，确认能查到累计时长与时间段。
10. **账户隔离**：换另一个账号登录，确认看不到先前账号的云端数据；本机统计仍在。
11. **回归**：桌宠素材切换 / 拖动 / 吸附 / 菜单 / 动态 WebP 均正常；Windows 端采集与云端筛选不受影响。

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

### 12.9 已知限制与未完成项

* **采集依附悬浮前台服务**：未显示桌宠时不会产生新记录（统计页已明示「未采集（桌宠未运行）」）；
  隐藏（≠ 停止）时仍按 5 秒降频继续记录。
* **Android 没有设备级指标**：不产出 `daily_usage`，因此概览只给「今日总使用时长（应用合计）」，
  屏幕会话 / 空闲时间**不展示也不填 0**（`deviceMetricsAvailable=false`）。
* **`device_locked` 未单列**：Android 上熄屏与锁屏是同一个广播，统一记 `screen_off`（不伪造区分不出的原因）。
* **未提供"自定义日期"筛选**：本阶段只做今天 / 昨天 / 最近 7 天 / 本周（需求 §8.3 允许留到后续）。

### 12.10 4C-5.1B 补充修复：跨端云端统计不一致

> 真机反馈：手机端能看到部分设备的使用时长；Windows 端只能看到 Windows 设备的数据；
> Windows 云端页选 `PLF110 · Android` 提示"当天没有云端记录"；设备列表里有多条
> Android/Windows 设备。暂不进入 4C-6，先做跨端一致性排查与修复。

#### 12.10.1 排查结论（基于真实数据，非推测）

Windows 客户端指向的服务端是 `http://8.163.22.28:8000`（见本机客户端库
`account_session_state.server_base_url`）。它的云端缓存里保存着**服务端当时返回的原始结果**，
因此可以离线还原"Windows 端到底看到了什么"：

| 设备（服务端 id） | 名称 | 平台 | model | 2026-09-29 会话数 | 2026-09-29 总秒数 |
|---|---|---|---|---|---|
| `e3ee93ca-…` | 2026-10 | windows | — | 589 | 16167 |
| `85bff623-…` | 超能吃菜Oo | windows | — | 54 | 3231 |
| `fd8ce699-…` | PLF110 | android | PLF110 | **0** | **0** |
| `22faef65-…` | 手机 | android | PLF110 | **0** | **0** |

* `all`（全部设备）= 19398 秒 = 16167 + 3231 —— **两台 Android 设备贡献 0**；
* 本机 Windows 设备的 `device_server_id` = `e3ee93ca-…`，与设备列表里的 `is_current` 一致
  → **Windows 上传用的服务端设备 UUID 是正确的**；
* 本机（Windows）`sync.deviceLocalId` = `06e572d1-…`，与本地开发库里那台 Windows 设备的
  `device_local_id` 完全一致 → **注册键就是 `DeviceIdentity` 的 UUID，没有混用本地标识**。

**结论：Windows 端"选 Android 设备就空"是事实正确，不是显示缺陷** —— 服务端上那两台
Android 设备的 segment 数确实为 0。真正的问题是"Android 为什么一段都没传上去"，
以及"同一台手机为什么出现两条设备记录"。

#### 12.10.2 根因

| # | 根因 | 证据 | 性质 |
|---|---|---|---|
| 1 | **Android 在 4C-5.1B 之前根本不产生使用记录** | 4C-5.1（含 5.1A）阶段原生只做前台识别、**一条 session 都不写**；5.1B 才引入原生会话采集 + journal + 导入，其 APK 今天才产出。09-29 那台手机跑的是 5.1A 版本 → 无记录可传 | 功能尚未交付到设备，**不是同步缺陷** |
| 2 | **同一台手机出现两条设备记录**（`PLF110` / `手机`，同 `model_name`） | `device_local_id` 是"应用自己生成、存在应用库里的随机 UUID"（`DeviceIdentity`），其稳定性保证是"**卸载前**不变"（决策 1 原文）。重装 / 清除数据会生成新 UUID → 服务端按 `(user_id, device_local_id)` 新建一行，旧行保留成历史 | 设计内行为；但**列表无法区分**才是缺陷 |
| 3 | **Windows 云端页本身有 4 个真实缺陷** | 见下 §12.10.3 | 真缺陷，必须修 |

> 根因 2 的补充：代码里**没有**任何"重新生成 device_local_id"的生产路径
> （`AppDatabase.purgeOwner` 无调用点，`sync.deviceLocalId` 只在缺失时才生成）。
> 因此只要不重装/清数据，同一台设备不会分叉。

#### 12.10.3 修复清单（全部在客户端；服务端协议与数据模型不变）

| 文件 | 修复 | 对应的验收项 |
|---|---|---|
| `lib/sync/cloud_statistics_controller.dart` | `_invalidate()` 除递增代次外**一并清空** `_summary/_timeline/_fetchedAt/_errorMessage` —— 切换设备瞬间不再出现"新设备名 + 旧数字"；请求失败也不会用旧设备的数字配离线横幅 | 6 |
| 同上 | 在途去重键从 `queryKey` 改为 **`epoch + queryKey`** —— 切设备/切日期后即使旧请求仍在途，也会为新查询**真正发起请求**（此前会复用旧 Future 并被 stale 丢弃，界面永久停在旧数据） | 4 / 6 |
| 同上 | `refresh({manual})` 的 `manual` 从"死参数"变为**真强制刷新**：重新拉设备列表 + 不被在途去重吞掉 | 4 |
| 同上 | 设备列表**每次刷新都拉**（与统计并发，失败只记日志）—— 新注册的设备不用重启就能看到 | 1 |
| 同上 | 账户变化（退出重登/换号）**自动清空**上一个账户的数据 | 8 |
| 同上 | 时区/今日改为**每次刷新重算**（此前只在 `initialize` 算一次） | 6（时区一致性） |
| `lib/ui/pages/cloud_statistics_page.dart` | 一次性 `_started` 闩锁改为**可重复触发**的 `_ensureStarted()`（带 `_initializing` 闸门防递归）：退出登录 → 重新登录（同一 State）后会重新初始化，不再永远停在空态 | 5 |
| 同上 | 空态**不再与"未初始化"共用文案**：新增"正在准备云端统计…"，空态文案带上**当前选中的设备名** | 用户体验 |
| 同上 | 设备下拉标签补上「型号 / 本机 / 已撤销 / 最近活动」，用于区分同名设备 | 1 / 3 / 7 |
| `lib/sync/cloud_statistics_cache.dart` | 缓存键加入 **`server_base_url`**（原为 `type|device|date|timezone|app`）；account 仍由表主键 `account_user_id` 承担 | 5 |
| `lib/app/app_scope.dart` | 把 `AuthenticatedApi.baseUrl` 注入缓存 | 5 |
| `lib/ui/widgets/overlay_pet_card.dart` | 设置页新增「云端归属」诊断：本机设备标识 / **服务端设备 ID** / 待上传条数 / 最近同步成功 —— 手机上即可自证整条链路 | 排查要求 1、4 |
| `server/tools/diagnose_cloud_consistency.py` | **新增只读诊断脚本**：按账户列出全部设备（UUID / device_local_id / 名称 / 平台 / 最近活动）+ 指定某天各设备的 segment 数 / 总秒数 / 最早最晚 + 自动标记"同名同平台分叉" | 排查要求 2、3 |

#### 12.10.4 不变项（明确不做什么）

* **服务端不改**：`(user_id, id)` 复合主键 + LWW 已能去重；`devices.platform` 已支持 android；
  **211 项服务端测试全部通过**（见 §12.10.5）；
* **不删除任何数据**：两台 Android 设备的历史段都是 0 段，没有需要合并的数据；
  旧设备行的处置方案是「保留为历史设备 + 可在账户页撤销」，而不是删库；
* **不把本地 `device_local_id` 与服务端 `device_id` 混用**：三者语义分离（§12.7.4）。

#### 12.10.5 测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin `testDebugUnitTest` | **BUILD SUCCESSFUL**（36 类 / 280 项 / 0 失败，本次未改原生） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **669 通过 / 1 跳过 / 0 失败**（新增 11 项；连续 4 次全量运行均通过） |
| **服务端 pytest**（`server/.python/python.exe -m pytest`） | **211 passed**（本次首次实跑成功 —— 之前误判为"本机无 Python"，实际仓库内嵌了 CPython 3.12 + pytest） |
| `flutter build apk --debug` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-5.1B-fix-9A2CBE6C.apk`） |
| APK 大小 / 时间 / SHA256 | **189,219,822 B** / 2026-09-30 14:37:30 / `9A2CBE6C9D772A177DF98511268A67FA988CF35F11A04E9846EBBDCDF8387979` |
| `flutter build windows --release` | 成功 |
| Windows Release | `petlife/build/windows/x64/runner/Release/`（入口 `petlife.exe`；改动所在代码在 `data/app.so`，8,487,816 B / 2026-09-30 14:38:23，SHA256 `3A5B628EA0ECA8E3CFD466A0271EA82B739ACCB1354E7BF12502A2BD59990B04`） |

#### 12.10.6 真机 / 端到端验收步骤（对应本次验收标准）

0. 两端都升级到本次构建（Android 用新 APK，Windows 用新 Release）。
1. **设备列表一致**：两端打开云端统计，设备下拉应都能看到**同一批设备**
   （含"本机/已撤销/型号/最近活动"标注）；新注册的设备不需要重启即可出现。
2. **Android 开始产生数据**：在手机上正常使用几个应用（浏览器 20s、Telegram 15s）→
   手机设置页「云端归属」应显示「待上传 0 条」且「最近同步成功」为刚刚 →
   回到 Windows，选那台 Android 设备，应能看到应用累计与时间线。
3. **切换设备不串数据**：在 Windows 云端页来回切换设备，切换瞬间应立刻显示加载态
   （不允许出现"新设备名 + 旧设备数字"）。
4. **强制刷新**：反复点右上角刷新，每次都应有真实请求；数据保持一致且**不翻倍**。
5. **退出重登 / 重启客户端**：退出登录再登录（不重启），云端页应自动重新加载，不再停在空态。
6. **重复同步不增加总时长**：连续点刷新 / 触发多次同步，同一应用时长不变。
7. **账户隔离**：换另一个账号登录，看不到上一个账号的任何设备与统计。
8. 同一账号同一天，两端选同一台 Windows 设备 / 同一台 Android 设备，应用累计与时间线一致。

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

## 12.11 Phase 4C-6A：状态联动接通（前台应用 → 状态 → 素材）

> 真机反馈：**前台应用识别与应用分类已经工作，但应用变化没有真正驱动悬浮桌宠切换状态与素材。**
>
> 本阶段只做状态联动，不新增环形菜单业务功能。

### 12.11.1 审计结论：链路是通的，断在"规则"上

4C-5 已经把整条链路搭好了（`AndroidForegroundAppSource → ForegroundAppRegistry →
PetStateMonitor → PetStateDebouncer → NativeAssetSelector → PetImageLoader`），
因此**不重写**，只修断点。逐行核对后，真正的断点有四处：

| # | 断点 | 证据 | 后果 |
|---|---|---|---|
| **1（主因）** | `AppCategoryStateMapper` 把 **browser / system / other 一律映射到 `default`** | `PetState.kt:325-327`（Dart 侧 `activity_state_mapper.dart:131-133` 同） | 打开浏览器、回到桌面、切到系统设置 —— **日常最高频的三类场景全部不产生状态变化** → 防抖 `Ignored("状态未发生变化")` → 桌宠毫无反应 |
| 2 | 防抖的"目标 == 当前 → 不上报"叠加素材去重 | `PetState.kt:424-427` + `PetOverlayService.kt:838-844`（assetId 相同跳过） | 即便状态变了，回退到同一张默认素材时视觉上也看不出变化 |
| 3 | 映射快照只在"服务在运行"时推送 | `overlay_pet_controller.dart:270` | 用户没点「显示悬浮桌宠」时原生手里没有映射（`MAPPING_MISSING`） |
| 4 | 缺少**自动开关**、**具体应用规则**、**命中规则诊断** | 全仓检索 `automaticState` / `app_state_rule` 无命中 | 无法关闭自动联动；无法按应用覆盖；出问题看不出来为什么 |

> 关于 #1 的历史原因：4C-5 当时的注释写着"浏览器故意映射为 default，因为仅凭进程
> 无法区分工作还是娱乐（需求「十」）"。4C-6A 的需求明确要求浏览器也要有反应，
> 因此在**既有 11 个状态**内重新选值（见 §12.11.2），并保留原注释解释这次变更。

### 12.11.2 实际使用的 wire value（**不新增任何状态命名**）

**状态（11 个，与 Dart `SystemState.wireName` 逐字一致）**：
`error / manual / concerned / tired / happy / gaming / focused / social / entertained / away / default`

**分类（8 个，与 Dart `AppCategory.wireName` 逐字一致）**：
`development / productivity / gaming / social / entertainment / browser / system / other`

**默认分类规则表（4C-6A 生效值）**：

| 分类 | 状态 | 说明 |
|---|---|---|
| development | `focused` | 不变（IDE / 终端） |
| productivity | `focused` | 不变（办公软件） |
| **browser** | **`focused`** | **变更**：既有状态里没有 reading/curious，"看网页"最接近"专注" |
| gaming | `gaming` | 不变 |
| social | `social` | 不变（Telegram / 微信） |
| entertainment | `entertained` | 不变（视频 / 音乐） |
| **system** | **保持上一个稳定状态** | **变更**：设置页 / 权限弹窗无法判断意图，硬切会让桌宠乱跳 |
| other | `default` | 不变（未归类） |
| **桌面（launcher）** | **`away`** | `system` 分类的特例；项目既有语义里 idle 就是 `away`（与"用户空闲 → away"一致） |

> 规则**只有一份**：Dart 的 `ActivityStateMapper.categoryStateRules` 是权威表，
> 随快照下发；原生 `AppCategoryStateMapper` 是**同语义的内置兜底**（快照缺失时用）。
> 两侧都有单测钉住取值（`activity_state_mapper_test.dart` / `AppCategoryStateMapperTest`）。

### 12.11.3 Flutter → Kotlin 配置快照

`OverlayStateMapping`（`lib/platform/overlay_state_mapping.dart`）在原有
`revision / characterId / defaultAsset / states` 之上**追加 4 个可选字段**：

| 字段 | 类型 | 缺省 | 用途 |
|---|---|---|---|
| `automaticEnabled` | bool | `true` | 自动联动总开关（设置页） |
| `defaultStateKey` | String? | null | 默认状态（诊断用） |
| `categoryRules` | Map<分类, 状态> | 空 | 分类 → 状态规则；**不在表里 = 保持上一个状态** |
| `appOverrides` | Map<包名, 状态> | 空 | 具体应用覆盖（优先级最高） |

* **不提升 `schemaVersion`**：新字段全部可选，老快照/老原生照样工作；提升反而会让升级瞬间"没有可用映射"。
* **`signature` 覆盖新字段** —— 否则"只关掉开关"会被去重吞掉，原生永远收不到。
* 原生持久化在现有 `PetOverlayStore`（`overlay.state.automatic_enabled` /
  `overlay.state.category_rules` / `overlay.state.app_overrides`），规则表用
  `键=值` 换行编码（与 journal 同样不引 JSON 依赖，保证可 JVM 单测）。
* 写入仍是**单次原子提交**（`editor.apply()` 一次性提交映射 + 素材 + 规则），
  不会出现"素材更新了、规则还没更新"的中间态。

### 12.11.4 防抖状态机（复用 4C-5 的既有实现）

`PetStateDebouncer`：候选需**连续出现 2 次且持续 ≥1000ms** 才提交；
另有 **400ms 快速切换抑制窗**；`fastPath`（显示/解锁后的首次检测）跳过稳定性门槛。
阈值集中在 `PetStateDebouncer` 常量里，没有散落硬编码。

新增的两条规则：
* **"保持上一个稳定状态"**（`CategoryStateOutcome.Hold`）：只清候选、不换素材；
* **自动开关关闭**：直接返回 null（不干预），但**手动覆盖仍然生效**。

只有以下任一变化才会触发渲染切换：`state_key` 变化 / `asset_id` 变化 / 文件版本变化 ——
因此**同一应用重复快照、同一分类的不同应用都不会重复解码**（有单测钉住）。

### 12.11.5 素材回退顺序（复用既有 `FallbackChain` / `NativeAssetSelector`）

```
① 当前状态的显式映射素材
② 当前状态下用户收藏/选中的素材（FallbackChain 内的既有规则）
③ default 状态映射素材
④ 当前角色任一有效素材
⑤ 全部失败 → 保持当前可显示素材并显示**可见的**错误占位（绝不透明/黑框）
```

### 12.11.6 手动覆盖行为（本阶段口径）

| 操作 | 行为 |
|---|---|
| 设置页「状态调试器 → 手动覆盖」 | 立即生效、不等防抖；期间不响应自动切换；**持久化**，服务重启仍生效 |
| 「恢复自动」 | 清除覆盖 → 下一次 tick 立即按当前前台应用重新解析（`fastPath`） |
| 「根据当前应用自动切换桌宠状态」开关 | 关闭后不提交自动状态；**前台识别与使用时长统计不受影响**；重启保持关闭 |
| 收藏素材按钮 | 只改变"该状态下的优先素材"（既有 `FallbackChain` 语义），**不关闭自动模式** |

### 12.11.7 改动文件

| 层 | 文件 | 改动 |
|---|---|---|
| Kotlin | `overlay/PetState.kt` | `CategoryStateOutcome`（Mapped/Hold）；`AppCategoryStateMapper.outcomeFor(category, isLauncher)`（browser→focused、system→Hold、桌面→away）；`PetStateRules`；`NativePetStateMapping` 增 3 字段 + `rules()`；`NativePetStateMappingParser` 解析/校验规则表（未知状态与未知分类**逐条丢弃**，字段缺失**沿用上一次**） |
| Kotlin | `overlay/PetStateMonitor.kt` | 注入 `isLauncher`；`tick(..., rules)`；规则优先级（app → category → built-in → default）；Hold 分支；新增诊断 `lastMatchedRule` |
| Kotlin | `overlay/PetOverlayService.kt` | 创建 monitor 时注入 `homePackages`；缓存 `stateRules` 并在 `updateStateMapping` 后刷新；`stateTick` 传规则；诊断新增 2 字段 |
| Kotlin | `overlay/PetOverlayStore.kt` | 持久化/读取/清理 3 个新键（`键=值` 紧凑编码） |
| Kotlin | `overlay/PetOverlayBridge.kt` | `stateDiagnostics()` 增 `automaticStateEnabled` / `matchedRule` |
| Flutter | `activity_tracking/activity_state_mapper.dart` | **规则表集中**：`categoryStateRules` / `categoryStateNotes`（唯一权威表）；browser→focused；system→返回 null（不干预） |
| Flutter | `platform/overlay_state_mapping.dart` | 快照增 4 字段 + `toJson` + `signature`；`buildOverlayStateMapping` 增入参 |
| Flutter | `ui/mobile/mobile_shell.dart` | 下发自动开关 + 规则表 + 默认状态 |
| Flutter | `settings/app_settings.dart` / `settings_controller.dart` | 新增持久化开关 `overlayAutomaticState`（默认开） |
| Flutter | `platform/overlay_pet.dart` | 诊断增 `automaticStateEnabled` / `matchedRule` + 中文说明 |
| Flutter | `ui/widgets/overlay_pet_card.dart` | 新增「根据当前应用自动切换桌宠状态」开关（切换后立即重新下发快照）；诊断新增「自动切换配置 / 命中规则」 |
| 测试 | `android/.../PetStateTest.kt` | 新增 `AppCategoryStateMapperTest` 扩展 + `PetStateMonitorTest` 7 项 + `NativePetStateMappingRulesTest` 5 项 |
| 测试 | `test/activity_state_mapper_test.dart` | 更新浏览器/系统分类断言 + 规则表契约 |
| 测试 | `test/overlay_state_mapping_4c6a_test.dart` | **新建**：快照新字段 / 去重签名 / 规则表契约 11 项 |

### 12.11.8 测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin `testDebugUnitTest` | **BUILD SUCCESSFUL**：37 个测试类 **302** 项，0 失败（4C-5.1B 为 280） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **680 通过 / 1 跳过 / 0 失败**（4C-5.1B 为 669） |
| `flutter build apk --debug` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-6A-3C1AF326.apk`） |
| APK 大小 / 时间 / SHA256 | **189,227,155 B** / 2026-09-30 15:19:16 / `3C1AF326ED627A34EA53E4797AEA346188C1D082E4C05FF9606A148B014DE6D7` |
| `flutter build windows --release` | 成功 |
| Windows Release | `petlife/build/windows/x64/runner/Release/`（入口 `petlife.exe`；改动代码在 `data/app.so`，8,487,816 B / 2026-09-30 15:19:57，SHA256 `125693FD0B0D5AB4381671D04FAC431ECA7DF5EB50B5097D66CC5D44AA8E43F9`） |

### 12.11.9 真机验收步骤

**基础联动**
1. 设置页打开「根据当前应用自动切换桌宠状态」。
2. 打开浏览器，等约 2 秒 → 桌宠切到 reading/focused 对应素材（诊断「命中规则」显示"内置分类规则"）。
3. 打开 Telegram → 切到 social 素材。
4. 打开游戏 → 切到 gaming 素材。
5. 返回桌面 → 稳定后切到 `away`（诊断「命中规则」显示"桌面 / 空闲"）。

**防抖**
6. 在两个应用间快速来回切 → 不连续闪图。
7. 下拉通知栏 / 弹权限窗 / 进最近任务 → 桌宠不乱跳（诊断显示"系统界面：保持上一个状态"）。
8. 两个同分类应用互切（Telegram ↔ 微信）→ 不重复加载同一素材。

**素材**
9. 静态图与动态 WebP 各自验证一次。
10. 某状态没有映射素材 → 回退到默认素材（诊断「当前状态素材」显示回退级别）。
11. 删掉正在用的映射素材 → 不出现透明框/黑框。
12. 换角色 → 自动联动使用新角色的映射。

**后台**
13. 回到手机桌面继续切应用 → 桌宠仍变化。
14. 划掉 PetLife 主界面（保留前台服务）→ 继续切应用 → 仍变化。
15. 停止再重新启动悬浮服务 → 规则与开关仍在（持久化生效）。

**手动与自动**
16. 状态调试器手动覆盖某状态 → 不被自动切换顶掉。
17. 点「恢复自动」→ 立刻切回当前应用对应状态。
18. 关闭自动开关 → 切应用不再换图；**使用统计仍继续增长**。
19. 重新打开开关 → 立刻恢复联动（不需要再切一次应用）。

**回归**
20. 桌宠位置/尺寸不变、不抽动；菜单展开时状态变化不导致几何异常。
21. 拖动、吸附、菜单、动态 WebP、使用统计、跨端同步均正常。

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

### 12.11.10 尚需真机确认 / 本阶段未做

* **真机确认**：真实 `UsageStatsManager` 事件驱动的联动时延、厂商 ROM 下 launcher 包名是否
  被 `queryIntentActivities(CATEGORY_HOME)` 完整覆盖、切应用时的动画是否平滑。
* **仪器测试仍阻塞**（无设备 / 无 AVD），不得声称通过。
* **具体应用覆盖规则只有数据接口**：原生的解析、优先级与回退**已实现并有单测**，
  但本阶段**没有编辑入口**（需求 §6 明确允许"只实现默认规则与数据接口"）。
  后续做规则编辑页时，只需往 `OverlayStateMapping.appStateOverrides` 里填条目即可。
* **未新增第二个轮询器**：状态解析仍复用 `PetStatePoller` 的同一个 tick（需求 §3）。

### 12.11.11 真机失败：切换应用后「当前桌宠状态」始终为 default（诊断与修复）

**真机现象**：前台应用可正常识别，但切到浏览器 / Telegram 后「当前桌宠状态」始终是 `default`。

**排查方式**：不做猜测式改动，而是先把"状态提交链路"的每一步都变成**可判定**的可读值
（§12.11.12 的 17 项诊断），再按 分类 → 规则 → 防抖提交 的顺序定位。

#### 根因 1（**主根因，能完整解释现象**）：界面读的不是原生状态

Android 的自动状态切换发生在**原生悬浮服务**里；而 Flutter 侧的
`stateEngineSnapshot`（状态引擎）在 Android 上**不会被前台事件驱动** ——
`MobileShell._bootstrap()` 里的采集器是"不可用"实现（其注释即写明"采集器据此不会驱动桌宠状态"）。

而这两处界面读的正是状态引擎：

| 位置（修复前） | 代码 | Android 上的后果 |
|---|---|---|
| 使用统计页「当前桌宠状态」 | `'...${s.stateEngineSnapshot.value.state.wireName}...'` | **永远是 `default`** |
| 桌宠页「桌宠状态」 | `_kv('桌宠状态', snapshot.state.descriptionZh)` | **永远是「默认」** |

所以"切到浏览器后状态仍是 default"**并不能证明原生链路坏了** ——
它证明的是这一行显示的值与原生状态无关。修复前，同一个页面上
「当前应用」来自原生（会变），「当前桌宠状态」来自 Flutter（不会变），
两者不同源，正好造成"应用能识别、状态却不动"的观感。

**修复**：Android 上的桌宠状态**只读原生诊断**（`OverlayPetController.stateDiagnostics`），
`overlay == null`（Windows / 桩）才回落到状态引擎。并在同一行补上
`分类 → 目标 · 规则 · 提交` 摘要，便于按应用逐条记录。

#### 根因 2：分类器的两处真实缺陷

1. **精确包名表的大小写陷阱（确定性缺陷）**：包名在查表前会经 `normalizePackageName`
   归一化成小写，而表里存在 `com.UCMobile` 这类含大写的**真实包名** ——
   该条**永远命中不到**，会落到 `other` → `default`。
   修复：查表用的 `exact` 由原始表统一小写构建。
2. **缺少 `ApplicationInfo.category` 兜底与包名关键字规则**：厂商定制 ROM 上
   `queryIntentActivities(CATEGORY_HOME)` 之外的桌面、以及改过包名/非主流应用
   会直接掉进 `other`。修复后优先级为：

```
① 用户为具体应用设定的分类（userCategory）
② 精确包名覆盖表（键统一小写）
③ 系统声明分类 ApplicationInfo.category（API 26+；UNDEFINED / 未知值不猜）
④ 内置包名前缀规则 → 内置包名关键字规则
⑤ other
```

   同时补齐了真机验收会用到的包名：Chrome/Firefox/Edge/Brave/夸克/UC/小米/heytap 浏览器、
   Telegram / 微信 / QQ / 钉钉、miHoYo / tmgp / supercell / freefire 等游戏、
   网易云 / B站 / QQ音乐等影音、Termux / RHMSoft Code / RV2IDE / Office / WPS 等办公开发、
   以及 OPPO / vivo / 一加 / 荣耀 / 中兴 / 传音 等厂商桌面。
   **判定只看包名，绝不看应用显示名**（显示名会随系统语言变化、也会被用户改名）。

#### 根因 3：快照解析失败被静默吞掉（违反"不能静默使用空规则"）

解析失败时 `NativePetStateMappingParser` 会**返回上一次的有效映射**并带上错误码；
但 `updateStateMapping` 随后会在"相同 revision → 幂等跳过"分支里提前返回 ——
**既没有写 `lastStateErrorCode`，也没有刷新 `stateRules`**。
修复后：解析失败（`mapping_parse_failed` / `mapping_revision_stale`）
一律**保留旧配置 + 报错 + 记日志**；"相同 revision"分支也**先刷新规则再跳过写盘**。

#### 顺带修掉的两处时序问题

| 问题 | 修复 |
|---|---|
| 防抖时间用 `System.currentTimeMillis()`（墙钟，会被校时/用户改时间打断） | 防抖改用**单调时钟** `SystemClock.elapsedRealtime()`；墙钟只用于给界面展示时间戳（两个时钟在 `stateTick` 里分开取，绝不混用） |
| 候选是否被"每次新快照对象"重置无法自证 | 新增诊断 `candidateSince` / `candidateElapsedMs`，并有单测钉住"连续相同目标不重置候选起点" |

> 说明：防抖本身早就比较的是 **state_key（String）**，并不比较快照对象；
> 这次是把它**变成可判定**（有字段可看、有单测钉住），并修掉墙钟这一条真实隐患。

### 12.11.12 状态提交链路的 17 项原生真值（设置页「实时诊断（原生真值）」）

设置页的「Android 悬浮桌宠」卡片新增只读区块，字段名与原生
`PetOverlayBridge.stateDiagnostics()` 的键**逐字对应**，**全部来自原生服务**，
Flutter 不做任何推算。刷新由 `OverlayPetController` 统一驱动（每 2 秒一次只读读取；
原生侧读取不会触发 `UsageStatsManager` 查询）。

| 字段 | 含义 | 判读 |
|---|---|---|
| `automaticEnabled` | 自动联动开关（原生侧实际取值） | false → 不会自动切换 |
| `collectorRunning` | 原生唯一前台轮询任务是否在跑 | false → 根本没检测，状态必然不动 |
| `foregroundPackage` | 有效外部应用包名 | 空 → 没识别到应用 |
| `foregroundLabel` | 应用标签 | 仅展示 |
| `foregroundCategory` | 分类（含命中依据，如 `exact:com.android.chrome`） | `other` → 分类器没覆盖 |
| `foregroundDetectionSource` | 检测来源（事件 / 统计兜底 / 缓存 / 不可用） | `unavailable` → 权限或窗口问题 |
| `resolvedTargetState` | **解析出的目标状态** | 有值但 stableState 不变 → 卡在防抖提交 |
| `candidateState` | 未生效的候选状态（含连续次数） | 一直有候选却不提交 → 看 `lastTransitionResult` |
| `candidateSince` | 候选首次出现时间（+已持续毫秒，单调时钟） | 反复刷新 → 候选被重置 |
| `stableState` | 已提交的稳定状态 | **与素材一一对应** |
| `matchedRule` | 命中的规则（`user-app`/`user-category`/`built-in`/`launcher`/`hold`/`manual`/`disabled`/`none`） | 能说明"为什么是这个状态" |
| `mappingRevision` | 原生生效的映射版本 | 0 → 快照从未下发 |
| `mappingReceivedAt` | 最近一次**成功应用**快照的时间 | 空 → 本次运行没收到过 |
| `manualOverrideState` | 手动覆盖（空 = 自动） | 非空 → 自动切换被覆盖 |
| `lastTransitionResult` | `committed`/`candidate`/`suppressed`/`unchanged`/`hold`/`manual`/`disabled`/`unavailable` | **定位卡在哪一步** |
| `lastTransitionReason` | 提交结果说明（含实际稳定毫秒数） | 例："候选稳定 1100ms，状态从 default 提交为 focused" |
| `lastCommittedAt` | 最近一次**真正提交**状态的时间 | 空 → 从未提交过 |

同时新增结构化日志 `state.resolve`（每次解析：包名 / 分类 / 来源 / 目标 / 规则 / 当前状态）
与 `state.transition.committed`（提交成功：from/to/规则/稳定时长/包名）——
**提交是"状态真的变了"的唯一证据，必须有日志**。

### 12.11.13 改动文件（本次修复）

| 层 | 文件 | 改动 |
|---|---|---|
| Kotlin | `overlay/PetState.kt` | `AppCategorySource` 增 `platform-category`；`AppCategoryResult` 增可解释 `detail`；新增 `AndroidAppInfoCategory`（`ApplicationInfo.category` → 既有 8 类）；`AndroidAppCategoryRules` 四级优先级 + 关键字规则 + 厂商桌面 + **精确表键统一小写**；`PetStateRulesCodec`（规则表编解码提到纯逻辑，可 JVM 单测）；`PetDebounceOutcome` 增结构化字段（`stableForMs` / `suppressed` / `code`） |
| Kotlin | `overlay/PetForegroundApp.kt` | 快照增 `category` / `categorySource` / `platformCategory`；`AndroidForegroundAppSource` 在**检测侧算一次分类**（含 `ApplicationInfo.category`，API 26+ 且失败降级），随快照传播给所有消费者 |
| Kotlin | `overlay/ForegroundAppRegistry.kt` | 分类优先用检测侧算好的那一份，快照没带才兜底 |
| Kotlin | `overlay/PetStateMonitor.kt` | 注入 `platformCategoryOf`；`tick(..., wallNow)` **双时钟**（单调用于防抖 / 墙钟用于展示）；新增诊断 `lastResolvedTargetState` / `lastTransitionResult` / `lastTransitionReason` / `candidateSinceWall` / `candidateElapsedMs` / `lastCommittedAt` / `lastCategoryDetail` / `lastPlatformCategory`；分类优先用快照里的那一份；`state.resolve` / `state.transition.committed` 日志 |
| Kotlin | `overlay/PetOverlayService.kt` | `stateTick` 分开取单调钟与墙钟；`mappingReceivedAt`；`updateStateMapping` **解析失败不静默**+"相同 revision 也刷新规则"；诊断发布扩到 17 项 |
| Kotlin | `overlay/PetOverlayStore.kt` | 规则表编解码改调 `PetStateRulesCodec` |
| Kotlin | `overlay/PetOverlayBridge.kt` | `stateDiagnostics()` 增 `resolvedTargetState` / `candidateSince` / `candidateElapsedMs` / `stableState` / `categoryDetail` / `platformAppCategory` / `mappingReceivedAt` / `lastTransitionResult` / `lastTransitionReason` / `lastCommittedAt` / `collectorRunning` |
| Flutter | `platform/overlay_pet.dart` | `OverlayStateDiagnostics` 增 11 个字段 + `fromMap` + `stableStateId` / `transitionResultZh` |
| Flutter | `ui/overlay_pet_controller.dart` | 新增 `refreshStateDiagnostics()` 与 **2 秒诊断轮询**（`attach` 启动 / `dispose` 取消）——诊断刷新只有一处来源 |
| Flutter | `ui/widgets/overlay_pet_card.dart` | 新增「实时诊断（原生真值）」区块（17 项，标签即原生字段名） |
| Flutter | `ui/pages/usage_stats_page.dart` | **「当前桌宠状态」改读原生**（`overlay` 传入；无 `overlay` 才回落状态引擎）；新增"分类 → 目标 · 规则 · 提交"摘要 |
| Flutter | `ui/mobile/mobile_shell.dart` | 桌宠页「桌宠状态」「当前应用」改读原生；把 `overlay` 传给桌宠页与统计页 |
| 测试 | `android/.../PetStateTest.kt` | 新增真实包名回归 8 项 + `PetStateRulesCodecTest` 3 项 + 监视器链路诊断 9 项 |
| 测试 | `test/overlay_pet_test.dart` | 新增「状态提交链路的原生真值」5 项 |

### 12.11.14 测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin `testDebugUnitTest` | **BUILD SUCCESSFUL**：**323** 项，0 失败（4C-6A 首版 302） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **685 通过 / 1 跳过 / 0 失败**（4C-6A 首版 680） |
| 服务端 `pytest` | **211 passed**（本次未改服务端，仅确认无回归） |
| `flutter build apk --debug` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-6A-fix-441F787D.apk`） |
| APK 大小 / 时间 / SHA256 | **189,237,440 B** / 2026-09-30 15:53:05 / `441F787DFC2DFB0E0284F52571557920F48B87080E9F42A8D6E8752FCDE07C90` |
| `flutter build windows --release` | 成功 |
| Windows Release | `petlife/build/windows/x64/runner/Release/`（入口 `petlife.exe`；改动代码在 `data/app.so`，8,487,816 B / 2026-09-30 15:54:06，SHA256 `A1D67CBA7879FD776A9BD9CFDFBA1573A2B35D3FADF099D5086331957D395CD1`） |

> 首轮 Kotlin 单测确实**跑出过一次真实失败**（`真实浏览器包名归 browser` 因 `com.UCMobile`
> 大小写命中不到），这正是根因 2 第 1 条的确定性证据；修复后全绿。

### 12.11.15 四个应用的诊断值：本地可判定的"修复后预期值"

**必须如实说明**：本机 `adb devices` 无设备、`emulator -list-avds` 无可用 AVD，
因此**下面不是真机实测值，而是由代码路径 + 单测锁定的"修复后预期值"**。
真机实测值需要在设备上按 §12.11.16 的记录模板填写，**未填之前不得声称真机通过**。

修复前（现象，用户报告）：四个应用下 `stableState` 均显示为 `default`
（其中「使用统计页 / 桌宠页」的值与原生状态无关，见根因 1）。

修复后**预期**（`foregroundDetectionSource` 视停留时长可能为 `activity-events` 或 `cache`）：

| 应用 | `foregroundPackage` | `foregroundCategory`（含依据） | `resolvedTargetState` | `stableState` | `matchedRule` |
|---|---|---|---|---|---|
| Chrome（浏览器） | `com.android.chrome` | `browser`（`exact:com.android.chrome`） | `focused` | `focused` | `user-category`（快照下发 browser→focused） |
| Telegram | `org.telegram.messenger` | `social`（`exact:org.telegram.messenger`） | `social` | `social` | `user-category` |
| 游戏（如原神） | `com.miHoYo.GenshinImpact` | `gaming`（`prefix:com.miHoYo.`） | `gaming` | `gaming` | `user-category` |
| 手机桌面 | 厂商 launcher 包名 | `system`（`exact:*` 或 `launcher`） | `away` | `away` | `launcher`（`isLauncher=true`） |

提交过程的预期诊断（以 Chrome 为例，轮询 1.5 秒）：

```
t+0.0s  resolvedTargetState=focused  candidateState=focused  lastTransitionResult=candidate  stableState=default
t+1.5s  resolvedTargetState=focused  candidateState=（空）   lastTransitionResult=committed  stableState=focused
        lastTransitionReason=候选稳定 1500ms，状态从 default 提交为 focused
```

### 12.11.16 真机验收步骤（本轮，对应 8 条验收标准）

**前置**：安装 `petlife-4C-6A-fix-441F787D.apk` → 授权悬浮窗 → 开启「显示悬浮桌宠」→
授权「使用情况访问」→ 保持「根据当前应用自动切换桌宠状态」为开。

**A. 按应用记录（每项停留 ≥3 秒，**停留后不要立刻切换**，直接在设置页读取）**

> 由于 PetLife 自身会被前台过滤器排除，进入设置页后 `foregroundPackage` 仍会显示
> 刚才那个外部应用（来源变为 `cache`），因此**可以在设置页边看边切**。

| 步骤 | 操作 | 要读的字段 | 通过标准（验收 1~6） |
|---|---|---|---|
| A1 | 打开 Chrome（或当前浏览器）停留 3 秒 | `foregroundPackage` / `foregroundCategory` / `resolvedTargetState` / `stableState` / `matchedRule` | 包名正确、分类 `browser`、目标 `focused`、`stableState` 变为 `focused`、规则可解释 |
| A2 | 打开 Telegram 停留 3 秒 | 同上 | 分类 `social`、`stableState` = `social` |
| A3 | 打开一个游戏停留 3 秒 | 同上 | 分类 `gaming`、`stableState` = `gaming` |
| A4 | 回到手机桌面停留 3 秒 | 同上 | 分类 `system`、`stableState` = `away`、`matchedRule=launcher` |

把上述四行**原样抄到验收记录里**（本节末尾模板），这就是"修复后四个应用的诊断值"。

**B. 素材与提交（验收 6）**

| 步骤 | 操作 | 通过标准 |
|---|---|---|
| B1 | 观察 A1~A4 期间桌宠图案 | 素材在 `stableState` 变化**之后**才切换（不是候选一出现就换） |
| B2 | 设置页看 `lastTransitionReason` | 含"候选稳定 NNNNms"（NNNN ≥ 1000） |
| B3 | 在两个应用间快速来回切 | `lastTransitionResult` 出现 `suppressed`；桌宠不连续闪图 |

**C. 后台与重启（验收 7）**

| 步骤 | 操作 | 通过标准 |
|---|---|---|
| C1 | 从最近任务**划掉 PetLife 主界面**（保留前台服务）→ 切浏览器/Telegram | 桌宠仍随应用变化（原生日志 `state.transition.committed` 持续出现） |
| C2 | 重新打开 PetLife → 设置页 | `mappingRevision` / `matchedRule` 仍在，`collectorRunning=true` |
| C3 | 通知栏「停止」→ 再「显示」→ 切应用 | 联动立即恢复，规则仍在（持久化生效） |
| C4 | 把「根据当前应用自动切换桌宠状态」关掉再打开 | 关：`automaticEnabled=false` 且不再换图（使用统计仍在涨）；开：立即恢复联动 |

**D. 回归**

| 步骤 | 通过标准 |
|---|---|
| D1 | 桌宠位置 / 大小 / 吸附 / 菜单 / 动态 WebP 全部正常，无抽动 |
| D2 | 使用统计页「当前应用」与「当前桌宠状态」**来自同一份原生数据**：状态行会随应用变化（不再是 default） |
| D3 | 跨端同步、本地时间段列表正常 |

**验收记录模板（真机填写后回填本节）**

| 应用 | foregroundPackage | foregroundCategory（依据） | foregroundDetectionSource | resolvedTargetState | candidateState | stableState | matchedRule | lastTransitionResult |
|---|---|---|---|---|---|---|---|---|
| 浏览器 | | | | | | | | |
| Telegram | | | | | | | | |
| 游戏 | | | | | | | | |
| 桌面 | | | | | | | | |

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

### 12.11.17 本机无法完成、必须真机执行的验证（**不得声称通过**）

* 17 项诊断在真机上的**实际取值**（本节 §12.11.15 已明确是"预期值"，不是实测值）。
* 厂商 ROM 上 `queryIntentActivities(CATEGORY_HOME)` 是否覆盖该桌面；
  以及 `ApplicationInfo.category` 在该 ROM 上是否为 `UNDEFINED`。
* 划掉 PetLife 主界面后前台服务与轮询是否被厂商后台策略杀掉。
* 仪器测试（`connectedDebugAndroidTest`）仍无设备可跑。


## 12.12 Phase 4C-6A.1：桌宠状态素材映射编辑器

### 12.12.1 需求 §2 实施前审计（结论：**不需要新增映射表**）

| 审计项 | 结论（含证据） |
|---|---|
| 状态映射表 | 已存在 `state_mappings`（`lib/database/schema.dart` v1 建表）：`id` 主键、`character_id`（外键→角色，ON DELETE CASCADE）、`system_state`、`asset_id`、`emotion_name`、`weight`、`priority`、`created_at/updated_at`，`CHECK (asset_id IS NOT NULL OR emotion_name IS NOT NULL)` |
| 唯一约束 | **刻意没有 UNIQUE**：4A 的需求 4.6 允许同一状态配置**多个候选**并按权重选择（`lib/character/models/state_mapping.dart` 注释）。因此本阶段**不加唯一索引**（理由见 §12.12.3） |
| 是否已存 `asset_id` | 是；另有 `emotion_name`（"按情绪绑定"，导入流程写入） |
| 同素材映射多个状态 | **天然支持**（无唯一约束） |
| 批量/事务接口 | 已有 `StateMappingDao.replaceForState`（删+插，自带事务）与 `deleteByCharacter`；本阶段**新增** `setExplicitForState`（upsert 主素材 + 清同状态其它行，单事务）与 `deleteReferencingAsset` |
| 素材结构 | `emotion_assets`：`id`、`character_id`、`emotion_name`、`variant_name`、`file_path`、`mime_type`、`is_animated`、`frame_count`、`enabled`、`validation_status`、`animation_duration_ms`…；**没有 favorite 列** |
| 状态 wire value | 11 个（见 §12.12.2）；Android 与 Windows 共用同一套（原生 `PetStateId` 与 Dart `SystemState.wireName` 逐字一致） |
| 配置发布链路 | `lib/platform/overlay_state_mapping.dart` → `OverlayPetController.syncStateMapping()` → MethodChannel `updateStateMapping` → `PetOverlayService.updateStateMapping` → `PetOverlayStore`（按状态拆键 + `键=值` 规则表） |
| 素材/角色删除 | `deleteCharacter` 已清映射；`deleteAsset` **原本不清映射**（只在渲染时被 `FallbackChain` 静默跳过）→ 本阶段补齐 |
| 结论 | **现有表足以表达"状态 → 素材"，不新增任何映射表**；唯一的 schema 变更是给 `emotion_assets` **加一列** `favorite`（见 §12.12.3） |

其它角色的素材运行期本来就被结构性挡住（`FallbackChain` 只在"传入角色的 renderable 列表"里查），本阶段在**写入侧**也补上了校验。

### 12.12.2 状态 wire value（本阶段使用的全部取值，**不新增命名**）

| wire | 中文（`SystemState.descriptionZh`） | 展示位置 |
|---|---|---|
| `default` | 默认 | 卡片顺序第 1 |
| `focused` | 专注 | 第 2 |
| `social` | 社交 | 第 3 |
| `gaming` | 游戏 | 第 4 |
| `entertained` | 娱乐 | 第 5 |
| `away` | 离开 | 第 6 |
| `concerned` / `tired` / `happy` / `error` / `manual` | 担忧 / 疲惫 / 开心 / 错误 / 手动锁定 | 其后（按 priority 降序） |

> **与需求 §14 的一处差异**：需求的示例表里出现 `thinking` / `cheerful`。项目里这两个是**素材的情绪名**（`EmotionAsset.emotionName`，作者自由命名），**不是状态 wire value**；状态只有上表 11 个。因此本阶段**不新增**这两个状态，卡片上显示的情绪名来自素材本身。

### 12.12.3 数据库变更：**只加一列**（v5）

```sql
ALTER TABLE emotion_assets ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_assets_favorite ON emotion_assets (character_id, favorite);
```

* `AppConstants.databaseSchemaVersion` 4 → **5**；迁移注册在 `DbSchema.migrations[5]`，并追加进 `createStatements`（新库同样建到 v5）；
* **刻意不改 v1 的建表语句**：v1 语句同时被"迁移测试重建一个真正的 v1 老库"使用，改它会让 v1→v5 的升级路径不再真实（且重复 ALTER 会报 duplicate column）；
* 没有任何收藏时，回退链行为与升级前**完全一致**（新层级直接跳过）；
* 升级路径有测试钉住：`test/state_asset_mapping_test.dart`（造一个真正的 v4 库 → 打开 → 断言 数据不丢 / `favorite` 默认 0 / 映射仍在），以及 `cloud_statistics_cache_test.dart` 的 v3 → 最新版迁移用例。

#### 为什么**不**加 `UNIQUE(character_id, system_state)`

需求 §7 建议该唯一性。但：

1. 既有库与导入流程会为**同一状态写多条候选**（按情绪绑定 + 权重）；加 UNIQUE 会让迁移在**既有数据上直接失败**（或者被迫先删除用户数据）；
2. 汇总分析：编辑器真正要的是"一个状态只有一张**显式主素材**"，这个约束在**应用层**用一个事务即可严格保证（`setExplicitForState`：先 upsert 目标行，再删同状态其它行），不需要动表结构；
3. 编辑器的写入是确定性的：`(角色, 状态)` 永远映射到**同一个行 id**（`Ids.explicitStateMappingId`），因此"重复保存"是更新同一行，不会产生重复记录（有单测）。

### 12.12.4 页面入口与 UI 结构（需求 §3 / §4 / §5 / §6 / §13）

| 入口 | 位置 | 说明 |
|---|---|---|
| 主入口 | 素材库 → 选作品包 → 选角色 → **「状态映射」**（窄屏在"设为当前桌宠角色"旁；宽屏在左侧角色树每行的齿轮按钮） | 映射属于**角色**，不属于作品包 |
| 快捷入口 | 设置 → 「Android 悬浮桌宠」卡片 → **「编辑状态素材」** | 打开"当前桌宠角色"的映射页；没有角色时明确提示去素材库 |
| 反向入口 | 素材卡片「更多」菜单 / 选择器大图预览里的 **「分配给状态…」** | 需求 §6 |

**映射页结构**：

```
AppBar：状态素材映射
├─ 顶部卡片：当前作品包 / 当前角色 / 可用素材 n/m
│            自动状态联动开关（与映射编辑解耦）
│            诊断：当前稳定状态 · displayMode · 当前实际素材 · 素材来源 + 回退级别
│                 命中的状态映射 · mappingRevision · mappingReceivedAt · 最近发布结果
├─ （预览中时）黄色横幅：正在临时预览「X」，约 N 秒后自动恢复 + 「恢复自动」
└─ 状态卡片（§4.2 固定顺序；窄屏单列 / ≥720dp 双列）
     缩略图 + 中文名 + wire value + 素材名
     + 状态徽标：已映射 / 映射已失效 / 文件丢失 / 按情绪匹配 /
                 回退 · 收藏素材 / 回退 · 角色默认 / 回退 · 任意可用素材 / 无可用素材
     + 当前状态徽标 + 动态 WebP 徽标
     + 操作：预览 / 结束预览 · 选择素材 / 更换 · 清除
```

* **回退绝不伪装成已映射**（§4.3）：只有存在显式 `asset_id` 映射时才显示"已映射"，其余一律写明命中了回退链的**哪一层**；
* 卡片高度由内容决定（不使用固定高度），操作行用 `Wrap` 而非 `Row` —— 360dp / 横屏 / 分屏 / 字体放大 1.3x 都不溢出（有 widget 测试）。

**素材选择器**（§5，底部弹层 + 大图对话框）：

```
弹层标题：为「状态名」选择素材 · <wire> · 只显示当前角色的素材（共 n 张）
网格（按宽度自适应列数，固定 mainAxisExtent，文本一律省略）：
   缩略图 + 动态徽标 + 收藏徽标 + 不可用徽标
   素材名（情绪 / 变体）
   分辨率 · 文件大小
   当前映射 / 角色默认 标记
点一张 → 大图/首帧预览对话框：
   静态图片/动态 WebP（n 帧） · 分辨率 · 文件大小 · 校验问题
   [收藏/取消收藏] [查看原图] [分配给状态…] （已是该状态素材 / 已是角色默认）
   [取消] [设为角色默认] [设为「X」素材]
```

* **点击素材只是查看**，必须再点"设为「X」素材"才写库（§5.3，有测试）；
* 不可用素材（禁用 / 校验未通过）**可见但不可选**，按钮禁用（有测试）；
* **只显示当前角色的素材**：选择器只拿到该角色的素材列表，测试断言"另一个角色的素材不出现"（§5.1）。

**反向分配对话框**（§6）：11 个状态复选框 + 每个状态"当前是什么" + 实时**变更摘要**
（`社交：未设置 → 本素材` / `专注：本素材 → 未设置`）；没有变更时"保存"按钮禁用。

### 12.12.5 映射保存与删除的事务说明（§7 / §8 / §10）

| 操作 | 事务边界 | 语义 |
|---|---|---|
| 设为某状态素材 | `StateMappingDao.setExplicitForState`（**一个事务**）：先按确定 id `UPDATE`，affected=0 才 `INSERT`，然后 `DELETE ... AND id <> :target` | 一个状态只留一条显式主素材；刻意**不用** `INSERT OR REPLACE`（它先 DELETE 再 INSERT，将来一旦有子表引用就会静默级联删除） |
| 清除某状态映射 | `replaceForState(..., [])`（事务内 delete） | 仅该状态；其它状态不受影响 |
| 反向分配（§6） | `CharacterRepository.assignAssetToStates` → `_inTransaction`：读现状 → 逐个状态 upsert / 解除 → 返回变更清单 | 勾选覆盖该状态原有映射；取消勾选**只**删"指向本素材"的那条；其它状态不动 |
| 收藏 | `AssetDao.setFavorite`（单列 update） | 只改 `favorite`，不动 `enabled` / `validation_status` |
| **删除素材**（§10.1） | `_inTransaction`：① `deleteReferencingAsset` ② 删素材行 ③ 清悬空的角色默认图片引用；**文件删除放在提交之后** | 任一步失败整体回滚 → 不会出现"映射删了素材还在"或反之；文件删除不可回滚，失败只记日志（最多留个孤儿文件，绝不产生坏数据） |
| 删除角色（§10.2） | `_inTransaction`：清映射 → 清素材 → 删角色；文件删除在提交后 | 不会留下"角色没了但映射还在"（那会让原生拿到失效 characterId） |
| 删除前提示 | `statesReferencingAsset(assetId)`（**删除前**查） | 删除对话框列出"该素材正被以下状态使用：… 删除后这些状态将使用回退素材"（有测试） |

**失败时保留旧映射**、**不产生孤儿记录**：由"单事务 + 先写后删"结构性保证。

### 12.12.6 原生快照更新流程与 revision 处理（§8）

```
保存映射（Flutter）
  → LibraryController.mutated()
      → repository.loadSnapshot()（本地快照刷新，界面立刻反映）
      → onLibraryMutated()（Android 外壳 = StateEngine.refresh()）
          → stateEngineSnapshot 变化
              → OverlayPetController._onSnapshotChanged → syncStateMapping()
                  → revision = _mappingRevision + 1（**先自增再请求**）
                  → buildOverlayStateMapping（复用既有 FallbackChain）
                  → signature 与上次相同 → 跳过（同一个素材 + 同一个 revision 不重复重载）
                  → MethodChannel updateStateMapping
                      → 原生解析 / 校验（旧 revision 直接拒绝；解析失败保留旧配置并报错）
                      → PetOverlayStore 原子写盘
                      → stateTick("mapping-updated") + **无条件按当前状态重解析素材**
```

* **"当前状态修改后立即切换"**：`updateStateMapping` 成功后除跑一次状态判定外，**再无条件**按 `currentStateId`（预览中则按预览状态）重解析一次素材 —— 只跑状态判定是不够的，因为"目标状态没变"会被状态机判为"状态未发生变化"而跳过素材重算；assetId 相同仍会被去重（不重复解码）；
* **"非当前状态修改后不改变当前画面"**：只为当前状态重解析，其它状态的变化只体现在下一次切换；
* **"原生服务未运行时仍保存数据库"**：写库与下发解耦；服务没跑时 `publishResult = skipped-service-not-running`，下次 `show()` 会带上最新快照；
* **"旧 revision 不得覆盖新 revision"**：原生 `NativePetStateMappingParser` 拒绝更小的 revision；Flutter 侧 `refresh()` 从原生"已生效版本"续接计数器；
* **"原生拒绝配置时保留旧配置并显示错误"**：解析失败（`mapping_parse_failed` / `mapping_revision_stale`）保留 `previous` 并写 `lastStateErrorCode`（4C-6A 修复时补齐）；
* **发布结果可见**：`OverlayPetController.lastPublishResult / lastPublishError / lastPublishAt / lastPublishedRevision` → 映射页与设置页显示"最近发布结果"；结构化日志 `state_mapping_publish_started / succeeded / failed`。

### 12.12.7 素材回退顺序（§9）

实际实现（`FallbackChain`，**6 级**）：

```
① 状态显式图片（state_mappings.asset_id）
② 状态指定情绪（state_mappings.emotion_name，导入流程写入）
③ 角色收藏素材（favorite = 1 的第一张，本阶段新增）
④ 角色默认图片（character_models.default_asset_id）
⑤ 角色第一个有效素材
⑥ 内置占位图（asset == null，界面上是"无可用素材"）
```

“保持当前可显示素材 / 绝不黑框”这一层不在回退链里，而在**渲染侧**：
原生 `NativeAssetSelector` 返回 null 时显示**可见的错误占位**（`PetVisualError`），窗口绝不消失；
Flutter 侧由 `StateSnapshot.resolution` 兜底。

> **与需求 §9 列举顺序的两处差异（如实标注）**：
> 1. 需求把「default 显式映射」排在收藏**之前**；本项目里 `characterDefault` 在未显式设置默认图时会隐式退化为"第一张有效素材"，把收藏放在它之后会让收藏**永远不可达**（快照构建会认为"结果等于默认素材"而跳过该状态）。因此收藏放在「角色默认」**之前**；
> 2. 需求列了「当前状态收藏素材」与「当前角色收藏素材」两级；项目里"与当前状态相关的素材"本来就是既有的**「状态指定情绪」**一级，为同一个概念再造成两级没有意义，因此**只新增一级**「角色收藏素材」。

映射页对每个状态**明确显示当前实际命中的层级**，"已映射 / 按情绪匹配 / 回退 · 收藏素材 / 回退 · 角色默认 / 回退 · 任意可用素材 / 无可用素材"六种文案互不混用。

### 12.12.8 临时预览 vs 手动覆盖 vs 编辑映射（§11 / §12）

| 行为 | 改的是什么 | 何时恢复 | 是否持久化 | `displayMode` |
|---|---|---|---|---|
| **编辑映射** | `状态 → 素材` 这张表 | 不恢复（就是最终配置） | 是（SQLite + 原生快照） | 仍是 `auto` |
| **手动覆盖** | 状态调试器的覆盖 | 用户点「恢复自动」 | 是（`PetOverlayStore`） | `manual` |
| **临时预览** | 只换"当前显示的那张图" | 约 10 秒后自动恢复，或用户点「恢复自动」 | **否**（[PreviewWindow] 无任何写盘接口） | `preview` |

* 预览期间：`stableState`（= `currentStateId`）**不变**、手动覆盖**不写**、自动状态机照常记账；
  期间若发生状态切换，服务只记账**不换画面**（否则预览会被自动切换顶掉）——日志 `state.preview.hold`；
* 预览另一个状态会**替换**上一个（`PreviewWindow.start` 直接覆盖）；
* 到期检查复用状态轮询的**同一个 tick**（不新增计时器）；
* 服务停止时预览一并结束（`resetRuntimeState`）；
* 诊断字段：`displayMode` / `previewState` / `previewExpiresAt`；日志 `state_asset_preview_started` / `state_asset_preview_ended`（reason: `cleared` / `expired` / `service-stopped`）；
* UI 文案三处严格分开：「预览」（卡片按钮）/「手动覆盖」（设置页状态调试器）/「编辑状态素材」（入口名称）。

### 12.12.9 改动文件

| 层 | 文件 | 改动 |
|---|---|---|
| DB | `lib/database/schema.dart` | 新增 `v5Statements`（`emotion_assets.favorite` + 索引），注册进 `migrations` 与 `createStatements` |
| DB | `lib/core/constants.dart` | `databaseSchemaVersion` 4 → 5 |
| DB | `lib/database/dao/asset_dao.dart` | 新增 `setFavorite` |
| DB | `lib/database/dao/state_mapping_dao.dart` | 新增 `setExplicitForState` / `_setExplicitOn` / `listReferencingAsset` / `deleteReferencingAsset` |
| 模型 | `lib/character/models/emotion_asset.dart` | 新增 `favorite` 字段（`toMap` / `fromMap` 缺失容错 / `copyWith`） |
| 仓储 | `lib/character/character_repository.dart` | 新增 `StateAssignmentChange`；接口新增 `setAssetFavorite` / `setStateAssetMapping` / `assignAssetToStates` / `statesReferencingAsset` |
| 仓储 | `lib/character/sqlite_character_repository.dart` | `_txnExecutor` + `_inTransaction`；`deleteAsset` / `deleteCharacter` 改**单事务**；新增上述 4 个方法 + `_requireOwnedAsset` / `_explicitMapping` |
| ID | `lib/core/ids.dart` | 新增 `explicitStateMappingId`（确定性：同角色同状态永远同一行） |
| 回退 | `lib/state_engine/fallback_chain.dart` | `FallbackLevel` 新增 `characterFavorite`（顺序说明见 §12.12.7）；`resolve` 新增收藏层级 |
| UI | `lib/ui/pages/state_asset_mapping_page.dart` | **新建**：映射页 + 状态卡片 + 反向分配对话框 `showAssignStatesDialog` |
| UI | `lib/ui/widgets/state_asset_picker.dart` | **新建**：素材选择器（网格 + 大图预览 + 收藏 + 设为状态/默认 + 分配给状态） |
| UI | `lib/ui/library_controller.dart` | 暴露 `settings`；新增 `assetsFor` / `setStateAssetMapping` / `clearStateAssetMapping` / `assignAssetToStates` / `setAssetFavorite` / `statesReferencingAsset` |
| UI | `lib/ui/pages/asset_library_page.dart` | 角色层新增「状态映射」入口（窄屏按钮 + 宽屏角色行齿轮）；素材卡片新增「更多」菜单（收藏 / 分配给状态… / 设为默认）与收藏角标；删除对话框新增"正被以下状态使用"；操作行改 `Wrap` + 卡片高度 216→252 |
| UI | `lib/ui/pages/settings_page.dart` | 透传 `library` 给悬浮桌宠卡片 |
| UI | `lib/ui/widgets/overlay_pet_card.dart` | 新增「编辑状态素材」快捷入口；诊断新增 `displayMode` / `previewState` |
| UI | `lib/ui/mobile/mobile_shell.dart` | 向素材库/设置页注入 `overlay` 与 `library` |
| UI | `lib/ui/desktop/control_panel.dart` | 桌面素材库同样可获得映射编辑器（`overlay` 为 null，预览会给出说明） |
| 调试 | `lib/ui/pages/state_debugger_page.dart` | 回退链级数改为动态（`FallbackLevel.values.length`） |
| 平台 | `lib/platform/overlay_pet.dart` | 接口新增 `previewState` / `clearPreview`；诊断新增 `displayMode` / `previewState` / `previewExpiresAt` + `displayModeZh` / `isPreviewing` |
| 平台 | `lib/platform/android/android_overlay_pet.dart` | 通道新增 `previewState` / `clearPreview` |
| 控制器 | `lib/ui/overlay_pet_controller.dart` | 新增 `previewState` / `clearPreview`；发布结果诊断 `lastPublishResult` / `lastPublishError` / `lastPublishAt` / `lastPublishedRevision` / `publishResultZh`；`syncStateMapping` 新增结构化日志 |
| Kotlin | `overlay/PetState.kt` | 新增 `PreviewWindow`（纯逻辑，可 JVM 测试） |
| Kotlin | `overlay/PetOverlayService.kt` | 预览状态机接入（`previewState` / `clearPreview` / `expirePreviewIfNeeded`）；`applyAssetForState` 拆出（只换图不换状态）；预览期间 hold；`displayMode`；`resetRuntimeState` 清预览；**`updateStateMapping` 后无条件重解析当前状态素材** |
| Kotlin | `overlay/PetOverlayBridge.kt` | 通道新增 `previewState` / `clearPreview`；诊断新增 `displayMode` / `previewState` / `previewExpiresAt` |
| 测试 | `test/state_asset_mapping_test.dart` | **新建** 24 项：DAO/事务/跨角色拒绝/删除联动/收藏/v4→v5 迁移/回退链 |
| 测试 | `test/state_asset_mapping_page_test.dart` | **新建** 12 项：顺序、已映射 vs 回退、文件丢失、禁用、窄屏/横屏、清除确认、选择器范围与不可选、写库时机、反向分配摘要与保存、空状态 |
| 测试 | `test/overlay_pet_controller_test.dart` | 新增 5 项预览行为；假件补齐 `previewState` / `clearPreview` |
| 测试 | `android/.../PetStateTest.kt` | 新增 `PreviewWindowTest` 8 项 |
| 测试 | `test/cloud_statistics_cache_test.dart` | 迁移用例改为断言"最新版本 = 5" |

### 12.12.10 测试与构建结果

| 项 | 结果 |
|---|---|
| Kotlin `testDebugUnitTest` | **BUILD SUCCESSFUL**：**331** 项，0 失败（4C-6A 修复版 323） |
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --no-pub` | **726 通过 / 1 跳过 / 0 失败**（4C-6A 修复版 685） |
| 服务端 `pytest` | **211 passed**（本阶段未改服务端，仅确认无回归） |
| `flutter build apk --debug` | 成功 |
| APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk`（另存 `DesktopPet/petlife-4C-6A1-CE979D02.apk`） |
| APK 大小 / 时间 / SHA256 | **189,316,737 B** / 2026-09-30 16:48:28 / `CE979D02FD8939932DBB66C5EDB934E41AC9EC89ED2AA0938A64884D81C69213` |
| `flutter build windows --release` | 成功（公共素材逻辑已改动：收藏列与回退链） |
| Windows Release | `petlife/build/windows/x64/runner/Release/`（入口 `petlife.exe`；`data/app.so` 8,717,192 B / 2026-09-30 16:49:56 / SHA256 `8D7EE9477C29152A7AF2BD9CD69E71B0C1E9CC9B5762CFF5217562D54E91C768`） |

### 12.12.11 真机验收步骤（对应需求 §18 的 21 条）

**前置**：安装本轮 APK → 授权悬浮窗 → 显示悬浮桌宠 → 授权使用情况访问 → 准备好至少 4 张素材（其中 1 张动态 WebP）。

**A. 进入与基本编辑**
1. 素材库 → 选作品包 → 选角色 → 点「状态映射」，确认顶部显示正确的作品包 / 角色 / 可用素材数，且状态卡片按 `default → focused → social → gaming → entertained → away → 其余` 排列。
2. 给 `default` 指定静态图 A；给 `focused` 指定静态图 B；给 `social` 指定静态图 C；给 `gaming` 指定动态 WebP D。每张卡片应显示缩略图、素材名、中文名与 wire value。
3. 每张卡片点「预览」：悬浮桌宠**立即**换成该状态素材，且**当前状态徽标不移动 / stableState 不变**（设置页诊断 `displayMode=preview`、`previewState` 有值）；约 10 秒后自动恢复真实状态。

**B. 自动联动按新映射工作**
4. 打开浏览器 → 稳定后显示 B；打开 Telegram → 显示 C；打开游戏 → 播放 D；回桌面 → `away` 映射或按回退链。
5.（§8）在浏览器仍在前台时把 `focused` 改成另一张图 → 悬浮桌宠**立即**变化（不需要切应用）。
6.（§8）此时修改 `social` 的映射 → 当前画面**不应**变化。

**C. 清除与回退**
7. 清除 `social` 映射 → 卡片应变成"按情绪匹配 / 回退 · …"（绝不再显示"已映射"），且从 Telegram 切回时使用回退素材。
8. 清除 `default` 映射 → 弹出提示说明"其它未映射状态可能改用角色收藏素材或任意可用素材"。

**D. 反向分配**
9. 素材库 → 某素材卡片「更多」→「分配给状态…」→ 勾选"专注"和"社交" → 摘要显示 `专注：未设置 → 本素材` → 保存 → 两个状态的卡片都变成该素材。
10. 在同一素材详情（选择器大图）里点「分配给状态…」再取消勾选"社交" → 只影响"社交"，"专注"保留。

**E. 删除联动**
11. 删除正在被 `focused` 使用的素材 → 对话框应列出"该素材正被以下状态使用：· 专注（focused）"→ 确认删除 → `focused` 卡片变成回退，悬浮桌宠**不出现黑框/透明**。
12. 删除当前角色 → 应用自动切到其它有效角色；没有其它角色时显示明确空状态。

**F. 持久化与后台**
13. 重启应用 → 映射仍在；重启悬浮服务（通知栏「停止」→「显示」）→ 映射仍在、联动正常。
14. 从最近任务划掉 PetLife 主界面 → 切应用，桌宠仍按映射变化（原生快照持久化生效）。

**G. 手动覆盖 / 预览的区分**
15. 设置页状态调试器手动覆盖某状态 → 卡片显示"已映射"不变，悬浮桌宠被覆盖；点「恢复自动」后回到自动状态。
16. 预览与手动覆盖同时存在时：先手动覆盖，再点某状态「预览」→ 显示预览素材，10 秒后回到**手动覆盖**的状态素材。

**H. 回归**
17. 静态图 / 动态 WebP 均正常；拖动、吸附、菜单展开、大小调整无退化。
18. 使用统计（本机时间段列表）、跨端云端统计、同步均正常。
19. 窄屏（360dp）、横屏、分屏、系统字体放大 1.5x → 映射页与选择器**均无溢出**。

**验收结论（待填）**：☐ 通过 / ☐ 未通过（问题：________）。

### 12.12.12 本机无法完成、必须真机执行的验证（**不得声称通过**）

* 上述 19 步全部需要在真机上人工执行；`adb devices` 无设备、`emulator -list-avds` 无可用 AVD，仪器测试仍无法运行。
* 需要确认：预览的 10 秒到期由**状态轮询 tick** 触发，因此在悬浮窗**隐藏**时（降频 5 秒）到期会有最多 5 秒延迟 —— 属于预期行为，需真机确认观感可接受。
* 需要确认：动态 WebP 在大图预览里只显示首帧（Flutter 侧预览不做动画解码），真机上是否可接受。
* 需要确认：厂商 ROM 上"删除素材后立刻切回前台应用"时，悬浮窗是否出现短暂的占位（预期最多一帧）。

### 12.12.13 抛给用户确认的 4 个问题（本阶段按"最小风险"取值，均可再调整）

| # | 问题 | 本阶段取值 | 若改选另一方案的影响 |
|---|---|---|---|
| 1 | 项目**原本没有"收藏"概念**，而需求 §5.2/§5.4/§9/§16 反复要求收藏 | **新增** `emotion_assets.favorite` 列（v5 迁移）+ 回退链新增**一级**「角色收藏素材」 | 若不要收藏：需删除该列与回退层级、选择器去掉收藏徽标与操作（范围更小，但与需求不一致） |
| 2 | 已存在 `state_mapping_page.dart`（Windows 桌面「候选 + 权重 + 情绪绑定」编辑器） | **并存**：新页走"一状态一图"的编辑器口径，旧页保留多候选/权重 | 若用新页替换旧页：将**移除**多候选、权重、按情绪绑定、套用建议映射、清空全部等既有能力 |
| 3 | §11「临时预览」必须由原生实现（Flutter 改不了悬浮窗） | **新增**原生预览态（内存、10 秒到期、`displayMode` 诊断） | 若不做：只能做静态大图查看，不满足"临时显示该状态映射素材" |
| 4 | §7 要求 `(character_id, state_key)` 唯一，而既有表**刻意支持多候选** | **不加** UNIQUE 索引，改在应用层用单事务保证 | 若加 UNIQUE：既有库可能**迁移失败**，且会破坏 4A 的多候选设计 |


## 12.13 Phase 4C-6B-1：P3P 风格分层轮盘菜单与主题系统

> 需求：`35-Phase4C悬浮桌宠` 的 4C-6B-1 规格（P3P 非对称轮盘 / 六项根菜单 / 分层菜单栈 /
> 固定返回键 / 菜单偏离桌宠 / 左右镜像与安全区 / 参数化高亮扇区 /
> 展开·切换·换层·返回·关闭动画 / 点击与圆弧滑选 / 松手确认与槽位滞回 /
> 与桌宠拖动严格互斥 / 默认 P3P 粉色主题与预设·自定义 / 统一 ActionDispatcher）。
>
> **本阶段不接入任何真实业务动作**：除导航（打开子菜单 / 返回 / 关闭菜单）与
> 主题设置外，其余命令一律走结构化占位事件（4C-6B-2 接入）。

### 12.13.1 实施前审计结论（改之前的事实）

审计对象：`OverlayMenu.kt`、`PetMenuView.kt`、窗口几何、触摸链路、桥接与设置链路。

| 审计项 | 结论 |
|---|---|
| 旧菜单是什么 | 4C-3B 的**占位圆盘**：`OverlayMenuCatalog.placeholderSlots()` 产生 `slot_1..slot_n`，点击统一提示「功能尚未配置」 |
| 旧菜单怎么画 | **多 View**：`PetMenuView`（FrameLayout）+ 每个按钮一个 `TextView` + `GradientDrawable` 圆 |
| 旧菜单怎么摆 | 按钮环**以桌宠为中心**均匀铺设（`OverlayMenuGeometry`），整体垂直/旋转避让 |
| 窗口结构 | 双窗口（桌宠窗口 + 菜单窗口）；菜单窗口 = **按钮触摸矩形的包围盒**；关闭即 `removeView` |
| 硬约束 | 菜单窗口**绝不压住桌宠中心抓取区**（否则点不中、拖不动桌宠） |
| 触摸链路 | 桌宠窗口 → `OverlayGestureMachine`（IDLE/PRESSING/DRAGGING/MENU_OPEN…）；菜单窗口 → 按钮点击 + 空白点击关闭 |
| 抽动基线 | 开/关菜单**不改桌宠窗口的 LayoutParams 一个字段**（结构性保证） |

**审计发现的三个矛盾点**（实施时按"保住已验收基线"处理）：

1. **"不要用多个独立 Window" vs 4C-3B 的双窗口结论**。
   需求 §7 建议单窗口 Canvas；但 §14 也要求"必须保持此前无抽动基线"。
   4C-3B 的真机结论是：单窗口"扩展同一窗口 + 平移桌宠相对矩形"**无法根治抽动**
   （Substrate 位置与子布局是两条通道）。
   → 采用**保留双窗口 + 菜单侧改成单个 Canvas View**：
   按钮不再是多个 View（满足 §7 的实质诉求），桌宠窗口仍一个字节不改（满足 §14）。
2. **要求"菜单中心偏离桌宠 0.35~0.5 倍桌宠宽度" vs "菜单窗口不得覆盖桌宠抓取区"**。
   实测：若把"刀刃跟随端点槽位"的全部可能角度都算进窗口，轮盘的可用空间被压缩，
   偏移会膨胀到 **1.6 倍以上**（轮盘被推离桌宠）。
   → 把 `MAX_HALF_SPAN_DEG` 收到 **72°**（配合 30° 刀刃半张角 = 最大 102°），
   实测偏移回落到 **0.4~0.6 倍桌宠宽度**（见 §12.13.3）。
3. **旧几何测试（`OverlayMenuTest` 的几何部分 / `OverlayMenuWindowTest`）测的是占位菜单**，
   与轮盘无关 → 删除，改为 `WheelMenuGeometryTest` 等 4 个新测试文件（§12.13.10）。

### 12.13.2 菜单层级结构（需求 §4，本阶段全部落地）

```text
根菜单（固定六项）
├── 桌宠     → 子菜单：自动状态 / 当前状态 / 手动状态 / 恢复自动 / 锁定位置 / 调整大小 / 默认位置 / 返回
├── 形象     → 子菜单：上一素材 / 下一素材 / 随机素材 / 收藏 / 切换角色 / 状态映射 / 素材库 / 返回
├── 记录     → 子菜单：今日时长 / 当前应用 / 暂停·恢复 / 立即同步 / 同步状态 / 详细统计 / 返回
├── 工具     → 子菜单：专注计时 / 快捷应用 / 打开 PetLife / 自定义快捷入口 / 返回
├── 设置     → 子菜单：主题 / 透明度 / 菜单距离 / 触觉反馈 / 音效 / 诊断信息 / 重启服务 / 停止服务 / 返回
└── 隐藏     → **直接动作**，不进子菜单
```

* 菜单栈只有一处：`WheelMenuStack`（`push` / `pop` / `popToRoot` / `clear`）。
  进入子菜单 = `push`，返回 = `pop`，关闭 = `clear` —— **没有为任何子菜单写独立返回逻辑**。
* **固定返回键**：每个子菜单的最后一项恒为 `isBack = true` 的「返回」，
  在几何里位于**最大角度**（视觉最下方）；镜像时角度取反，返回键仍在下（需求 §5）。
* 最大层级是「设置」（8 项 + 返回 = **9 项**），因此窗口信封按 **9 项**计算。

### 12.13.3 参数化几何（需求 §8 / §9）

**两段式 API**（这是"窗口只展开一次"的关键）：

```text
WheelMenuGeometry.computeEnvelope(bounds, petRect, maxItemCount = 9, spec, prevDir, locked)
    └─→ WheelMenuEnvelope { direction, windowRect, centerX, centerY, maxRingRadiusPx, buttonDiameterPx, degraded }
WheelMenuGeometry.layoutFor(envelope, level, petRect, spec)
    └─→ WheelMenuLayout { 环带/缺口/刀刃/各槽位角度与坐标… }   // 只读信封，绝不改窗口
```

* 打开时按**最胖的一层**算一次信封 → 之后根选项切换、进出子菜单**只改内部绘制**（需求 §14）；
* `layoutFor` 里**环带半径与按钮直径取自信封**（恒定）→ 换层时轮盘不会忽大忽小。

高亮扇区（"刀刃"）**完全由参数生成**，没有六张背景图：

```text
selectionAngle   = absoluteAngle(direction, (selectionPosition − (n−1)/2) × step)
connectorAngle   = 同刀刃角度（刀刃就是"当前选项的连接扇区"）
innerRadius      = notchRadius × 0.72
outerRadius      = bladeLength
panelExtent      = bladeLength − rimOuter（随半径按 0.42 比例派生，夹在 44~96dp）
cutoutDepth      = rimLobe × 0.9（中央"齿轮"缺口的齿深）
cornerRadius      = (outerRadius − innerRadius) × 0.28
highlightProgress / mirrorDirection 由动画帧与方向决定
slotAngle        = absoluteAngle(direction, (i − (n−1)/2) × step)
slotRadius       = 信封半径（恒定）
selectedScale    = 1.14
menuOffset       = max(0.42 × 桌宠宽, 抓取区半径 + 净空)，再按安全区夹取
```

**关键常量**（`WheelMenuGeometry`）：扇形半张角 ≤ **72°**、刀刃半张角 **30°**、
角度间隔夹在 **18°~30°**、环带半径下界 **76dp**、按钮 **44dp**（条目 ≥7 时 40dp）、
粗黑描边 **3dp**、中央缺口半径 = 环带半径 × **0.42**。

**偏移与安全区算法**（需求 §9）：

```text
1. 比较桌宠中心左右可用空间 → 得到自然方向；
2. 与上一次方向做**滞回**（死区 = 可用宽度 × 8%），中央缓冲区不反复翻转；
3. 菜单打开期间方向**锁定**（下次打开才重新判断）；
4. 求解轮盘中心的可放置区间：
     offset ≥ 抓取区半径 + 刀刃向内侵入量 + 净空(6dp)   ← 保证不压住桌宠抓取区
     offset ≤ 可用空间 − 刀刃长度 − 净空                 ← 保证窗口不越界
   区间为空 → 依次缩小半径（1.0/0.94/0.88/0.82/0.76/0.70）、
              收缩扇形（90°/80°/70°）、最后走 forcedPlan 并如实标记 degraded=true；
5. 垂直方向：轮盘中心可平移，但窗口必须整体落在安全区内；
6. 只调整菜单，**桌宠坐标一动不动**。
```

**镜像算法**：方向 `right` 为 `+offset`、`left` 为 `−offset`；
角度换算 `absoluteAngle(direction, offset) = normalizeAngle(base + direction.sign × offset)`
（`base` = 0° / 180°）。**取反**而不是相加，是为了让"下标越大越靠下"在两侧都成立。
图标与文字**只旋转、不水平翻转**（需求 §20.7）：标题倾斜角 = `sign × (−14° + offset × 0.3)`。

### 12.13.4 动画时序表（需求 §10）

统一时钟：`WheelAnimationRun` + `WheelAnimationClock.frame(run, now)`（**纯函数**，
`postOnAnimation` 逐帧驱动，只 `invalidate()`）。

| 动画 | 时长 | 分段 |
|---|---|---|
| 展开 | 300ms | 主体 0~120ms（scale 0.75→1.03→1.0 / rotation −6°→1°→0°）、按钮 50~230ms（错峰 ≈18ms/个）、标题与扇区 100~300ms |
| 根选项切换 | 220ms | 旧按钮收缩 → 沿弧线滑动 → 扇区连接点移动 → 新按钮弹起 → 标题分层进入 |
| 进入子菜单 | 300ms | 根按钮收回 → 扇区保留 → 标题切换 → 子菜单按钮重新弹出（返回键最后） |
| 返回 | 230ms | 进入子菜单的反向 |
| 关闭 | 180ms | 比展开更快 |
| 按下反馈 | 70ms | 压扁 → 回弹（与主时钟解耦，见下） |

缓动（**纯 Kotlin 三次贝塞尔**，不依赖 `PathInterpolator`，因此可 JVM 打靶）：
展开 `(0.16, 1.0, 0.30, 1.0)`、切换/换层 `(0.22, 0.85, 0.30, 1.0)`、
关闭 `(0.55, 0.0, 0.85, 0.35)`、按钮弹出 `(0.18, 1.36, 0.36, 1.0)`（轻量回弹，不弹跳过度）。

`selectionPosition` 是**连续浮点**（0.0 = 第一项），切换时插值而不是换索引；
`layerProgress` / `titleProgress` / `mirrorProgress` / `pressProgress` 同样在同一个结构里。

**按下反馈单独一条 run**：与主动画解耦，避免"点一下按钮把展开/换层动画顶掉"。

### 12.13.5 滑选角度与滞回（需求 §11）

```text
angle = normalizeAngle(atan2(py − cy, px − cx) − base) × direction.sign
raw   = angle / step + (n − 1) / 2
滞回：|raw − previous| < 0.5 + min(7°/step, 0.45)  → 保持上一个槽位
```

* **只用角度，不看水平位移**（下半圈用水平位移会判反）；
* 滞回 **7°**（需求 6~10°）；
* 分区：`中心缺口（dist < notchRadius）= 取消`、`滑选环带（≤ rimOuter）= 可选`、`环带之外 = 取消`；
* 短暂离开环带 **130ms** 内保持高亮，超时取消；
* **松手确认**：划过不执行 → 「隐藏」「停止服务」这类动作不会被误触发；
* 每跨一个槽位**一次轻触觉**（`WheelGestureOutcome.haptic`）；
* **不做惯性旋转**（需求 §11.5）：甩动最多按手指最后落点确认一项，绝不额外多滚。

### 12.13.6 手势互斥状态机（需求 §12）

两条手势链在**窗口层面**就分开（这是双窗口方案的额外收益）：

```text
轮盘窗口（WheelMenuGestureController）            桌宠窗口（OverlayGestureMachine，4C-3A 既有）
  Owner: none / pressing / swiping /                PRESSING →（>touchSlop）DRAGGING
         pendingOutside / cancelled                  （<阈值）点击；多指 → SCALING 取消
  · 按在按钮/环带 → press；移动 > 12dp → 滑选        · 按在桌宠 → 拖动
  · 按在空白/中心 → pendingOutside；抬手 → 关闭菜单    · 点桌宠 → 开关菜单（开着就关）
  · 多指 → 本轮一律取消                              · 菜单开着时开始拖动 → **先关菜单**再拖
```

* **所有权一旦确定，本轮触摸序列不再改变**（`Owner` 是单一枚举，不是若干布尔量）；
* 抓取区不被轮盘窗口覆盖（几何硬约束 + `WheelMenuGeometryTest` 断言）→
  "从桌宠区域按下拖动"永远归桌宠窗口，两条链不会互相抢；
* 点击阈值 **8dp**、滑选启动 **12dp**。

### 12.13.7 主题结构（需求 §13）

```text
WheelMenuTheme { themeId, displayName, primary, secondary, background,
                 highlight, outline, text, disabled, gradientEnabled,
                 animationStyle, revision }
```

默认主题 = 需求 §13.1 的 P3P 粉色（**逐字一致**）：

| 角色 | 值 |
|---|---|
| primary | `#F24D96` |
| secondary | `#FF8ABA` |
| background | `#FFD8E9` |
| highlight | `#FFD42A` |
| outline | `#111111` |
| text | `#FFFFFF` |
| disabled | `#8E7180` |

* 内置预设：**P3P 粉色 / 蓝色 / 红色 / 紫色 / 绿色 / 自定义**；
* 预设只钉一个主色，其余由 `WheelMenuThemes.custom()` **确定性派生**
  （secondary = 提亮 42%、background = 与白混 84%、highlight 固定 P3P 黄、outline 固定近黑）；
* **文字色自动选择**：白字对比度 ≥ 3.0（WCAG 大号粗体阈值）就用白色，否则用黑色 ——
  刻意偏向白字，因为"白字压在饱和主色上"才是 P3P 的视觉语言；
* `isLegible(theme)` 给设置页一句明确反馈，`contrastRatio()` 是标准 WCAG 计算（单测钉住 21:1 / 1:1）；
* **revision 守卫**：`menu.theme_revision` 单调递增，原生拒绝更旧的写入
  （Flutter 侧用 `getMenuTheme().revision + 1` 续接）；
* 持久化在原生 `SharedPreferences`（`overlay.menu.theme_id` / `theme_custom_primary` /
  `theme_revision`），因此**服务独立于 Flutter 运行时也能画对颜色**；
* 设置页改动 → 桥 `setMenuTheme` → 落盘 + **立即推给运行中的服务**（不重开菜单）。

### 12.13.8 统一动作接口（需求 §17）

```text
WheelMenuAction（39 个命令，wire 名稳定）
  ├─ navigation（本阶段真实生效）：openPetMenu / openAppearanceMenu / openRecordsMenu /
  │                                openToolsMenu / openSettingsMenu / back / closeMenu
  ├─ info（只读）：showInfo（"当前状态""当前应用""同步状态"…）
  └─ business（本阶段**结构化占位事件**）：其余全部（含 hideOverlay / selectTheme /
                                            stopOverlayService …）

WheelMenuActionDispatcher.dispatch(action, entryId, entry) → WheelActionOutcome{route, handled}
  └─ WheelMenuActionHost { onNavigateAction / onBusinessAction / onInfoAction }
       └─ PetOverlayManager 实现（导航 = 进子菜单 / 返回 / 关闭；业务 = host.onMenuAction 占位）
```

* **交互层永远只调用 `dispatch`**，不允许任何一处直接去调业务方法 ——
  否则"哪个是真的、哪个是占位"会散落在渲染代码里，4C-6B-2 接线必然漏。
* 业务占位事件的落地形式：结构化日志（`menu.action wire=… id=… route=business`）+
  一句 Toast + 诊断字段 `lastMenuActionPlaceholder=true`。
* `hideOverlay` 按需求 §17 的**字面口径**归入"其他动作"（占位）；
  它与 `selectTheme` 一样，真正的生效入口分别在 4C-6B-2 与设置页。

### 12.13.9 改动文件

新增（`android/app/src/main/kotlin/asia/akechi/petlife/overlay/`）：

| 文件 | 职责（需求 §6 的分层） |
|---|---|
| `WheelMenuModel.kt` | 命令枚举 / 层级目录（根 + 5 子菜单）/ 菜单栈 |
| `WheelMenuTheme.kt` | 主题模型、预设、派生、对比度、十六进制编解码 |
| `WheelMenuGeometry.kt` | 信封与参数化几何（按钮 / 环带 / 缺口 / 刀刃 / 镜像 / 偏移 / 安全区） |
| `WheelMenuState.kt` | 交互状态机（阶段 / 层级 / 选中 / 预览 / 方向锁定） |
| `WheelMenuAnimator.kt` | 缓动、时序表、动画时钟（纯函数） |
| `WheelMenuGesture.kt` | 手势控制器（点击 / 圆弧滑选 / 滞回 / 取消 / 分区） |
| `WheelMenuActionDispatcher.kt` | 统一命令分发与路由 |
| `WheelMenuRenderer.kt` | Canvas 绘制（刀刃 / 环带 / 齿轮缺口 / 装饰 / 按钮 / 文本） |
| `WheelMenuIcons.kt` | 原创 Vector 图标（Path 现场绘制，支持换色） |
| `WheelMenuView.kt` | 轮盘窗口根 View（状态机 + 手势 + 逐帧重绘 + 帧耗时统计） |

修改：

| 文件 | 改动 |
|---|---|
| `OverlayMenu.kt` | 只保留 `OverlayRect` + 窗口级状态机 + `canUpdateMenuWindow`；删除占位目录/旧几何/旧窗口模型 |
| `PetMenuView.kt` | **删除**（多 View 占位按钮 → 单个 Canvas View） |
| `PetOverlayManager.kt` | 菜单段整体换成轮盘：信封 + 层级切换 + 动作分发 + 主题下发 + 诊断 |
| `PetOverlayStore.kt` | 新增轮盘主题与外观的持久化键 + revision 守卫 + 距离比安全化 |
| `PetOverlayBridge.kt` | 新增 `getMenuTheme` / `setMenuTheme`；运行时状态增加 7 个轮盘诊断字段 |
| `PetOverlayService.kt` | 轮盘诊断快照 + `onMenuInfo` 只读信息 + 占位动作落地 + `applyMenuTheme` 静态入口 |
| `lib/platform/overlay_pet.dart` | 主题模型（色板 / 预设 / 状态 / 更新结果）+ 运行时诊断 7 字段 + 接口 2 方法 |
| `lib/platform/android/android_overlay_pet.dart` | `getMenuTheme` / `setMenuTheme` 的通道实现 |
| `lib/platform/android/...`（Unsupported） | 非 Android 读回默认色板、写抛 `OverlayUnsupportedException` |
| `lib/ui/overlay_pet_controller.dart` | `refreshMenuTheme` / `selectMenuTheme` / `menuThemeNextRevision` |
| `lib/ui/widgets/overlay_pet_card.dart` | 「轮盘主题」分区（预设色块 + 自定义 RGB 取色 + 轮盘只读诊断） |

测试：删除 `OverlayMenuWindowTest.kt` 与 `OverlayMenuTest.kt` 的几何部分（测的是已删除的占位菜单），
新增 `WheelMenuGeometryTest.kt` / `WheelMenuStateTest.kt` / `WheelMenuGestureTest.kt`
（含动画与主题），并在 `test/overlay_pet_controller_test.dart` 增加 7 条轮盘主题用例。

### 12.13.10 测试与构建结果

| 项目 | 结果 |
|---|---|
| Kotlin 单测 | **355 项全绿**（4C-6A.1 为 331；本轮新增 24、删除旧占位几何/窗口测试） |
| Flutter `analyze` | **No issues found** |
| Flutter 测试 | **733 项通过 + 1 skipped**（4C-6A.1 为 726 + 1） |
| 服务端 pytest | 本阶段不改服务端，未跑（**如实标注**） |
| Android Debug APK | 见 §12.13.11 |
| Windows Release | 未受影响（本轮只改 Android 原生 + Flutter 通用模型；未构建 Windows） |

覆盖对照（需求 §18）：

* **18.1 几何**：左右布局 / 安全区 / 屏幕四角 / 横屏 / 分屏 / 不同桌宠尺寸 / 菜单偏移 /
  返回键固定底部（含镜像）/ 所有按钮不越界 / 窗口不压抓取区 / 中央缓冲区方向不抖动 /
  所有层级共用同一窗口矩形。
* **18.2 状态机**：closed→root、root→submenu、多级返回、点击空白关闭、
  非法菜单路径、快速重复开关、动画中打断收敛、打开期间方向锁定。
* **18.3 手势**：点击、圆弧滑选、松手确认、滑出取消、回中心取消、槽位滞回、
  快速甩动最多前进一项、触觉每槽一次、多指取消、分区判定。
* **18.4 动画**：各段时长、缓动端点与单调性、展开/关闭、连续插值、按钮错峰、
  结束帧无漂移、换层按钮进度。
* **18.5 主题**：默认色板逐字一致、预设齐全、文字色自动选择、对比度数学、
  自定义派生确定性、十六进制往返、非法输入不抛错、`fromWire` 回落。
* **回归**：Kotlin 355 项 + Flutter 733 项全量通过（含素材导入 / 动态 WebP /
  状态联动 / 映射编辑器 / 使用统计 / 跨端同步 / 拖动吸附）。

性能与稳定性（需求 §15）：

* 使用 `postOnAnimation`（Choreographer）统一驱动，每帧只 `invalidate()`；
* `Paint` / `Path` / `RectF` / `Shader` 全部复用，`onDraw` 内**不分配对象、不查库、不读文件**；
* 文本宽度只在内容变化时测量一次；
* 菜单收起 / 窗口移除即停止动画时钟（`onDetachedFromWindow` + `stopTicker`），
  不留 `Timer` / `Animator` / `Drawable` 泄漏；
* 新增诊断：`menuLevel` / `menuActiveIndex` / `menuAnimation` / `menuGestureOwner` /
  `menuThemeId` / `menuPerformance`（`frames / avg / max / dropped`）/ `lastMenuActionPlaceholder`。

### 12.13.11 构建产物

| 项 | 值 |
|---|---|
| 命令 | `flutter build apk --debug --no-pub`（前置：`GRADLE_USER_HOME=%USERPROFILE%\.gradle`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`） |
| APK 路径 | `petlife/build/app/outputs/flutter-apk/app-debug.apk` |
| 另存副本 | `petlife-4C-6B1-4827B46F.apk`（仓库根目录，便于真机安装） |
| 大小 | **189,330,533 B** |
| 构建时间 | 2026-09-30 17:50:51 |
| SHA256 | `4827B46F80CDAA6615317E983298D89A07C863785B8C94F399413A0A504C5A24` |

Windows Release：本阶段只改 Android 原生菜单层与 Flutter 通用模型（`overlay_pet.dart` 等），
Windows 侧仍编译通过（`flutter analyze` 全绿），但**未重新构建 Windows Release**。

### 12.13.12 真机验收步骤（对应需求 §20 的 38 条）

前置：`adb install -r <APK>`，授予「显示在其他应用上层」与「使用情况访问」。

```text
[视觉]
 1. 单击桌宠 → 轮盘展开：确认是"非对称 P3P 战斗菜单"观感（大扇区 + 粗黑描边 + 齿轮缺口 +
    黄色装饰弧），不是一圈普通圆按钮。
 2. 主题应为 P3P 粉色（设置 → 悬浮桌宠 → 轮盘主题 → 当前：P3P 粉色）。
 3. 高亮扇区与按钮都有粗黑描边。
 4. 英文大标题 / 中文名称 / 说明三层清晰可读。
 5. 桌宠主体（脸与立绘）没有被轮盘遮住。
 6. 把桌宠拖到屏幕左侧再开菜单：轮盘向右展开；拖到右侧再开：轮盘向左展开。
 7. 镜像后图标与文字**没有被水平翻转**（文字仍从左到右读）。

[动画]
 8. 展开、关闭都平滑，没有"先闪一帧再动"。
 9. 点根菜单里的非导航项（如"隐藏"）：高亮沿弧线滑过去，不是瞬间跳。
10. 高亮扇区是连续移动/变形，不是图片硬切。
11. 标题分层进入（中文名先到、说明后到）。
12. 进入子菜单时轮盘**没有关闭再重开**（没有闪烁、没有窗口重挂）。
13. 点「返回」动画自然。
14. 连续快速点「返回」与再进入子菜单，不会卡死也不会跳到错误层级。

[手势]
15. 点按钮能选中并执行（导航项真进子菜单）。
16. 手指按在按钮上沿圆弧滑动时，高亮跟着手指走。
17. 每跨一个槽位只有**一次**轻触觉。
18. 松手执行当前高亮项。
19. 滑出环带或回到中心缺口后松手，**不执行**任何动作。
20. 菜单开着时按住桌宠拖动：先收起菜单再拖动，两条手势不互相抢。
21. 拖动结束不会误触发菜单（不会"拖完突然弹出菜单"）。

[几何]
22. 展开/关闭菜单时桌宠**一动不动**（可在诊断模式看 `menu.geometry.settled delta=(0,0)`）。
23. 展开后切换选项 / 进出子菜单，桌宠与菜单都不抽动。
24. 把桌宠拖到四个角再开菜单：轮盘不越出屏幕（超出状态栏/导航栏即为不通过）。
25. 横屏与分屏下仍能用（可能进入降级布局，但不得压住桌宠抓取区）。
26. 每个子菜单的「返回」都在视觉最下方（左右镜像都成立）。
27. 关闭菜单后桌宠区域完全恢复（点得中、拖得动）。

[主题]
28. 默认 P3P 粉色。
29. 设置 → 悬浮桌宠 → 轮盘主题：依次点蓝色/红色/紫色/绿色，轮盘立即变色（不用重开菜单）。
30. 点「自定义」→ 调 RGB → 应用：轮盘立即用新主色，文字自动变黑或变白。
31. 主题改动立即生效（无需重启服务）。
32. 杀掉应用并重启服务后，主题仍是你选的那个。
33. 任意主题下标题与图标都清晰可辨（对比度不足时设置页会提示）。

[回归]
34. 动态 WebP 仍正常循环播放。
35. 自动状态联动仍随前台应用切换（用设置页 17 项原生真值核对）。
36. 状态素材映射编辑器仍然生效。
37. 使用统计与跨端同步仍然正常。
38. 反复开关轮盘 50 次以上，观察内存无持续增长、无多个 Animator/Timer 泄漏
    （可看 `dumpsys meminfo asia.akechi.petlife` 与 `menuPerformance` 的 dropped 计数）。
```

### 12.13.13 本机无法完成、必须真机执行的验证（**不得声称通过**）

* 真机 38 条验收（含视觉观感、触觉、镜像、四角、横屏、分屏）**全部未执行**；
* 轮盘在真实 ROM 上的帧率与掉帧（本机只有 JVM 单测与编译，不是性能证据）；
* 与桌宠拖动的手感互斥、外部点击是否真的关闭菜单、菜单窗口是否真的不抢桌宠触摸；
* 主题在"服务独立运行（Flutter 已退出）"时的持久化表现。

**未通过上述真机验收之前，4C-6B-1 不得标记为通过。**

## 12.14 Phase 4C-6B-1.1：轮盘与桌宠融合、尺寸调节及边缘适配

> 需求：4C-6B-1.1 规格（轮盘围绕桌宠 / 窗口层级反转 / 缺口绑定桌宠 / 轮盘大小设置 /
> 垂直边缘适配 / 可读性重构 / 诊断字段）。
> **只修视觉、几何、尺寸与边缘适配，不进入 4C-6B-2。**

### 12.14.1 真机反馈的根因

| 反馈 | 根因 |
|---|---|
| 1 菜单与桌宠明显分离 | 4C-6B-1 把"菜单窗口不得覆盖桌宠抓取区"当成硬约束 → 偏移被推到 0.4~0.9 倍桌宠宽（实测某场景 443px ≈ 1.7 倍），轮盘被推离人物 |
| 2 轮盘占屏面积过大 | 扇形半张角 68° + 半径下界 76dp + 装饰过密；且窗口必须为正圆包围盒 |
| 3 没有轮盘大小设置 | 尺寸参数只有密度，没有用户可调项 |
| 4 标题/说明/图标可读性不足 | 英文标题与中文名分别放在 0.72 / 0.93 倍刀刃半径处，刀刃变短后**两者重叠**；字号无下限；描边 3dp 过粗；按钮无标签 |
| 5 顶部/底部时缺口与桌宠错位 | 为了让窗口落进安全区，把**轮盘中心整体平移**，但缺口跟着中心走 → 与桌宠分离 |
| 6 边缘适配移动了轮盘中心却没同步桌宠锚点 | 同上；轮盘中心与"桌宠锚点"是两个各自为政的量 |

**结论：问题 1/5/6 是同一个结构性问题** —— 4C-6B-1 的模型里没有"桌宠锚点"这个量，
只有"轮盘中心"，而窗口约束（避开抓取区 / 落进安全区）都在直接推这个中心。

### 12.14.2 窗口层级（需求 §2）

> ⚠️ **本节方案已被 §12.14.14 取代并作废。**
> "菜单窗口用更低窗口类型（`TYPE_SYSTEM_ALERT` / `TYPE_PHONE`）来造层级"在真机上
> **直接导致菜单完全不显示**。现行为：两种窗口用**同一个** `TYPE_APPLICATION_OVERLAY`，
> 层级靠 addView 先后（菜单后加 → 在上层），中央区域的拖动由菜单 View **主动转发**。
> 保留本节只为记录"为什么当初会这么想"，**不要照此实现**。

```text
        ┌────────────────────────────────────────┐
 上层   │  桌宠 Window（petWindowType）            │  ← 显示人物 + 负责拖动
        │  ┌──────────────┐                      │
        │  │  人物立绘     │                      │
        │  └──────────────┘                      │
        ├────────────────────────────────────────┤
 下层   │  轮盘 Window（menuWindowType，**更低**）  │  ← 画环带/刀刃/文字
        │        ╭─ 中央缺口（透明） ─╮            │     缺口处透出上层桌宠
        │       ╱   缺口中心 = 桌宠锚点   ╲          │
        └────────────────────────────────────────┘
```

* **删除**"菜单窗口不得与桌宠 grabRect 重叠"这条硬约束（4C-6B-1 的核心限制）；
* 两级层级靠**窗口类型**固定，而不是 addView 先后顺序 ——
  后者要求"重新添加桌宠窗口"，而需求明令禁止：
  * 桌宠窗口：`TYPE_APPLICATION_OVERLAY`(2038, API≥26) / `TYPE_SYSTEM_ALERT`(2003, 24~25)
  * 轮盘窗口：`TYPE_SYSTEM_ALERT`(2003, API≥26) / `TYPE_PHONE`(2002, 24~25)
  * 断言：`menuWindowType(sdk) < petWindowType(sdk)`（单测钉住，sdk 24/25/26/30/36）
* 缺口处**不需要任何窗口裁剪**：上层桌宠天然透出，触摸也天然归桌宠窗口（缺口命中判定为取消区）；
* ⚠️ 若某 ROM 无视类型顺序，症状是"菜单打开时拖不动桌宠" —— 属于真机验收第 21 条要抓的问题。

### 12.14.3 petAnchor / holeAnchor 算法（需求 §3）

```text
petVisibleRect = 素材的**视觉边界**（alpha 包围盒）折算到屏幕
                 （PetAlphaBounds.measureFile：inSampleSize 采样解码 + 扫描 alpha，
                  阈值 12；失败/全透明 → 回退整张图；再退化时按窗口的 86% 兜底）
petAnchor      = petVisibleRect.center
holeRx         = petVisibleRect.width  × 1.04 / 2
holeRy         = petVisibleRect.height × 0.90 / 2
off            = clamp(petVisibleRect.width × menuDistance, ≥ 4dp)     // menuDistance 默认 0.16
wheelCenter    = petAnchor + direction.sign × off        // 垂直方向**不动**
notchCenter    = petAnchor                                // 永远压在人物锚点上
```

**三条不变量（单测钉住）**：

```text
1. notchCenter == petAnchor                       （三种垂直模式 + 四角 + 左右镜像都成立）
2. distance(wheelCenter, petAnchor) == off ≤ allowedOffset
3. 按钮圆与 petVisibleRect 不相交                  （否则按钮会被上层桌宠盖住、点不到）
```

不变量的**代价**被显式接受：环带半径必须 ≥ `petClearanceRadius`
（桌宠可见矩形四角到轮盘中心的最大距离 + 按钮半径 + 净空），
因此"轮盘永远比人物大一圈"是几何必然 —— 这是"围绕"而不是"避开"的代价。

### 12.14.4 垂直模式与滞回（需求 §8）

| 模式 | 触发（比较桌宠锚点上下可用空间） | 布局后果 |
|---|---|---|
| `CENTER` | 上下空间相近 | 标准扇形，`fanBias = 0°` |
| `TOP_EDGE` | 上方空间 < 下方 × 0.55 | 扇形**向下偏 26°**，顶部装饰减少，必要时降 `actualScale` |
| `BOTTOM_EDGE` | 下方空间 < 上方 × 0.55 | 扇形**向上偏 26°**，底部装饰减少，返回键取安全区内最靠下的槽位 |

* **绝不平移轮盘中心**（那正是问题 5/6 的根因）：靠边只改扇形朝向与缩放；
* 偏转通过 `absoluteAngle(direction, offset + fanBias)` 与
  `rawIndexAt`（减去 bias）统一进角度换算，因此手势命中与绘制**永远一致**；
* 滞回：死区 = 安全区高度 × 6%，阈值附近不反复切换（单测钉住）；
* 菜单打开期间方向与垂直模式**一起锁定**（下次打开重新判断）。

### 12.14.5 preferredScale / actualScale / compactMode（需求 §5 / §7 / §9）

```text
preferredScale  = 用户在设置页选的值（0.60 ~ 1.20，5% 步进，默认 0.78）
actualScale     = min(preferred, 放得下的最大比例)，且恒 ≥ 0.60
```

求解顺序（`computeEnvelope`）：

```text
1. 先按 preferredScale 连续降档尝试（0.06 一档，不切紧凑）
2. 全部放不下 → 打开 compactMode 再降档
3. 仍放不下 → 记下"能包住缺口"的最好方案并标记 degraded=window-clamped
4. 最后兜底 forcedPlan（缺口优先，外圈装饰允许被裁）→ degraded=min-scale
```

"放得下"的判定只看**环带 + 刀刃**的包围盒：必须落在安全区内，且
宽度 ≤ 安全区 65%（紧凑 55%）、高度 ≤ 70%（紧凑 60%）。
中央缺口在屏幕边缘被裁是**正常且无害**的（缺口是透明的，那一侧还被上层桌宠盖着）。

`compactMode` 的表现：扇形半张角 68°→50°、按钮直径 ×0.92、装饰点减半、缺口齿数 7→5、描边取更细的一档。

### 12.14.6 可读性（需求 §10）

**文本安全区**（`WheelTextLayout`，纯函数）：

```text
bandStart = ringRadius + buttonDiameter/2 + 4dp     ← 按钮圆**外侧**（旧版从环带内缘起排 → 压住高亮按钮）
bandEnd   = bladeLength
titleRadius = bandStart + band × 0.30      chipRadius = bandStart + band × 0.72
infoRadius  = bandStart + band × 0.93
可用宽度    = 2 × radius × sin(bladeHalfSweep × 0.78)   ← 只取张角的一部分，不顶到扇区尖角
```

| 文字 | 最小字号 | 说明 |
|---|---|---|
| 英文装饰标题 | 13sp | 倾斜角收敛到 **±8°**（原为 −14°+跟随，容易越界） |
| 中文名称 | **16sp** | 倾斜 ≤ **3°**；放不下时先缩到最小字号，再逐字省略 |
| 说明 / 实时信息 | 11sp | 同上 |
| 按钮中文标签 | 10sp | **仅根菜单**；画在按钮**外侧**径向，镜像后位置跟着翻但文字不翻转 |

* `fitText()`：先按 0.92 递减缩到最小字号，仍放不下就逐字加 `…` 省略 ——
  **绝不返回超出可用宽度的字符串**（这正是"标题越过按钮和扇区边界"的修复点）；
* 描边基准 3dp → **2.2dp**，并带 1.2~4.5dp 上下限；
* 三层文字在径向上各占一段，标题与中文名的间距 ≥ 两者半行高之和（单测钉住）。

### 12.14.7 尺寸设置与持久化（需求 §5 / §16）

* 原生键：`overlay.menu.scale` / `button_scale` / `compact` / `layout_revision`，
  与主题键**分线**（各有独立 revision 守卫）；
* 桥：`getMenuLayout` / `setMenuLayout`；比例会被**吸附到 5% 步进**并夹到 0.60~1.20；
* 设置页：设置 → 悬浮桌宠 → 轮盘主题 → **轮盘大小**（滑块 + 当前百分比 + 恢复默认）；
* 生效口径：
  * 菜单**关着**改 → 直接保存，下次点击桌宠即用新尺寸；
  * 菜单**开着**改 → **立即收起菜单**（不重开、不闪），下次打开用新尺寸；
  * 服务重启后保留（落在原生 SharedPreferences）。

### 12.14.8 诊断（需求 §14）

新增结构化日志与字段（**只在布局变化时打，不逐帧**）：

```text
wheel_layout_computed  bounds/petWindow/petAnchor/hole/wheelWindow
wheel_layout_bounds    asset/bounds（视觉边界测量结果）
wheel_layout_settings_updated  scale 新旧值 + compact
menu.open 摘要同时带：dir / vmode / scale(preferred→actual) / compact / degraded / anchorDist
```

原生运行时状态新增/沿用可读字段：`menuLevel / menuActiveIndex / menuAnimation / menuGestureOwner /
menuThemeId / menuPerformance / lastMenuActionPlaceholder`（设置页「轮盘」一行可见）。

### 12.14.9 改动文件

| 文件 | 改动 |
|---|---|
| `PetContentBounds.kt` | **新增**：alpha 包围盒测量（采样解码 + 纯函数判定），含"采样率/相对边界"纯逻辑 |
| `WheelMenuGeometry.kt` | **重写核心**：`WheelMenuEnvelope` 增加 petAnchor / holeRx,Ry / fanBias / actualScale / compact；删除"避开抓取区"约束；新增 `WheelVerticalMode`、`WheelMenuLayoutSettings`、`petVisibleRect`、`petClearanceRadius`、`WheelTextLayout`；`absoluteAngle`/`rawIndexAt` 支持扇形偏转 |
| `PetOverlayStore.kt` | 窗口类型拆成 `petWindowType` / `menuWindowType`（菜单更低）；新增轮盘布局键与 `menuLayoutSettings()` / `writeMenuLayoutSettings()` |
| `PetOverlayManager.kt` | 轮盘窗口改用低层级类型；打开时按视觉边界 + 设置算信封；新增 `setPetContentBounds` / `applyMenuLayoutSettings` + 垂直模式滞回状态 |
| `PetOverlayService.kt` | 素材加载成功后**后台线程**量一次视觉边界并回传；`applyMenuLayoutSettings` 静态入口；销毁时关掉测量线程 |
| `PetOverlayBridge.kt` | 新增 `getMenuLayout` / `setMenuLayout` |
| `WheelMenuGesture.kt` | 中央缺口改为**椭圆**判定（`insideNotch`），与缺口绑定一致 |
| `WheelMenuRenderer.kt` | 椭圆缺口 + 齿；装饰随 compact 减量；三层文字改用 `WheelTextLayout` + 最小字号 + 省略；新增按钮中文标签；描边收细；倾斜角收敛 |
| `WheelMenuView.kt` | 渲染参数补 density / 根菜单标签开关；几何不再依赖 petRect |
| `lib/platform/overlay_pet.dart` | 新增 `OverlayWheelLayoutSettings` / `OverlayWheelLayoutUpdate` + 接口 2 方法 |
| `lib/platform/android/android_overlay_pet.dart` | `getMenuLayout` / `setMenuLayout` 通道实现 |
| `lib/ui/overlay_pet_controller.dart` | `refreshWheelLayout` / `setWheelScale` / `wheelLayoutSettings` |
| `lib/ui/widgets/overlay_pet_card.dart` | 「轮盘大小」滑块 + 恢复默认 + 说明文案 |

测试：`WheelMenuGeometryTest` 重写（锚点/尺寸/垂直模式/可读性）、
`OverlayLogicTest` 的窗口类型断言改为 pet/menu 两级 + 层级序断言、
`WheelMenuGestureTest` 的 prepare 适配新 API。

### 12.14.10 测试与构建结果

| 项目 | 结果 |
|---|---|
| Kotlin 单测 | **364 项全绿**（4C-6B-1 为 355；本轮 +9） |
| Flutter `analyze` | **No issues found** |
| Flutter 测试 | **733 通过 + 1 skipped**（与 4C-6B-1 持平；本轮 Dart 侧新增模型/控制器/UI，**未新增 Dart 用例**） |
| 服务端 pytest | 未跑（本轮不改服务端） |
| Android Debug APK | 见 §12.14.11 |
| Windows Release | 未构建（本轮只动 Android 原生 + Flutter 通用模型） |

覆盖对照（需求 §15.1 / §15.2 / §15.3）：

* **锚点**：三种垂直模式缺口对准、左右镜像、四角、横屏、分屏、不同桌宠尺寸、
  透明留白素材（缺口更小）、`anchorDistance ≤ allowedOffset`；
* **尺寸**：0.60 / 默认 / 1.20 的实际缩放区间与单调性、极窄屏进入 compact、
  缩放值夹取与 5% 步进吸附、按钮直径层级一致、**按钮不压住桌宠可见矩形**；
* **可读性**：文本安全带完全在按钮圆之外、三层半径单调、最小字号（13/16/11sp）、
  标题与中文名径向不重叠、可用弦长随半径单调；
* **窗口层级**：`menuWindowType < petWindowType`（24/25/26/30/36）；
* **回归**：全量 Kotlin 364 + Flutter 733+1 通过。

### 12.14.11 构建产物

| 项 | 值 |
|---|---|
| 命令 | `flutter build apk --debug --no-pub`（前置：`GRADLE_USER_HOME=%USERPROFILE%\.gradle`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`） |
| APK 路径 | `petlife/build/app/outputs/flutter-apk/app-debug.apk` |
| 另存副本 | `petlife-4C-6B1.1-CB205B8A.apk`（仓库根目录） |
| 大小 | **189,337,780 B** |
| 构建时间 | 2026-09-30 18:27:52 |
| SHA256 | `CB205B8A8339276627384E2B9184E6725BF350794B2655E9EA724F0C9423FF11` |

Windows Release：未构建（本轮只动 Android 原生菜单层与 Flutter 通用模型，`flutter analyze` 全绿）。

### 12.14.12 本阶段**未实现**的部分（如实标注）

1. **需求 §12 的"打开期间 180~220ms 几何插值"** 未实现 ——
   当前口径是"开着菜单改尺寸则立即收起菜单，下次打开用新尺寸"（见 §12.14.7）。
   原因：几何变化必然要重算窗口，而"打开期间窗口不变"是 4C-6B-1 的硬约束；
   做插值需要"旧窗口内插值到新几何 + 动画结束后一次性改窗口"的两段式方案，本轮未做。
2. **垂直模式切换的插值**同样未做 —— 但垂直模式在菜单打开期间是**锁定**的，
   因此不存在"打开时瞬间跳动"的问题。
3. **未新增 Dart 侧用例**（模型/控制器有实现但只有 analyze 保障）。
4. **`compactMode` 用户强制开关**已贯通桥接，但设置页本轮只暴露"轮盘大小"滑块，
   未加"强制紧凑"开关。

### 12.14.13 真机验收步骤（对应需求 §17 的 25 条）

```text
前置：adb install -r <APK>，授予悬浮窗权限；把一个带透明留白的角色立绘设为桌宠。

[融合]
 1. 默认轮盘明显比 4C-6B-1 更紧凑（扇形更窄、装饰更少、整体更小）。
 2. 桌宠**位于轮盘中央缺口内**（人物在缺口里，不是被轮盘推开）。
 3. 展开/关闭菜单时桌宠屏幕位置不变（诊断可见 delta=(0,0)）。
 4. 桌宠靠左 → 向右展开；靠右 → 向左展开。
 5. 桌宠贴到屏幕**顶部**：缺口仍对准人物，扇形更多向下展开。
 6. 桌宠贴到屏幕**底部**：缺口仍对准人物，扇形更多向上展开。
 7. 四个角都不分离（缺口中心始终压在人物锚点上）。
 8. 横屏与分屏下不越界（可能自动紧凑）。
 9. **菜单打开时按住人物仍能拖动桌宠**（先收菜单再拖）—— 这条同时验证窗口层级；
    若拖不动，说明该 ROM 无视窗口类型顺序，请回报。
10. 拖动结束后不会误开菜单。

[尺寸]
11. 设置 → 悬浮桌宠 → 轮盘主题 → 轮盘大小：可从 60% 拉到 120%。
12. 改完关闭设置页 → 点桌宠：轮盘按新尺寸出现。
13. 重启服务（停止→显示）后尺寸仍保留。
14. 点"恢复默认"回到 78%。

[可读性]
15. 主扇区里英文标题与中文名**不重叠、不越出扇区**。
16. 中文标题清晰（≥16sp），在系统字号调大时不糊成一团。
17. 根菜单六个按钮都有可读的中文标签（返回键除外）。
18. 描边不再糊住字（比 4C-6B-1 更细）。
19. P3P 粉色主题仍是白字；切到浅色自定义主题时自动变黑字。

[交互回归]
20. 点击按钮、圆弧滑选、松手确认、槽位滞回都正常。
21. 中央人物区域可拖动；按钮区域不会拖动桌宠。
22. 开关菜单不抽动；窗口只展开一次、关闭一次。
23. 动态 WebP 不重启、不闪烁。
24. 自动状态 / 状态映射 / 使用统计 / 跨端同步无退化。
25. 反复开关轮盘 50 次以上，内存无持续增长（`menuPerformance` 的 dropped 计数不持续上升）。
```

**未通过上述真机验收前，4C-6B-1.1 不得标记为通过，也不得进入 4C-6B-2。**

### 12.14.14 真机回归修复：点击桌宠无法显示菜单

**现象**：装上 4C-6B-1.1 首版后，点击桌宠**完全没有菜单**（上一版 `4827B46F` 正常）。

**根因**：本阶段为了让"桌宠窗口盖在菜单窗口之上"，把**菜单窗口**的窗口类型改成了
`TYPE_SYSTEM_ALERT`(2003)（API≥26）/ `TYPE_PHONE`(2002)（24~25），同时把桌宠窗口
在 API 24~25 改成 `TYPE_SYSTEM_ALERT`。
这些类型在 Android 8+ 属**遗留/废弃**类型，各 ROM 行为不一致：
本机表现为菜单窗口 `addView` 后**不显示**（或直接被拒），而异常当初被 `catch` 后
只写了日志、没有落到任何可读诊断里 —— 于是"看不出来任何菜单"。

**为什么不改点击阈值/手势**：点击链路（`ACTION_DOWN` → 未超 slop → `ACTION_UP` →
`onPetClick` → `requestOpenMenu` → `addMenuWindow`）本次**一行未动**，
问题在窗口能否真正显示，不在触摸识别。

#### 修复内容

| # | 修复 |
|---|---|
| 1 | **两种窗口统一用 `TYPE_APPLICATION_OVERLAY`**（API 26+）；API 24~25 沿用 4C-2 起已验收的 `TYPE_PHONE`（不再用 `TYPE_SYSTEM_ALERT` 造层级）。层级 = addView 先后（菜单后加 → 在上层）。单测钉住"两种窗口类型必须完全相同"。 |
| 2 | **中央区域拖动改为主动转发**：菜单在上层，缺口处触摸仍归菜单窗口，因此按在人物身上拖动 → `WheelMenuView` 判为 `petDrag` → 转发给 manager 移动桌宠窗口；拖动期间**不画轮盘**（View 保持 VISIBLE，触摸流不断）；拖动结束**先收菜单**再走既有贴边 + 落盘链路（需求 §13）。 |
| 3 | **addView 异常不再被吞**：记录 `异常类全名: message` + `type/flags/rect`，写入 `lastMenuOpenError`；并在**下一帧**核对 `isAttachedToWindow`，未附着则记 `addView-ok-but-not-attached`（区分"抛异常"与"被系统静默拒绝"）。 |
| 4 | **可判定诊断**：新增一行 `menuOpenDiagnostics`，把"点击 → 请求 → addView → 附着 → 可见性 → 窗口矩形 → 两种类型 → 错误"串成可读字段，写入日志、运行时状态与设置页。 |
| 5 | **失败回滚**：addView 失败 → `menuState` 回 `closed`；不保留 opening；不建 View/Animator；桌宠照常可拖可点；下次点击可重试。 |

#### 诊断字段（设置页「轮盘」区块可直接看）

```text
tap=1 req=1 addAttempt=1 addOk=1 attached=1 vis=VISIBLE
bounds=(x,y w x h) types=2038/2038 err=<none>
```

五种缺口的判读方式：

| 组合 | 结论 |
|---|---|
| `tap=0` | 没收到点击（触摸链路问题） |
| `tap=1 req=0` | 收到点击但没请求打开（状态机/几何被拒，看 `err`） |
| `req=1 addAttempt=1 addOk=0` | `addView` 抛异常（`err` 里是完整异常类与 message） |
| `addOk=1 attached=0` | `addView` 返回成功但被系统拒绝（多为窗口类型/权限问题） |
| `attached=1 vis=VISIBLE bounds=...` 但仍看不见 | 窗口在其它窗口下方，或几何被算到了屏幕外（对比 `bounds` 与屏幕尺寸） |

#### 本轮验证

| 项目 | 结果 |
|---|---|
| Kotlin 单测 | **368 项全绿**（新增：窗口类型同类型断言、中央区域 petDrag 转发、按钮区不触发拖动、alpha bounds 不影响按钮命中） |
| Flutter `analyze` | No issues found |
| Flutter 测试 | 本轮未重跑（Dart 侧只加了一个诊断字符串字段；`analyze` 已过） |
| APK | `petlife-4C-6B1.1-fix-CBC50754.apk`，189,338,336 B，18:49:44，SHA256 `CBC50754B5378E8D7538B4395298877D53716583F2668B4095F041B8DAB5576F` |

#### 真机验收顺序（本轮**只验这 5 条**，通过后再谈尺寸与边缘布局）

```text
1. 点击桌宠能看到菜单（先解决"看不见"）
2. 菜单显示在其他应用之上
3. 桌宠能透过中央缺口显示
4. 菜单关闭后桌宠仍可拖动
5. 连续点击不会产生多个菜单
若第 1 条仍失败：把设置页「轮盘」那一行的 menuOpenDiagnostics 整行发我，不用猜。
```

## 12.15 Phase 4C-6B-1.2：轮盘视觉修复与功能接入（进行中）

> 需求：4C-6B-1.2 + 4C-6B-2 合并规格。按用户要求分三个内部增量：
> **A（视觉与层级）→ B（业务功能）→ C（回归与交付）**。
> 本节只记录**已完成的部分**；A3 与增量 B 尚未开始。

### 12.15.1 本文档状态

| 增量 | 状态 |
|---|---|
| A · 几何/视觉（按钮比例、文字不裁切、消除空白） | **已完成**（§12.15.2 / §12.15.3） |
| A2 · 桌宠覆盖菜单（单一视觉来源） | **已完成后于 A2.1 整体删除**（§12.15.4 为历史记录） |
| A2.1 · 撤销桌宠隐藏机制 + 轮盘/按钮范围扩到 50%~250% | **已完成**（§12.15.7） |
| A3 · 四方向布局与边缘适配 | **未开始**（用户明确要求本轮不开始） |
| A · 动画调整（scale 0.88→1.0、子菜单按钮淡入淡出） | **未开始** |
| B · 六个根菜单业务接入 | **未开始**（仍只发结构化占位事件） |
| C · 统一全量验证与交付 | **部分完成**（已出 A2.1 验收用 APK，见 §12.15.7.5） |

### 12.15.2 按钮比例与无效空白

| 问题 | 修法 |
|---|---|
| 菜单很大但按钮很小 | 按钮直径 = `基准 × 轮盘缩放 × **按钮缩放**`；"按钮大小"是**独立设置**（80%~140%，默认 **130%**，键 `overlay.menu.button_scale`），不再靠整体放大轮盘 |
| 环带内一圈无效纯色 | 中央缺口改为**贴着按钮轨道内缘**：`notchR = max(桌宠需求, R − 按钮半径 − 4dp)` —— 保留"缺口必须包住桌宠"这条下界 |
| 视觉与点击分离 | 命中仍是**角度判定 + 整条环带**，按钮视觉缩小不会让点击范围跟着缩（需求 §4.2） |

设置页新增「按钮大小」滑块（与「轮盘大小」并列，各自独立、各有恢复默认）。

### 12.15.3 文字不裁切

窗口包围盒以前只算"环带 + 刀刃"，**漏了文字**，所以真机上六个根按钮的中文被窗口矩形裁掉。
现在 `menuWindowEnvelope` 并入：

```text
环带外圈 + 刀刃 + 旋转后的文字 AABB + 中央缺口 + 10dp 安全边距
```

文字 AABB 用"最长中文标签（7 字：自定义快捷入口）"作上界，径向按倾斜 8° 放大 1.7 倍（保守）。

### 12.15.4 A2：桌宠覆盖菜单 —— 单一视觉来源（**A3 已改为"结构上不可能隐藏"**）

> ⚠️ **本节记录的是 A2 首版方案，该方案在 A3 被判定为失败并整体删除。**
> A2 曾引入 `PetVisualOwner`（`PET_WINDOW` / `MENU_FOREGROUND`）所有权切换：
> 菜单窗口先取前景快照并画人物首帧，**下一帧**再把原窗口内容隐藏
> （`imageView.imageAlpha = 0`），并靠 `dispatchDraw` 每帧回调在
> `petVisualOwner == MENU_FOREGROUND` 时刷新菜单窗口。
>
> **两次真机回归均出现"打开菜单后桌宠消失"** —— 这条切换链任何一环失败，
> 两个窗口就都不画人物。因此 A3 **彻底删除**该机制，改为：
>
> ```text
> 原桌宠窗口永远自己绘制自己（PET_WINDOW，不可切换）
> 菜单窗口只在人物区域打透明洞（PorterDuff.CLEAR），绝不持有桌宠 Drawable
> ```
>
> 删除清单与不变式见 §12.15.7。**本节其余内容仅作历史记录，不代表当前实现。**

A2 历史实现要点（已删除）：

1. ~~菜单窗口先拿前景快照画出人物首帧，下一帧隐藏原窗口内容~~
2. 不摘窗口：原桌宠窗口保持 attached，`LayoutParams` 一个字段都不改（**该结论保留，仍是当前实现**）
3. ~~前景快照只持有当前 Drawable 的引用 + 内容层尺寸~~
4. ~~`PetOverlayView.dispatchDraw` 每帧回调作为共用帧时钟~~
5. ~~拿不到快照时不做切换，保持原窗口绘制~~
6. 绘制顺序：轮盘背景 → 装饰 → 按钮 → 按钮文字 → 人物（**该结论保留**：人物由下层桌宠窗口透出）

### 12.15.5 本轮验证与产物

| 项目 | 结果 |
|---|---|
| Kotlin 单测 | **368 项全绿** |
| Flutter `analyze` | No issues found |
| Flutter 测试 | 本轮未跑（Dart 侧只加了独立滑块与字段；`analyze` 已过） |
| APK（A2 预验收） | `petlife-4C-6B1.2-A2-A49DD873.apk`，189,340,209 B，19:35:52，SHA256 `A49DD8735BE048C93D459D1AD3B2408FDF70D232A487CD0BC41A739DA3BF0D7D` |

### 12.15.6 可以先用这个 APK 验的（A2 范围内）

```text
1. 按钮明显变大、占轮盘比例合理
2. 六个根按钮的中文标签完整可见（不被窗口裁切）
3. 桌宠完整覆盖在菜单前面（人物在轮盘之上）
4. 不存在两份人物/重影
5. 动态 WebP 连续播放（菜单开着时也不停）
6. 开关菜单时人物不闪烁、不消失
7. 菜单关闭后桌宠仍正常显示与拖动
8. 菜单打开时按住人物仍能拖动桌宠（拖动期间轮盘不可见，松手后菜单关闭）
```

**A3（四方向布局）与增量 B（业务功能）未做，因此"上下左右/四角不偏移"这一条本轮无法验收。**

### 12.15.7 A2.1：撤销桌宠隐藏机制 + 尺寸范围扩展到 50%~250%

> 触发原因：上一轮交付遗漏两项核心要求 ——
> ① 只把 `setSourceHidden(true)` 改成 no-op，**隐藏机制本身仍在**；
> ② 文档写着"未改动尺寸范围"，而要求是轮盘/按钮都要到 **50%~250%**。

#### 12.15.7.1 桌宠隐藏旧架构删除清单

| 类别 | 符号 | 位置 | 处理 |
|---|---|---|---|
| 枚举 | `PetVisualOwner`（含 `MENU_FOREGROUND`） | `WheelMenuGesture.kt` | **删除**（无引用） |
| 方法 | `setSourceHidden(hidden: Boolean)` | `PetOverlayView.kt` | **删除**，替换为 `ensureSourceVisible(): Boolean` |
| 属性 | `isSourceHidden` | `PetOverlayView.kt` | **删除** |
| 调用点 | `enforcePetAlwaysVisible` 读 `isSourceHidden` / 写 `setSourceHidden(false)` | `PetOverlayManager.kt` | 改为只调 `ensureSourceVisible()`；仅当真的纠正过才记 ERROR |
| 诊断 | `sourceHidden=${if (view?.isSourceHidden == true) 1 else 0}` | `PetOverlayManager.dump()` | 改为常量片段 `PetVisualInvariant.diagnosticSegment()` |
| 死代码 | `petVisualOwnerName` | `PetOverlayManager.kt` | **删除**（无引用） |

**确认本就不存在**（更早已删）：`PetForegroundSnapshot`、`onPetForegroundDrawn`、
`menuGeneration`、`setPetForeground`、`invalidatePetLayer`，以及任何 `imageAlpha = 0` 写入。
全仓搜索 `setSourceHidden` / `PetVisualOwner` / `MENU_FOREGROUND` 均为 **0 处**。

固定不变式（`OverlayMenu.kt` 的 `PetVisualInvariant`）：

```text
owner=PET_WINDOW sourceHidden=0 foregroundCopy=disabled
```

* 设置页诊断恒输出该片段，与菜单状态、层级、生命周期路径**无关**；
* `enforcePetAlwaysVisible` 仍在 4 条路径被调用（`diagnostics` / `menu-open` / `pet-drag` /
  `remove-menu-window:*`），正常路径**零日志**（需求 §20 禁止稳定态刷 INFO）；
* 新增 `PetVisualInvariantTest`：遍历全部 `OverlayMenuState × OverlayMenuEvent`（含二次转移）
  断言片段恒定，并断言状态机**不存在**带 `hide/hidden/foreground/owner/source` 语义的事件与状态。

#### 12.15.7.2 轮盘大小 50%~250% 完整调用链

| 环节 | 位置 | 实现 |
|---|---|---|
| 常量 | `WheelMenuLayoutSettings` | `MIN_SCALE=0.50` `MAX_SCALE=2.50` `STEP=0.10` `DEFAULT_SCALE=1.00` |
| 归一 | `normalized()` → `clampScale` | 非有限值→1.00；越界→夹取 |
| 吸附 | `quantizeScale` | 吸附到 10% 网格 |
| 持久化 | `PetOverlayStore`（`KEY_MENU_SCALE`） | `getFloat/putFloat` + `normalized()` |
| Bridge 读 | `menuLayoutState()` | 序列化 `minScale/maxScale/step/defaultScale/preferredScale` |
| Bridge 写 | `applyMenuLayout()` | `quantizeScale(rawScale)` |
| Dart 模型 | `OverlayWheelLayoutSettings` | `minScale/maxScale/step/defaultScale` + `fromMap` 夹取 |
| Dart 控制器 | `setWheelScale` | 透传 revision 守卫 |
| Flutter UI | `overlay_pet_card.dart` | `Slider(min: settings.minScale, max: settings.maxScale)`，`divisions=(max-min)/step=20` |
| 恢复默认 | 「恢复默认」按钮 | `defaultScale` = 1.00 |
| 测试 | Kotlin / Dart | 常量、夹取、吸附、越界、百分比文案 |

顺带修掉一处**静默夹取**：`WheelMenuGeometry.intrinsicLayout` 里刀刃伸长原为
`preferredScale.coerceIn(0.6f, 1.2f)`，会把 120% 以上的设置夹回旧范围（表现为"调大了没反应"），
现改为 `coerceIn(MIN_SCALE, MAX_SCALE)`。

#### 12.15.7.3 按钮大小 50%~250% 完整调用链

与轮盘同构（`MIN_BUTTON_SCALE=0.50` / `MAX_BUTTON_SCALE=2.50` / `DEFAULT_BUTTON_SCALE=1.30`），
另加：

* 新增 `BUTTON_STEP=0.10` 与 `quantizeButtonScale`，Bridge 写入时吸附 10% 步进；
* Flutter 按钮滑块 `divisions` 由硬编码 `0.05` 改为 `(max-min)/step`（=20）；
* **按钮放大时轨道半径自动外扩**：`ringRadius = max(spacingRadiusPx, minRadiusForNotch, clearance, MIN_RADIUS)`
  —— 相邻按钮不重叠（已有测试：250% 时相邻弦长 ≥ 按钮直径）；
* **按钮缩小时触控下限不缩**：`buttonTouchDiameterPx = max(视觉直径, 48dp)`（已有测试：50% 时 ≥ 48dp）；
* 「恢复默认」= `defaultButtonScale` 1.30。

#### 12.15.7.4 本轮验证

| 项目 | 结果 |
|---|---|
| 全局搜索 `setSourceHidden(true)` | **0 处**（符号已整体删除） |
| Kotlin 单元测试 | **BUILD SUCCESSFUL**（全绿，含新增 `PetVisualInvariantTest`） |
| Flutter `analyze` | **No issues found** |
| Flutter `test` | **737 通过 + 1 skipped**（较 4C-6B-1.1 的 733 增加 4 条尺寸范围用例） |
| `flutter build apk --debug` | **成功** |

#### 12.15.7.5 产物

| 项目 | 值 |
|---|---|
| APK 路径 | `build/app/outputs/flutter-apk/app-debug.apk` |
| 大小 | 189,384,234 B |
| 构建时间 | 2026-09-30 20:43:16 |
| SHA256 | `AC7F4BF9147D60BF6611549A5DE9AADD0CC7706DE54E9DFF47072B11609C0596` |
| 另存副本 | `petlife-4C-6B1.2-A3-AC7F4BF9.apk`（仓库根目录，便于真机安装） |

> 本轮**保留**上一轮已完成的视觉改动：菜单透明窗口、基于人物 alpha bounds 的紧凑圆角保护区、
> 只绘制按钮轨道附近的窄扇形带、人物/素材不可用时拒绝打开或关闭菜单、既有触摸优先级不变。
> **未触及**窗口生命周期与尺寸范围以外的几何算法。

## 12.16 Phase 4C-6B-2 架构验证包：单窗口分层（人物覆盖菜单）

> 触发原因：真机上"打开菜单后桌宠仍消失""桌宠不能真正覆盖菜单"。
> 此前用**两个窗口**（菜单窗口在上）+ `PorterDuff.CLEAR` 在人物区域**挖透明洞**，
> 本质是"避让"而不是"覆盖"，真机不可靠。用户明确否定了这套方案。

### 12.16.1 架构变更：两个窗口 → 一个窗口两个绘制层

```text
一个透明悬浮窗口（既有 PetOverlayView，本身就是 FrameLayout）
└── PetOverlayView
    ├── index 0  menuHost(FrameLayout) → WheelMenuView   下层：菜单背景/装饰/按钮/文字
    └── index 1  petContent(FrameLayout) → ImageView     上层：桌宠（同一个实例，全程不变）
```

绘制顺序即子 View 顺序：**菜单 → 人物**，人物天然覆盖菜单；人物透明像素自然透出后方菜单。
不再有第二个窗口、不再换窗口类型、不再重复 addView 调整层级。

### 12.16.2 删除项（避免"挖洞避让"残留）

| 删除 | 位置 |
|---|---|
| `WheelMenuRenderer.clearPetHole()` 及其调用 | 渲染层 |
| `holePaint`（`PorterDuffXfermode(CLEAR)`）字段 | 渲染层 |
| `HOLE_CORNER_RADIUS_RATIO` 与不再使用的 `kotlin.math.min` 导入 | 渲染层 |
| `PetOverlayManager.addMenuWindow()`（第二个 `windowManager.addView`） | 管理器 |
| `menuParams: WindowManager.LayoutParams`（菜单窗口 LP） | 管理器 |

`buildFanBand`（窄开放扇带）**保留** —— 它本来就是开放式扇形，不是完整圆盘。

### 12.16.3 新增项

| 新增 | 位置 | 作用 |
|---|---|---|
| `OverlaySceneLayout` / `OverlaySceneSolver`（纯 Kotlin，无 `android.*`） | 新文件 | 由"人物屏幕矩形 + 菜单屏幕矩形"求解窗口矩形与两层容器内位置；`assertConsistent()` 自检 |
| `PetOverlayView.menuHost` + `attachMenuLayer/detachMenuLayer/isMenuLayerAttached/menuLayerRect` | 视图层 | 在**同一窗口内**挂/摘菜单层（index 0，人物层之下） |
| `PetOverlayView.prepareSceneGeometry(windowSize, petRectInWindow)` | 视图层 | 提交窗口尺寸 + 人物层容器内偏移；`prepareWindowGeometry(size)` 委托给它（行为等价） |
| `PetOverlayManager.attachMenuLayer()/detachMenuLayer()` | 管理器 | 一次求解 + **唯一一次** `updateViewLayout` 提交窗口与人物层偏移 |
| `WheelMenuRenderer.drawVerifyFan()` + `WheelRenderParams.verifyFan` + `WheelMenuView.debugVerifyFan` | 渲染层 | 架构验证用的粉色开放扇区（默认开启，见 §12.16.5） |

**关键陷阱与修复**：窗口矩形现在描述**整个场景**（人物 ∪ 菜单），不再等于人物矩形。
因此 `petWindowRect()` 改为"窗口原点 + 人物层容器内偏移 + 人物尺寸"反算；
`currentTopLeft()` / `petSize()` / 拖动 / 位置持久化全部继续使用**人物屏幕矩形**。
这正是"菜单开关不改变人物屏幕位置"的实现基础。

### 12.16.4 不变式与测试

```text
人物屏幕矩形 = 窗口原点 + 人物层容器内偏移
菜单打开：窗口 = 人物 ∪ 菜单；人物层反向平移同样的量 ⇒ 人物屏幕矩形逐像素不变
菜单关闭：窗口缩回人物矩形；人物层偏移归零 ⇒ 同样不变
```

* 新增 `OverlaySceneLayoutTest`（**11 个用例**）：`closed()` 窗口==人物；`open()` 保持
  `petScreenRect` 完全相等；容器内偏移与并集四方向；往返一致性；`assertConsistent()`。
* 既有测试全部保持通过（含 `OverlayWindowSpecTest.menuWindowType`）。

### 12.16.5 交付边界（**这是架构验证包，不是完整轮盘**）

本包只证明"人物不消失并覆盖菜单"。完整开放式轮盘外观、主题与尺寸设置、子菜单与返回、
圆弧滑动动画、业务动作接线**不属于本包**，按用户要求待真机验收通过后再整合。

* 粉色验证扇区由 `debugVerifyFan = true` 控制（`// ARCH-VERIFY: 架构验证包默认开启`），
  **发布前必须关闭**；
* 菜单打开时"按住人物拖动"仍由菜单层**主动转发**给桌宠手势机
  （人物层 `petContent` 不可点击 ⇒ 事件会继续下发给菜单层）。这是保留既有行为、避免回归的处理，
  与"人物 View 自己收触摸"的描述在实现上不同，已在代码注释中说明。

### 12.16.6 快照与产物

| 项目 | 值 |
|---|---|
| 代码快照（改造前） | `snapshots/petlife-src-before-A4-20260930-210001.zip`（1,378,720 B） |
| 改造前 APK | `build/app/outputs/flutter-apk/app-debug.apk`，189,384,234 B，2026-09-30 20:43:16，SHA256 `AC7F4BF9147D60BF6611549A5DE9AADD0CC7706DE54E9DFF47072B11609C0596` |
| 本包 APK | 189,384,234 B，2026-09-30 21:13:47，SHA256 `4625D216832EB3D0861FFBAB554B61FA65EE4C4D96B337206BFC1742DC95B6E9` |
| 另存副本 | `petlife-ARCHVERIFY-A4-4625D216.apk`（仓库根目录） |

> 项目**不是 Git 仓库**，因此用源码压缩包做可恢复快照；未做任何整体回滚。

## 12.17 修复包：开关菜单人物"抽动" + 视觉收尾

> 真机反馈：单窗口后人物与菜单同时显示明显改善，但**开关菜单时人物短暂跳动后归位**，
> 因此 4C-6B-2 的"几何稳定性"**尚未通过验收**。本包先修抽动，再收尾视觉。

### 12.17.1 抽动的根因与结构性修法

**根因（判断）**：开/关菜单时窗口矩形与人物层局部偏移**一起变化**，但 WindowManager 的窗口帧提交
与子 View 的重新布局**可能落在不同帧** —— 于是出现"窗口原点已是新值、人物层偏移还是旧值"
（或反之）的一帧，人物被偏移量抛出后又归位。偏移量可达数百像素，肉眼即"抽动"。

**（本轮定稿已被 §12.18 取代；下面记录当时的修法与结论，并标注其**错误**之处。）**

当时的修法：让开关菜单完全不改变窗口几何 —— 新增**稳定场景帧** `sceneFrame = 人物 ∪ 菜单信封 + 8dp`，
人物局部矩形 `petLocalRect` 固定；`attachMenuLayer()` 只把菜单 View 挂进菜单层、**不碰 `params`、
不 `updateViewLayout`**，`detachMenuLayer()` 只摘子 View、**不缩窗口**；声称"窗口原点与人物层偏移
只可能一起更新，不存在错位的那一帧"。

**⚠️ 该方案已被证伪（见 §12.18）**：它把窗口**永久**留在"人物 ∪ 信封 + 8dp"，而这个大窗口内部的
透明 padding **仍会消费触摸**：
* `FLAG_NOT_TOUCH_MODAL` 只让事件**落在窗口之外**时才交给下层应用；它**不会**因为某个 View 返回
  `false` 就把窗口**内部**的落点重新派发给下层窗口 —— 返回 `false` 只表示"本 View 不消费这一串事件"，
  窗口依旧把该点拦下。
* 因此"菜单层摘除 + `PetOverlayView.onTouchEvent` 返回 `false`"**不能**让 padding 区域穿透，
  那是一圈**永久触摸遮挡**（真机阻塞缺陷）。
* 拖动 / 夹取 / 吸附 / 位置落盘的"人物坐标系"换算本身是对的，予以保留；错的是"窗口常驻大矩形"。

**正确做法（§12.18 定稿）**：菜单关闭时窗口**必须**收缩回人物矩形（零透明 padding）。平台**没有**任何
公开 API 能声明"窗口内只有某一块子区域可触摸"（`ViewTreeObserver.OnComputeInternalInsetsListener` /
`ViewTreeObserver.InternalInsetsInfo` 属 AOSP `@hide`，已核实本项目 `android.jar`（compileSdk
35 / 36 / 37）中**不存在**；反射 / 隐藏 API 被项目规则禁止），所以**窗口本身不能比交互区更大**。

> 关于"人物抽动"：曾据"窗口几何改变 → 混合帧"的推断去解释真机的左右漂，但**该推断从未被真机日志
> 确认**；它至今只是一个**待真机日志验证的假设**。`menu.trace`（每帧 `mixedFrame`）与
> `menu.geometry.delta`（`ΔwindowOrigin` / `ΔpetLocal`）只是**判读证据**，不是"已确认"的结论。

### 12.17.2 逐帧探针（供真机定位）

每次开/关菜单打 **12 帧**有界日志 `menu.trace`，包含：窗口 LP `(x,y w×h)`、`petContent`
`left/top/w/h`、根与人物层的 `translationX/Y`、人物层 `scaleX/Y`、
人物 `getLocationOnScreen()`、菜单层是否挂载、菜单状态。
据此可直接判定"人物**实际画出**的位置"在过渡中是否移动（**最终坐标相同 ≠ 中间没有抽动**）。

### 12.17.3 视觉收尾

| 项 | 修法 |
|---|---|
| 黄色大底 | **关闭架构验证绘制**（`debugVerifyFan = false`） |
| 正式底色 | 保留开放扇形轮廓，底色改为**主题派生**的半透明玫红：`baseFanColor = withAlpha(mix(secondary, background, 0.40), 108)`；默认 P3P 得 `0x6CFFA9CD`（软玫瑰粉 ≈42% 透明）。**不写死粉色**，其他主题同样派生 |
| 明暗区分 | 按钮轨道带用 `theme.background`（更亮），单测断言"轨道带亮度 > 底色扇面亮度"对全部 5 个预设成立 |
| 顶部强调线 | 保留（`drawRimDecoration` 的高亮弧） |
| 标题重复 | `titleEn != null` 时画英文装饰标题 + 中文 chip；`titleEn == null`（如"今日时长"）时**只画一次**中文标题（近白底 + 深色字），**跳过 chip** —— 消除两串相同中文叠画 |

### 12.17.4 验证与产物

| 项目 | 结果 |
|---|---|
| Kotlin 单测 | **BUILD SUCCESSFUL**（新增：稳定场景帧 5 例、底色扇面主题/亮度对比） |
| `:app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| Dart 侧 | 未改动，未跑 Flutter 检查 |
| 基线快照 | `snapshots/petlife-src-singlewindow-baseline-20260930-212639.zip`（1,383,027 B） |
| 基线 APK | 189,384,234 B / 20:43:16 / `4625D216…95B6E9` |
| 本包 APK | 189,384,234 B / **2026-09-30 21:38:40** / `55FA0CD5FFBCBB4004A20F80E6CDC069E532C13F14D6F3381186AEE030F99BBF` |
| 另存副本 | `petlife-FIX-JITTER-55FA0CD5.apk`（仓库根目录） |

### 12.17.5 待真机验收（本包）

1. 屏幕中央连续开关 20 次，人物位置与大小全程稳定；
2. 左右边缘、顶部、底部各开关若干次；
3. 快速点击打断开/关动画；
4. 菜单打开后从人物区域拖动；
5. 静态图与动态 WebP 各测一次；
6. 默认尺寸与较大轮盘尺寸各测一次。

**验收标准**：开关菜单时人物的位置与大小**全程稳定，没有短暂偏移后归位**。
自动测试只能证明几何不变式，画面必须真机确认。

> 六个根菜单的**业务功能接入**、后台/冷启动链路、完整回归**不在本包**，
> 按用户要求待上述真机验收通过后作为"菜单整合包"实施。

## 12.18 定向修复包：输入遮挡 + 快速拖动脱手

> 真机阻塞缺陷：**菜单关闭后原菜单区域仍挡住其他应用点击**；**快速拖动桌宠会脱手**。
> 两者同源于窗口输入与手势生命周期，合并排查。

### 12.18.1 接口核实结论（决定架构走向）

先核实"能否让系统可触摸区域随菜单状态改变"：

* 候选接口 `ViewTreeObserver.OnComputeInternalInsetsListener` / `ViewTreeObserver.InternalInsetsInfo`
  **不是公开 API**。已用 SDK 的 `android.jar` 逐一核实：`android-35` / `android-36` / `android-37.0`
  中 `ViewTreeObserver*InternalInsets*` **全部不存在**（属 AOSP `@hide` 灰名单）。
* 因此访问它只能靠反射/隐藏 API。按项目规则（**不得依赖隐藏 API、反射或特定 ROM 行为作为通用实现**），
  该方案**不交付**，已实现的反射代码**全部删除**（仅保留一条说明性注释）。

**结论**：公开 API 下无法让"大窗口"局部穿透。于是采用既定回退方案 ——
**菜单关闭时窗口收回人物必要范围**（不是"大窗口常驻"）。

### 12.18.2 输入遮挡修复

| 状态 | 窗口矩形 | 人物层容器内矩形 |
|---|---|---|
| 菜单关闭 | **= 人物屏幕矩形**（零透明 padding） | (0,0)–(人物宽高) |
| 菜单打开 | = 人物 ∪ 菜单信封 | 人物屏幕矩形 − 窗口原点 |

* 唯一提交点 `commitSceneLayout(layout, tag)`：**先写人物层放置 → 再写窗口 LP → 最后一次
  `requestLayout()` + 一次 `updateViewLayout`**，杜绝"窗口已移动、人物层未跟上"的中间帧。
* `OverlaySceneSolver` 仍是唯一权威；`assertConsistent()` 校验 `窗口原点 + 人物层偏移 == 人物屏幕矩形`。
* 先前为消除抽动引入的 `stableFrame`（常驻大窗口 + 8dp padding）**已移除** —— 它正是遮挡的来源。

### 12.18.3 快速拖动脱手修复

* **坐标基准**：旧实现用"按下时人物原点 + 局部 `event.rawX - pressRawX`"累加，且菜单转发用的是
  **View 局部** `event.x/y`；窗口随手指移动 ⇒ 基准每帧变化 ⇒ 失步。现改为：
  `抓取偏移 = 手指屏幕坐标(DOWN) − 人物屏幕原点(DOWN)`（只记一次），
  每帧 `目标 = 当前手指屏幕坐标 − 抓取偏移`，**绝不累加、绝不用局部坐标**。
* **指针锁定**：整段手势锁定 DOWN 的 pointer id，第二根手指不抢占。
* **手势连续**：DOWN 被接受后不再重跑"必须点在人物内"的命中判定；手指移出人物/窗口范围不丢弃手势；
  边界夹取只夹位置、**不结束手势**，手指回来后继续跟手。
* **UP 用最后手指位置结算**，随后才走既有吸附与落盘；**CANCEL** 干净收敛、不清位置、不误触菜单动作。
* **菜单中途摘除**：转发拖动进行中，菜单层摘除与窗口收缩**一并挂起**（同一闸门），
  手势结束后一次性执行，避免 `ACTION_CANCEL` 打断拖动流。

### 12.18.4 证据采集

`menu.trace`（每次开/关 12 帧有界）每帧输出：窗口矩形、人物层容器内矩形、
`petScreenComputed = 窗口原点 + 人物层偏移`、`petLayerTraceSegment()` 里 `getLocationOnScreen()`
的**真实**人物屏幕位置（含根/人物层 `translationX/Y` 与 `scaleX/Y`）、几何提交计数、动画阶段，
以及 `mixedFrame = (计算位置 != 真实位置)`。`menu.geometry.delta`（每次开/关各一条）给出
`ΔwindowOrigin` / `ΔpetLocal`。

**口径（不要过度解读）**：以上全部是**判读证据**，不是结论。特别是"窗口几何改变 → 一帧画出
'旧窗口原点 + 新人物层偏移'的混合帧导致左右漂"这一条，**至今只是假设、未被真机日志确认**；
必须用真机 `menu.trace` / `menu.geometry.delta` 日志来验证或证伪。

### 12.18.5 验证与产物

| 项目 | 结果 |
|---|---|
| 反射/隐藏 API 残留 | overlay 包 **0 处**（仅 1 条说明性注释） |
| Kotlin 单测 | **BUILD SUCCESSFUL**（`OverlaySceneLayoutTest` 17 例；`OverlayGestureTest` 含拖动数学 8 例） |
| `:app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| Dart 侧 | 未改动，未跑 Flutter 检查 |
| 本包 APK | 189,384,234 B / **2026-09-30 22:11:27** / `5C5377FD4D61A5711D606D131ACD2AB3300E47B8619CE82A31B2914B94718ECD` |
| 另存副本 | `petlife-FIX-INPUT-DRAG-5C5377FD.apk`（仓库根目录） |

### 12.18.6 风险（未验证，必须真机确认）

窗口在菜单开/关时**重新改变尺寸**（关态 = 人物矩形，开态 = 人物 ∪ 菜单信封）—— 这是修复触摸遮挡
的**必要代价**（平台没有公开的局部可触摸区域 API；返回 `false` 不保证穿透）。因此
"开/关不抽动"**必须真机重新确认**：提交顺序已严格约束为"先写人物层放置 → 再写窗口 LP →
一次 `requestLayout()` + 一次 `updateViewLayout`"，但平台是否同帧原子应用无法由 JVM 单测证明。

`menu.trace` / `menu.geometry.delta` 即为判定依据。

## 12.19 菜单业务整合包（4C-6B-2 完整功能）

> 前置：底层交互（单窗口分层 / 无抽动 / 无触摸遮挡 / 快速拖动）已真机验收通过。本包只做**业务接入**，不改已验收模块。

### 12.19.1 六项设计决策（用户确认）
1. 新增原生→Dart 菜单请求通道（复用现有 `MethodChannel`，不要求 EventChannel）；Flutter 不可用时写入**持久化待处理队列**，打开 PetLife 后消费；**不启动第二个 FlutterEngine**。
2. 新增可外部驱动的导航接缝（应用级导航控制器 + `MobileShell` 订阅），支持前台/后台/Activity 重建/冷启动，**只消费一次**；不直接改 `_MobileShellState._index`。
3. 尺寸类动作采用**"收起菜单后生效"**，不改窗口几何提交逻辑。
4. **沿用现有 `entry.id` + `WheelMenuAction`**，不新建第二套 Action ID；禁止用中文标题判业务。
5. `settings.theme` 指**轮盘主题**；本阶段不新增 App 全局主题。
6. 反馈使用**同一悬浮窗口内的轻量反馈层**；仅当该层无法显示时才回退 Toast。

### 12.19.2 请求协议
| 方向 | 方法 | 载荷 |
|---|---|---|
| 原生→Dart | `menuRequest` | `{requestId, actionId, args, createdAt}` → Dart 回 `{status, message}` |
| Dart→原生 | `pullPendingMenuRequests` | → `{requests:[…]}`（**取出即消费**） |
| Dart→原生 | `completeMenuRequest` | `{requestId, status, message}` → `{ok}` |

终态 `completed/failed/expired`（内部另有 `pending/delivered`）；队列落盘键 `overlay.menu.pending_requests`，按 `requestId` 幂等，TTL 10 分钟，上限 32 条，终态 LRU 64；路由分类 `navigation | native | dartRequest | info`；Dart 幂等台账复用既有 `local_settings` 表（**未新建库/表**）。

### 12.19.3 新增/改动文件
**Kotlin 新增**：`MenuRequestQueue.kt`（纯 Kotlin 可单测）、`MenuRequestStore.kt`、`MenuRequestBridge.kt`、`MenuFeedback.kt`、`MenuActions.kt`。
**Kotlin 修改**：`WheelMenuModel.kt`、`WheelMenuActionDispatcher.kt`（四通道路由）、`PetOverlayView.kt`（反馈层，子 View 顺序 menu→feedback→pet）、`PetOverlayManager.kt`、`PetOverlayService.kt`、`OverlayNotification.kt`、`PetOverlayBridge.kt`、`MainActivity.kt`、`WheelMenuStateTest.kt`。
**Dart 新增**：`lib/navigation/app_navigation.dart`、`lib/platform/android/android_overlay_menu_bridge.dart`、`lib/ui/overlay_menu_actions.dart`。
**Dart 修改**：`mobile_shell.dart`、`usage_stats_page.dart`、`settings_controller.dart`、`app_settings.dart`。

### 12.19.4 "今日时长"口径修正
原用 `ActivityTracker.todayActiveSeconds`，与"使用统计（本机）"页**口径不一致**（Android 时长由原生 journal 导入 `daily_usage`）。现改为同服务同窗口同字段：`UsageAnalyticsService.summarize(windowFor(UsageRange.today)).overview.appActiveSeconds`；异常返回 `failed` + 中文原因，不静默报 0。

### 12.19.5 验证与产物
| 项目 | 结果 |
|---|---|
| Kotlin 编译 + 单测 | **BUILD SUCCESSFUL**（全量 421 项） |
| Flutter `analyze` | **No issues found** |
| Flutter `test` | **783 通过 + 1 skipped** |
| 本包 APK | **189,427,289 B** / **2026-09-30 22:54:16** / `BE5C858864A6B6B5C505257FC40CB810E8BAEF3F0274A4BD779918947CCE5ACA` |
| 另存副本 | `petlife-MENU-INTEGRATED-BE5C8588.apk` |

### 12.19.6 已知限制
* 反馈条固定在窗口底部，极端垂直模式下可能与最低按钮轻微重叠，需真机目视确认（不允许改几何）。
* 桌面外壳未订阅导航请求（Windows 无该原生通道）；`AppDestination` 已平台中立。
* `records_cloud` 未登录时仍跳转云端子页（页面自带"去登录"入口）。
* 全部业务行为与 §12.18 三项交互基线**仍需真机验收**。

## 12.20 Android 悬浮桌宠冻结基线（进入 Windows 阶段前）

> 日期：2026-10-05。本节的唯一目的：把 Android 原生悬浮桌宠**当前状态冻结为基线**、登记 1 个已知问题，随后进入 **Windows 阶段**。冻结期内 Android 侧**只读**。

### 12.20.1 冻结声明

本阶段 **Android 原生悬浮桌宠代码全部冻结**。本阶段**不允许**对以下任一对象做任何改动：

* Android Kotlin（`android/app/src/main/kotlin/**`、`android/app/src/test/kotlin/**`）；
* Android `AndroidManifest.xml`；
* Android Gradle（`android/**/*.gradle*`、`android/gradle.properties` 等）；
* Android（Kotlin JVM）测试；
* 悬浮窗（人物窗口 / 菜单窗口）的行为、几何与窗口参数。

**双窗口探针、单窗口回退能力与既有诊断数据不得删除**——它们是本基线的验收证据；任何"清理"都必须等 Windows 阶段结束后单独评估。

### 12.20.2 已验收项（12 项）

1. 悬浮桌宠前台服务与通知控制
2. 人物窗口与菜单窗口分离
3. 人物视觉覆盖菜单
4. 菜单关闭后不遮挡底层应用
5. 快速拖动不脱手
6. 菜单按人物当前位置处理左右镜像、上下边缘与屏幕夹取
7. 菜单窗口只添加一次，通过 updateViewLayout 开关
8. 正式根菜单、子菜单、17 个业务动作、多级返回与反馈
9. 自动状态联动、素材映射、统计与同步
10. Android 开机自启
11. 双窗口/单窗口回退能力
12. 双窗口探针与诊断数据

### 12.20.3 冻结基线产物

| 项 | 值 |
|---|---|
| APK 路径 | `build/app/outputs/flutter-apk/app-debug.apk` |
| 版本标识 | `0.1.0+1`（debug） |
| 大小 | 189,457,789 B |
| 构建时间 | 2026-10-05 19:11:27 |
| SHA256 | `EA035E3AC4095EDD006765CA85C9853DF54F1055DF7A4F3173CD53E5D30D4EFF` |
| 另存副本 | `petlife-MENUOPEN-MEASUREGATE-EA035E3A.apk` |

### 12.20.4 已知问题（登记，暂缓，不阻塞）

* **ID**：`ANDROID-KNOWN-MENU-OPEN-VISUAL-OFFSET`
* **现象**：打开菜单时，菜单视觉最初出现在最终位置**上方**，随后落到正确位置；最终位置正确，人物不漂移。
* **已尝试**：两阶段打开（prepare → 等待真实 layout → present/起动画）；`menuHost` 改用 `INVISIBLE` 参与测量；门控改读 `WheelMenuView` 的 `measuredWidth/Height`（非宿主尺寸）；布局代次/会话守卫。
* **状态**：**已知问题、暂缓处理、不阻塞 Windows 阶段**。
* **影响面**：仅菜单开场首帧观感；不影响功能、输入、层级、人物稳定性。
* **复现/证据采集入口**：诊断模式下 `menu.open.frame`（前 12 帧）、`menu.open.layout_ready`、`menu.open.layout_timeout`。

### 12.20.5 复现与证据采集

开启悬浮桌宠的**诊断模式**后打开一次菜单，抓取以下三类日志：

1. `menu.open.frame`：打开后**有界前 12 帧**（`MENU_OPEN_DIAG_FRAMES = 12`），逐帧记录
   `session` / `frame`（1..12）/ `gen`（布局代次）/ `menuWindow` 窗口参数 /
   `windowScreen` 窗口屏幕坐标 / `contentState`（`INVISIBLE`/`VISIBLE`）/
   `contentMeasured` 轮盘 `WheelMenuView` 自身测量尺寸 / `contentLeftTop` /
   `contentTrans` / `pivot` / `openProgress` / `menuAnchorPetRect` /
   `targetMenuRect`（本帧目标矩形）/ `contentBounds` / `phase`（打开序列阶段）。
2. `menu.open.layout_ready`：闸门**放行**（轮盘已量到目标尺寸且内容转 `VISIBLE`）时记一条，
   含 `measured`、`target`、`content`、`pivotLocal`、`anchorLocal`。
3. `menu.open.layout_timeout`：超过 `maxLayoutFrames` 仍未达标时的**降级**分支——
   直接显示在最终位置、不播动画，含 `target` 与 `reason`。

判读规则（与 `DualWindowMenuScene.kt` / `PetOverlayManager.kt` 的实现一致）：

* **`contentState=VISIBLE` 的第一个可见帧**：`contentMeasured` **必须**等于 `targetMenuRect`
  —— 这是通过判据；若该帧 `contentMeasured` 与 `targetMenuRect` 不一致、且 `contentLeftTop`
  停在最终位置**上方**，即本已知问题的直接证据。
* **`contentState=INVISIBLE` 的隐藏准备帧**：`contentMeasured` **允许**为 0 / 1×1（`GONE`
  子树不参与 measure/layout，尚无目标尺寸是正常的），**不算视觉失败**；这类帧只计入
  等待帧数，不产生任何可观测动作。因此不要把隐藏准备帧的 0 误判为该问题。

## 13. 后续阶段

| 阶段 | 内容 |
|---|---|
| ~~4C-1~~ | ~~权限与原生服务骨架~~ **已完成并通过真机验收** |
| ~~4C-2~~ | ~~静态素材显示（配置校验、PNG/JPG/WebP、采样、回退链）~~ **已完成并通过真机验收（稳定基线，见 §0）** |
| ~~4C-3A~~ | ~~拖动、屏幕边界限制、贴边吸附、相对位置持久化、横竖屏/分屏重算、大小调整（50%~200% 滑块）~~ **已完成并通过真机验收（稳定基线，见 §0 / §8.9）** |
| ~~4C-3B~~ | ~~单击圆盘菜单**框架**（6 占位槽位、展开方向与边界修正、菜单动画、点击/拖动冲突）~~ **已完成并通过真机验收（稳定基线，见 §0 / §9.10）** |
| ~~4C-4~~ | ~~动态 WebP 播放：API 28+ 用 `AnimatedImageDrawable` 完整循环；24~27 如实标注"仅显示第一帧"~~ **已完成并通过真机验收（稳定基线，见 §0 / §10）** |
| 4C-5 | 状态联动：复用项目现有状态体系，按前台应用自动切换素材（见 §11） |
| 4C-5.1A | **修复统计页「当前应用」为空**：两页共用同一份 Android 前台快照、设备 ID 依赖注入与兼容迁移（见 §12.4）——**已通过真机验收** |
| 4C-5.1B | Android 会话采集 + journal + 幂等导入 + Outbox/云同步 + 时间段列表（见 §12.6~§12.9）——**已实现，待真机验收** |
| 4C-5.1B 补 | **跨端云端统计一致性修复**（切设备串数据 / 强制刷新无效 / 退出重登卡空态 / 设备列表陈旧 / 缓存键缺服务端地址）——**已实现，待真机验收**（见 §12.10） |
| 4C-6A | **状态联动接通**：分类→状态规则修正（browser→focused、桌面→away、系统页保持）、Flutter 下发规则与自动开关、规则优先级、命中规则诊断——**已实现，待真机验收**（见 §12.11） |
| 4C-6A 修复 | **真机失败诊断与修复**：界面状态改读原生（使用统计页 / 桌宠页原本读 Flutter 状态引擎 → 在 Android 上永远 `default`）、分类器四级优先级 + `ApplicationInfo.category` + 大小写陷阱、17 项原生真值诊断、解析失败不静默、防抖改单调时钟——**已实现（单测/分析/构建全绿），待真机验收**（见 §12.11.11~§12.11.17） |
| 4C-6A.1 | **状态素材映射编辑器**：映射页（状态卡片 / 回退层级如实标注 / 响应式）、素材选择器（大图预览 / 收藏 / 设为状态或默认）、反向分配、删除联动、临时预览（原生内存态 + 10 秒到期 + `displayMode`）、v5 迁移（`emotion_assets.favorite`）——**已实现（331 / 726 / 211 全绿 + APK/Windows 构建成功），待真机验收**（见 §12.12） |
| 4C-6B-1 | **P3P 风格分层轮盘菜单与主题系统**：六项根菜单 + 五个子菜单 + 固定返回键、参数化几何（高亮扇区 / 中央齿轮缺口 / 左右镜像 / 偏移与安全区）、统一动画时钟（展开·切换·换层·返回·关闭 + 按下反馈）、点击与圆弧滑选（角度判定 + 槽位滞回 + 松手确认）、手势互斥、默认 P3P 粉色主题与预设·自定义（revision 守卫 + 立即生效）、统一 `WheelMenuActionDispatcher`（**业务动作只发结构化占位事件**）——**已实现（Kotlin 355 / Flutter 733+1 / analyze 全绿 + APK 构建成功），待真机验收**（见 §12.13） |
| 4C-6B-1.1 | **轮盘与桌宠融合 / 尺寸调节 / 边缘适配**：窗口层级反转（菜单在下、桌宠在上，靠窗口类型固定）、删除"避开桌宠抓取区"硬约束、缺口恒绑桌宠**视觉锚点**（alpha 包围盒）、CENTER/TOP_EDGE/BOTTOM_EDGE（扇形偏转 + 滞回，**绝不平移轮盘中心**）、preferredScale/actualScale/compactMode、轮盘大小滑块（60~120%，5% 步进，持久化）、可读性重构（文本安全带 / 最小字号 / 按钮中文标签 / 描边收细）、诊断事件——**已实现（Kotlin 364 / Flutter 733+1 / analyze 全绿 + APK 构建成功），待真机验收**（见 §12.14） |
| 4C-6B-1.2 A2.1 | **撤销桌宠隐藏旧架构 + 尺寸范围扩到 50%~250%**：删除 `PetVisualOwner`/`MENU_FOREGROUND`/`setSourceHidden`/`isSourceHidden`/`petVisualOwnerName` 与一切 `imageAlpha = 0` 写入，诊断恒定输出 `owner=PET_WINDOW sourceHidden=0 foregroundCopy=disabled`；轮盘与按钮均可 50%~250%（10% 步进），并修掉刀刃 `coerceIn(0.6,1.2)` 的静默夹取——**已实现（Kotlin 单测全绿 / Flutter 737+1 / analyze 全绿 / APK 构建成功）**（见 §12.15.7） |
| 4C-6B-2 | 把轮盘上全部业务动作接到真实实现（状态 / 素材 / 记录 / 同步 / 隐藏 / 停止服务 / 主题入口 / 工具），替换占位处理器 |
| 4C-6 | 设置页完整开关（显示模式/大小/吸附/穿透/锁屏）+ 通知控制 + 厂商后台限制帮助卡 |
| 4C-7 | Kotlin 仪器测试、全量回归、APK/Windows 构建、真机人工验收 |

本阶段**不需要**任何服务端变更（无 Docker / 无 Alembic / 无 API 与 MCP 重建）。
