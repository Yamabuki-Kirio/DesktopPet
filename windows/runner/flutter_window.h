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

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 窗口 Region 通道。三条可调用方法名：
  //   applyInteractionRegion / clearInteractionRegion / restorePetOnlyRegion，
  // 另加两条只读诊断：gdiObjectCount / regionBoundingBox。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      surface_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
