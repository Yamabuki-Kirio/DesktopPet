import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/logger.dart';
import '../../sync/api_client.dart';
import '../../sync/authenticated_api.dart';
import '../../sync/models/sync_models.dart';
import '../../sync/proxy/proxy_controller.dart';
import '../../sync/proxy/proxy_models.dart';
import '../../sync/proxy/proxy_probe.dart';
import '../../sync/proxy/system_proxy.dart';
import '../../sync/sync_engine.dart';
import '../dialogs/device_edit_dialog.dart';
import '../widgets/cloud_sync_actions.dart';
import 'ai_access_card.dart';

/// 「账户与同步」页面（需求「七、账户与同步页面」）。
///
/// 设计原则：
/// * **不登录也能用**：页面顶部明确写出"不登录也可正常使用桌宠和本地统计"，
///   未登录状态不做任何网络请求；
/// * **失败不弹窗**：所有错误都渲染在页面里（需求明确禁止连续弹窗），
///   只有"需要重新登录"这种需要用户决策的情况才给出显著提示；
/// * **不显示令牌**：界面上只出现邮箱、显示名、设备名与状态，
///   令牌只存在于凭据存储与内存中；
/// * **页面关闭后同步继续**：同步引擎属于 `AppServices`，生命周期与页面无关。
class AccountSyncPage extends StatefulWidget {
  const AccountSyncPage({super.key, required this.services});

  final AppServices services;

  @override
  State<AccountSyncPage> createState() => _AccountSyncPageState();
}

class _AccountSyncPageState extends State<AccountSyncPage> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  // --- 网络连接（代理）表单 ---
  final TextEditingController _proxyHost = TextEditingController();
  final TextEditingController _proxyPort = TextEditingController();
  final TextEditingController _proxyUsername = TextEditingController();
  final TextEditingController _proxyPassword = TextEditingController();
  ProxyMode _proxyMode = ProxyMode.automatic;
  bool _proxyBypassLocalhost = true;

  bool _busy = false;
  String? _error;
  String? _notice;
  List<RemoteDevice> _devices = const <RemoteDevice>[];

  AppServices get _s => widget.services;
  SyncEngine get _engine => _s.syncEngine;
  AuthenticatedApi get _api => _s.authenticatedApi;
  ProxyController get _proxyCtl => _s.proxyController;

  @override
  void initState() {
    super.initState();
    _loadInitial();
    _engine.addListener(_onEngineChanged);
    _proxyCtl.addListener(_onEngineChanged);
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngineChanged);
    _proxyCtl.removeListener(_onEngineChanged);
    _baseUrl.dispose();
    _email.dispose();
    _password.dispose();
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUsername.dispose();
    _proxyPassword.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadInitial() async {
    final String url = await _s.syncPreferences.serverBaseUrl();
    if (!mounted) return;
    _applyProxyForm(_proxyCtl.settings);
    setState(() {
      _baseUrl.text = url;
      _email.text = _api.lastAccount?.email ?? '';
    });
    if (_api.isSignedIn) {
      await _refreshDevices();
    }
  }

  /// 把配置写进表单控件。
  void _applyProxyForm(ProxySettings settings) {
    _proxyMode = settings.mode;
    _proxyHost.text = settings.host;
    _proxyPort.text = '${settings.port}';
    _proxyUsername.text = settings.username ?? '';
    _proxyPassword.clear();
    _proxyBypassLocalhost = settings.bypassLocalhost;
  }

  /// 用表单里的值组装 [ProxySettings]（**不含密码**）。
  ProxySettings _formProxySettings() {
    final int? port = int.tryParse(_proxyPort.text.trim());
    return ProxySettings(
      mode: _proxyMode,
      host: _proxyHost.text.trim().isEmpty
          ? ProxySettings.defaults.host
          : _proxyHost.text.trim(),
      port: (port != null && port > 0 && port <= 65535)
          ? port
          : ProxySettings.defaults.port,
      username: _proxyUsername.text.trim().isEmpty ? null : _proxyUsername.text.trim(),
      passwordCredentialReference: _proxyCtl.settings.passwordCredentialReference,
      bypassLocalhost: _proxyBypassLocalhost,
    );
  }

  /// 测试时要用的密码：优先用表单里刚输入的；否则用凭据存储里已保存的。
  Future<String?> _effectiveProxyPassword() async {
    if (_proxyPassword.text.isNotEmpty) return _proxyPassword.text;
    if (!_proxyCtl.hasSavedPassword) return null;
    try {
      return await _s.credentialStore.read(ProxyController.passwordReference);
    } catch (e, st) {
      Loggers.proxy.fine('读取代理密码失败（按无密码处理）', e, st);
      return null;
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final List<RemoteDevice> devices = await _api.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } catch (e, st) {
      Loggers.sync.fine('拉取设备列表失败', e, st);
      if (!mounted) return;
      setState(() => _error = '拉取设备列表失败：$e');
    }
  }

  /// 把异常翻译成一句用户可读、且**不含敏感信息**的说明。
  String _describe(ApiException e) {
    final String base = '${e.kind.labelZh}：${e.message}';
    return e.requestId == null ? base : '$base（request_id=${e.requestId}）';
  }

  // ---------------------------------------------------------------------------
  // 登录 / 注册
  // ---------------------------------------------------------------------------

  /// 登录 / 注册。
  ///
  /// 两步**分开报告**（这是需求明确要求的）：
  /// 1. 登录本身失败 → 「登录失败」，表单留在原地让用户改密码或地址；
  /// 2. 登录成功后的**首次同步**失败 → 只是「已登录，但首次同步失败」。
  ///    此时会话是有效的，页面必须显示已登录：同步失败会退避重试，
  ///    不能把它退化成"登录失败"再把登录表单塞回用户面前。
  Future<void> _submit({required bool register}) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    // --- 第一步：登录 / 注册（这一步成功之后会话就有效了）---
    try {
      await _api.signIn(
        baseUrl: _baseUrl.text,
        email: _email.text.trim(),
        password: _password.text,
        registerInsteadOfLogin: register,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(e);
      });
      return;
    } catch (e, st) {
      Loggers.sync.warning('登录/注册失败', e, st);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '登录失败：$e';
      });
      return;
    }

    // 登录已经成功：先把"已登录 + 正在同步"显示出来
    if (!mounted) return;
    setState(() {
      _password.clear();
      _busy = false;
      _notice = register ? '注册成功，正在同步本地历史数据…' : '登录成功，正在同步…';
    });

    // --- 第二步：首次同步。它失败**不是**登录失败 ---
    try {
      await _engine.onSignedIn();
    } catch (e, st) {
      // 引擎内部已经兜住异常；这里再兜一层，确保"同步出问题"不会
      // 冒泡成"登录失败"
      Loggers.sync.fine('登录后的首次同步未完成（登录状态仍然有效）', e, st);
    }
    if (!mounted) return;
    setState(() => _notice = _firstSyncNotice(register: register));
    await _refreshDevices();
  }

  /// 首次同步的结果文案：**登录成功与同步结果分开说**。
  String _firstSyncNotice({required bool register}) {
    final String action = register ? '注册成功' : '登录成功';
    if (_engine.status == SyncStatus.success) {
      return '$action，首次同步已完成';
    }
    final String reason = _engine.lastError ?? _engine.status.labelZh;
    return '$action，但首次同步失败：$reason\n\n'
        '登录状态是有效的（本机数据会保留并在稍后自动重试，'
        '也可以在下方点「立即上传本机记录」再试一次）。';
  }

  Future<void> _signOut() async {
    final bool? confirmed = await _confirm(
      title: '退出登录',
      message: '将删除本机保存的登录凭据。\n\n'
          '本地使用记录、桌宠素材与未上传的待同步数据都会保留，'
          '下次登录后会继续上传。',
      confirmText: '退出登录',
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _api.signOut();
      await _engine.onSignedOut();
      // Phase 4B：退出账户必须清掉该账户的**云端统计缓存**，
      // 否则下一个账户登录进来会看到上一个账户的云端数据。
      await _s.cloudStatistics.onSignedOut();
      if (!mounted) return;
      setState(() {
        _devices = const <RemoteDevice>[];
        _password.clear();
        _notice = '已退出登录。本地使用记录与素材未受影响，桌宠继续正常工作。';
      });
    } catch (e, st) {
      Loggers.sync.warning('退出登录失败', e, st);
      if (!mounted) return;
      setState(() => _error = '退出登录时出现问题：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 网络连接（代理）
  // ---------------------------------------------------------------------------

  Future<void> _detectSystemProxy() async {
    await _proxyCtl.detectSystemProxy();
    final SystemProxyInfo? info = _proxyCtl.detected;
    if (!mounted || info == null) return;

    // 检测到静态代理时顺手填进表单：用户点"手动 HTTP 代理"就不用再抄端口了。
    final ProxyServerEntry? entry = info.parsed.preferredHttp;
    if (entry != null && info.enabled) {
      setState(() {
        _proxyHost.text = entry.host;
        _proxyPort.text = '${entry.port}';
        if (info.bypassLocalByDefault) _proxyBypassLocalhost = true;
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _testProxy() async {
    await _proxyCtl.testProxy(
      baseUrl: _baseUrl.text,
      settings: _formProxySettings(),
      password: await _effectiveProxyPassword(),
    );
  }

  Future<void> _testServer() async {
    await _proxyCtl.testServer(
      baseUrl: _baseUrl.text,
      settings: _formProxySettings(),
      password: await _effectiveProxyPassword(),
    );
  }

  Future<void> _saveProxy() async {
    FocusScope.of(context).unfocus();
    await _proxyCtl.save(
      _formProxySettings(),
      // 空字符串表示"本次不改动已保存的密码"（要清除请用下面的按钮）
      password: _proxyPassword.text.isEmpty ? null : _proxyPassword.text,
    );
    if (!mounted) return;
    if (_proxyPassword.text.isNotEmpty) _proxyPassword.clear();
    setState(() {});
  }

  Future<void> _clearProxyPassword() async {
    await _proxyCtl.clearStoredPassword();
    if (!mounted) return;
    _proxyPassword.clear();
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 设备操作
  // ---------------------------------------------------------------------------

  Future<void> _editCurrentDevice() async {
    final AccountSession? account = _api.lastAccount;
    final String? deviceId = account?.deviceServerId;
    if (deviceId == null) {
      setState(() => _error = '当前设备还未绑定到服务端，请先执行一次同步');
      return;
    }
    final RemoteDevice? existing = _devices
        .where((RemoteDevice d) => d.id == deviceId)
        .cast<RemoteDevice?>()
        .firstWhere((RemoteDevice? d) => true, orElse: () => null);

    // 控制器与校验都在 DeviceEditDialog 自己的 State 里：调用方只拿**不可变结果**。
    // 旧写法在 `await showDialog` 返回后立刻 dispose 控制器，会在弹窗路由
    // 还在跑退场动画时销毁它，触发 `'_dependents.isEmpty': is not true.` —— 见 docs/32。
    final DeviceEditResult? result = await DeviceEditDialog.show(
      context,
      initialDeviceName: existing?.deviceName ?? '',
      initialModelName: existing?.modelName ?? '',
    );
    if (result == null) return;
    // 弹窗是异步的：返回时页面可能已经被销毁。
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.updateDevice(
        deviceId: deviceId,
        // 名称已在弹窗内校验为非空，不需要再回退成 null。
        deviceName: result.deviceName,
        modelName: result.modelName,
      );
      await _refreshDevices();
      if (!mounted) return;
      setState(() => _notice = '设备信息已更新');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeDevice(RemoteDevice device) async {
    final bool? confirmed = await _confirm(
      title: '撤销设备',
      message: '撤销后该设备上的登录立即失效，且无法继续上传数据。\n\n'
          '设备：${device.deviceName}\n\n'
          '历史数据会保留在服务端。',
      confirmText: '撤销',
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.revokeDevice(device.id);
      await _refreshDevices();
      if (!mounted) return;
      setState(() => _notice = '设备「${device.deviceName}」已撤销');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmText,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmText),
            ),
          ],
        ),
      );

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _banner(),
                const SizedBox(height: 16),
                if (_api.isSignedIn) ...<Widget>[
                  _accountCard(),
                  const SizedBox(height: 16),
                  _syncCard(),
                  const SizedBox(height: 16),
                  _devicesCard(),
                ] else
                  _loginCard(),
                const SizedBox(height: 16),
                AiAccessCard(api: _api, isSignedIn: _api.isSignedIn),
                const SizedBox(height: 16),
                _networkCard(),
                const SizedBox(height: 16),
                _privacyCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _banner() {
    if (_error != null) {
      return _messageBox(
        icon: Icons.error_outline,
        color: const Color(0xFFB3261E),
        title: '出错了',
        body: _error!,
      );
    }
    if (_api.needsReauthentication) {
      return _messageBox(
        icon: Icons.lock_clock,
        color: const Color(0xFFB26A00),
        title: '需要重新登录',
        body: '登录凭据已失效（可能是改过密码、退出过全部设备，或该设备已被撤销）。\n\n'
            '**本地采集与桌宠不受影响**，仍在正常记录使用数据；'
            '重新登录后会自动补传。',
      );
    }
    if (_notice != null) {
      return _messageBox(
        icon: Icons.info_outline,
        color: const Color(0xFF2E7D32),
        title: '操作完成',
        body: _notice!,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _messageBox({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) =>
      Card(
        color: color.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: color)),
                    const SizedBox(height: 4),
                    Text(body, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // --- 未登录 ---

  Widget _loginCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('登录到 PetLife 账户',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              '不登录也可以正常使用桌宠和本地统计。\n'
              '登录只是额外把使用数据同步到你自己的服务器，便于多设备查看。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: '服务端地址',
                hintText: 'http://127.0.0.1:8000',
                helperText: '生产环境必须使用 https://',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              decoration: const InputDecoration(labelText: '邮箱'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              // 需求：密码输入框不得回显密码
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              autofillHints: const <String>[AutofillHints.password],
              onSubmitted: (_) => _submit(register: false),
              decoration: const InputDecoration(labelText: '密码（至少 8 位）'),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(register: false),
                  icon: const Icon(Icons.login, size: 16),
                  label: const Text('登录'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _submit(register: true),
                  icon: const Icon(Icons.person_add_alt, size: 16),
                  label: const Text('注册'),
                ),
                const SizedBox(width: 16),
                if (_busy) const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '凭据后端：${_s.credentialStore.backendName}',
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  // --- 已登录 ---

  Widget _accountCard() {
    final AccountSession? account = _api.lastAccount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('账户',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _signOut,
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('退出登录'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _kv('显示名称', account?.displayName ?? '—'),
            _kv('邮箱', account?.email ?? '—'),
            _kv('服务端', account?.serverBaseUrl ?? '—'),
            _kv('当前设备', _currentDeviceLabel()),
            _kv('凭据后端', _s.credentialStore.backendName),
            const SizedBox(height: 4),
            const Text(
              '界面与日志都不会显示完整令牌；令牌保存在系统凭据存储中，退出登录时删除。',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  String _currentDeviceLabel() {
    final String? id = _api.deviceServerId;
    if (id == null) return '未绑定（下次同步时自动注册）';
    final RemoteDevice? match = _devices
        .where((RemoteDevice d) => d.id == id)
        .cast<RemoteDevice?>()
        .firstWhere((RemoteDevice? d) => true, orElse: () => null);
    return match == null ? id : '${match.deviceName}（$id）';
  }

  Widget _syncCard() {
    final SyncStatus status = _engine.status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('同步状态',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                // 注意：这里**不再**放"立即同步"按钮。
                // 上传与云端查询是两个方向，按钮已拆成下方明确的两个
                // （见 CloudSyncActionsCard），避免一个含糊的"同步"造成误解。
                if (_engine.isSyncing)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 28,
              runSpacing: 10,
              children: <Widget>[
                _stat('同步状态', status.labelZh),
                _stat('待同步记录', '${_engine.pendingCount} 条'),
                _stat('上次成功同步', _formatTime(_engine.lastSuccessAt)),
                _stat('连续失败次数', '${_engine.consecutiveFailures}'),
                _stat('下次重试', _formatTime(_engine.nextRetryAt)),
              ],
            ),
            if (_engine.lastError != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.warning_amber, size: 16, color: Color(0xFFB26A00)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('最近错误：${_engine.lastError}',
                        style: const TextStyle(fontSize: 12, color: Color(0xFFB26A00))),
                  ),
                ],
              ),
            ],
            if (_engine.lastRejectedNote != null) ...<Widget>[
              const SizedBox(height: 6),
              Text('服务端拒收：${_engine.lastRejectedNote}',
                  style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ],
            const SizedBox(height: 12),
            // Phase 4B：两个含义明确的动作按钮（上传 / 云端查询）
            CloudSyncActionsCard(
              upload: SyncEngineUploadHost(_engine),
              cloud: CloudControllerRefreshHost(_s.cloudStatistics),
              deviceName: _deviceDisplayName(),
              serverBaseUrl: _api.baseUrl,
              lastError: _engine.lastError,
            ),
            const SizedBox(height: 10),
            const Text(
              '同步在后台进行，关闭本页面或最小化窗口都不会中断；'
              '同步失败只在页面与日志中展示，不会弹窗打扰，也不影响桌宠与本地采集。',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  /// 「当前设备」展示名：优先服务端返回的设备名，回退到设备 ID。
  String _deviceDisplayName() {
    final RemoteDevice? current = _currentDevice;
    if (current != null && current.deviceName.isNotEmpty) return current.deviceName;
    final String? id = _api.deviceServerId;
    if (id == null) return '未注册';
    for (final RemoteDevice device in _devices) {
      if (device.id == id) {
        return device.deviceName.isNotEmpty ? device.deviceName : id;
      }
    }
    return id;
  }

  RemoteDevice? get _currentDevice {
    final String? id = _api.deviceServerId;
    if (id == null) return null;
    for (final RemoteDevice device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  Widget _devicesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('设备列表',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _refreshDevices,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新'),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _editCurrentDevice,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('修改本机'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_devices.isEmpty)
              const Text('暂无设备（登录后同步一次即可完成绑定）',
                  style: TextStyle(fontSize: 12, color: Colors.black54))
            else
              for (final RemoteDevice device in _devices) _deviceRow(device),
          ],
        ),
      ),
    );
  }

  Widget _deviceRow(RemoteDevice device) {
    final bool isCurrent = device.id == _api.deviceServerId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            device.isRevoked
                ? Icons.block
                : (isCurrent ? Icons.computer : Icons.devices_other),
            size: 16,
            color: device.isRevoked ? Colors.grey : const Color(0xFF2F4A63),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        device.deviceName,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrent)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('（本机）',
                            style: TextStyle(fontSize: 11, color: Color(0xFF2E7D32))),
                      ),
                    if (device.isRevoked)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('（已撤销）',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ),
                  ],
                ),
                Text(
                  '${device.platform}/${device.architecture}'
                  '${device.modelName == null || device.modelName!.isEmpty ? '' : ' · ${device.modelName}'}'
                  ' · 最近活跃 ${_formatIso(device.lastSeenAt)}',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (!isCurrent && !device.isRevoked)
            TextButton(
              onPressed: _busy ? null : () => _revokeDevice(device),
              child: const Text('撤销', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // --- 网络连接 ---

  Widget _networkCard() {
    final ProxyController ctl = _proxyCtl;
    final ProxyResolution res = ctl.resolution;
    final SystemProxyInfo? detected = ctl.detected;
    final bool busy = _busy || ctl.busy;
    final bool manual = _proxyMode == ProxyMode.manualHttp;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('网络连接',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '长期使用 Clash 的用户请让 Clash 开启 System Proxy，或在此选择「手动 HTTP 代理」'
              '并填写 Clash 的 HTTP/Mixed 端口。\n'
              '不需要开启 TUN 模式。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 84,
                  child: Text('连接方式',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                ),
                Expanded(
                  child: DropdownButton<ProxyMode>(
                    value: _proxyMode,
                    isExpanded: true,
                    onChanged: busy
                        ? null
                        : (ProxyMode? m) {
                            if (m == null) return;
                            setState(() => _proxyMode = m);
                          },
                    items: ProxyMode.values
                        .map((ProxyMode m) => DropdownMenuItem<ProxyMode>(
                              value: m,
                              child: Text(m.labelZh,
                                  style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (manual) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _proxyHost,
                      decoration: const InputDecoration(
                        labelText: '代理地址',
                        hintText: '127.0.0.1',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _proxyPort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        hintText: '7877',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxyUsername,
                decoration: const InputDecoration(
                  labelText: '用户名（可选）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxyPassword,
                // 与登录密码一致：密码框不得回显
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: '密码（可选）',
                  isDense: true,
                  helperText: ctl.hasSavedPassword
                      ? '已保存密码；留空表示不修改。密码保存在系统凭据存储中，不写入本地数据库。'
                      : '密码保存在系统凭据存储中，不写入本地数据库。',
                ),
              ),
            ],
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _proxyBypassLocalhost,
              onChanged: busy
                  ? null
                  : (bool? v) => setState(() => _proxyBypassLocalhost = v ?? true),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('本地地址不走代理（<local>）',
                  style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: busy ? null : _detectSystemProxy,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('检测系统代理'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _testProxy,
                  icon: const Icon(Icons.lan_outlined, size: 16),
                  label: const Text('测试代理'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _testServer,
                  icon: const Icon(Icons.cloud_done_outlined, size: 16),
                  label: const Text('测试服务端'),
                ),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : _saveProxy,
                  icon: const Icon(Icons.save, size: 16),
                  label: const Text('保存并重新连接'),
                ),
                if (ctl.hasSavedPassword)
                  TextButton(
                    onPressed: busy ? null : _clearProxyPassword,
                    child: const Text('清除已保存的密码', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _kv('检测到的系统代理', _describeDetected(detected)),
            _kv(
              '当前实际使用',
              res.usesProxy
                  ? '代理 ${res.authority}（${res.sourceLabel}）'
                  : '直连（${res.sourceLabel}）',
            ),
            if (res.blockedReason != null) ...<Widget>[
              const SizedBox(height: 8),
              _inlineNote(
                icon: Icons.error_outline,
                color: const Color(0xFFB3261E),
                text: res.blockedReason!,
              ),
            ] else if (res.warning != null) ...<Widget>[
              const SizedBox(height: 8),
              _inlineNote(
                icon: Icons.info_outline,
                color: const Color(0xFFB26A00),
                text: res.warning!,
              ),
            ],
            if (ctl.error != null) ...<Widget>[
              const SizedBox(height: 8),
              _inlineNote(
                icon: Icons.error_outline,
                color: const Color(0xFFB3261E),
                text: ctl.error!,
              ),
            ] else if (ctl.notice != null) ...<Widget>[
              const SizedBox(height: 8),
              _inlineNote(
                icon: Icons.check_circle_outline,
                color: const Color(0xFF2E7D32),
                text: ctl.notice!,
              ),
            ],
            if (ctl.lastProbe != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                ctl.lastProbeIncludedHealth ? '测试服务端结果' : '测试代理结果',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              for (final ProxyProbeStep step in ctl.lastProbe!.steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        step.ok ? Icons.check : Icons.close,
                        size: 14,
                        color: step.ok ? const Color(0xFF2E7D32) : const Color(0xFFB3261E),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${step.label}：${step.detail}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            const Text('Clash 使用说明',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              '• Clash 必须开启 System Proxy，或在本页选择「手动 HTTP 代理」填写 HTTP/Mixed Port。\n'
              '• 不要求开启 TUN 模式。\n'
              '• SOCKS 端口不能直接当 HTTP 代理使用；如果只开了 SOCKS5，'
              '请在 Clash 里改用 Mixed Port（HTTP 与 SOCKS 共用同一个端口）。\n'
              '• 代理地址一般是 127.0.0.1，端口以 Clash 设置页显示的为准（例如 7877）。\n'
              '• PetLife 暂不支持 PAC/WPAD 自动配置脚本；检测到时会明确提示并退回直连。',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  String _describeDetected(SystemProxyInfo? info) {
    if (info == null) return '尚未检测';
    if (!info.available) return '读取失败（${info.error ?? '未知原因'}）';
    if (info.hasStaticProxy) {
      return '${info.proxyServer}（来源：${info.source}'
          '${info.enabled ? '' : '，但系统未启用'}）';
    }
    if (info.hasPac) return 'PAC：${info.autoConfigUrl}（不支持）';
    if (info.autoDetect) return '自动检测（WPAD，不支持）';
    return '未设置静态代理';
  }

  Widget _inlineNote({
    required IconData icon,
    required Color color,
    required String text,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      );

  Widget _privacyCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('上传了什么',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text(
                '只上传：应用使用时间段（应用名、分类、起止时间、活跃秒数）、'
                '每日用量快照（会话/活跃/空闲秒数）、应用库的分类与显示名、设备名称等自报信息。\n\n'
                '绝不上传：窗口标题、文档名、网页标题或网址、本地文件完整路径、'
                '键盘输入、鼠标内容、剪贴板、截图、素材文件与日志文件。',
                style: TextStyle(fontSize: 12, color: Colors.black87),
              ),
              const SizedBox(height: 8),
              const Text(
                '服务端地址可随时修改；退出登录只清理认证信息与**云端统计缓存**，'
                '不会删除本地使用记录与桌宠素材。',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              const Text('云同步能力（当前真实状态）',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              // 这里只展示**真实能力**：不提供没有实际效果的开关。
              _capabilityRow('上传应用名称', '已启用'),
              _capabilityRow('上传应用标识', '已启用'),
              _capabilityRow('上传详细时间线', '已启用'),
              _capabilityRow('窗口标题', '当前版本不上传'),
              const SizedBox(height: 6),
              const Text(
                '说明：详细时间线是「云端统计里能看到具体使用时间段」的前提。'
                '当前协议尚未支持按开关切换为"仅上传每日聚合"，因此本版本**不提供**'
                '该开关（避免做出一个没有实际效果的按钮）；相关能力列为后续支持。',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
        ),
      );

  Widget _capabilityRow(String label, String state) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 120,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: Text(
                state,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 84,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: SelectableText(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _stat(String label, String value) => SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
      );

  static String _formatTime(DateTime? time) {
    if (time == null) return '—';
    return _formatLocal(time.toLocal());
  }

  /// 服务端返回的是 ISO 8601 UTC 字符串，这里转成本地时间展示。
  static String _formatIso(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final DateTime? parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    return _formatLocal(parsed.toLocal());
  }

  static String _formatLocal(DateTime local) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
