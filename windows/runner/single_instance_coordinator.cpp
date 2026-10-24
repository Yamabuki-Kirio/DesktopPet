#include "single_instance_coordinator.h"

#include <cstdlib>
#include <string_view>

namespace petlife {
namespace {

// 规格§一：当前用户会话级命名互斥体。名称升级（v1）即换锁，
// 与旧版本残留实例互不阻塞——旧实例在重启 Windows 后自然消失。
constexpr wchar_t kMutexName[] = L"Local\\PetLife.Desktop.SingleInstance.v1";

// 规格§六：主实例「正在退出」标记（手工复位，初始未触发）。
constexpr wchar_t kShuttingDownEventName[] =
    L"Local\\PetLife.Desktop.ShuttingDown.v1";

// 消息只读窗口的类名与标题（固定字符串，供 FindWindowExW 定位）。
constexpr wchar_t kSinkWindowClass[] = L"PetLifeSingleInstanceSink";
constexpr wchar_t kSinkWindowTitle[] = L"PetLifeSingleInstanceSink";

// 第二实例 → 主实例的信号消息（注册消息，避免与系统消息撞车）。
constexpr wchar_t kInstanceSignalName[] = L"PetLife.Desktop.InstanceSignal.v1";

// 主实例对 SendMessageTimeout 的应答值：证明消息循环活着且已受理。
constexpr DWORD_PTR kSinkAck = 0x504C4143;  // "PLAC"（PetLife Ack）

// 第二实例探测参数：
// * 单次投递超时 3s：超过即判定主实例无响应；
// * 接收窗口未建（主实例极早期）时每 300ms 重试，共 3 次。
constexpr DWORD kSignalTimeoutMs = 3000;
constexpr int kSinkRetryCount = 3;
constexpr DWORD kSinkRetryIntervalMs = 300;

// 「主实例正在退出」时第二实例的最长等待（规格§六：等待退出完成后提示重试）。
constexpr int kExitWaitPolls = 100;      // 100 × 100ms = 10s
constexpr DWORD kExitWaitIntervalMs = 100;

// WM_ENDSESSION 里等待 Dart 退出事务完成的预算（规格§二：3 秒内进程归零）。
constexpr DWORD kSessionEndPumpMs = 3000;

UINT InstanceSignalMessage() {
  static const UINT message =
      RegisterWindowMessageW(kInstanceSignalName);
  return message;
}

}  // namespace

// static
bool SingleInstanceCoordinator::HasShutdownSwitch(const wchar_t* command_line) {
  if (command_line == nullptr) return false;
  const std::wstring_view text(command_line);
  const std::wstring_view token(L"--shutdown");
  size_t pos = 0;
  while ((pos = text.find(token, pos)) != std::wstring_view::npos) {
    const bool start_ok = pos == 0 || text[pos - 1] == L' ' ||
                          text[pos - 1] == L'\t' || text[pos - 1] == L'=';
    const size_t end = pos + token.size();
    const bool end_ok = end >= text.size() || text[end] == L' ' ||
                        text[end] == L'\t';
    if (start_ok && end_ok) return true;
    ++pos;
  }
  return false;
}

// static
SingleInstanceCoordinator& SingleInstanceCoordinator::Instance() {
  static SingleInstanceCoordinator instance;
  return instance;
}

SecondInstanceDecision SingleInstanceCoordinator::AcquireOrAct(
    bool request_primary_shutdown) {
  ::SetLastError(ERROR_SUCCESS);
  HANDLE handle = ::CreateMutexW(nullptr, FALSE, kMutexName);
  const DWORD error = ::GetLastError();

  if (handle == nullptr) {
    if (error == ERROR_ACCESS_DENIED) {
      // 提权实例已暴露命名对象但未授予本进程访问：按「已有实例」处理，
      // 绝不失败放行（那会启动第二套数据库）。
      return ActAsDuplicate(request_primary_shutdown);
    }
    // 无法仲裁（极少见）：宁可不起，也不能在未知状态下触碰共享数据库。
    ::MessageBoxW(
        nullptr,
        L"PetLife 无法确认是否已有实例在运行。\n\n"
        L"请重新启动 PetLife；如果持续出现，请重启 Windows 后再试。",
        L"PetLife", MB_OK | MB_ICONINFORMATION);
    second_instance_exit_code_ = EXIT_FAILURE;
    return SecondInstanceDecision::kPrimaryUnresponsive;
  }

  if (error == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(handle);
    return ActAsDuplicate(request_primary_shutdown);
  }

  // 主实例：持有互斥体；创建「正在退出」事件与「退出完成」私有事件。
  mutex_ = handle;
  shutting_down_event_ =
      ::CreateEventW(nullptr, TRUE /*manual reset*/, FALSE /*nonsignaled*/,
                     kShuttingDownEventName);
  shutdown_done_event_ =
      ::CreateEventW(nullptr, TRUE /*manual reset*/, FALSE /*nonsignaled*/,
                     nullptr);
  return SecondInstanceDecision::kPrimary;
}

SecondInstanceDecision SingleInstanceCoordinator::ActAsDuplicate(
    bool request_primary_shutdown) {
  // 1) 主实例正在统一退出事务中：等待其真正退出后提示重试
  //    （规格§六：等待退出完成后退出第二实例，提示稍后重试）。
  if (IsPrimaryShuttingDown()) {
    WaitForPrimaryExitThenPrompt();
    return SecondInstanceDecision::kPrimaryExiting;
  }

  // 2) 通知主实例：唤醒（或转交退出请求）。SendMessageTimeout 同时是
  //    投递与响应性探测——3 秒内无应答即判定无响应。
  for (int attempt = 0; attempt < kSinkRetryCount; ++attempt) {
    HWND sink = ::FindWindowExW(HWND_MESSAGE, nullptr, kSinkWindowClass,
                                nullptr);
    if (sink != nullptr) {
      DWORD_PTR ack = 0;
      const LRESULT ok = ::SendMessageTimeoutW(
          sink, InstanceSignalMessage(),
          request_primary_shutdown ? kShutdownSignal : kWakeSignal, 0,
          SMTO_BLOCK | SMTO_ABORTIFHUNG, kSignalTimeoutMs, &ack);
      if (ok != 0 && ack == kSinkAck) {
        // 已受理：第二实例使命完成，立即退出（不建引擎 / 不碰数据库）。
        return request_primary_shutdown ? SecondInstanceDecision::kShutdownRequested
                                        : SecondInstanceDecision::kPrimaryWoke;
      }
      // 超时 / 拒绝：主实例挂起。不再重试，直接提示。
      break;
    }
    // 互斥体已存在但接收窗口还没建：主实例处于极早期启动，稍候重试。
    ::Sleep(kSinkRetryIntervalMs);
  }

  PromptUnresponsive();
  return SecondInstanceDecision::kPrimaryUnresponsive;
}

bool SingleInstanceCoordinator::IsPrimaryShuttingDown() const {
  // 事件不存在 = 主实例从未进入退出事务（或旧版本根本不建事件）。
  // EVENT_QUERY_STATE / EVENT_MODIFY_STATE：部分 SDK 头文件未导出前者，用常量。
  constexpr DWORD kEventQueryState = 0x0001;
  constexpr DWORD kEventModifyState = 0x0002;
  HANDLE event = ::OpenEventW(kEventQueryState | kEventModifyState, FALSE,
                              kShuttingDownEventName);
  if (event == nullptr) return false;
  const bool signaled =
      ::WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
  ::CloseHandle(event);
  return signaled;
}

void SingleInstanceCoordinator::WaitForPrimaryExitThenPrompt() {
  for (int i = 0; i < kExitWaitPolls; ++i) {
    ::SetLastError(ERROR_SUCCESS);
    HANDLE probe = ::CreateMutexW(nullptr, FALSE, kMutexName);
    const DWORD error = ::GetLastError();
    if (probe != nullptr) {
      const bool still_running = error == ERROR_ALREADY_EXISTS;
      ::CloseHandle(probe);
      if (!still_running) break;  // 互斥体已释放：主实例退出完成。
    } else if (error != ERROR_ACCESS_DENIED) {
      break;  // 对象已消失：主实例退出完成。
    }
    ::Sleep(kExitWaitIntervalMs);
  }
  ::MessageBoxW(nullptr,
                L"PetLife 正在退出，请稍后重新启动。",
                L"PetLife", MB_OK | MB_ICONINFORMATION);
}

void SingleInstanceCoordinator::PromptUnresponsive() {
  ::MessageBoxW(nullptr,
                L"PetLife 已在运行但暂时无响应。\n\n"
                L"请稍后重试；如果持续无响应，可以在任务管理器中结束 "
                L"PetLife 进程后重新启动。",
                L"PetLife", MB_OK | MB_ICONINFORMATION);
}

// static
LRESULT CALLBACK SingleInstanceCoordinator::SinkWndProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  if (message == InstanceSignalMessage()) {
    auto* self = reinterpret_cast<SingleInstanceCoordinator*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self == nullptr) {
      // 接收窗口尚未完成 this 绑定（理论上不可能——绑定在创建后立即执行）：
      // 绝不能返回 ack，否则第二实例会误判「通知成功」而主实例毫无动作
      //（历史缺陷：假 ack 让退出/唤醒请求无声丢失）。返回 0 触发对方超时。
      return 0;
    }
    if (wparam == kShutdownSignal) {
      if (self->shutdown_request_handler_ != nullptr) {
        self->shutdown_request_handler_();
      } else {
        self->pending_shutdown_request_ = true;
      }
    } else {
      if (self->wake_handler_ != nullptr) {
        self->wake_handler_();
      } else {
        self->pending_wake_ = true;
      }
    }
    return static_cast<LRESULT>(kSinkAck);
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

bool SingleInstanceCoordinator::CreateSinkWindow() {
  if (sink_window_ != nullptr) return true;

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = SinkWndProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kSinkWindowClass;
  ::RegisterClassW(&window_class);

  sink_window_ = ::CreateWindowExW(
      0, kSinkWindowClass, kSinkWindowTitle, 0, 0, 0, 0, 0, HWND_MESSAGE,
      nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (sink_window_ == nullptr) return false;
  // SinkWndProc 通过 GWLP_USERDATA 取回 this（不依赖 WM_NCCREATE 时序）。
  ::SetWindowLongPtrW(sink_window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
  return true;
}

void SingleInstanceCoordinator::DestroySinkWindow() {
  if (sink_window_ != nullptr) {
    ::DestroyWindow(sink_window_);
    sink_window_ = nullptr;
  }
  ::UnregisterClassW(kSinkWindowClass, nullptr);
}

void SingleInstanceCoordinator::SetWakeHandler(
    std::function<void()> handler) {
  wake_handler_ = std::move(handler);
  DeliverPendingSignals();
}

void SingleInstanceCoordinator::SetShutdownRequestHandler(
    std::function<void()> handler) {
  shutdown_request_handler_ = std::move(handler);
  DeliverPendingSignals();
}

void SingleInstanceCoordinator::ClearHandlers() {
  wake_handler_ = nullptr;
  shutdown_request_handler_ = nullptr;
  pending_wake_ = false;
  pending_shutdown_request_ = false;
}

void SingleInstanceCoordinator::DeliverPendingSignals() {
  // 引擎就绪前到达的唤醒 / 退出请求在这里补投递（只补一次）。
  if (pending_wake_ && wake_handler_ != nullptr) {
    pending_wake_ = false;
    wake_handler_();
  }
  if (pending_shutdown_request_ && shutdown_request_handler_ != nullptr) {
    pending_shutdown_request_ = false;
    shutdown_request_handler_();
  }
}

void SingleInstanceCoordinator::MarkShuttingDown() {
  if (shutting_down_event_ != nullptr) {
    ::SetEvent(shutting_down_event_);
  }
}

void SingleInstanceCoordinator::MarkShutdownComplete() {
  if (shutdown_done_event_ != nullptr) {
    ::SetEvent(shutdown_done_event_);
  }
}

void SingleInstanceCoordinator::PumpUntilShutdownComplete(DWORD timeout_ms) {
  if (shutdown_done_event_ == nullptr) return;
  const ULONGLONG start = ::GetTickCount64();
  while (::WaitForSingleObject(shutdown_done_event_, 50) != WAIT_OBJECT_0) {
    MSG msg;
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    if (::GetTickCount64() - start >= timeout_ms) break;
  }
}

void SingleInstanceCoordinator::ReleasePrimaryLock() {
  if (mutex_ != nullptr) {
    ::CloseHandle(mutex_);
    mutex_ = nullptr;
  }
  if (shutting_down_event_ != nullptr) {
    ::CloseHandle(shutting_down_event_);
    shutting_down_event_ = nullptr;
  }
  if (shutdown_done_event_ != nullptr) {
    ::CloseHandle(shutdown_done_event_);
    shutdown_done_event_ = nullptr;
  }
}

}  // namespace petlife
