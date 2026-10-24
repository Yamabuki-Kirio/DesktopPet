#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 主实例唤醒通道（规格§一/§六）：把第二实例的信号转发给 Dart。
  // 引擎未就绪时由协调器暂存信号，OnCreate 完成后补投递。
  void NotifySecondInstanceWake();
  // 退出请求（`--shutdown` 第二实例 / 更新程序）→ Dart 统一退出事务。
  void NotifyExitRequested(const std::string& reason);
  // 系统注销 / 关机（WM_QUERYENDSESSION / WM_ENDSESSION）→ Dart 统一退出事务。
  void NotifySystemSessionEnd();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 注册"固定画布 + 窗口 Region"原生通道
  // （`asia.akechi.petlife/windows_surface`）。
  void RegisterSurfaceChannel();

  // 注册应用生命周期通道（`asia.akechi.petlife/app_lifecycle`）：
  // * Dart → 原生：markShuttingDown / shutdownComplete（统一退出事务协作）；
  // * 原生 → Dart：onSecondInstance / onExitRequested / onSystemSessionEnd。
  void RegisterLifecycleChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 窗口 Region 通道。三条可调用方法名：
  //   applyInteractionRegion / clearInteractionRegion / restorePetOnlyRegion，
  // 另加两条只读诊断：gdiObjectCount / regionBoundingBox。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      surface_channel_;

  // 应用生命周期通道（单实例唤醒 / 统一退出协作）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      lifecycle_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
