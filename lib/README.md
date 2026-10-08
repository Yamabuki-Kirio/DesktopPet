# Flutter 应用源码

这里是 PetLife 的 Dart/Flutter 主代码，包含共享业务、本地数据库、活动采集、素材系统、同步服务、页面，以及 Windows/Android 平台适配层。

- `main.dart`：应用入口。
- `ui/`：控制面板、移动端页面与 Windows 桌宠界面。
- `menu/`：跨平台菜单契约、动作和轮盘逻辑。
- `platform/`：平台能力适配。
- `sync/`：账户、设备与云端同步。
- `database/`：本地 SQLite schema 与 DAO。

修改轮盘几何、窗口 Region 或同步协议时，应同步运行对应的 `test/` 回归测试。

维护要点：跨平台逻辑放在这里；只有必须调用系统能力的部分才下沉到 `android/` 或 `windows/`。
