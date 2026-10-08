#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 通道名：与 Dart 侧 `windowsSurfaceChannelName` 逐字一致。
constexpr char kSurfaceChannelName[] = "asia.akechi.petlife/windows_surface";

// 从 EncodableMap 里取一个整数字段（兼容 int32 / int64 / double）。
bool GetLongField(const flutter::EncodableMap& map, const char* key, long* out) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return false;
  const flutter::EncodableValue& value = it->second;
  if (std::holds_alternative<int32_t>(value)) {
    *out = std::get<int32_t>(value);
    return true;
  }
  if (std::holds_alternative<int64_t>(value)) {
    *out = static_cast<long>(std::get<int64_t>(value));
    return true;
  }
  if (std::holds_alternative<double>(value)) {
    *out = static_cast<long>(std::get<double>(value));
    return true;
  }
  return false;
}

// RECT → EncodableMap（物理像素，客户端坐标）。
flutter::EncodableValue RectToMap(const RECT& rect) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int32_t>(rect.left));
  map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int32_t>(rect.top));
  map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int32_t>(rect.right));
  map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int32_t>(rect.bottom));
  return flutter::EncodableValue(map);
}

// 用 `CreateRectRgn` + `CombineRgn(RGN_OR)` 合成一个 HRGN。
//
// 空片段（right<=left / bottom<=top）被忽略；返回的 HRGN 所有权在**调用方**：
// * `SetWindowRgn` 成功 → 系统接管，调用方不得 DeleteObject；
// * `SetWindowRgn` 失败 → 调用方必须 DeleteObject。
HRGN BuildRegionFromRects(const flutter::EncodableList& rects,
                          int* rect_count,
                          RECT* bounding_box) {
  HRGN region = ::CreateRectRgn(0, 0, 0, 0);  // 空区域，后续 OR 合并
  if (region == nullptr) return nullptr;

  bool has_box = false;
  RECT box = {0, 0, 0, 0};
  int count = 0;
  for (const flutter::EncodableValue& item : rects) {
    if (!std::holds_alternative<flutter::EncodableMap>(item)) continue;
    const flutter::EncodableMap& map = std::get<flutter::EncodableMap>(item);
    long left = 0, top = 0, right = 0, bottom = 0;
    if (!GetLongField(map, "left", &left) || !GetLongField(map, "top", &top) ||
        !GetLongField(map, "right", &right) || !GetLongField(map, "bottom", &bottom)) {
      continue;
    }
    if (right <= left || bottom <= top) continue;

    HRGN part = ::CreateRectRgn(static_cast<int>(left), static_cast<int>(top),
                                static_cast<int>(right), static_cast<int>(bottom));
    if (part == nullptr) continue;
    ::CombineRgn(region, region, part, RGN_OR);
    ::DeleteObject(part);  // 临时片段：合并后立即释放（不泄漏）

    if (!has_box) {
      box = {static_cast<LONG>(left), static_cast<LONG>(top),
             static_cast<LONG>(right), static_cast<LONG>(bottom)};
      has_box = true;
    } else {
      if (left < box.left) box.left = static_cast<LONG>(left);
      if (top < box.top) box.top = static_cast<LONG>(top);
      if (right > box.right) box.right = static_cast<LONG>(right);
      if (bottom > box.bottom) box.bottom = static_cast<LONG>(bottom);
    }
    count++;
  }

  if (rect_count != nullptr) *rect_count = count;
  if (bounding_box != nullptr) *bounding_box = box;
  return region;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 引擎就绪后才注册窗口 Region 通道（此时 messenger 可用）。
  RegisterSurfaceChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (surface_channel_) {
    // 析构 MethodChannel 会注销消息处理函数（内部等价于 SetMethodCallHandler(null)）。
    surface_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterSurfaceChannel() {
  if (!flutter_controller_ || !flutter_controller_->engine()) return;

  surface_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kSurfaceChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  surface_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        HWND hwnd = GetHandle();

        // applyInteractionRegion / restorePetOnlyRegion 都接受
        // { "rects": [ {left,top,right,bottom}, ... ] }（物理客户端像素）。
        if (method == "applyInteractionRegion" ||
            method == "restorePetOnlyRegion") {
          if (hwnd == nullptr) {
            result->Error("no_window", "窗口句柄不可用");
            return;
          }
          const flutter::EncodableMap* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad_args", "参数必须是 {rects: [...]}");
            return;
          }
          const auto it = args->find(flutter::EncodableValue("rects"));
          if (it == args->end() ||
              !std::holds_alternative<flutter::EncodableList>(it->second)) {
            result->Error("bad_args", "缺少 rects 列表");
            return;
          }
          const flutter::EncodableList& rects =
              std::get<flutter::EncodableList>(it->second);
          if (rects.empty()) {
            result->Error("empty_rects", "rects 不能为空");
            return;
          }

          int count = 0;
          RECT box = {0, 0, 0, 0};
          HRGN region = BuildRegionFromRects(rects, &count, &box);
          if (region == nullptr) {
            result->Error("region_failed", "CreateRectRgn 失败");
            return;
          }

          // ---- HRGN 所有权规则（GDI 泄漏铁律，必须严格遵守）----
          // SUCCESS：SetWindowRgn 接管 HRGN（连同旧区域由系统删除），
          //          调用方 **不得** DeleteObject。
          // FAILURE：调用方 **必须** DeleteObject（含旧区域未被替换的情形），
          //          否则每次失败都泄漏一个 GDI 对象。
          if (::SetWindowRgn(hwnd, region, TRUE) != 0) {
            flutter::EncodableMap payload;
            payload[flutter::EncodableValue("success")] =
                flutter::EncodableValue(true);
            payload[flutter::EncodableValue("rectCount")] =
                flutter::EncodableValue(count);
            payload[flutter::EncodableValue("boundingBox")] = RectToMap(box);
            result->Success(flutter::EncodableValue(payload));
          } else {
            ::DeleteObject(region);  // 失败：必须释放，绝不泄漏
            result->Error("set_window_rgn_failed", "SetWindowRgn 调用失败");
          }
          return;
        }

        if (method == "clearInteractionRegion") {
          if (hwnd == nullptr) {
            result->Error("no_window", "窗口句柄不可用");
            return;
          }
          // NULL 区域 = 恢复普通矩形窗口；不涉及 HRGN 所有权转移。
          BOOL ok = ::SetWindowRgn(hwnd, nullptr, TRUE);
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("success")] =
              flutter::EncodableValue(ok != 0);
          result->Success(flutter::EncodableValue(payload));
          return;
        }

        if (method == "gdiObjectCount") {
          // GetGuiResources 由 user32 导出；失败（含 GR_GDIOBJECTS 不可用）返回 0。
          DWORD count = ::GetGuiResources(::GetCurrentProcess(), GR_GDIOBJECTS);
          result->Success(flutter::EncodableValue(static_cast<int32_t>(count)));
          return;
        }

        if (method == "regionBoundingBox") {
          if (hwnd == nullptr) {
            // 无区域 / 不可用：返回 null（Dart 侧按"不可用"处理）。
            result->Success(flutter::EncodableValue());
            return;
          }
          // GetWindowRgn 把窗口当前区域**复制**进我们创建的 HRGN：我们拥有它，必须释放。
          HRGN copy = ::CreateRectRgn(0, 0, 0, 0);
          if (copy == nullptr) {
            result->Success(flutter::EncodableValue());
            return;
          }
          int got = ::GetWindowRgn(hwnd, copy);
          if (got == ERROR || got == NULLREGION) {
            ::DeleteObject(copy);
            result->Success(flutter::EncodableValue());
            return;
          }
          RECT box;
          if (::GetRgnBox(copy, &box) == 0) {
            ::DeleteObject(copy);
            result->Success(flutter::EncodableValue());
            return;
          }
          ::DeleteObject(copy);  // 自建的 copy，必须释放
          result->Success(RectToMap(box));
          return;
        }

        result->NotImplemented();
      });
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
