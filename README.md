# PetLife

跨平台桌面宠物 + 屏幕使用统计。当前着力于 **Windows x64** 桌面端（悬浮桌宠 + 环形菜单），
并带有一个 **Android** 端与配套的 **云端同步后端**。

> 项目状态：**开发中（早期原型）**。接口与数据格式仍可能变动。

---

## 功能概览

- **桌宠**：置顶悬浮的宠物窗口，支持拖拽移动、点击互动、多套形象素材。
- **环形菜单**：在桌宠旁展开的圆形菜单，包含桌宠 / 形象 / 记录 / 工具 / 设置 / 隐藏六大类及其子菜单。
- **屏幕使用统计**：自动记录前台应用与使用时长，可暂停采集、可查看本机统计与时间线。
- **形象与素材**：素材导入、解码、状态映射，支持把宠物状态与系统/应用事件关联。
- **记录与同步**：本机记录 + 云端记录；支持账号登录、离线保留、联网后同步（上传/下载增量）。
- **云端后端**：基于 FastAPI + PostgreSQL 的账户与同步服务，另附 MCP Server 供外部集成调用。

## 目录结构

```
petlife/
├── lib/                     # Flutter 应用源码（Dart）
│   ├── activity_tracking/   #   前台应用与使用时长采集
│   ├── asset_decoder/       #   素材解码
│   ├── asset_import/        #   素材导入
│   ├── character/           #   形象与素材模型
│   ├── core/                #   日志、通用工具
│   ├── database/            #   本地 SQLite（schema / DAO）
│   ├── desktop_window/      #   桌面窗口管理（置顶、点击穿透等）
│   ├── diagnostics/         #   诊断
│   ├── menu/                #   菜单契约与动作定义（平台无关纯 Dart）
│   ├── navigation/          #   页面导航
│   ├── platform/            #   平台适配层
│   │   ├── android/         #     Android 实现
│   │   └── windows/         #     Windows 实现
│   ├── settings/            #   设置
│   ├── state_engine/        #   宠物状态引擎
│   ├── sync/                #   账号、鉴权与云端同步
│   ├── ui/                  #   界面
│   │   ├── desktop/         #     桌面端（含环形菜单与绘制/命中测试）
│   │   ├── mobile/          #     移动端
│   │   ├── pages/           #     通用页面
│   │   └── ...
│   └── main.dart
├── test/                    # Dart 单元 / Widget 测试
├── assets/                  # 应用内置资源（托盘图标等）
├── windows/                 # Windows 平台工程（C++ runner + CMake）
├── android/                 # Android 平台工程（Gradle + Kotlin）
├── server/                  # 云端后端（Python / FastAPI），详见 server/README.md
├── tools/                   # 开发辅助脚本
├── docs/                    # 设计与交付文档
└── snapshots/               # 源码快照归档（zip）
```

## 环境要求

| 用途 | 要求 |
| --- | --- |
| Flutter 端 | Flutter（stable 通道，Dart SDK `>=3.9.0 <4.0.0`） |
| Windows 构建 | Visual Studio 2022（含「使用 C++ 的桌面开发」工作负载）、Windows 10/11 x64 |
| Android 构建 | Android SDK + JDK 17 |
| 后端 | Python 3.11+；生产使用 Docker + PostgreSQL |

## 快速开始（Flutter 端）

```bash
flutter pub get

# 运行（Windows 桌面）
flutter run -d windows

# 运行（Android）
flutter run -d <device-id>

# 构建
flutter build windows --release
flutter build apk --release
```

产物位置：

- Windows：`build/windows/x64/runner/Release/`
- Android：`build/app/outputs/flutter-apk/`

### 运行测试

```bash
flutter analyze
flutter test
```

## 后端（server/）

后端是独立的 Python 服务，包含账户体系、JWT 鉴权、同步接口与 MCP Server。

```bash
cd server
cp .env.example .env        # 然后按需修改其中的密钥与口令
# 具体启动方式（本地 / Docker Compose / 迁移）见 server/README.md
```

**必须在 `.env` 中设置 `PETLIFE_JWT_SECRET` 与 `POSTGRES_PASSWORD` 等机密项**，
且 `.env` 已被 `.gitignore` 排除，**不会**进入本仓库。

## 隐私与数据

- 使用统计数据存储在**本机**数据库中；只有在用户主动登录并触发同步时才会上传。
- 采集可随时暂停。
- 本仓库**不包含**任何密钥、令牌或签名文件；`server/.env.example` 仅提供占位示例。

## 已知限制

- 桌面端目前以 Windows x64 为主要目标平台。
- 环形菜单的几何与交互行为受冻结区约束，改动需配套回归测试。

## 许可证

尚未指定。若计划开源，请补充 `LICENSE` 文件（如 MIT / Apache-2.0）。
