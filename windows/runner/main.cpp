#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance_coordinator.h"
#include "utils.h"

// 单实例仲裁（规格§一）必须最先执行：在创建 Flutter 引擎、窗口、日志文件
// 和数据库之前，由 Runner 完成仲裁。
//
// * 第一个实例取得 `Local\PetLife.Desktop.SingleInstance.v1` 命名互斥体，
//   继续启动，并立刻创建消息接收窗口（唤醒通道）。
// * 第二个实例不初始化 Flutter / SQLite / 托盘：通知主实例唤醒桌宠或
//   控制面板后立即退出；主实例无响应时给出中文提示，绝不启动第二套数据库。
// * 主进程异常退出时 Windows 自动销毁互斥体，下次可以正常启动。
int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // `--shutdown`：第二实例把退出请求转交主实例后立即退出（更新程序 /
  // 验收脚本入口，规格§二「更新程序要求退出」）。
  const bool request_primary_shutdown =
      petlife::SingleInstanceCoordinator::HasShutdownSwitch(command_line);

  petlife::SingleInstanceCoordinator &coordinator =
      petlife::SingleInstanceCoordinator::Instance();
  if (coordinator.AcquireOrAct(request_primary_shutdown) !=
      petlife::SecondInstanceDecision::kPrimary) {
    // 已完成通知 / 等待 / 提示：直接结束，不触碰任何共享资源。
    return coordinator.second_instance_exit_code();
  }

  // 主实例：接收窗口在引擎之前创建，这样启动期间（引擎尚未就绪）的
  // 二次双击也能被受理（信号暂存，等引擎就绪后补投递）而不是误报无响应。
  coordinator.CreateSinkWindow();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"petlife", origin, size)) {
    coordinator.DestroySinkWindow();
    coordinator.ReleasePrimaryLock();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();

  // 统一退出事务的最后两步（规格§二）：移除消息接收窗口，释放互斥体，
  // 然后随进程返回结束。进程被强杀时这些句柄也由 Windows 自动回收。
  coordinator.DestroySinkWindow();
  coordinator.ReleasePrimaryLock();
  return EXIT_SUCCESS;
}
