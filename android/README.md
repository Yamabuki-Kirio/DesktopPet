# Android 平台工程

这里保存 PetLife 的 Android 原生工程与 Kotlin 悬浮桌宠实现，包括前台服务、开机自启、使用情况访问、双窗口悬浮层和 P3P 风格轮盘菜单。

- `app/src/main/kotlin/`：Android 原生实现。
- `app/src/main/res/`：清单、图标和平台资源。
- `app/src/test/`：Kotlin/JVM 单元测试。
- `gradle/`：Gradle Wrapper 配置。

应用的共享业务与 Flutter 界面仍位于仓库根目录的 `lib/`。构建与签名说明见 [`../docs/28-Android构建与签名.md`](../docs/28-Android构建与签名.md)。

维护边界：这里只放 Android 平台工程；账户、同步和通用页面修改应优先放在 `lib/`。
