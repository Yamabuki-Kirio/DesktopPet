# 28 - Android 构建与签名

> 当前状态：**Debug APK 已产出**（本机实测通过）。
> 本文记录**已落进仓库**的配置、**只在本机**的环境级处理，以及从零构建的完整步骤。

## 1. 工具链版本（官方模板矩阵，不再手工猜测）

### 1.1 版本矩阵

| 组件 | 版本 | 来源 |
|---|---|---|
| Flutter | 3.47.5（stable）/ Dart 3.13.4 | 本机 SDK |
| Gradle Wrapper | **9.3.1（`-all`）** | Flutter 官方模板 |
| Android Gradle Plugin | **9.1.0** | Flutter 官方模板 |
| Kotlin | **2.4.0** | Flutter 官方模板 |
| Flutter Gradle Plugin 应用方式 | `id("dev.flutter.flutter-plugin-loader") version "1.0.0"` + `id("dev.flutter.flutter-gradle-plugin")` | Flutter 官方模板 |
| `android.newDsl` / `android.builtInKotlin` | **`false` / `false`** | Flutter 官方模板 |
| compileSdk / targetSdk | 36 / 36（`flutter.compileSdkVersion` / `flutter.targetSdkVersion`） | Flutter 3.47 默认 |
| minSdk | 24（`flutter.minSdkVersion`） | Flutter 3.47 默认 |
| JDK | 17（Adoptium 17.0.20.1） | 见 §3.1 |

### 1.2 怎么确认的（方法比结论重要）

**不手工猜版本**。用**同一套** Flutter SDK 生成一个临时空项目，与 PetLife 逐文件比对：

```powershell
$probe = Join-Path $env:TEMP 'petlife_android_template'
& 'C:\src\flutter\bin\flutter.bat' create --platforms=android --org asia.akechi $probe

$files = @('android\settings.gradle.kts','android\build.gradle.kts',
           'android\app\build.gradle.kts','android\gradle.properties',
           'android\gradle\wrapper\gradle-wrapper.properties')
foreach ($f in $files) {
    $d = Compare-Object (Get-Content (Join-Path $probe $f)) (Get-Content (Join-Path $repo $f))
    if ($d) { $d } else { "IDENTICAL: $f" }
}
Remove-Item -Recurse -Force $probe      # 比对完删除临时项目
```

实测结果：

| 文件 | 比对结果 |
|---|---|
| `android/settings.gradle.kts` | **IDENTICAL** |
| `android/build.gradle.kts` | **IDENTICAL** |
| `android/gradle.properties` | **IDENTICAL** |
| `android/gradle/wrapper/gradle-wrapper.properties` | 仅 `distributionUrl` 不同（同版本号的国内镜像，见 §3.2） |
| `android/app/build.gradle.kts` | 仅 `applicationId` / `namespace` 与注释不同 |

### 1.3 允许的差异（仅此五类）

按需求约束，PetLife 相对官方模板**只允许**这五类差异：

1. `applicationId`：`asia.akechi.petlife`
2. `namespace`：`asia.akechi.petlife`
3. `minSdk`：仍写 `flutter.minSdkVersion`（= 24，**没有**手工降低或抬高）
4. 应用名称：`PetLife`（manifest 的 `android:label`）
5. **国内镜像地址**：Gradle 发行版下载源（§3.2）与 Maven 镜像（§3.3）

> **不通过降级 AGP / 混用旧模板来解决网络问题**。之前把 AGP 降到 8.7.3 的做法已被推翻：
> Flutter 3.47.5 的 Gradle 插件按 "AGP ≥ 9" 读取 DSL，降级后会直接报
> `Starting AGP 9+, only the new DSL interface will be read`。

## 2. 产物路径

| 构建 | 命令 | 产物 |
|---|---|---|
| Debug APK | `flutter build apk --debug` | `build/app/outputs/flutter-apk/app-debug.apk` |
| Release APK | `flutter build apk --release` | `app-release.apk`（需先配置签名，见 §5） |
| 按 ABI 拆分 | `flutter build apk --split-per-abi --release` | `app-{armeabi-v7a,arm64-v8a,x86_64}-release.apk` |

**本机实测（2026-09-29）**

| 项 | 值 |
|---|---|
| 产物 | `build/app/outputs/flutter-apk/app-debug.apk` |
| 大小 | 188,930,012 B（180.18 MB） |
| SHA-256 | `7FE046C26C43E6D477982D6C74E8A06B2CCB7964A9C8B31684DAF84C4E0469C9` |
| 构建时间 | 2026-09-29 15:00:25（**对话框生命周期缺陷修复后重建**，见 docs/32；PRAGMA 修复后的上一版是 `AC863476…`） |
| Gradle 耗时 | 11.4 s（`assembleDebug`，热缓存） |
| 权限 | `INTERNET` + AGP 自动注入的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 |
| ABI | `arm64-v8a`、`armeabi-v7a`、`x86_64` |

校验命令：

```powershell
Get-FileHash 'build\app\outputs\flutter-apk\app-debug.apk' -Algorithm SHA256
# 本机没有 cmdline-tools（无 apkanalyzer），改用 build-tools 里的 aapt2：
& "$env:LOCALAPPDATA\Android\sdk\build-tools\36.0.0\aapt2.exe" dump badging `
  'build\app\outputs\flutter-apk\app-debug.apk'
```

## 3. 本机环境需要处理的四件事（**都不在仓库内**，除 §3.3 的镜像仓库声明）

### 3.1 JDK：必须显式指定 17

`JAVA_HOME` 未设置时 Flutter 可能选中 Android Studio 的 JBR（JDK 25）。
本机用 Adoptium 17：

```powershell
# 方式 A（一次性写进用户级 Flutter 配置）
flutter config --jdk-dir='C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot'

# 方式 B（只对当前终端生效）
$env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
```

### 3.2 Gradle 发行版：同版本 + 华为镜像

```properties
# android/gradle/wrapper/gradle-wrapper.properties
distributionUrl=https\://mirrors.huaweicloud.com/gradle/gradle-9.3.1-all.zip
```

* **版本号一个字都没改**（仍是模板指定的 `gradle-9.3.1-all`），只把下载源换成国内镜像；
* 原地址 `services.gradle.org` 在本机下载 200MB 发行包反复 `Premature EOF`
  （只能拿到 0.5MB 残包）；华为镜像实测约 850 KB/s，约 4 分钟完成；
* 注意 Gradle wrapper 是按 **`distributionUrl` 的哈希**定位缓存目录的，
  所以改 URL 会落到新的目录（本机为 `~/.gradle/wrapper/dists/gradle-9.3.1-all/d8eluw0qjsgvmi9ldga2uqudm`），
  旧地址的残包不会被复用。

### 3.3 Maven 依赖：镜像要**排在最前**，且必须补回 Plugin Portal

本机网络有三个坑，缺一不可：

1. `github.com:443` 超时，而部分 Gradle Module Metadata 里的 jar 绝对地址指向 github；
2. `repo.maven.apache.org` / `dl.google.com` 可达但**大文件会长时间停滞**（实测 10 分钟卡在 15MB）；
3. 一旦给 `pluginManagement` 显式配了仓库，Gradle 就**不再隐式加入默认的 Gradle Plugin Portal**，
   而 Flutter 的 included build（`packages/flutter_tools/gradle`）需要 `kotlin-dsl` 插件，它只在 Portal 上。

**环境级 init 脚本**（`~/.gradle/init.gradle`，Groovy；**不在仓库内**）：

```groovy
def petlifeMirrors = { handler ->
    handler.maven { name = 'petlifeMirrorGradlePlugin'
        url = 'https://mirrors.huaweicloud.com/repository/gradle-plugin/'
        metadataSources { mavenPom(); artifact() } }
    handler.maven { name = 'petlifeMirrorCentral'
        url = 'https://mirrors.huaweicloud.com/repository/maven/'
        metadataSources { mavenPom(); artifact() } }
    handler.maven { name = 'petlifeMirrorGoogle'
        url = 'https://mirrors.huaweicloud.com/repository/google/'
        metadataSources { mavenPom(); artifact() } }
    // 补回被"显式配置"顶掉的默认 Plugin Portal（用独立名字，避免与 settings 里的重名）
    handler.maven { name = 'petlifeMirrorPluginPortal'
        url = 'https://plugins.gradle.org/m2/'
        metadataSources { mavenPom(); artifact() } }
}

// 镜像必须排在官方仓库**之前**，否则等于没用。
def prioritizeMirrors = { handler ->
    def official = new ArrayList(handler)
    try { handler.clear() } catch (Exception e) { return }
    petlifeMirrors(handler)
    official.each { repo ->
        if (repo.name == null || !repo.name.startsWith('petlifeMirror')) {
            try { handler.add(repo) } catch (Exception e) { /* 忽略 */ }
        }
    }
}

beforeSettings  { s -> prioritizeMirrors(s.pluginManagement.repositories) }
settingsEvaluated { s -> prioritizeMirrors(s.dependencyResolutionManagement.repositories) }
allprojects { p -> p.buildscript.repositories.with { prioritizeMirrors(delegate) } }
```

**仓库内**还额外给项目级仓库加了镜像（这属于允许的"国内镜像地址"差异），
因为 `android/build.gradle.kts` 的 `allprojects { repositories { google(); mavenCentral() } }`
是 `PREFER_PROJECT` 模式下的实际来源，settings 级 mirror 管不到它：

```kotlin
// android/build.gradle.kts
allprojects {
    repositories {
        maven { url = uri("https://mirrors.huaweicloud.com/repository/google/")
                metadataSources { mavenPom(); artifact() } }
        maven { url = uri("https://mirrors.huaweicloud.com/repository/maven/")
                metadataSources { mavenPom(); artifact() } }
        google()
        mavenCentral()
    }
}
```

> 三个踩过的坑：① 镜像要挂在 **settings 级**（`pluginManagement` /
> `dependencyResolutionManagement`）——Flutter 的 included build 改不到它的项目级仓库；
> ② init 脚本必须用 **Groovy**（`init.gradle`），Kotlin DSL 的 `init.gradle.kts` 里
> `settingsEvaluated` 只接受 `Closure`，会编译失败；
> ③ 光"追加"镜像没用，**必须重排到官方仓库之前**（本机实测：追加时卡在
> `repo.maven.apache.org` 的 `kotlin-compiler-embeddable-2.2.21.jar` 十几分钟不动）。

### 3.4 Flutter 引擎产物：`storage.googleapis.com` 被重置，必须换源

`:app:mergeDebugAssets` 阶段 Gradle 需要 `io.flutter:armeabi_v7a_debug` 等引擎 AAR，
Flutter 插件把它们指向 `https://storage.googleapis.com/download.flutter.io`，
本机对该地址是 `Connection reset`。用 Flutter 官方支持的环境变量换源：

```powershell
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
```

这是**官方提供的镜像开关**（只换下载源，不改任何版本号）。
Flutter 会打印一行提示：`Flutter assets will be downloaded from https://storage.flutter-io.cn`。

## 4. 从零构建的完整命令（本机实测可用）

```powershell
$env:PUB_CACHE='C:\src\pub-cache'
$env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'   # §3.4
$repo='C:\Users\Administrator\WorkBuddy\DesktopPet\petlife'

cd $repo
flutter clean
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
# → build\app\outputs\flutter-apk\app-debug.apk
```

前置条件：`~/.gradle/init.gradle`（§3.3）已就位；Gradle 发行版已按 §3.2 指向镜像。

## 5. 签名（Release）

**当前状态**：release 构建仍是 Flutter 模板默认——**使用 debug 签名**
（`signingConfig = signingConfigs.getByName("debug")`）。只够本地验证，**不能上架**。

正式签名步骤（**尚未执行**，需要人工提供密钥库）：

1. 生成密钥库（**不要**提交到仓库）：

```powershell
keytool -genkey -v -keystore petlife-release.jks -keyalg RSA -keysize 2048 `
  -validity 10000 -alias petlife
```

2. 在 `android/key.properties` 写入（该文件已被 `android/.gitignore` 忽略）：

```properties
storeFile=../../keys/petlife-release.jks
storePassword=<保密>
keyAlias=petlife
keyPassword=<保密>
```

3. 在 `android/app/build.gradle.kts` 里读取 `key.properties`、声明 `signingConfigs.release`，
   并把 release 指向它；
4. 口令用 CI/环境变量注入，**不得**写进仓库文件或日志。

已由仓库配置保证：`android/.gitignore` 忽略 `key.properties` / `**/*.keystore` /
`**/*.jks`（`test/platform_isolation_test.dart` 会断言这一点）。

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 卡在 `Downloading gradle-9.3.1-all.zip` / `Premature EOF` | 受限网络下载 Gradle 发行版失败 | §3.2（换镜像，**不改版本号**） |
| `Java version used for the build is 25.x, which is incompatible with ...` | Flutter 选中 Android Studio 的 JDK 25 | §3.1 |
| `Plugin [id: 'org.gradle.kotlin.kotlin-dsl', version: '6.4.2'] was not found` | 显式配了 `pluginManagement` 仓库，顶掉了默认 Plugin Portal | §3.3（补 `petlifeMirrorPluginPortal`） |
| 卡在 `Downloading .../kotlin-compiler-embeddable-x.y.z.jar`（十几分钟不动） | 镜像只是"追加"在官方仓库之后，实际仍从 `repo.maven.apache.org` 拉 | §3.3（**重排到最前**） |
| `Could not download kotlin-compiler-embeddable-*.jar` → `Connect to github.com:443 failed` | Gradle Module Metadata 把 jar 绝对地址指向 github | §3.3（镜像 + `metadataSources { mavenPom(); artifact() }`） |
| `Type mismatch: ... Closure was expected`（init 脚本） | 用了 Kotlin DSL 写 init 脚本 | 用 Groovy `init.gradle` |
| `Could not resolve io.flutter:arm64_v8a_debug:...` + `storage.googleapis.com:443: Connection reset` | 引擎 AAR 走 googleapis，被重置 | §3.4（`FLUTTER_STORAGE_BASE_URL`） |
| `Starting AGP 9+, only the new DSL interface will be read` | 把 AGP 降到了 8.x | §1.2（回到官方矩阵 AGP 9.1.0） |
| `LINK : fatal error LNK1104: 无法打开文件 ...Release\petlife.exe` | Windows 端：还有正在运行的 `petlife.exe` 锁着产物 | 关闭正在运行的程序，**或**在单独干净构建目录验证（**不要**把被锁产物改名） |
| `Android license status unknown`（`flutter doctor`） | 未执行 `flutter doctor --android-licenses` | 组件齐全时不阻塞构建 |
| `WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP)` | `device_info_plus` / `file_picker` 仍以旧方式应用 KGP | 当前只是警告，不影响构建；未来 Flutter 版本会报错，届时升级插件 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 之前装过不同签名的同名应用 | `adb uninstall asia.akechi.petlife` |

## 7. 真机安装

```powershell
adb devices
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

或直接把 `app-debug.apk` 传到手机点击安装（需允许"安装未知来源应用"）。

> 本机当前**没有连接任何设备**，也没有可用的模拟器
> （无 AVD / 无系统镜像，且 WHPX 处于 Disabled 状态）→ 安装与 16 步人工验收
> 保持"待执行"，见 docs/29 §4.0。
