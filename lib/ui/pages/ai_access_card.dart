import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../../sync/api_client.dart';
import '../../sync/authenticated_api.dart';
import '../../sync/models/api_key_models.dart';

/// 「AI 数据访问」卡片。
///
/// 这里生成的是**个人访问密钥**（`plk_...`）：把它配置到 AI / MCP 侧的
/// `PETLIFE_API_KEY` 之后，AI 就能查询本账户的使用统计。身份由密钥本身决定，
/// 因此 AI 侧不需要（也无法）指定 ``user_id`` 或 Telegram 身份。
///
/// 设计要点
/// --------
/// * **仅登录后可用**：未登录时只显示说明，不发任何请求；
/// * **明文只显示一次**：生成后完整密钥只活在内存里（不写 SQLite、不写偏好），
///   退出登录或点「我已保存」即丢弃；列表里永远只出现前缀；
/// * **撤销才是失效途径**：界面上不提供"再看一次密钥"，服务端也只存哈希；
/// * **网络状态可见**：加载中 / 空数据 / 未登录 / 网络失败 / 登录失效 / 服务端错误
///   各有明确文案，且**只渲染在卡片内，不弹窗**；
/// * **撤销失败不假装成功**：只有服务端确认（`is_active == false`）后才刷新列表；
/// * 所有请求都走 [AuthenticatedApi]（复用 Access Token 自动刷新与当前代理配置）。
class AiAccessCard extends StatefulWidget {
  const AiAccessCard({
    super.key,
    required this.api,
    required this.isSignedIn,
  });

  final AuthenticatedApi api;
  final bool isSignedIn;

  @override
  State<AiAccessCard> createState() => _AiAccessCardState();
}

class _AiAccessCardState extends State<AiAccessCard> {
  /// 刚生成的密钥（**仅内存**）。用户点「我已保存」或退出登录后清空。
  ApiKeyCreated? _created;

  List<ApiKeySummary> _keys = const <ApiKeySummary>[];

  bool _loading = false;
  bool _busy = false;
  String? _error;
  String? _notice;

  /// 生成对话框里的名称输入框（默认值给最常见的接入方，减少一次输入）。
  final TextEditingController _nameController =
      TextEditingController(text: 'AstrBot');

  @override
  void initState() {
    super.initState();
    if (widget.isSignedIn) {
      unawaited(_loadKeys());
    }
  }

  @override
  void didUpdateWidget(covariant AiAccessCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSignedIn == oldWidget.isSignedIn) return;
    if (widget.isSignedIn) {
      unawaited(_loadKeys());
    } else {
      // 退出登录：明文密钥与列表都必须清掉。
      // 这里不调 setState —— 本方法本身就在一次重建过程中，直接改字段即可。
      _clearLocalState(notify: false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 清空本地状态（**不发请求**）。
  void _clearLocalState({bool notify = true}) {
    void apply() {
      _created = null;
      _keys = const <ApiKeySummary>[];
      _loading = false;
      _busy = false;
      _error = null;
      _notice = null;
    }

    if (!notify) {
      apply();
      return;
    }
    if (!mounted) return;
    setState(apply);
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  Future<void> _loadKeys() async {
    if (!widget.isSignedIn) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<ApiKeySummary> keys = await widget.api.listApiKeys();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } catch (e, st) {
      Loggers.sync.fine('拉取 API 密钥列表失败', e, st);
      if (!mounted) return;
      setState(() => _error = '拉取密钥列表失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 生成 / 复制
  // ---------------------------------------------------------------------------

  Future<void> _generate() async {
    final String? name = await _askKeyName();
    if (name == null) return;
    if (name.isEmpty) {
      setState(() => _error = '请先给密钥起个名字，方便日后识别');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final ApiKeyCreated created = await widget.api.createApiKey(name);
      if (!mounted) return;
      setState(() {
        _created = created;
        _notice = '密钥已生成。它只会显示这一次，请立即复制保存。';
      });
      // 列表里应当立刻多出这条（只带前缀）
      await _loadKeys();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } catch (e, st) {
      Loggers.sync.fine('生成 API 密钥失败', e, st);
      if (!mounted) return;
      setState(() => _error = '生成密钥失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyKey() async {
    final ApiKeyCreated? created = _created;
    if (created == null || created.key.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: created.key));
    if (!mounted) return;
    setState(() => _notice = '已复制密钥到剪贴板，请粘贴到 AI 侧的 PETLIFE_API_KEY');
  }

  void _dismissCreated() {
    setState(() {
      _created = null;
      _notice = '已收起密钥。之后无法再次查看，如需更换请重新生成。';
    });
  }

  // ---------------------------------------------------------------------------
  // 撤销
  // ---------------------------------------------------------------------------

  Future<void> _revoke(ApiKeySummary key) async {
    final bool? go = await _confirm(
      title: '撤销密钥',
      message: '撤销后，使用这把密钥的 AI / MCP 会立刻无法读取你的数据。\n\n'
          '名称：${key.name}\n前缀：${key.keyPrefix}…\n\n'
          '你可以随时生成一把新的密钥。',
      confirmText: '撤销',
    );
    if (go != true) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final ApiKeySummary result = await widget.api.revokeApiKey(key.id);
      if (!mounted) return;
      if (result.isActive) {
        // 服务端说它还有效 → 不能假装撤销成功
        setState(() => _error = '服务端未确认撤销（该密钥仍处于有效状态），请稍后重试');
        return;
      }
      // 刚生成的明文若正是这一把，也一并收起（它已经没用了）
      if (_created?.summary.id == key.id) _created = null;
      // 只有服务端确认后才刷新列表
      await _loadKeys();
      if (!mounted) return;
      setState(() => _notice = '已撤销密钥「${key.name}」');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } catch (e, st) {
      Loggers.sync.fine('撤销 API 密钥失败', e, st);
      if (!mounted) return;
      setState(() => _error = '撤销失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('AI 数据访问',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                TextButton.icon(
                  onPressed: widget.isSignedIn && !_loading && !_busy
                      ? () => unawaited(_loadKeys())
                      : null,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '生成一把只读密钥，配置给 AI 助手（如 AstrBot / MCP）后，'
              '它就能查询你的电脑使用统计。\n'
              'AI 只能读取汇总统计（时长、应用排行、分类、设备），'
              '读不到窗口标题、网页地址或任何输入内容；密钥可随时撤销。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            if (!widget.isSignedIn)
              _hint(
                icon: Icons.lock_outline,
                color: const Color(0xFF2F4A63),
                text: '登录 PetLife 账户后即可生成密钥。不登录也可以正常使用桌宠与本地统计。',
              )
            else ...<Widget>[
              if (_created != null) ...<Widget>[
                _createdKeySection(),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
              ],
              _keysSection(),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              _hint(
                icon: Icons.error_outline,
                color: const Color(0xFFB3261E),
                text: _error!,
              ),
            ] else if (_notice != null) ...<Widget>[
              const SizedBox(height: 10),
              _hint(
                icon: Icons.info_outline,
                color: const Color(0xFF2E7D32),
                text: _notice!,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- 刚生成的密钥（一次性明文） ---

  Widget _createdKeySection() {
    final ApiKeyCreated created = _created!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: Color(0xFFB26A00)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '「${created.summary.name}」的密钥只显示这一次，请立即复制保存',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFB26A00),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            created.key,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => unawaited(_copyKey()),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制密钥'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _dismissCreated,
              child: const Text('我已保存'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '把它填到 AI 侧的 PETLIFE_API_KEY 即可。关掉提示后无法再查看，'
          '丢失时只需撤销并重新生成。',
          style: TextStyle(fontSize: 11, color: Colors.black45),
        ),
      ],
    );
  }

  // --- 密钥列表 ---

  Widget _keysSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text('已有的密钥',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            if (_loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_loading && _keys.isEmpty)
          const Text('正在加载…', style: TextStyle(fontSize: 12, color: Colors.black54))
        else if (_keys.isEmpty)
          const Text('还没有生成任何密钥',
              style: TextStyle(fontSize: 12, color: Colors.black54))
        else
          for (final ApiKeySummary key in _keys) _keyRow(key),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => unawaited(_generate()),
          icon: const Icon(Icons.vpn_key, size: 16),
          label: const Text('生成密钥'),
        ),
      ],
    );
  }

  Widget _keyRow(ApiKeySummary key) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            key.isActive ? Icons.key_outlined : Icons.key_off_outlined,
            size: 16,
            color: key.isActive ? const Color(0xFF2F4A63) : Colors.grey,
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
                        key.name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        key.isActive ? '（有效）' : '（已撤销）',
                        style: TextStyle(
                          fontSize: 11,
                          color: key.isActive
                              ? const Color(0xFF2E7D32)
                              : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  '${key.keyPrefix}… · ${key.scopesLabel}'
                  ' · 创建于 ${_formatTime(key.createdAt)}'
                  ' · ${key.lastUsedAt == null ? '从未使用' : '最近使用 ${_formatTime(key.lastUsedAt)}'}'
                  '${key.revokedAt == null ? '' : ' · 撤销于 ${_formatTime(key.revokedAt)}'}',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (key.isActive)
            TextButton(
              onPressed: _busy ? null : () => unawaited(_revoke(key)),
              child: const Text('撤销', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // --- 小部件 ---

  Widget _hint({
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

  /// 询问密钥名称；取消返回 null，确认为去掉首尾空白的名称。
  Future<String?> _askKeyName() => showDialog<String>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('生成 API 密钥'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '给这把密钥起个名字，方便日后识别（例如「AstrBot」「家里的助手」）。'
                '权限固定为只读统计。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                autofocus: true,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: '名称',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, _nameController.text.trim()),
              child: const Text('生成'),
            ),
          ],
        ),
      );

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

  /// 把异常翻译成用户可读、且**不含敏感信息**的说明。
  String _describe(ApiException e) {
    final String base = '${e.kind.labelZh}：${e.message}';
    if (e.kind.needsReauth) {
      return '$base\n需要重新登录：凭据可能已失效（改过密码、退出过全部设备，'
          '或该设备已被撤销）。请在本页上方重新登录。';
    }
    return e.requestId == null ? base : '$base（request_id=${e.requestId}）';
  }

  static String _formatTime(DateTime? time) {
    if (time == null) return '—';
    final DateTime local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
