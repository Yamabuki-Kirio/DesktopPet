# 15 · Phase 2 总体架构

> 适用范围：**PetLife Phase 2**（账户 / 设备 / 服务端数据同步）。
> 客户端（Windows Flutter）部分见本文件 §5 的进度说明。

## 1. 四层架构

```
┌──────────────────────────────────────┐
│ Windows Flutter 客户端                │
│  SQLite（本地优先，v3）                │
│  活动采集 / 统计 / 桌宠渲染            │
└───────────────┬──────────────────────┘
                │ HTTPS + JSON（Bearer / Refresh）
┌───────────────▼──────────────────────┐
│ REST API（FastAPI）                   │
│  auth / devices / sync / stats        │
│  Argon2id · JWT · 统一错误体           │
└───────────────┬──────────────────────┘
                │ SQLAlchemy 2 + Alembic
┌───────────────▼──────────────────────┐
│ PostgreSQL 16（生产） / SQLite（开发） │
└──────────────────────────────────────┘
```

**核心约束**：客户端的活动采集**始终先写本地 SQLite**，网络同步只是后台任务。
任何网络异常都不能影响桌宠显示与本地计时——这条约束决定了同步必须做成
「outbox + 后台重试」而不是「实时写远端」。

## 2. 服务端模块（`server/`）

| 目录 | 职责 | 关键文件 |
|---|---|---|
| `app/core/` | 配置、统一错误体、日志脱敏、UTC 时间、自定义列类型 | `config.py` `errors.py` `logging.py` `timeutil.py` `types.py` |
| `app/database/` | 引擎、会话、声明式基类与命名约定 | `session.py` `base.py` |
| `app/models/` | ORM 模型（7 张表） | `user.py` `device.py` `refresh_token.py` `activity.py` |
| `app/schemas/` | 请求 / 响应模型（`extra="forbid"`） | `auth.py` `device.py` `sync.py` `stats.py` `common.py` |
| `app/security/` | Argon2id、JWT、鉴权依赖 | `passwords.py` `tokens.py` `deps.py` |
| `app/services/` | 业务逻辑 | `auth_service.py` `device_service.py` `sync_service.py` `stats_service.py` |
| `app/api/v1/` | 路由 | `auth.py` `devices.py` `sync.py` `stats.py` |
| `app/main.py` | 应用装配 + `/health` | |
| `migrations/` | Alembic 迁移 | `0001_initial_schema.py` `env.py` |
| `tests/` | pytest（100 项） | `test_auth.py` `test_sync.py` `test_migrations.py` … |
| `tools/` | 端到端冒烟脚本 | `e2e_smoke.py` |

## 3. 数据模型（服务端）

7 张表，全部以 UUID 为主键（没有自增业务 ID）：

| 表 | 主键 | 说明 |
|---|---|---|
| `users` | `id` | 邮箱唯一且统一小写；`status ∈ active/disabled/deleted` |
| `devices` | `id` | `UNIQUE(user_id, device_local_id)`；`revoked_at` 表示已撤销 |
| `refresh_tokens` | `id` | 只存 `sha256(token)`；带轮换链 `replaced_by_id` 与泄露标记 |
| `activity_segments` | **`(user_id, id)`** | `id` 是客户端生成的稳定 UUID |
| `daily_usage` | **`(user_id, device_id, local_day)`** | 整行快照覆盖，不累加 |
| `user_applications` | **`(user_id, app_key)`** | 只有 4 个数据字段，无路径无标题 |
| `sync_log` | `seq`（BIGSERIAL） | 为增量拉取提供**单调递增游标** |

**为什么把 `user_id` 放进主键**：这让「用户 A 重放用户 B 的记录 UUID 去覆盖对方数据」
在**结构层面**不可能发生，而不是靠业务代码里记得加 `WHERE user_id = ?`。
`test_migrations.py` 里有一条用例专门断言这个不变量。

## 4. 关键设计决策

### 决策 A：Refresh Token 用不透明随机串，不用 JWT

需求要求「注销 / 改密 / 撤销设备后旧 Refresh Token 立即失效」。
JWT 是自包含的、无法真正吊销；不透明随机串 + 服务端存哈希才能做到即时失效。

### 决策 B：游标用变更日志的自增序号，而不是时间戳

`sync_log.seq` 是单表自增主键，在 SQLite 与 PostgreSQL 上都是严格递增的
（PG 序列回滚会留空洞，但单调性不受影响）。用时间戳做游标会在并发写入、
时钟回拨时丢数据或重复。

### 决策 C：每日用量是「整行快照覆盖」

秒数累加在重试场景下必然重复计数（网络超时但服务端已写入 → 客户端重传 → 累加两次）。
改成整行覆盖后，重传同一份快照是幂等空操作——**从模型上消除**了这类 bug。

### 决策 D：`app_key` 必须先在客户端规范化，服务端再拒绝路径分隔符

需求要求「app_key 含完整路径时应先规范化或哈希，不能直接上传完整路径」。
服务端在 pydantic 校验层直接拒绝含 `\` 或 `/` 的 `app_key`，
这样即使客户端有 bug，本地路径也上不来（双重防线）。

### 决策 E：隐私靠「表结构里没有这些列」保证

`activity_segments` / `daily_usage` / `user_applications` 里**根本不存在**
窗口标题、URL、文档名、可执行文件路径、截图等列。
配合请求模型的 `extra="forbid"`，客户端就算误传这些字段也会被 422 拒绝，
而不是静默入库。`test_migrations.py::test_migrated_schema_contains_no_privacy_columns`
会扫描所有列名做断言。

### 决策 F：登录错误不区分「邮箱不存在」与「密码错误」

两者都返回 `invalid_credentials` 与**完全相同**的文案，避免被用来枚举已注册邮箱。
`test_auth.py::test_wrong_password_and_unknown_email_share_the_same_error` 断言这一点。

### 决策 G：`alembic.ini` 保持纯 ASCII

configparser 用 `encoding="locale"` 读它；在 zh-CN Windows 上 locale 是 GBK，
混入中文注释会让**所有** alembic 命令在建连之前就崩掉。
已加测试 `test_alembic_ini_is_ascii_only` 防止回归。

## 5. 客户端进度（已完成）

服务端与客户端**都已完成**，并各自通过测试与真实端到端联调
（见 `20-Phase2测试与验收报告.md`）。

客户端 Phase 2 交付内容与实现落点：

| 交付项 | 实现 | 说明 |
|---|---|---|
| SQLite v2 → v3 迁移 | `lib/database/schema.dart`（`DbSchema.v3Statements`） | 新增 `account_session_state` / `sync_state` / `sync_outbox`，**只新增不改表** |
| 稳定设备身份 | `lib/sync/device_identity.dart` | 首次生成 UUID v4 存 `local_settings['sync.deviceLocalId']`，重启不变；**无硬件指纹** |
| 令牌安全存储 | `lib/sync/credential_store.dart` + `win32_credential_native.dart` + `dpapi_file_credential_store.dart` + `credential_store_factory.dart` | Credential Manager 优先 → DPAPI（用户范围）→ 内存（仅测试） |
| API 客户端 | `lib/sync/api_client.dart` + `authenticated_api.dart` | UI 不拼 HTTP；401 刷新一次并重试一次，重试深度编译期固定 |
| Outbox | `lib/sync/outbox_producer.dart` + `lib/database/dao/sync_outbox_dao.dart` | 本地先写、稳定 UUID、每批 ≤200、服务端确认才 `acknowledged_at` |
| 同步引擎 | `lib/sync/sync_engine.dart` | 7 状态、指数退避、单任务互斥、退出前严格超时 |
| 账户与同步页面 | `lib/ui/pages/account_sync_page.dart` | 控制面板第 5 个页签（共 7 个） |
| 采集解耦 | `lib/activity_tracking/local_change_sink.dart` + `lib/sync/outbox_change_sink.dart` | 打破"采集层依赖网络层"的构造顺序环 |

前置工作（阶段 1 就已具备，因此不需要改表）：

- 客户端的 `activity_segments` / `daily_usage` / `applications` 已经使用
  **稳定 UUID / 稳定复合键**（`Ids.segment()`、`(device, day)`、`app_key`），
  与服务端的主键约定一致。
- 客户端已有 `sync_status` 列（v1 起预留）；Phase 2 改为由
  `sync_outbox.acknowledged_at` 决定同步进度（该列保留，不再作为同步依据）。

### 5.1 两个 `device` 标识不要混淆

| 标识 | 值 | 用途 |
|---|---|---|
| `AppConstants.localDeviceId` | `desktop.local`（固定字符串） | **本地库的分区键**：`activity_segments.device_local_id`、`daily_usage` 复合主键、`tracking_settings` 复合主键都用它。Phase 2 没有改这些既有键 |
| `local_settings['sync.deviceLocalId']` | 首次运行生成的 UUID v4 | **对服务端上报的 `device_local_id`**，用于 `/devices/register` 去重与设备识别 |

两者互不影响：前者决定"本地数据怎么分片"，后者决定"服务端认为这是哪台机器"。
`sync_outbox.entity_key` 里的每日用量键用的是**前者**（`desktop.local:2026-09-27`），
而 push payload 里的 `device_id` 用的是**服务端返回的设备 UUID**。

## 6. 与 Phase 0 / Phase 1 的边界

服务端是**纯新增**：不修改任何客户端既有代码，不读取客户端素材或日志。
Phase 0 的素材/动画/窗口与 Phase 1 的采集/统计逻辑完全不受影响。

客户端的 Phase 2 改动也遵守同一条边界：**采集路径上不引入任何网络等待**。
本地写入成功后只做一次本地 outbox 入队，网络请求全部在后台任务里异步进行。
