import 'package:flutter/material.dart';

import '../../sync/cloud_statistics_controller.dart';
import '../../sync/sync_engine.dart';

/// 「立即上传本机记录」需要的最小能力。
///
/// 抽成接口是为了让账户页的两个按钮能被独立测试，同时不与具体实现耦合。
abstract interface class UploadActionHost implements Listenable {
  /// 待上传（未确认）的记录数。
  int get pendingCount;

  /// 最近一次**上传成功**的时间。
  DateTime? get lastUploadAt;

  bool get isUploading;

  /// 立即上传本机记录（忽略退避）。
  Future<void> uploadNow();
}

/// 「刷新云端统计」需要的最小能力。
abstract interface class CloudRefreshHost implements Listenable {
  /// 最近一次成功刷新云端统计的时间。
  DateTime? get lastRefreshedAt;

  bool get isRefreshing;

  /// 按当前查询条件刷新云端统计（**不**操作 outbox）。
  Future<void> refreshNow();
}

/// [SyncEngine] → [UploadActionHost] 适配器（只做转发，不含业务逻辑）。
class SyncEngineUploadHost implements UploadActionHost {
  SyncEngineUploadHost(this._engine);

  final SyncEngine _engine;

  @override
  int get pendingCount => _engine.pendingCount;

  @override
  DateTime? get lastUploadAt => _engine.lastSuccessAt;

  @override
  bool get isUploading => _engine.isSyncing;

  @override
  Future<void> uploadNow() => _engine.syncNow(manual: true);

  @override
  void addListener(VoidCallback listener) => _engine.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _engine.removeListener(listener);
}

/// [CloudStatisticsController] → [CloudRefreshHost] 适配器。
class CloudControllerRefreshHost implements CloudRefreshHost {
  CloudControllerRefreshHost(this._controller);

  final CloudStatisticsController _controller;

  @override
  DateTime? get lastRefreshedAt => _controller.lastRefreshedAt;

  @override
  bool get isRefreshing =>
      _controller.status == CloudStatsStatus.refreshing ||
      _controller.status == CloudStatsStatus.loading;

  @override
  Future<void> refreshNow() => _controller.refresh(manual: true);

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);
}

/// 账户与同步页的两个**含义明确**的动作按钮。
///
/// 为什么要把「立即同步」拆开：
/// 上传（本机 → 服务器）和查询（服务器 → 本机）是两个方向、两套状态，
/// 一个含糊的「立即同步」会让用户以为"点了就会看到其他设备的数据"。
/// 现在：
/// * **立即上传本机记录**：把本机待同步队列推给服务器（调用 [SyncEngine]）；
/// * **刷新云端统计**：按当前查询条件重新读取服务器统计（**不碰 outbox**）。
class CloudSyncActionsCard extends StatelessWidget {
  const CloudSyncActionsCard({
    super.key,
    required this.upload,
    required this.cloud,
    this.deviceName,
    this.serverBaseUrl,
    this.lastError,
  });

  final UploadActionHost upload;
  final CloudRefreshHost cloud;

  /// 当前设备名（"当前设备"）。
  final String? deviceName;

  /// 服务器地址。
  final String? serverBaseUrl;

  /// 最近一次错误（上传或查询的）。
  final String? lastError;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[upload, cloud]),
          builder: (BuildContext context, Widget? _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('云端同步动作',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _infoRow('当前设备', deviceName ?? '未知'),
                _infoRow('待上传记录', '${upload.pendingCount} 条'),
                _infoRow(
                  '最近上传',
                  upload.lastUploadAt == null
                      ? '尚未上传'
                      : _formatTime(upload.lastUploadAt!),
                ),
                _infoRow(
                  '最近云端查询',
                  cloud.lastRefreshedAt == null
                      ? '尚未查询'
                      : _formatTime(cloud.lastRefreshedAt!),
                ),
                if (serverBaseUrl != null && serverBaseUrl!.isNotEmpty)
                  _infoRow('服务器地址', serverBaseUrl!),
                if (lastError != null && lastError!.isNotEmpty)
                  _infoRow('最近错误', lastError!, danger: true),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: upload.isUploading ? null : _onUpload,
                      icon: const Icon(Icons.upload, size: 18),
                      label: const Text('立即上传本机记录'),
                    ),
                    OutlinedButton.icon(
                      onPressed: cloud.isRefreshing ? null : _onRefreshCloud,
                      icon: cloud.isRefreshing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined, size: 18),
                      label: const Text('刷新云端统计'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '上传只把本机记录送到服务器；要看其他设备的数据请点「刷新云端统计」，'
                  '或到「使用统计 → 云端」查看。',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _onUpload() async {
    try {
      await upload.uploadNow();
    } catch (e, st) {
      debugPrint('上传本机记录失败: $e\n$st');
    }
  }

  Future<void> _onRefreshCloud() async {
    try {
      await cloud.refreshNow();
    } catch (e, st) {
      debugPrint('刷新云端统计失败: $e\n$st');
    }
  }

  Widget _infoRow(String label, String value, {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: danger ? const Color(0xFFB71C1C) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime at) {
    final DateTime local = at.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
