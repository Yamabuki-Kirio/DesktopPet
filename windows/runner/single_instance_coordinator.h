#ifndef RUNNER_SINGLE_INSTANCE_COORDINATOR_H_
#define RUNNER_SINGLE_INSTANCE_COORDINATOR_H_

#include <windows.h>

#include <functional>

namespace petlife {

// 第二实例仲裁结果。
enum class SecondInstanceDecision {
  // 本进程是主实例：持有互斥体，继续启动。
  kPrimary,
  // 已通知主实例唤醒桌宠 / 控制面板：第二实例静默退出。
  kPrimaryWoke,
  // 已把退出请求交给主实例（`--shutdown` / 更新程序）：第二实例静默退出。
  kShutdownRequested,
  // 主实例正在退出：已等待其结束并提示稍后重试。
  kPrimaryExiting,
  // 主实例无响应：已提示；第二实例绝不启动第二套引擎与数据库。
  kPrimaryUnresponsive,
};

// 单实例仲裁 + 主实例唤醒通道 + 统一退出协作。
//
// 仲裁必须在 wWinMain 最先执行：先于 Flutter 引擎、窗口、日志文件与
// SQLite。命名对象全部位于 `Local\`（当前用户会话）命名空间：
// * 互斥体    `Local\PetLife.Desktop.SingleInstance.v1`
//   —— 进程级存在标记：主进程异常退出时 Windows 自动销毁，下次可正常启动。
//   刻意不用文件锁：崩溃后会留下需要人工清理的锁文件。
// * 退出事件  `Local\PetLife.Desktop.ShuttingDown.v1`
//   —— 主实例进入统一退出事务时置位，第二实例据此区分「正在退出」与「无响应」。
// * 接收窗口  消息只读窗口（message-only window），类名固定，
//   第二实例通过 `SendMessageTimeout` 投递唤醒 / 退出请求并探测响应性。
class SingleInstanceCoordinator {
 public:
  static SingleInstanceCoordinator& Instance();

  // 仲裁入口。返回 kPrimary 时本进程已持有互斥体；否则函数内部已完成
  // 「通知主实例 / 等待退出 / 提示用户」，调用方必须立即按
  // second_instance_exit_code() 结束进程，不得再初始化任何子系统。
  SecondInstanceDecision AcquireOrAct(bool request_primary_shutdown);

  // 主实例：创建消息接收窗口（隐藏；在 Flutter 引擎之前创建，
  // 保证主实例启动期间二次双击也能被唤醒而不是误判无响应）。
  bool CreateSinkWindow();
  void DestroySinkWindow();

  // 主实例：唤醒 / 退出请求回调（由 FlutterWindow 注入并转发到 Dart）。
  // 引擎未就绪期间到达的信号会被暂存，处理器注册时补投递。
  void SetWakeHandler(std::function<void()> handler);
  void SetShutdownRequestHandler(std::function<void()> handler);
  void ClearHandlers();

  // 统一退出事务协作（Dart 通过 app_lifecycle 通道调用）：
  // * MarkShuttingDown：事务开始 → 置命名事件（第二实例判定「正在退出」）。
  // * MarkShutdownComplete：事务完成 → 置私有事件（WM_ENDSESSION 泵解除阻塞）。
  void MarkShuttingDown();
  void MarkShutdownComplete();

  // WM_ENDSESSION 处理：泵消息等待 Dart 完成统一退出事务。
  // Dart 与消息循环同线程，必须持续泵消息引擎才能继续运行。
  void PumpUntilShutdownComplete(DWORD timeout_ms);

  // 释放互斥体与事件句柄（主实例消息循环结束后调用；进程终止也会自动释放）。
  void ReleasePrimaryLock();

  int second_instance_exit_code() const { return second_instance_exit_code_; }

  // 命令行里是否带 `--shutdown` / `-shutdown`（按整词匹配，不会命中子串）。
  // 第二实例以此把退出请求转交主实例（更新程序 / 验收脚本入口，规格§二）。
  static bool HasShutdownSwitch(const wchar_t* command_line);

  // 唤醒信号在接收窗口消息里的 wParam 约定。
  static constexpr UINT_PTR kWakeSignal = 0;
  static constexpr UINT_PTR kShutdownSignal = 1;

 private:
  SingleInstanceCoordinator() = default;
  ~SingleInstanceCoordinator() = default;

  SecondInstanceDecision ActAsDuplicate(bool request_primary_shutdown);
  bool IsPrimaryShuttingDown() const;
  void WaitForPrimaryExitThenPrompt();
  void PromptUnresponsive();
  void DeliverPendingSignals();

  static LRESULT CALLBACK SinkWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept;

  HANDLE mutex_ = nullptr;
  HANDLE shutting_down_event_ = nullptr;
  HANDLE shutdown_done_event_ = nullptr;
  HWND sink_window_ = nullptr;
  std::function<void()> wake_handler_;
  std::function<void()> shutdown_request_handler_;
  bool pending_wake_ = false;
  bool pending_shutdown_request_ = false;
  int second_instance_exit_code_ = EXIT_SUCCESS;
};

}  // namespace petlife

#endif  // RUNNER_SINGLE_INSTANCE_COORDINATOR_H_
