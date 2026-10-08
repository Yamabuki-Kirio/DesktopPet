# 26 - Android 权限与隐私说明

> 范围：Phase 4A。**本阶段不采集任何使用数据**，因此应用是"零敏感权限"的。

## 1. 当前申请的权限

`android/app/src/main/AndroidManifest.xml` 里**只有一项**：

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

用途：访问 PetLife 服务端（登录 / 注册设备 / 推送同步数据 / 拉取增量）。
之所以要显式声明：debug 构建由 Flutter 的 debug manifest 自动加上，
**release 构建不会**，不写会导致 release 包登录直接失败。

**构建产物里实际出现的第二条权限（自动注入，非本项目声明）**：

| 权限 | 来源 | 说明 |
|---|---|---|
| `asia.akechi.petlife.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AGP / androidx 在 manifest 合并阶段注入 | Android 13+ 注册"非导出"广播接收器所需。它是**签名级**权限，只对本应用自身生效，**不授予任何系统能力**（不能读使用情况、不能画悬浮窗、不能读通知）。源 manifest 里没有、也无法手写这条 |

用 `aapt2 dump badging` 核对 APK 时看到 2 条是正常的；
`test/platform_isolation_test.dart` 断言的仍然是**源 manifest**，那里必须恰好 1 条 `INTERNET`。

## 2. 明确**没有**申请的权限

| 权限 | 为什么不需要 |
|---|---|
| `PACKAGE_USAGE_STATS`（使用情况访问） | Phase 4A 不采集应用使用时长。它是特殊权限，需要用户在系统设置里手动授予，属于 Phase 4B |
| `SYSTEM_ALERT_WINDOW`（悬浮窗） | 系统悬浮桌宠属于 Phase 4D |
| `FOREGROUND_SERVICE` / `POST_NOTIFICATIONS` | 后台采集的前台服务与常驻通知属于 Phase 4B |
| `QUERY_ALL_PACKAGES` | 不枚举已安装应用 |
| 存储权限（`READ/WRITE_EXTERNAL_STORAGE`） | 素材导入走系统文件选择器（SAF），**不需要**存储权限 |
| 位置 / 通讯录 / 相机 / 麦克风 / 电话 | 与功能无关 |

`test/platform_isolation_test.dart` 会静态断言：manifest 里恰好只有一条
`<uses-permission>`，且必须是 `INTERNET`；出现 `PACKAGE_USAGE_STATS` 或
`SYSTEM_ALERT_WINDOW` 直接判定失败。

## 3. 数据流与隐私边界（Phase 4A 实际行为）

```
Android 应用
  ├─ 本地 SQLite（应用私有目录 /data/data/asia.akechi.petlife/）
  │    只存：账户会话元数据（邮箱 / 显示名 / 设备 ID / 服务端地址）、
  │          素材与角色、状态映射、设置、同步游标
  ├─ Android Keystore + SharedPreferences（密文信封）
  │    只存：Access Token / Refresh Token（整包 JSON）、代理密码
  │    形式：`v1:<随机 IV 的 Base64>:<AES-GCM 密文的 Base64>`，
  │          密钥本身由 AndroidKeyStore 持有，应用进程无法导出、也不落盘
  └─ HTTPS/HTTP → PetLife 服务端
       只发：登录凭据、设备注册信息、同步数据（当前为空，因为不采集）
```

**隐私硬约束（沿用 Phase 2/3 的约定，未放宽）：**

* 令牌**绝不**写入 SQLite 或 SharedPreferences 明文 —— 见 §4；
* 不采集也不上传：页面内容、输入内容、通知正文、网页 URL、文件名、聊天内容、无障碍界面树；
* 不上报硬件指纹（无 MAC / 序列号 / IMEI），设备标识是客户端自己生成的随机 UUID，
  用户可随时在服务端撤销。

## 4. 凭据存储：Windows 用系统凭据，Android 用 Keystore（**均已实现**）

| 平台 | 后端 | 说明 |
|---|---|---|
| Windows | Credential Manager → DPAPI 文件 → 内存 | Phase 2 原实现，**未改**（有测试断言工厂仍选这条链） |
| **Android** | **Android Keystore（AES/GCM/NoPadding）** | 本轮实现；**没有内存兜底** |

### 4.1 Android 实现（原生 MethodChannel）

| 层 | 文件 |
|---|---|
| Dart | `lib/platform/android/android_keystore_credential_store.dart`（`CredentialStore` 实现 + 错误码映射） |
| Dart | `lib/platform/android/android_credential_store.dart`（工厂，固定返回 Keystore 后端） |
| Kotlin | `android/app/src/main/kotlin/asia/akechi/petlife/MainActivity.kt`（注册通道 `asia.akechi.petlife/credential_store`） |
| Kotlin | `android/app/src/main/kotlin/asia/akechi/petlife/PetLifeCredentialStore.kt`（KeyStore + AES/GCM） |

`AndroidKeystoreCredentialStore` 走 MethodChannel 的 `write` / `read` / `delete` 三个方法，
参数只有 `key` 与（写入时的）`secret`。

### 4.2 为什么不用 `flutter_secure_storage`

它在 **Windows 侧**会编译一个依赖 ATL（`atlstr.h`）的 C++ 插件；本机 VS Build Tools
未安装 ATL → 引入它会让 **Windows Release 构建直接失败**（实测复现，已回退）。
既然 Android 侧本来就需要原生代码，就在项目内自建 MethodChannel，**Windows 完全不受影响**：
Kotlin 文件只被 Android 构建编译，Dart 侧也只有 `AndroidCredentialStoreFactory` 会创建通道对象。

### 4.3 安全性质（可直接核对）

| # | 性质 | 实现方式 | 自动化验证 |
|---|---|---|---|
| 1 | 密钥**不可导出** | AndroidKeyStore 生成的 AES-256 密钥留在系统 keystore 守护进程内（`getEncoded()` 返回 null） | 静态契约测试断言使用 `AndroidKeyStore` + 256 位 |
| 2 | 认证加密 | `AES/GCM/NoPadding`，128 位 tag | 同上 |
| 3 | **每次写入用随机 IV** | `setRandomizedEncryptionRequired(true)`，IV 由系统生成（加密路径不接受调用方传入 IV） | 同明文两次写入得到不同密文 / 不同 IV |
| 4 | SharedPreferences 只存 IV + 密文 + 版本 | 只写 `v1:<IV base64>:<密文 base64>` 单一信封 | 扫描密文，明文与任意 6 字符片段均不出现 |
| 5 | **不保存明文** | Access Token / Refresh Token / 代理密码都只以上述信封落盘 | 同上（另有一条静态检查：`putString` 不接受 `secret`） |
| 6 | 支持 `read` / `write` / `delete` | Kotlin 三个方法；删除幂等 | 写/读/覆盖/删/幂等/多条目互不干扰 |
| 7 | 失败时**明确报错、不回退明文** | 解密失败 → `cipher_corrupt`；密钥失效 → `key_invalid`；都不返回兜底值 | 错误码 → 明确异常的映射测试 |
| 8 | Windows 仍走 Credential Manager / DPAPI | 两套工厂互不引用 | 「Windows 工厂不引用任何 Android 实现」静态契约 |
| 9 | Android **不再**使用内存作为正式后端 | 工厂固定返回 Keystore 后端；探测失败也只记警告 | 「通道不可用时仍返回 Keystore，不降级内存」 |
| 10 | 通道仅在 Android 注册，不影响 Windows 链接 | Kotlin 只存在于 `android/app/src/main/kotlin/` | APK 反查：`classes10.dex` 含通道名与实现类 |

> 关于第 7 条的取舍：Android 侧**故意不做**"Keystore 不可用就退回内存"的降级。
> 静默降级会让"重启后仍保持登录"变成没人发现的假象；宁可让登录失败并给出明确错误。

## 5. 网络与传输

* 只与用户在「账户与同步」里填写的服务端地址通信；
* 代理设置沿用 Phase 2 的应用内配置（Android 上不做系统代理自动探测，
  因为 `PlatformCapabilities.supportsSystemProxyDetection == false`）；
* **不绕过 TLS 校验**（与 Windows 端同一份 `ApiClient`，没有任何 `badCertificateCallback`）；
* 日志脱敏规则沿用 Phase 2：`Loggers.*` 会对令牌、绑定码、密钥做 `redact()`。

## 6. 素材与文件访问

| 操作 | 实现 | 权限 |
|---|---|---|
| 导入 ZIP 素材包 | 系统文件选择器（SAF `ACTION_OPEN_DOCUMENT`），只接收 `.zip` | 不需要权限 |
| 导入单张 / 多张图片 | 系统文件选择器，只接收图片类型 | 不需要权限 |
| 导入文件夹 | **Android 上不提供**（`supportsFolderImport == false`，界面隐藏入口） | —— |

文件夹导入需要 SAF 的 `ACTION_OPEN_DOCUMENT_TREE`（返回 `content://` URI），
再把整棵树复制到应用私有目录，这需要 Kotlin 侧的原生通道，归入 Phase 4B。
界面在 Android 上隐藏「导入文件夹」与「按路径导入」，空状态提示引导用户改用 ZIP 素材包。

导入的素材写入**应用私有目录**（`getApplicationSupportDirectory()`），
不写用户的外部存储，也不需要盘符或反斜杠假设（路径统一交给 `path` 包处理）。

## 7. Phase 4B 将会引入什么（预告，尚未实现）

实施 `UsageStatsManager` 采集时，会新增：

* 权限：`PACKAGE_USAGE_STATS`（**特殊权限**，必须在系统设置中由用户手动授予，
  不能通过普通运行时权限弹窗获取，也不会伪装成运行时权限）；
* 前台服务：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` + 常驻通知（`POST_NOTIFICATIONS`）；
* 授权引导页：说明用途 → 跳转系统设置 → 返回后重新检测 → 用户拒绝也不影响
  桌宠 / 登录 / 同步 / 已有统计。

采集数据的范围与禁止范围见 docs/27（口径）与本文 §3（禁止清单不会放宽）。

## 8. 用户可核对的事实清单

1. `android/app/src/main/AndroidManifest.xml` 里只有 `INTERNET` 一条权限
   （构建产物中多出的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 是 AGP 自动注入的签名级权限，见 §1）；
2. 应用私有目录里的 SQLite 文件**不含** `access_token` / `refresh_token` 明文
   （由 `test/sync_security_test.dart` 与 `test/auth_relogin_race_test.dart` 断言）；
3. 令牌只经过 `CredentialStore`；Android 实现是 **Android Keystore**，
   `SharedPreferences` 里能看到的只有 `v1:<IV>:<密文>` 信封；
4. 装了 APK 之后，可以在设备上确认「设置 → 应用 → PetLife → 权限」里**没有**
   使用情况访问 / 悬浮窗 / 无障碍 / 通知读取 / 存储；
5. 任何时刻都可以在「账户与同步 → 退出登录」清空本地令牌，
   或在服务端撤销该设备让令牌立即失效。
