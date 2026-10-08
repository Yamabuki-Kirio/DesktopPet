import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import '../platform/startup_registrar.dart';
import 'settings_controller.dart';

/// 开机自启开关的协调器。
///
/// 它把三件容易搞混的事情分开：
///
/// | 概念 | 存放在哪 | 谁是权威 |
/// |---|---|---|
/// | 用户**意图** | SQLite `local_settings.behavior.launchAtStartup` | 用户操作 |
/// | 系统**实况** | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `PetLife` 值 | **系统** |
/// | 界面开关 | 每次重建都读系统实况 | —— |
///
/// 两条关键规则（对应需求 6、7）：
///
/// 1. **界面开关以系统实况为准**：用户在 `regedit` / 任务管理器里手工删掉启动项后，
///    界面必须显示为"关闭"，而不是继续显示 SQLite 里那个已经撒谎的 true；
/// 2. **启动时按意图修复实况**：偏好为开启时，启动阶段会重新写一次启动项，
///    于是"发布目录被移动/重命名"后路径会自动更新到当前 exe。
///
/// 失败处理（需求 8）：[setEnabled] 在注册表操作失败时**抛出异常**，
/// 并在抛出前**不修改偏好**；调用方（设置页）据此把开关回滚到真实状态并显示原因。
///
/// 它同时是一个 [ChangeNotifier]：每当**系统状态可能变化**（开关切换、
/// 启动对齐、恢复默认设置）时通知一次，设置页的开关据此重新读系统实况。
/// 转发设置控制器的通知，是为了让偏好被别处改写时开关也能跟着刷新。
class StartupRegistrationService extends ChangeNotifier {
  StartupRegistrationService({
    required StartupRegistrar registrar,
    required SettingsController settings,
    required String Function() executablePath,
  })  : _registrar = registrar,
        _settings = settings,
        _executablePath = executablePath {
    _settings.addListener(notifyListeners);
  }

  final StartupRegistrar _registrar;
  final SettingsController _settings;

  /// 当前进程可执行文件的绝对路径（生产代码传 `Platform.resolvedExecutable`）。
  final String Function() _executablePath;

  @override
  void dispose() {
    _settings.removeListener(notifyListeners);
    super.dispose();
  }

  /// 当前平台是否支持真实注册开机自启。
  bool get isSupported => _registrar.isSupported;

  /// 系统里当前真实的启动命令（诊断用）；未注册或读取失败返回 null。
  String? registeredCommandOrNull() {
    try {
      return _registrar.registeredCommand();
    } catch (e, st) {
      Loggers.settings.warning('读取开机自启启动项失败', e, st);
      return null;
    }
  }

  /// **系统真实状态**：注册表里是否有启动项（不是 SQLite 偏好）。
  ///
  /// 读取失败时返回 false 并记录日志：此时界面显示"关闭"是诚实的，
  /// 因为系统里确实没有可用的启动命令。
  bool isRegistered() => registeredCommandOrNull() != null;

  /// 切换开关。
  ///
  /// * 先做**系统操作**，成功了才写偏好 —— 顺序反了就会出现
  ///   "SQLite 说开着、注册表里没有"的假象；
  /// * 抛 [StartupRegistrationException] 时偏好保持原值，调用方负责回滚 UI。
  Future<void> setEnabled(bool value) async {
    if (!_registrar.isSupported) {
      throw const StartupRegistrationException('当前平台不支持开机自启');
    }

    try {
      if (value) {
        _registrar.enable(_executablePath());
      } else {
        _registrar.disable();
      }
    } catch (e, st) {
      Loggers.settings.warning(
        '开机自启${value ? '注册' : '删除'}失败（偏好保持不变）',
        e,
        st,
      );
      rethrow;
    }
    await _settings.setLaunchAtStartup(value);
    notifyListeners();
  }

  /// 启动时对齐：按偏好修复系统实况，再把偏好校正为系统实况。
  ///
  /// 幂等，可在每次启动时调用。
  Future<void> reconcileOnStartup() async {
    if (!_registrar.isSupported) return;

    final bool preferred = _settings.settings.launchAtStartup;

    if (preferred) {
      try {
        // 重新写一次：位置没变时等价于空操作，位置变了就是修正路径。
        _registrar.enable(_executablePath());
      } catch (e, st) {
        Loggers.settings.warning(
          '更新开机自启启动项失败，界面将按系统真实状态显示',
          e,
          st,
        );
      }
    }

    final bool actual = isRegistered();
    if (actual != preferred) {
      Loggers.settings.warning(
        '开机自启偏好与系统实况不一致（偏好=$preferred，实况=$actual），已按系统实况校正',
      );
      await _settings.setLaunchAtStartup(actual);
    }
    notifyListeners();
  }

  /// 「恢复默认设置」时调用：删除系统启动项。
  ///
  /// 只删启动项，偏好由 `SettingsController.resetToDefaults()` 负责重置。
  /// 失败时抛异常，由调用方提示用户（不能让用户以为已经清干净了）。
  Future<void> removeForReset() async {
    if (!_registrar.isSupported) return;
    _registrar.disable();
    notifyListeners();
  }
}
