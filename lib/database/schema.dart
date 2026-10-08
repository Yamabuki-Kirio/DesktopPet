/// SQLite 表结构定义。
///
/// 版本：
/// - v1（阶段 0）：素材 / 角色 / 作品包 / 状态映射 / 本地设置，以及预留的 activity_segments。
/// - v2（阶段 1）：应用库、活动检查点、每日用量、采集设置。
///
/// 设计原则：
/// 1. 所有业务表都带 `owner_id`，即使阶段 0 只有一个本地默认用户。
///    服务端 / 多用户接入时无需改表结构，只需换成真实 owner。
/// 2. 时间统一存毫秒时间戳（INTEGER），避免时区与格式歧义。
/// 3. 布尔存 0/1（INTEGER）。
/// 4. 素材的托管路径与用户原始路径分开存：删除素材只删托管副本。
class DbSchema {
  DbSchema._();

  static const String tablePacks = 'character_packs';
  static const String tableCharacters = 'character_models';
  static const String tableAssets = 'emotion_assets';
  static const String tableStateMappings = 'state_mappings';
  static const String tableSettings = 'local_settings';
  static const String tableActivitySegments = 'activity_segments';

  // --- v2（阶段 1）---
  static const String tableApplications = 'applications';
  static const String tableActivityCheckpoints = 'activity_checkpoints';
  static const String tableDailyUsage = 'daily_usage';
  static const String tableTrackingSettings = 'tracking_settings';

  // --- v3（Phase 2：账户与同步）---
  static const String tableAccountSession = 'account_session_state';
  static const String tableSyncState = 'sync_state';
  static const String tableSyncOutbox = 'sync_outbox';

  // --- v4（Phase 4B：云端统计缓存）---
  static const String tableCloudCache = 'cloud_statistics_cache';

  /// v1（阶段 0）建表语句。按依赖顺序执行。
  ///
  /// 公开（而不是 `_` 私有）是为了让迁移测试能够**真实重建一个 v1 老库**，
  /// 从而验证「v1 → v2 升级后阶段 0 数据不丢失」。
  static const List<String> v1Statements = <String>[
    '''
CREATE TABLE IF NOT EXISTS $tablePacks (
  id           TEXT    PRIMARY KEY,
  owner_id     TEXT    NOT NULL,
  name         TEXT    NOT NULL,
  source_type  TEXT    NOT NULL,
  source_path  TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  UNIQUE (owner_id, name)
);
''',
    '''
CREATE TABLE IF NOT EXISTS $tableCharacters (
  id               TEXT    PRIMARY KEY,
  pack_id          TEXT    NOT NULL REFERENCES $tablePacks (id) ON DELETE CASCADE,
  owner_id         TEXT    NOT NULL,
  internal_name    TEXT    NOT NULL,
  display_name     TEXT    NOT NULL,
  default_asset_id TEXT,
  enabled          INTEGER NOT NULL DEFAULT 1,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  UNIQUE (pack_id, internal_name)
);
''',
    '''
CREATE TABLE IF NOT EXISTS $tableAssets (
  id                    TEXT    PRIMARY KEY,
  character_id          TEXT    NOT NULL REFERENCES $tableCharacters (id) ON DELETE CASCADE,
  emotion_name          TEXT    NOT NULL,
  variant_name          TEXT    NOT NULL,
  file_path             TEXT    NOT NULL,
  original_file_path    TEXT,
  file_hash             TEXT    NOT NULL,
  mime_type             TEXT    NOT NULL,
  file_size             INTEGER NOT NULL,
  width                 INTEGER NOT NULL,
  height                INTEGER NOT NULL,
  frame_count           INTEGER NOT NULL DEFAULT 1,
  is_animated           INTEGER NOT NULL DEFAULT 0,
  has_alpha             INTEGER NOT NULL DEFAULT 0,
  enabled               INTEGER NOT NULL DEFAULT 1,
  validation_status     TEXT    NOT NULL DEFAULT 'unchecked',
  validation_error      TEXT,
  animation_duration_ms INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  UNIQUE (character_id, emotion_name, variant_name)
);
''',
    '''
CREATE TABLE IF NOT EXISTS $tableStateMappings (
  id           TEXT    PRIMARY KEY,
  character_id TEXT    NOT NULL REFERENCES $tableCharacters (id) ON DELETE CASCADE,
  system_state TEXT    NOT NULL,
  asset_id     TEXT,
  emotion_name TEXT,
  weight       INTEGER NOT NULL DEFAULT 1,
  priority     INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  CHECK (asset_id IS NOT NULL OR emotion_name IS NOT NULL)
);
''',
    '''
CREATE TABLE IF NOT EXISTS $tableSettings (
  owner_id   TEXT    NOT NULL,
  key        TEXT    NOT NULL,
  value      TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (owner_id, key)
);
''',
    '''
-- 后续阶段（阶段 1）使用；阶段 0 只建表不写入。
CREATE TABLE IF NOT EXISTS $tableActivitySegments (
  id             TEXT    PRIMARY KEY,
  owner_id       TEXT    NOT NULL,
  device_local_id TEXT   NOT NULL,
  app_key        TEXT    NOT NULL,
  app_name       TEXT,
  process_name   TEXT,
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  active_seconds INTEGER,
  end_reason     TEXT,
  sync_status    TEXT    NOT NULL DEFAULT 'pending',
  created_at     INTEGER NOT NULL
);
''',
    'CREATE INDEX IF NOT EXISTS idx_packs_owner ON $tablePacks (owner_id);',
    'CREATE INDEX IF NOT EXISTS idx_characters_owner ON $tableCharacters (owner_id);',
    'CREATE INDEX IF NOT EXISTS idx_characters_pack ON $tableCharacters (pack_id);',
    'CREATE INDEX IF NOT EXISTS idx_assets_character ON $tableAssets (character_id);',
    'CREATE INDEX IF NOT EXISTS idx_assets_emotion ON $tableAssets (character_id, emotion_name);',
    'CREATE INDEX IF NOT EXISTS idx_assets_hash ON $tableAssets (file_hash);',
    'CREATE INDEX IF NOT EXISTS idx_mappings_character_state ON $tableStateMappings (character_id, system_state);',
    'CREATE INDEX IF NOT EXISTS idx_activity_owner_time ON $tableActivitySegments (owner_id, started_at);',
    'CREATE INDEX IF NOT EXISTS idx_activity_sync ON $tableActivitySegments (sync_status);',
  ];

  /// v2（阶段 1）新增的表与索引。
  ///
  /// 全部使用 `IF NOT EXISTS`，因此同一份语句既能用于「新库直接建全量」，
  /// 也能用于「v1 老库升级」，且**不会删除或改写任何阶段 0 数据**。
  static const List<String> v2Statements = <String>[
    '''
-- 应用库：app_key 为稳定主键（规范化可执行文件名）。
CREATE TABLE IF NOT EXISTS $tableApplications (
  app_key         TEXT    PRIMARY KEY,
  display_name    TEXT    NOT NULL,
  process_name    TEXT,
  executable_path TEXT,
  category        TEXT    NOT NULL DEFAULT 'other',
  user_overridden INTEGER NOT NULL DEFAULT 0,
  excluded        INTEGER NOT NULL DEFAULT 0,
  first_seen_at   INTEGER NOT NULL,
  last_seen_at    INTEGER NOT NULL
);
''',
    '''
-- 活动检查点：每 30 秒保存一次，异常退出时用它补齐关闭活动段。
CREATE TABLE IF NOT EXISTS $tableActivityCheckpoints (
  segment_id     TEXT    PRIMARY KEY,
  app_key        TEXT    NOT NULL,
  wall_at        INTEGER NOT NULL,
  active_seconds INTEGER NOT NULL DEFAULT 0,
  updated_at     INTEGER NOT NULL
);
''',
    '''
-- 设备级每日用量：屏幕会话 / 活跃 / 空闲秒数（不含应用归属）。
CREATE TABLE IF NOT EXISTS $tableDailyUsage (
  owner_id        TEXT    NOT NULL,
  device_local_id TEXT    NOT NULL,
  day_key         TEXT    NOT NULL,
  session_seconds INTEGER NOT NULL DEFAULT 0,
  active_seconds  INTEGER NOT NULL DEFAULT 0,
  idle_seconds    INTEGER NOT NULL DEFAULT 0,
  first_active_at INTEGER,
  last_active_at  INTEGER,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (owner_id, device_local_id, day_key)
);
''',
    '''
-- 采集设置：键值存储，便于后续扩展而不改表结构。
CREATE TABLE IF NOT EXISTS $tableTrackingSettings (
  owner_id        TEXT    NOT NULL,
  device_local_id TEXT    NOT NULL,
  key             TEXT    NOT NULL,
  value           TEXT,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (owner_id, device_local_id, key)
);
''',
    // 统计查询走 (owner_id, started_at) 范围；这里再补一条覆盖「按应用聚合」的索引，
    // 避免每次采样或每次统计都全表扫描。
    'CREATE INDEX IF NOT EXISTS idx_activity_owner_app ON $tableActivitySegments (owner_id, app_key);',
    'CREATE INDEX IF NOT EXISTS idx_activity_owner_device ON $tableActivitySegments (owner_id, device_local_id);',
    'CREATE INDEX IF NOT EXISTS idx_applications_last_seen ON $tableApplications (last_seen_at);',
    'CREATE INDEX IF NOT EXISTS idx_daily_usage_day ON $tableDailyUsage (owner_id, day_key);',
  ];

  /// v3（Phase 2）新增的表与索引：账户会话 / 同步状态 / 待同步队列。
  ///
  /// **只新增，不改动任何既有表**，因此 v1/v2 的素材、设置与使用记录逐字段不变。
  ///
  /// 安全约定（见 `docs/19-隐私与安全说明.md`）：
  /// - 本库中**没有**密码列，也**没有** Access Token / Refresh Token 列；
  /// - 令牌只保存在 Windows 凭据存储里，这里仅留一个 `credential_reference`
  ///   （凭据条目的名字，不含凭据内容）。
  static const List<String> v3Statements = <String>[
    '''
-- 账户会话：只存非敏感账户信息 + 安全凭据引用。
-- 命名为 account_session_state 而不是 account_session，避免与 SQLite 关键字
-- 或未来可能的同名实体混淆；单行表（id 固定为 1）。
CREATE TABLE IF NOT EXISTS $tableAccountSession (
  id                    INTEGER PRIMARY KEY CHECK (id = 1),
  server_base_url       TEXT    NOT NULL,
  user_id               TEXT    NOT NULL,
  email                 TEXT    NOT NULL,
  display_name          TEXT,
  device_server_id      TEXT,
  credential_reference  TEXT    NOT NULL,
  access_token_expires_at INTEGER,
  updated_at            INTEGER NOT NULL
);
''',
    '''
-- 同步状态：每类实体的游标与退避状态。
CREATE TABLE IF NOT EXISTS $tableSyncState (
  entity_type          TEXT    PRIMARY KEY,
  cursor               INTEGER NOT NULL DEFAULT 0,
  last_success_at      INTEGER,
  last_error           TEXT,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  next_retry_at        INTEGER,
  updated_at           INTEGER NOT NULL
);
''',
    '''
-- 待同步队列（outbox）：本地先写，后台再传。
--
-- id 是稳定 UUID（不是 SQLite 自增 ID）：远程身份必须与本地存储实现无关。
-- entity_key 是「同一份远端记录」的稳定业务键，用于**去重排队**：
--   activity_segment -> <记录 UUID>
--   daily_usage      -> <device_local_id>:<YYYY-MM-DD>
--   application      -> <app_key>
-- 同一 entity_key 只保留一行未确认记录（payload 用最新快照覆盖），
-- 因此重复排队是幂等的。
CREATE TABLE IF NOT EXISTS $tableSyncOutbox (
  id               TEXT    PRIMARY KEY,
  entity_type      TEXT    NOT NULL,
  entity_key       TEXT    NOT NULL,
  entity_local_id  TEXT,
  operation        TEXT    NOT NULL DEFAULT 'upsert',
  payload_json     TEXT    NOT NULL,
  created_at       INTEGER NOT NULL,
  attempt_count    INTEGER NOT NULL DEFAULT 0,
  next_attempt_at  INTEGER NOT NULL DEFAULT 0,
  last_error       TEXT,
  acknowledged_at  INTEGER
);
''',
    // 待同步查询：主路径是「取未确认且已到重试时间的记录，按时间升序」。
    'CREATE INDEX IF NOT EXISTS idx_sync_outbox_pending '
        'ON $tableSyncOutbox (acknowledged_at, next_attempt_at, created_at);',
    // 去重排队：同一实体键只允许一条未确认记录。
    'CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_outbox_pending_entity '
        'ON $tableSyncOutbox (entity_type, entity_key) WHERE acknowledged_at IS NULL;',
    'CREATE INDEX IF NOT EXISTS idx_sync_outbox_entity ON $tableSyncOutbox (entity_type, entity_key);',
  ];

  /// v4（Phase 4B）新增：**云端统计缓存表**。
  ///
  /// 为什么必须是独立的一张表（而不是复用采集表 / 设置表）：
  /// * 云端数据（来自服务器）与本机采集数据语义完全不同 ——
  ///   混进 `activity_segments` / `daily_usage` 会造成**重复累计**；
  /// * 缓存必须能按账户整表清理（退出登录时），而本机采集数据不能跟着被删；
  /// * 缓存数据**永远不参与同步**：它既不进 `sync_outbox`，也不被 outbox 读取。
  ///
  /// 主键 `(account_user_id, cache_key)` 让"同一查询重复写入"是覆盖而不是新增；
  /// `cache_key` 由 device / date / timezone / query_type / app_id 组成（见 [CloudCacheKey]）。
  static const List<String> v4Statements = <String>[
    '''
-- 云端统计缓存：只读缓存，绝不参与同步。
CREATE TABLE IF NOT EXISTS $tableCloudCache (
  account_user_id TEXT    NOT NULL,
  cache_key       TEXT    NOT NULL,
  query_type      TEXT    NOT NULL,
  device_key      TEXT    NOT NULL,
  day_key         TEXT    NOT NULL,
  timezone        TEXT    NOT NULL,
  app_id          TEXT,
  payload_json    TEXT    NOT NULL,
  fetched_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (account_user_id, cache_key)
);
''',
    'CREATE INDEX IF NOT EXISTS idx_cloud_cache_account_type '
        'ON $tableCloudCache (account_user_id, query_type);',
    'CREATE INDEX IF NOT EXISTS idx_cloud_cache_account_fetched '
        'ON $tableCloudCache (account_user_id, fetched_at);',
  ];

  /// v5（Phase 4C-6A.1）新增：素材**收藏**标记。
  ///
  /// 为什么需要它：状态映射编辑器要能"把某张图钉在回退链更靠前的位置"
  /// （需求 §5.2 / §5.4 / §9），而项目此前**完全没有收藏概念**。
  /// 这里只加**一列**（默认 0），因此：
  /// * 没有任何收藏时，回退链的行为与升级前**完全一致**；
  /// * 不新增表、不改动既有列，老库升级不丢任何数据。
  ///
  /// ⚠️ 刻意**不**把该列写进 [v1Statements]：v1 的建表语句同时被"迁移测试
  /// 重建一个真正的 v1 老库"使用，改了它会让 v1→v5 的升级路径不再是真实路径
  /// （而且重复 ALTER 会报 duplicate column）。
  static const List<String> v5Statements = <String>[
    'ALTER TABLE $tableAssets ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;',
    'CREATE INDEX IF NOT EXISTS idx_assets_favorite ON $tableAssets (character_id, favorite);',
  ];

  /// 全量建表语句（新库创建时执行）。
  static const List<String> createStatements = <String>[
    ...v1Statements,
    ...v2Statements,
    ...v3Statements,
    ...v4Statements,
    ...v5Statements,
  ];

  /// 迁移脚本：版本号 -> 语句列表。
  ///
  /// 后续阶段新增表/字段时，在这里追加 `6: [...]`，并在 [AppConstants] 中提升版本号。
  static const Map<int, List<String>> migrations = <int, List<String>>{
    2: v2Statements,
    3: v3Statements,
    4: v4Statements,
    5: v5Statements,
  };

  /// 供文档使用：表名 -> 中文说明。
  static const Map<String, String> tableDescriptions = <String, String>{
    tablePacks: '作品包（一个素材来源，例如 Ace Attorney 文件夹）',
    tableCharacters: '角色（归属作品包，例如 Maya）',
    tableAssets: '素材项（静态或动态图片，统一管理）',
    tableStateMappings: '系统状态 -> 情绪/图片 的映射与权重',
    tableSettings: '本地配置键值对（按 owner 隔离）',
    tableActivitySegments: '使用时长分段（阶段 1 启用；连续使用同一应用合并为一段）',
    tableApplications: '应用库（app_key = 规范化可执行文件名，含分类与排除标记）',
    tableActivityCheckpoints: '活动段检查点（每 30 秒一次，用于异常退出恢复）',
    tableDailyUsage: '设备级每日用量（屏幕会话 / 活跃 / 空闲秒数）',
    tableTrackingSettings: '采集设置键值对（暂停、空闲阈值、提醒开关）',
    tableAccountSession: '账户会话（非敏感账户信息 + 凭据引用；不含任何令牌明文）',
    tableSyncState: '同步状态（游标与指数退避状态，按实体类型分行）',
    tableSyncOutbox: '待同步队列（本地先写、后台再传；稳定 UUID 作为远程身份）',
    tableCloudCache: '云端统计缓存（只读缓存，按账户隔离，绝不参与同步）',
  };
}
