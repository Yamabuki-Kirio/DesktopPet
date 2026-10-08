import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../sync/models/sync_models.dart';
import '../schema.dart';

/// `account_session_state` 数据访问（单行表）。
///
/// 表里**不存令牌明文**，只存非敏感账户信息与凭据引用。
class AccountSessionDao {
  AccountSessionDao(this._db);

  final Database _db;

  Future<AccountSession?> load() async {
    final List<Map<String, Object?>> rows = await _db.query(
      DbSchema.tableAccountSession,
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AccountSession.fromMap(rows.first);
  }

  /// 覆盖写入（单行表，幂等）。
  Future<void> save(AccountSession session) async {
    await _db.insert(
      DbSchema.tableAccountSession,
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 局部更新（例如只更新设备 ID 或令牌过期时间）。
  Future<void> update({
    String? serverBaseUrl,
    String? displayName,
    String? deviceServerId,
    DateTime? accessTokenExpiresAt,
    DateTime? updatedAt,
  }) async {
    final Map<String, Object?> values = <String, Object?>{
      'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    };
    if (serverBaseUrl != null) values['server_base_url'] = serverBaseUrl;
    if (displayName != null) values['display_name'] = displayName;
    if (deviceServerId != null) values['device_server_id'] = deviceServerId;
    if (accessTokenExpiresAt != null) {
      values['access_token_expires_at'] = accessTokenExpiresAt.millisecondsSinceEpoch;
    }
    await _db.update(
      DbSchema.tableAccountSession,
      values,
      where: 'id = 1',
    );
  }

  /// 退出登录：清掉账户信息。
  ///
  /// **不动** `sync_outbox` 与任何使用记录——需求要求「退出登录只清理认证信息，
  /// 不删除本地使用记录和桌宠素材」。未确认的待同步数据留待下次登录后继续上传。
  Future<void> clear() async {
    await _db.delete(DbSchema.tableAccountSession);
  }
}
