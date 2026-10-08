# 20 · Phase 2 测试与验收报告

> 结论方式：每一项都给出**实际执行过的命令与结果**，
> 并严格区分「已自动验证」「待人工验证」「因环境阻塞未验证」。
> 未验证的项目**不预先判定为通过**。
>
> 本轮（Phase 2 客户端）结束时的完整状态。

## 0. 本轮进度声明

Phase 2 分为「服务端」与「客户端」两块，**两块均已完成**：

| 块 | 状态 |
|---|---|
| 服务端（FastAPI + PostgreSQL 目标 + Alembic + Docker Compose） | ✅ 完成，100 / 100 测试通过 |
| 客户端（SQLite v3 / 令牌安全存储 / outbox / 同步引擎 / 账户与同步页面 / 代理） | ✅ 完成，Flutter 测试 234 / 234 通过（+1 跳过） |
| 客户端 ↔ 真实服务端端到端联调 | ✅ 完成，5 个阶段全部通过（真实 HTTP / 真实 JWT / 真实 Argon2 / 真实 Windows Credential Manager） |

**20 项验收标准中 19 项已自动验证通过**，仅第 19 项（Docker Compose）因本机无 Docker
而**环境阻塞未验证**。

最终复核已在沙箱外完成：修复 lint 后的真实 E2E 五阶段全部通过，
`E2E_EXIT=0`；随后基于最终代码重建 Windows Release，`BUILD_EXIT=0`。
明细见 §2.6 与 §5。

### 0.1 本轮追加：代理支持（Clash / HTTP 代理）—— 质量门已过，真实联调待做

在 Phase 2 之上追加了「正式代理支持」（Clash System Proxy / 手动 HTTP 代理）。
**实现与质量门（analyze / test / Release 构建）均已完成并实测通过**；
**真实 Clash 联调的 10 步尚未执行**，因此那一部分**不预先判定为通过**。
明细见 §11。

## 1. 本机环境与阻塞项

| 能力 | 状态 | 影响 |
|---|---|---|
| Flutter 3.47.5 / Dart 3.13.4 | ✅ 可用 | 客户端可构建、测试、跑真实联调 |
| 网络（pypi / python.org） | ✅ 可用 | 可下载运行时与依赖 |
| **Python** | ❌ 系统未安装 | **已绕过**：项目内下载官方 embeddable 包（`server/.python/`，3.12.10），服务端与联调都用它 |
| **Docker / Compose** | ❌ 未安装 | `docker compose up` **无法验证**（验收项 19） |
| **PostgreSQL** | ❌ 未安装 | 真实 PG 上的迁移与运行 **无法验证**（已用离线 DDL 生成部分替代，见 §2.3） |
| Windows Credential Manager | ✅ 可用 | 真实联调中凭据后端被识别为 `Windows Credential Manager` |

## 2. 已自动验证

### 2.1 服务端测试套件

```
$ .python\python.exe -m pytest -q
........................................................................ [ 72%]
............................                                             [100%]
100 passed
```

| 文件 | 项数 | 覆盖重点 |
|---|---|---|
| `test_auth.py` | 21 | 注册 / 重复邮箱 / 大小写归一 / 登录 / 密码错误与未知邮箱同码 / 刷新轮换 / 复用检测 / 注销单个与全部 / 改密 / 删号 / 过期 Access Token / 幽灵令牌 / 弱密码 / 令牌类型混用 / 过期 Refresh Token |
| `test_sync.py` | 19 | push+pull 往返 / 重复上传不重复 / 同批次重复提交 / 每日用量重传不累加 / 快照覆盖 / LWW 双向 / 人工分类优先 / 非法 UUID / 非法时间范围（单条拒绝） / device_id 不一致 / app_key 含路径被拒 / 未知字段被拒 / 超批 413 / 满批 200 / 游标单调 + limit + has_more / 按设备过滤 / 负游标 / 空批 / limit 越界 |
| `test_migrations.py` | 10 | 真实 Alembic 迁移 vs 模型声明（表/列/主键/外键/索引全比对） / 主键含 user_id / 无隐私列 / 升降级往返 / **离线生成 PG DDL 并检查 UUID & BIGSERIAL** / alembic.ini 纯 ASCII |
| `test_devices.py` | 13 | 注册幂等 / model_name 不被客户端覆盖 / 列表 is_current / 改名 / **撤销后同步被拒 + 令牌失效** / 重复撤销幂等 / **撤销释放 device_local_id 可重绑** / 缺设备头 / 非法设备头 / 非法平台 / last_seen 更新 / 完整登录绑定流程 |
| `test_logging_redaction.py` | 15 | 9 类敏感串脱敏 / 裸 JWT / 普通文本不动 / **真实登录日志不含密码与令牌** / handler 级兜底 |
| `test_stats.py` | 11 | 四个口径分离 / 今日-7天-30天聚合 / 时区窗口计算（纯函数断言） / 跨日比例拆分 / **时区改变日期归属** / 排行与占比 / 分类 / 设备合计与重叠提示 / 参数校验 / 需鉴权 |
| `test_isolation.py` | 6 | pull 不跨用户 / **重放他人记录 UUID 不改他人数据** / 统计隔离 / 不能碰他人设备 / 应用库隔离 / 同用户双设备同日分行 |
| `test_health.py` | 5 | /health 探数据库 / 统一错误体 / request_id 透传 / **校验错误不回显输入值** |

**没有只验证 Mock 返回值的空洞测试**：数据库行为全部走真实 SQLite 事务与真实 SQL；
迁移用真实 Alembic；认证用真实 Argon2id 与真实 JWT。

### 2.2 服务端真实 HTTP 端到端

```
$ .python\python.exe tools\e2e_smoke.py
=== 1. 迁移（空库 → head）===        ok
=== 2. 启动 uvicorn ===              ok  /health 返回 ok（database=True）
=== 3. 注册（带设备信息）===          ok  201 + device_id
=== 4. 登录 ===                      ok  同一 device_local_id 不产生第二台设备
=== 5. 同步上传 ===                  ok  接受 5 条 / 无拒绝 / 游标 5
=== 6. 重复提交同一批次（幂等）===    ok  仍 3 段 + 1 日用量 + 1 应用
=== 7. 服务端统计 ===                ok  活跃 4h / 空闲 1h / 会话 5h / 应用 5400s
=== 8. 账户隔离 ===                  ok  新账户拉不到别人数据
=== 9. Token 刷新与吊销 ===          ok  轮换成功 / 复用判定泄露
=== 10. 撤销设备后同步被拒 ===       ok  403 device_revoked
=== 11. 服务端日志脱敏抽查 ===       ok  无密码 / 无令牌 / 无明文 Authorization
E2E SMOKE PASSED
```

这一步是**真起了一个 uvicorn 进程、走真实 TCP 与 HTTP**。

### 2.3 PostgreSQL 方言（离线验证）

```
$ .python\python.exe -m alembic -x db_url=postgresql+psycopg2://... upgrade head --sql
CREATE TABLE users ( ... id UUID NOT NULL, PRIMARY KEY (id) );
CREATE UNIQUE INDEX ix_users_email_lower ON users (email);
CREATE TABLE sync_log ( seq BIGSERIAL NOT NULL, ... PRIMARY KEY (seq) );
CREATE TABLE activity_segments ( ... PRIMARY KEY (user_id, id) );
CREATE TABLE daily_usage ( ... PRIMARY KEY (user_id, device_id, local_day) );
```

证明 UUID 映射为原生 `UUID`、自增游标映射为 `BIGSERIAL`、复合主键正确。

### 2.4 客户端静态检查与构建

```
$ flutter analyze --no-pub
Analyzing petlife...
No issues found! (ran in 4.6s)
ANALYZE_EXIT=0

$ flutter build windows --release --no-pub
Building Windows application...                                     9.5s
√ Built build\windows\x64\runner\Release\petlife.exe
BUILD_EXIT=0
```

> 上面是**加了代理支持之后**的最终一次复跑（analyze 4.6s / build 9.5s）。
> 更早一轮（代理之前）的对应结果是 `No issues found! (ran in 9.2s)` 与 65.7s，
> 两者一致通过。

产物：`build\windows\x64\runner\Release\`

| 文件 | 大小 | 时间戳 |
|---|---|---|
| `petlife.exe` | 92,160 B | 2026-09-27 20:05 |
| `data\app.so` | 7,881,608 B | **2026-09-28 17:48**（代理支持后的构建） |
| `sqlite3.dll` | 1,479,168 B | 2026-09-27 20:05 |
| `flutter_windows.dll` | 21,274,112 B | 2026-09-18 |

> `petlife.exe` 是 CMake 生成的 runner 壳，源码未变时不会重新链接，因此时间戳早于本次构建是正常的；
> Dart 代码的 AOT 产物是 `data\app.so`，其时间戳随每次构建更新。

### 2.5 客户端 Flutter 测试套件

```
$ flutter test --no-pub
234 项通过
1 项跳过
TEST_EXIT=0
```

> 跳过的是 `e2e_real_server_test.dart`（未设置 `PETLIFE_E2E_STAGE` 时 `markTestSkipped`），
> 因此**默认套件不依赖外部服务端**。
> 原先"命令迟迟不返回"的原因是 PowerShell 的 `Tee-Object`/CLIXML 输出管道与退出码传递问题，
> **不是 Flutter 测试本身**；固定用法见 `06-构建运行手册与开发环境.md` §11。

| 文件 | 项数 | 类型 |
|---|---|---|
| `state_engine_test.dart` | 22 | 纯 Dart |
| `ids_test.dart` | 23 | 纯 Dart |
| `application_classifier_test.dart` | 18 | 纯 Dart |
| `activity_state_mapper_test.dart` | 20 | 纯 Dart |
| `filename_parser_test.dart` | 13 | 纯 Dart |
| `pet_animation_repaint_test.dart` | 10 | 纯 Dart |
| `settings_persistence_test.dart` | 8 | SQLite |
| `usage_analytics_test.dart` | 8 | SQLite |
| `activity_segment_service_test.dart` | 14 | SQLite |
| `activity_migration_test.dart` | 4 | SQLite |
| `asset_import_integration_test.dart` | 3 | SQLite |
| `webp_container_test.dart` | 2 | 纯 Dart |
| **`sync_migration_v3_test.dart`** | **6** | SQLite（Phase 2 新增） |
| **`sync_security_test.dart`** | **17** | SQLite + 纯 Dart（Phase 2 新增） |
| **`sync_outbox_test.dart`** | **11** | SQLite（Phase 2 新增） |
| **`sync_engine_test.dart`** | **17** | 真实本地 HTTP（Phase 2 新增） |
| `e2e_real_server_test.dart` | （默认跳过） | 见 §2.6，需环境变量驱动 |

Phase 1 结束时为 145 项；Phase 2 净增 **51** 项（6 + 17 + 11 + 17）；代理支持再净增 **38** 项
（27 + 11），合计 **234 通过 + 1 跳过**。
**原有 145 项全部继续通过**（0 失败）。

### 2.6 客户端 ↔ 真实服务端端到端联调（5 个阶段）

编排脚本：`tools/e2e_client_sync.ps1`；测试用例：`test/e2e_real_server_test.dart`。
**这不是 mock**：脚本真实启动 uvicorn、真实执行 Alembic 迁移，
客户端走真实 HTTP、真实 JWT、真实 Argon2id、真实 Windows Credential Manager。

拆分原因：需求要求覆盖「断网 → 恢复 → 补传 → 撤销」，这需要在两次客户端运行之间起停服务端，
而单个 `flutter test` 进程做不到。因此每个阶段是一次独立调用，共享同一个
`build/e2e/e2e.db`（等价于"关掉客户端再打开"）。

```
=== prepare ===
  running server migrations...
  server test db ready: ...\build\e2e\server.db
  server ready (pid=35172, db=...\build\e2e\server.db)

=== stage: online ===
  [e2e] 注册成功
  [e2e] 已登录 e2e-client@example.com，设备=c0d81459-700e-446e-b593-9c956bde2548
  [e2e] 凭据后端=Windows Credential Manager
  [e2e] 首次同步完成，待同步=0
  [e2e] 服务端统计：设备数=1，应用数=2，应用使用时间=420s
  [e2e] 重复同步后统计未变：app_active=420s
  OK
  server stopped

=== stage: offline ===
  [e2e] 离线正常：状态=等待网络，待同步=3 条，本地活动段=4 条
  OK
  server ready (pid=7852, db=...\build\e2e\server.db)

=== stage: recover ===
  [e2e] 网络恢复补传成功：3 条 → 0 条
  [e2e] 服务端统计：设备数=1，活跃=0s，应用使用=840s
  OK

=== stage: revoked ===
  [e2e] 已从另一会话撤销设备 c0d81459-700e-446e-b593-9c956bde2548
  [e2e] 设备撤销后：状态=需要重新登录，本地活动段=5 条（采集未停止），待同步=2 条
  OK

=== stage: signout ===
  [e2e] 重新登录以验证退出登录流程
  [e2e] 退出登录完成：凭据已删除，本地活动段=6 条，待同步=3 条仍保留
  OK

=== ALL STAGES PASSED ===
server log: ...\build\e2e\uvicorn.log
stage output: ...\build\e2e\stage_*.txt
```

**数字自洽性**（这是"没有重复统计"的硬证据）：

| 阶段 | 服务端应用使用时间 | 说明 |
|---|---|---|
| `online` | **420s** | = 300 + 120，本地两条应用活动段之和 |
| `online`（重复同步后） | **420s** | 完全不变 → 重复上传幂等 |
| `recover` | **840s** | = 420 + 240 + 180，断网期间新增的两条被补传 |

联调过程中**真实发现并修复了一个 bug**：`application` 类型的 payload 被多塞了一个
`device_id`，而服务端 `AppRecordIn` 是 `extra="forbid"`，导致整条 422 被拒。
修复为「只有活动段与每日用量带 `device_id`」。
另一个发现：服务端 `ActivitySegmentIn.id` 是 `uuid.UUID`，
测试最初用 `e2e-segment-1` 这类字符串会被 422（已改为生成合法 UUID）。

> **最终复跑状态**：修复两处字符串插值 lint 后，已在沙箱外重新执行完整五阶段联调。
> `online` / `offline` / `recover` / `revoked` / `signout` 全部显示 `OK`，
> 最终输出 `ALL STAGES PASSED`，`E2E_EXIT=0`。应用使用时间从 420 秒恢复补传到 840 秒，
> 重复同步未重复累计。

## 3. 待人工验证 / 因环境阻塞未验证

| 项 | 状态 | 原因与替代验证 |
|---|---|---|
| 真实 PostgreSQL 上执行迁移并运行 | ⏳ **因环境阻塞未验证** | 本机无 PostgreSQL 且无 Docker。已用离线 DDL 生成验证方言（§2.3） |
| `docker compose up` 从空库启动并自动迁移 | ⏳ **因环境阻塞未验证** | 本机无 Docker。已用 PyYAML 解析确认 3 个 service、命名卷、`depends_on` 关系正确 |
| HTTPS / 反向代理实际生效 | ⏳ 待人工 | 需要真实域名与证书 |
| 生产限流、备份、密钥轮换实际演练 | ⏳ 待人工 | 需要真实环境 |
| **真实 GUI 人工验收**（账户页面的可视与交互） | ⏳ 待人工 | 自动化测试覆盖了页面状态与逻辑，但**像素级布局、DPI 缩放、多屏**仍需人眼确认 |
| **DPAPI 文件后端的真实路径验证** | ⏳ 待人工 | 本机 Credential Manager 可用，因此走的是首选后端；DPAPI 回退路径由单元测试覆盖（用内存实现），**未在真实 Windows 上强制降级验证** |
| **多设备（两台真实机器）同日数据分行** | ⏳ 待人工 | 服务端侧由 `test_isolation.py` 覆盖；真实第二台机器未接入 |
| **修复 lint 后的 E2E 复跑** | ✅ 已完成 | 五阶段全部通过，`ALL STAGES PASSED`，`E2E_EXIT=0` |
| **基于最终代码重建 Release** | ✅ 已完成 | `√ Built build\windows\x64\runner\Release\petlife.exe`，`BUILD_EXIT=0` |
| 受限沙箱下运行 `flutter analyze` / `flutter test` | ⚠️ 环境限制 | 沙箱禁止写 `C:\src\flutter\bin\cache\engine.stamp`，Flutter 包装脚本会报 `Unable to determine engine version...`。需在沙箱外运行，或把该路径加入沙箱白名单 |

## 4. 交付物清单

### 4.1 本轮新增（客户端，24 个文件）

```
lib/sync/models/sync_models.dart
lib/sync/api_client.dart
lib/sync/authenticated_api.dart
lib/sync/credential_store.dart
lib/sync/credential_store_factory.dart
lib/sync/dpapi_file_credential_store.dart
lib/sync/win32_credential_native.dart
lib/sync/device_identity.dart
lib/sync/outbox_producer.dart
lib/sync/outbox_change_sink.dart
lib/sync/sync_engine.dart
lib/sync/sync_preferences.dart
lib/database/dao/account_session_dao.dart
lib/database/dao/sync_state_dao.dart
lib/database/dao/sync_outbox_dao.dart
lib/activity_tracking/local_change_sink.dart
lib/ui/pages/account_sync_page.dart
test/sync_migration_v3_test.dart
test/sync_security_test.dart
test/sync_outbox_test.dart
test/sync_engine_test.dart
test/e2e_real_server_test.dart
test/support/fake_petlife_server.dart
tools/e2e_client_sync.ps1
```

### 4.2 本轮修改（客户端，9 个文件）

| 文件 | 改动 |
|---|---|
| `lib/database/schema.dart` | 新增 `v3Statements`（3 表 + 3 索引）、`createStatements` 与 `migrations` 增加 v3 |
| `lib/core/constants.dart` | `databaseSchemaVersion` → `3`；新增 `appVersion = '0.2.0'`；新增 `SyncConfig` |
| `lib/core/logger.dart` | **修复真实安全缺陷**：`format()` 原先未调用 `redact()`，导致所有日志出口都是明文；新增 `Loggers.sync` / `Loggers.credential` |
| `lib/core/paths.dart` | 新增 `credentialsDir`（不主动创建，仅 DPAPI 回退时使用） |
| `lib/activity_tracking/activity_segment_service.dart` | 新增 `changeSink` 参数与 `_notifySegment` / `_notifyDaily`；**本地写入成功后才入队** |
| `lib/activity_tracking/application_repository.dart` | 新增 `changeSink` 参数（默认 `NoopLocalChangeSink`） |
| `lib/app/app_scope.dart` | 装配 outbox DAO / producer / sink / SyncEngine；`dispose()` 顺序；诊断字段 +11 项 |
| `lib/ui/control_panel.dart` | 页签 6 → 7，新增「账户与同步」（`accountSyncTabIndex = 4`） |
| `test/activity_migration_test.dart` | 3 处硬编码 `user_version == 2` 改为引用 `AppConstants.databaseSchemaVersion` |

### 4.3 上一轮（服务端，35 个文件 + 6 份文档）

见本文件历史版本；服务端目录 `server/` 在本轮**零改动**（按用户要求未重构、未重新实现）。

### 4.4 本轮修改的文档

```
docs/05-数据库设计与迁移.md      （v3 从「尚未实施」改为已实施；新增 §2.2 / 重写 §8）
docs/06-构建运行手册与开发环境.md （测试构成与实际项数；新增客户端联调 / 代理章节）
docs/15-Phase2总体架构.md        （§5 客户端进度改为已完成；新增两个 device 标识的区分）
docs/18-数据同步协议.md          （§5 客户端 outbox 改为已实施；新增 §8 同步引擎 / §9 真实联调实测）
docs/19-隐私与安全说明.md        （§7 令牌本地保存改为实际实现；新增 §7.3 清理时机 / §7.4 日志脱敏）
docs/20-Phase2测试与验收报告.md  （本文件，按 20 项标准重写最终状态）
```

## 5. Phase 2 验收标准对照（20 项）

图例：✅ 已自动验证 · 🧑 待人工验证 · 🚫 因环境阻塞未验证

| # | 验收项 | 状态 | 证据 |
|---|---|---|---|
| 1 | 无网络时桌宠和本地活动采集正常 | ✅ | `sync_engine_test.dart`（服务端不可达用例）；真实联调 `offline` 阶段：状态=等待网络，待同步 3 条，**本地活动段仍增长到 4 条** |
| 2 | 用户可以注册、登录和退出 | ✅ | 服务端 `test_auth.py`（21 项）+ e2e 步骤 3/4/9；客户端 `sync_engine_test.dart` 登录/退出用例 + 真实联调 `online`/`signout` 阶段 |
| 3 | 登录后设备能够稳定绑定 | ✅ | 服务端 `test_devices.py`（13 项）；客户端 `device_local_id` 重启不变（`sync_security_test.dart`）；真实联调 `online` 阶段产出 `device=c0d81459-...` |
| 4 | 本地历史记录可以增量上传 | ✅ | 服务端 push 往返 + 游标分页；客户端 `outbox_producer` 历史回填用例（幂等，上限 20000）；真实联调 `recover` 阶段补传 3 条 |
| 5 | 相同数据重复上传不会重复统计 | ✅ | 服务端：重复 push 3 次 / 同批次重提 2 次 / 每日用量重传 4 次；客户端：部分唯一索引 + `acknowledge` 幂等；真实联调：重复同步后 `app_active` 仍为 **420s** |
| 6 | 网络中断后恢复可以自动继续同步 | ✅ | `sync_engine_test.dart` 网络恢复用例（重置退避）；真实联调 `recover` 阶段：3 条 → 0 条 |
| 7 | Token 过期可自动刷新 | ✅ | 服务端刷新+轮换已测试；客户端 `sync_engine_test.dart`：401 → 刷新一次 → 重试一次成功 |
| 8 | Refresh Token 失效提示重新登录、本地采集不停止 | ✅ | `sync_engine_test.dart` 刷新失效/无无限循环用例；真实联调 `revoked` 阶段：状态=需要重新登录，**本地活动段仍增长到 5 条** |
| 9 | 两个账户的数据严格隔离 | ✅ | 服务端 `test_isolation.py`（6 项），含"重放他人记录 UUID"与"不能碰他人设备" |
| 10 | 被撤销设备不能继续同步 | ✅ | 服务端 `test_devices.py` + e2e 步骤 10（403 `device_revoked`）；客户端真实联调 `revoked` 阶段 |
| 11 | 服务端可查询今日 / 7 天 / 30 天 / 多设备 / 分类统计 | ✅ | `test_stats.py`（11 项）+ e2e 步骤 7；另有 `yesterday` 与 `/stats/devices` |
| 12 | 服务端不存储窗口标题、URL、完整本地路径和截图 | ✅ | 表结构无这些列（`test_migrations.py` 扫描断言）；请求模型 `extra="forbid"`；`app_key` 含路径被拒；客户端 payload 白名单（`sync_outbox_test.dart` 精确断言字段集合） |
| 13 | SQLite v2 → v3 迁移不丢失任何旧数据 | ✅ | `sync_migration_v3_test.dart`（6 项）：真实建 v2 库写入阶段 0/1 数据 → v3 打开 → 逐字段断言；含"新库直接建 v3"、"重复打开不重复迁移"、"新表可读写" |
| 14 | 原有桌宠、素材、动画、状态切换与 Phase 1 采集功能无回归 | ✅ | 原有 145 项测试**全部继续通过**，`flutter test` 总计 234 项通过 / 0 失败 |
| 15 | `flutter analyze --no-pub` 无错误 | ✅ | `Analyzing petlife... / No issues found! (ran in 9.2s)`，`EXIT=0`（见 §2.4）。修复了 `e2e_real_server_test.dart` 的 2 处字符串插值 lint |
| 16 | 全部 Flutter 测试通过 | ✅ | `flutter test --no-pub` → 234 项通过 / 1 项跳过 / `TEST_EXIT=0`（§2.5） |
| 17 | 全部服务端测试通过 | ✅ | `100 passed`（§2.1） |
| 18 | Windows Release 构建成功 | ✅ | `BUILD_EXIT=0`，`√ Built build\windows\x64\runner\Release\petlife.exe`（§2.4） |
| 19 | Docker Compose 环境可从空数据库启动并完成迁移 | 🚫 | 本机无 Docker。compose 文件已通过 YAML 解析校验；**必须在有 Docker 的机器上复跑** |
| 20 | 完成一次真实流程：离线使用 → 注册登录 → 上传 → 服务端查询 → 断网继续使用 → 恢复网络补传 | ✅ | 真实联调 5 阶段全部通过（§2.6），含额外的"撤销设备"与"退出登录"两步 |

### 5.1 结论

| 维度 | 状态 |
|---|---|
| 服务端实现 | ✅ 完成 |
| 服务端自动化测试 | ✅ 100 / 100 |
| 服务端真实 HTTP 端到端 | ✅ 通过 |
| 客户端实现 | ✅ 完成（v3 / 凭据 / outbox / 引擎 / 账户页） |
| 客户端静态检查 | ✅ 0 issue |
| 客户端自动化测试 | ✅ 234 / 234（含原有 145 项无回归，另有 1 项默认跳过） |
| Windows Release 构建 | ✅ 成功 |
| **客户端 ↔ 真实服务端联调** | ✅ 5 / 5 阶段通过 |
| 服务端上线就绪（真实 PG + Docker） | 🚫 待在有 PostgreSQL/Docker 的环境复跑 |
| 真实 GUI 人工验收 | 🧑 待人工 |
| 修复 lint 后的 E2E 复跑 | ✅ 五阶段通过，`E2E_EXIT=0` |
| 基于最终代码重建 Release | ✅ 成功，`BUILD_EXIT=0` |

**20 项验收标准：19 项 ✅ 已自动验证通过，1 项 🚫 因环境阻塞未验证（第 19 项 Docker Compose）。**
该项**不预先判定为通过**，必须在有 Docker + PostgreSQL 的机器上复跑一次（步骤见 §6.1）。
另有 §3 中列出的 GUI、DPAPI 回退与真实多设备等人工项待确认。

## 6. 仍需人工执行的步骤

### 6.1 服务端（在有 Docker 的机器上）

1. `cd server && cp .env.example .env`，用
   `python -c "import secrets;print(secrets.token_urlsafe(48))"` 生成 `PETLIFE_JWT_SECRET`，
   设置一个强 `POSTGRES_PASSWORD`。
2. `docker compose up --build` → 观察 `migrate` 容器成功退出、`api` 变 healthy。
3. `curl http://127.0.0.1:8000/health` → `{"status":"ok","database":true}`。
4. `docker compose exec db psql -U petlife -d petlife -c '\dt'` → 7 张表 + `alembic_version`。
5. 故意用错误密码启动一次，确认 compose **拒绝启动**（默认弱口令防线）。
6. `docker compose down` 后再 `up`，确认数据仍在（命名卷持久化）。
7. 配置 Caddy/Nginx HTTPS 反代，用 `curl https://<域名>/health` 验证。

### 6.2 客户端 GUI 人工验收

1. 打开「账户与同步」页（控制面板第 5 个页签），确认未登录态：服务端地址 / 邮箱 / 密码 /
   登录 / 注册 / "不登录也可正常使用桌宠和本地统计"说明都在；**密码框不回显**。
2. 填服务端地址 → 注册 → 登录 → 确认设备出现在服务端 `GET /devices`。
3. 使用若干分钟后点「立即同步」，确认页面显示同步状态、上次同步时间、待同步数量，
   并在服务端 `GET /sync/pull` 与 `/stats/*` 确认数字与本地一致。
4. 制造一次网络错误（填一个不可达地址），确认**不连续弹窗**，且错误只显示在页面内。
5. 关闭控制面板，确认同步仍在后台运行（改「每 5 分钟」定时器可观察）。
6. 断网继续使用（活动采集必须不受影响）；恢复网络后确认自动补传。
7. 在服务端 `DELETE /devices/{id}` 撤销该设备，确认客户端提示重新登录、
   停止上传，且**本地采集仍在继续**。
8. 在服务端改密码（或手工失效 Refresh Token），确认客户端进入「需要重新登录」而不是崩溃。
9. 点「退出登录」，确认凭据已删除（可用 `cmdkey /list` 观察 `PetLife:account` 消失），
   本地使用记录与素材**保留**。
10. 手工构造一个 v2 数据库文件放进 `<AppData>/PetLife/`，启动客户端，
    确认升级到 v3 后素材、设置、Phase 1 使用记录全部保留。

### 6.3 强制 DPAPI 回退路径（可选）

本机 Credential Manager 可用，因此真实运行走的是首选后端。
若要验证回退路径，可在测试环境临时让 `CredWriteW` 失败（或直接运行
`dpapi_file_credential_store.dart` 的针对性测试），确认密文落在
`<AppData>/PetLife/credentials/` 且**只能被同一个 Windows 用户**解开。

### 6.4 复跑真实 E2E（校验项 20 的最终确认）

必须在**能自由写 `C:\src\flutter\bin\cache\`** 的终端里执行（沙箱会挡住 Flutter 包装脚本）：

```powershell
cd C:\Users\Administrator\WorkBuddy\DesktopPet\petlife
$env:PUB_CACHE='C:\src\pub-cache'
$env:NO_PROXY='localhost,127.0.0.1,::1'
powershell -ExecutionPolicy Bypass -NoProfile -File tools\e2e_client_sync.ps1
Write-Output "E2E_EXIT=$LASTEXITCODE"
```

期望输出：`=== ALL STAGES PASSED ===`，且 5 个阶段都打印 `OK`
（`online` 应用使用 420s → 重复同步后仍 420s → `recover` 变 840s）。

脚本会把每个阶段的完整输出写到 `build\e2e\stage_<stage>.txt`，
服务端日志在 `build\e2e\uvicorn.log`。

### 6.5 基于最终代码重建 Release

```powershell
cd C:\Users\Administrator\WorkBuddy\DesktopPet\petlife
$env:NO_PROXY='localhost,127.0.0.1,::1'
flutter build windows --release --no-pub
Write-Output "BUILD_EXIT=$LASTEXITCODE"
```

产物：`build\windows\x64\runner\Release\petlife.exe`
（Dart AOT 代码在 `build\windows\x64\runner\Release\data\app.so`，
看这个文件的时间戳才能确认构建是新的）。

自 2026-09-28 14:32 那次成功构建以来，只改动了
`test/e2e_real_server_test.dart`（测试文件，不参与 Release 构建）、
`tools/e2e_client_sync.ps1`（脚本）与 `docs/*`，
**发布二进制逻辑上未变**；但按"用最终代码构建一次"的要求，仍需复跑确认。

## 11. 本轮追加：代理支持（Clash / HTTP 代理）

> ⚠️ **状态：实现完成，验证未执行。** 本节所有"待记录 / 未验证"都必须由
> 真实运行结果补上，**不得依据代码存在就判定通过**。

### 11.1 实现内容

| 交付项 | 实现落点 |
|---|---|
| `ProxyMode`（automatic / system / manualHttp / direct） | `lib/sync/proxy/proxy_models.dart` |
| `ProxySettings`（host/port/username/passwordCredentialReference/bypassLocalhost） | 同上；**模型里没有密码字段** |
| 配置持久化 | `SyncPreferences.proxySettings()` / `setProxySettings()` → `local_settings` 的 `sync.proxy*` 键 |
| 代理密码 | `CredentialStore`，条目名 `PetLife:proxy` |
| Windows 系统代理检测 | `lib/sync/proxy/win32_system_proxy.dart`：WinHTTP `WinHttpGetIEProxyConfigForCurrentUser`（+ `GlobalFree`）→ 注册表回退（`RegGetValueW` 读 `ProxyEnable`/`ProxyServer`/`ProxyOverride`/`AutoConfigURL`） |
| `ProxyServer` 解析 | 支持 `127.0.0.1:7877` 与 `http=...;https=...`；SOCKS 条目会被识别但**不选用**并给出说明 |
| 决策与 `findProxy` | `lib/sync/proxy/proxy_resolver.dart` → `'DIRECT'` / `'PROXY host:port'`；`bypassLocalhost` 对应 `<local>` 语义 |
| 统一出口 + 重建连接池 | `ApiClient` 接收 `ProxyResolver`；`AuthenticatedApi.applyProxySettings()` / `reconfigureNetwork()`；`networkGeneration` 作为可断言信号 |
| 分阶段探测 | `lib/sync/proxy/proxy_probe.dart`：TCP → CONNECT（裸 socket，可读 407）→ TLS（交回 `HttpClient`，证书校验不绕过）→ `/health` |
| UI | 「账户与同步」→「网络连接」卡片：模式、手动字段、绕过本地、四个按钮、分阶段结果、Clash 说明 |
| 新增失败分级 | `proxyUnreachable` / `proxyAuthRequired` / `tlsHandshakeFailed`（`sync_models.dart`） |
| 日志脱敏 | `Proxy-Authorization` / `proxy_password` 纳入 `AppLog.redact()` |

**明确不做**（已写在界面与文档里，不是遗漏）：

- **PAC / WPAD 不支持**：检测到就明确提示并退回直连；
- **SOCKS 端口不能当 HTTP 代理用**：引导用户改用 Clash Mixed Port；
- **不通过代理绕过 TLS**：全仓库没有一处 `badCertificateCallback` 赋值。

### 11.2 新增/修改的文件

新增：

```
lib/sync/proxy/proxy_models.dart
lib/sync/proxy/proxy_resolver.dart
lib/sync/proxy/proxy_controller.dart
lib/sync/proxy/proxy_probe.dart
lib/sync/proxy/proxy_http_client.dart
lib/sync/proxy/win32_system_proxy.dart
test/support/fake_http_proxy.dart
test/proxy_settings_test.dart
test/proxy_client_test.dart
```

修改：`api_client.dart`、`authenticated_api.dart`、`sync_preferences.dart`、
`models/sync_models.dart`、`app/app_scope.dart`、`ui/pages/account_sync_page.dart`、
`core/constants.dart`、`core/logger.dart`、`test/support/fake_petlife_server.dart`（新增 `/health`）。

### 11.3 测试覆盖（**实测全部通过**）

`test/proxy_settings_test.dart`（纯逻辑，无需网络）：

- direct 返回 `DIRECT`；manualHttp 返回 `PROXY host:port`；
- 解析 `127.0.0.1:7877`、`http=...;https=...`、带 scheme 的写法、IPv6、非法输入；
- SOCKS-only 给出明确说明；
- automatic 检测不到代理 → 回退直连（不算错误）；system 检测不到 → **明确报错**；
- PAC / WPAD 明确标记为不支持；
- localhost 与单标签主机名按 `bypassLocalhost` 绕过；
- 配置持久化往返（含"移除用户名"不残留）；
- 代理密码不落 SQLite（扫描 db 文件字节）；
- `Proxy-Authorization` / `proxy_password` 日志脱敏。

`test/proxy_client_test.dart`（真实本地假代理 + 假服务端）：

- 注册/登录/刷新/设备/同步/统计/注销 **9 个请求全部经同一个代理**（并断言服务端确实收到，排除"代理自造响应"）；
- 代理连接被拒绝 → `proxyUnreachable`；
- `badCertificateCallback` 始终为 `null`（含重建后）；
- 代理配置变化 → `networkGeneration` +1（旧 HttpClient 被关闭重建）且决策改变、配置落库；
- `ProxyProbe`：TCP+CONNECT 成功、CONNECT 407、带凭据后成功、隧道断开→`tlsHandshakeFailed`、
  `/health` 全绿、`/health` 非 200、直连模式不经代理。

### 11.4 质量门（**已执行**）

| 项 | 结果 |
|---|---|
| `flutter analyze --no-pub` | ✅ `Analyzing petlife... / No issues found! (ran in 4.6s)`，`ANALYZE_EXIT=0` |
| `flutter test --no-pub` | ✅ `234 项通过 + 1 项跳过`，`TEST_EXIT=0`（代理新增 **38** 项：`proxy_settings_test.dart` 27 + `proxy_client_test.dart` 11） |
| `flutter build windows --release --no-pub` | ✅ `√ Built build\windows\x64\runner\Release\petlife.exe`，`BUILD_EXIT=0`；`data\app.so` 7,881,608 B，时间戳 2026-09-28 17:48 |

沙箱白名单已放行 `C:\src\flutter\**` 与 `%LOCALAPPDATA%\.dartServer\**`，
因此以上三条都在本机直接跑通。

#### 11.4.1 质量门暴露并修掉的两类真实问题

**（一）`ApiClient` 的请求体用 chunked 编码**

原先写请求体是 `request.write(jsonEncode(body))`，**没有设 `Content-Length`**，
Dart 会退化成 `Transfer-Encoding: chunked`。真实 uvicorn 能处理，
但任何按定长解析的中间件/替身都会读到 `1D\r\n{...}` 这种 chunk 头 ——
这在假代理上直接表现为服务端返回 `500 FormatException: Unexpected character at character 2`。
现在改成显式定长：

```dart
final List<int> payload = utf8.encode(jsonEncode(body));
request.headers.contentType = ContentType.json;
request.contentLength = payload.length;
request.add(payload);
```

**（二）测试替身对 chunked 的处理**

`FakeHttpProxy` 只实现"带 `Content-Length` 的定长请求体"。
遇到 chunked 请求时**明确回 501**（并计入 `chunkedRequests`），
而不是把 chunk 头当 body 原样转发 —— 后者只会让下游抛一个莫名其妙的 JSON 解析错误。

另外修掉的编译期/静态问题：`proxy_controller.dart` 的 `credential_store.dart` 相对路径写错、
`EdgeInsets.zero` 误加 `const`、`SocketException.message` 非空导致的 dead null-aware、
`e2e` 用例里未使用的 `_originForm`。

### 11.5 真实 Clash 联调（部分执行，被服务端不可达阻塞）

#### 11.5.1 已实测的环境事实（本机当前状态）

```
HKCU\...\Internet Settings
  ProxyEnable   = 1
  ProxyServer   = 127.0.0.1:7877          ← 与需求给的 Clash Mixed Port 一致
  ProxyOverride = *zhihu.com;...;localhost;*.local;127.*;172.16.*;...;192.168.*
  AutoConfigURL = （空 → 没有 PAC）
127.0.0.1:7877 可连 = True                 → Clash 正在运行
```

结论：本机满足 `automatic` 模式的使用前提 —— 客户端启动后会把这台机器的
`127.0.0.1:7877` 识别为系统代理（`ProxyOverride` 里没有 `<local>`，
但客户端自身的默认 `bypassLocalhost=true` 已经把回环排除，与 `127.*` 的语义一致）。

#### 11.5.2 用真实 CONNECT 路径做的链路验证

用 PowerShell 复现了客户端 `ProxyProbe` 的同一路径
（TCP → `CONNECT` → TLS，**证书校验保持开启**）：

| 探测 | 结果 |
|---|---|
| TCP → `127.0.0.1:7877` | ✅ 通 |
| `CONNECT petlife.akechi.asia:443` | ✅ `HTTP/1.1 200 Connection established` |
| TLS（经代理）→ `www.baidu.com:443` | ✅ 握手成功 → **Clash + CONNECT + TLS 这条链是好的** |
| TLS（经代理）→ `petlife.akechi.asia:443` | ❌ 对端在握手阶段关闭连接 |
| TLS（**直连**）→ `petlife.akechi.asia:443` | ❌ 同样失败（"forcibly closed by the remote host"） |
| DNS | `petlife.akechi.asia` → `8.163.22.28` |

**直连与经代理同样失败 → 与代理无关**：`8.163.22.28:443` 当前没有可用的 TLS 服务
（域名解析指向的地址不对，或安全组未放行 443，或服务未启动）。

#### 11.5.3 10 步验收的执行情况

| # | 步骤 | 结果 |
|---|---|---|
| 1 | Clash 开启 System Proxy、关闭 TUN | ✅ 已确认开启（`ProxyEnable=1`） |
| 2 | PetLife automatic 检测到 `127.0.0.1:7877` | ✅ 环境前提已确认；**应用内按钮未人工点击**（该逻辑由 `proxy_settings_test.dart` 的 10 条解析器用例覆盖） |
| 3 | 「测试代理」成功 | 🟡 同一路径已用真实 CONNECT 验证通过（§11.5.2）；**应用内按钮未人工点击** |
| 4 | 「测试服务端」访问 `https://petlife.akechi.asia/health` | ❌ **被服务端不可达阻塞**（§11.5.2） |
| 5 | 注册与登录成功 | ❌ 同 4，未执行 |
| 6 | 立即同步成功 | ❌ 同 4，未执行 |
| 7 | 停掉 Clash → 等待网络且本地采集继续 | ⏳ 未执行 |
| 8 | 恢复 Clash → 自动补传 | ⏳ 未执行 |
| 9 | 切到 direct → 确认直连 | ⏳ 未执行 |
| 10 | 切回 system/manual → 连接池重建并恢复通信 | ⏳ 未执行 |

**先把服务端弄可达**（确认 `petlife.akechi.asia` 的 A 记录指向正确主机、443 已放行、
服务已启动），再执行 4～10；或临时把服务端地址改成本机 `server/`（见 §11.6 备注）。

**在此之前，代理支持的"真实联调"部分不算通过。**

### 11.6 复跑命令与人工联调步骤

质量门三条（现在**本机可直接跑**，沙箱已放行 `C:\src\flutter\**` 与 `%LOCALAPPDATA%\.dartServer\**`）：

```powershell
cd C:\Users\Administrator\WorkBuddy\DesktopPet\petlife
$env:PUB_CACHE='C:\src\pub-cache'
$env:NO_PROXY='localhost,127.0.0.1,::1'

flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
```

真实 Clash 联调（需要 Clash 开着并开启 System Proxy；本机已满足）：

1. 启动 `build\windows\x64\runner\Release\petlife.exe`；
2. 控制面板 →「账户与同步」→「网络连接」→ 点「检测系统代理」，
   应看到 `127.0.0.1:7877`（本机注册表实测就是这个值）；
3. 点「测试代理」→ 应显示 TCP 与 CONNECT 两阶段通过；
4. 服务端地址填 `https://petlife.akechi.asia`，点「测试服务端」→ 四阶段全绿；
5. 保存并重新连接 → 注册/登录 → 立即同步；
6. 关闭 Clash：客户端应进入「等待网络」，**本地采集继续**；
7. 重开 Clash：应自动补传（服务端统计增长，且不重复）；
8. 切「直接连接」→「当前实际使用」显示直连；再切回系统/手动 → 恢复通信。

> **备注（服务端不可达时的替代做法）**：若 `https://petlife.akechi.asia` 仍不可达，
> 可先用本机 `server/`（`http://127.0.0.1:8000`）跑完 5～10 步：
> 此时把「连接方式」设为**手动 HTTP 代理**、地址 `127.0.0.1:7877`、
> 并**取消勾选**「本地地址不走代理」——否则回环地址会被 `<local>` 规则直接绕过，
> 就验证不到"经代理访问服务端"了。这样能验证 4～6、9～10 的链路，
> 但**不能**替代对真实 `petlife.akechi.asia` 的验证。

把每一步的**实际结果**回填到 §11.5。在此之前，代理支持的"真实联调"部分**不算通过验收**。
