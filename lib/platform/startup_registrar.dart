/// 开机自启注册的**中立接口**（Windows 专属能力的抽象）。
///
/// 为什么要有这层
/// --------------
/// 「开机自启」在 Windows 上是一条注册表项，在 Android 上**根本不存在**
/// （Android 没有"登录时启动"的概念，只有 Phase 4B 才会考虑前台服务）。
/// 因此这里只描述"能不能做、现在是什么状态、怎么做"，
/// 具体实现放在 `platform/windows/`，Android 走 [UnsupportedStartupRegistrar]。
///
/// 设计约束
/// --------
/// * 本文件**不得** import 任何平台专属库（ffi / win32 / ...）；
/// * [isSupported] 为 false 时，调用方必须**隐藏入口**，而不是"点了再报错"；
/// * [registeredCommand] 读的是**系统真实状态**，不是本地偏好 ——
///   用户在注册表里手工删掉启动项后，界面必须能如实反映。
library;

/// 开机自启注册失败。
///
/// [message] 面向用户展示，必须能说明"是什么操作失败了、为什么"，
/// 且**不得**包含任何凭据类内容。
class StartupRegistrationException implements Exception {
  const StartupRegistrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 开机自启注册器。
abstract interface class StartupRegistrar {
  /// 当前平台是否支持真实注册开机自启。
  ///
  /// * Windows：注册表可写时为 true；
  /// * Android：[UnsupportedStartupRegistrar] 恒为 false。
  bool get isSupported;

  /// 读取**系统里当前真实存在**的启动命令；未注册返回 null。
  ///
  /// 读取失败（注册表不可访问等）抛 [StartupRegistrationException]。
  String? registeredCommand();

  /// 注册（或更新）当前用户的启动项，启动命令指向 [executablePath]。
  ///
  /// [executablePath] 由调用方给出（生产代码传**当前进程的可执行文件绝对路径**），
  /// 这样"写哪个 exe"是策略、而"怎么写"是实现，两者都在测试里可验证。
  ///
  /// 重复调用是幂等的：已存在则覆盖为最新路径（这正是"exe 被移动后自动修复"的实现）。
  /// 失败抛 [StartupRegistrationException]，**不得**静默忽略。
  void enable(String executablePath);

  /// 删除当前用户的启动项。条目不存在也算成功（幂等）。
  void disable();
}

/// 不支持开机自启的平台（Android）使用。
///
/// 四个操作都给出**明确且一致**的行为：读状态返回 null（未注册），
/// 写操作抛异常 —— 这样即使 UI 的隐藏逻辑出了 bug，也不会静默"假装成功"。
class UnsupportedStartupRegistrar implements StartupRegistrar {
  const UnsupportedStartupRegistrar();

  static const String _reason = '当前平台不支持开机自启（该选项仅 Windows 提供）';

  @override
  bool get isSupported => false;

  @override
  String? registeredCommand() => null;

  @override
  void enable(String executablePath) =>
      throw const StartupRegistrationException(_reason);

  @override
  void disable() => throw const StartupRegistrationException(_reason);
}
