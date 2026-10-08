# Windows 平台工程

这里保存 Flutter Windows Runner、CMake 配置及原生 C++ 窗口通道实现。Windows 桌宠的业务和绘制主要位于 `lib/ui/desktop/`，这里负责 HWND、窗口 Region、托盘与平台消息等原生能力。

构建要求 Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载：

```powershell
flutter build windows --release
```

分发时必须复制整个 `build/windows/x64/runner/Release/` 目录，不能只分发 `petlife.exe`。

维护边界：这里只维护 Windows Runner 和原生桥接；轮盘业务与 Flutter 绘制仍位于 `lib/`。
