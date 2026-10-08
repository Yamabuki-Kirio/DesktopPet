# 34 - Phase 4B 跨设备云端使用统计（服务端）

> 范围：**Phase 4B 服务端 + 客户端界面**（会话存储复用、统计查询接口、MCP 工具、
> Flutter 云端统计页与账户页动作按钮、构建产物与本地 E2E）。
> 第 1 ~ 7 章是服务端；第 8 章起是客户端与交付结果。

## 1. 审计结论：现有实现已经具备什么

Phase 4B 的目标是"Windows 上传使用记录，Android 读云端数据"。
审计后确认：**上传链路原本就已在传原始逐条会话，不需要第二套同步体系**。

| 需求 | 现状 | 结论 |
|---|---|---|
| 本地记录开始/结束/时长/应用/设备 | 客户端 `activity_segments` 有 `id`（稳定 uuid v5）、`started_at`、`ended_at`、`active_seconds`、`app_key`、`app_name`、`device_local_id` | ✅ 已具备 |
| outbox 上传什么 | `entity_type=activity_segment`，`entity_key` = 段 UUID，payload 含起止时间与活跃秒数 | ✅ 已在传原始会话，不是只传日汇总 |
| 服务端存了什么 | `activity_segments`（复合主键 `(user_id, id)`、`device_id`、`app_key`、`category`、`started_at`、`ended_at`、`active_seconds`、`change_seq`） | ✅ 已有逐条会话表 |
| 是否存在统计查询接口 | `GET /api/v1/stats/{summary,apps,categories,devices}`，仅支持 `period` + `tz_offset_minutes` | ⚠️ 不支持按设备/日期/逐条会话查询 |
| 设备/用户/记录的关系 | `devices.user_id → users.id`；`activity_segments.user_id`、`device_id` 均为 CASCADE 外键 | ✅ 隔离是结构保证 |
| Android 是否把云端写入本机采集表 | 客户端**没有任何**云端读取路径（`AuthenticatedApi.stats()` 存在但从未被 UI 调用） | ✅ 无循环同步风险 |
| MCP 现有工具 | 6 个只读工具，走 `/api/v1/integrations/stats/*`（`X-API-Key`） | ⚠️ 不支持按设备/日期/时间段查询 |

**字段映射（因此不需要新表）**：

| 需求字段 | 实际来源 |
|---|---|
| `local_record_id` | `activity_segments.id`（客户端生成的稳定 UUID，同时就是同步幂等键） |
| `app_id` | `activity_segments.app_key` |
| `app_name` | `user_applications.display_name`，回退 `app_key` |
| `device_id` | `activity_segments.device_id` |
| `duration_seconds` | `activity_segments.active_seconds` 按窗口裁剪后的秒数 |
| `category` | `user_applications.category`，回退 `activity_segments.category` |

**幂等**：`(user_id, id)` 复合主键比需求里的 `UNIQUE(user_id, device_id, local_record_id)`
**更强** —— 同一个 `local_record_id` 无论从哪台设备重放都只会覆盖同一行，
不可能新增重复行（已由 `test_statistics.py` 的三个用例验证）。

## 2. 数据库迁移

`migrations/versions/0004_usage_stats_indexes.py`（`down_revision = 0003_api_keys`）

* 新增两条索引，供"设备 + 日期"与"设备 + 应用 + 日期"查询使用：
  * `ix_activity_segments_user_device_started (user_id, device_id, started_at)`
  * `ix_activity_segments_user_device_app_started (user_id, device_id, app_key, started_at)`
* **不新增表、不加列、不改主键、不动任何既有数据**，`downgrade` 只删这两条索引。
* 同步修改了 `app/models/activity.py`（模型与迁移必须逐字一致，
  `tests/test_migrations.py` 会逐表比对列/主键/外键/索引）。

部署：`docker compose run --rm migrate`（即 `alembic upgrade head`）。

## 3. 统计查询接口

客户端（Bearer 令牌）：

```
GET /api/v1/statistics/summary
GET /api/v1/statistics/apps
GET /api/v1/statistics/sessions
GET /api/v1/statistics/timeline
```

MCP / 集成（个人访问密钥 `X-API-Key`，身份同样由密钥推导）：

```
GET /api/v1/integrations/statistics/devices
GET /api/v1/integrations/statistics/{summary,apps,sessions,timeline}
```

设备列表复用既有的 `GET /api/v1/devices`（已含 id / 名称 / 平台 / 型号 /
最近在线 / 是否撤销 / 是否本机），不另开同义端点。

**两套端点调用同一个 `app/services/statistics_service.py`**，
因此 App 与 MCP 的数字不可能出现两套口径（有逐字段相等的测试）。

### 通用查询参数

`device_id`（不传或 `all` = 全部设备；指定时必须属于当前账户，否则 404）、
`date`、`date_from` / `date_to`（≤ 92 天）、`timezone`（IANA 名）、
`tz_offset_minutes`（时区名的等价替代）、`app_id`、`cursor`、`limit`。

响应中的时长单位一律是**秒**，时间戳为 UTC ISO8601（`...Z`）。

## 4. 时长口径（与 `/stats/*` 保持一致的延伸）

1. **单条会话**：`active_seconds` 按窗口重叠比例折算（与既有 `stats_service._clip` 同一公式）；
2. **同设备同应用重叠去重**：先取这些会话时钟区间的**并集**，再按该组活跃占比折算；
   无重叠时结果与逐条相加完全一致，因此**不改变既有口径**；
3. **展示合并**：同设备同应用、间隔 ≤ 60s 的相邻会话在**时间线**里合并成一条，
   合并项时长仍是区间并集（不是首尾相减 —— 中间 20 秒的间隙不计入）；
4. **跨午夜**：按用户时区的本地午夜切分，原始 UTC 记录不动；
5. **全部设备**：各设备求和（可能重叠），响应带 `overlap_warning`，绝不偷偷去重。

**时区**：优先 IANA 名（`zoneinfo`）；运行环境缺少 `tzdata` 时回退到内置的
常用时区标准偏移表；再不行返回明确的 422。`.env` 里的生产镜像用 Linux 系统时区库，
不受影响。

## 5. MCP 工具（Phase 4B 新增 5 个）

| 工具 | 用途 |
|---|---|
| `petlife_list_devices` | 我有哪些设备（拿到 device_id） |
| `petlife_get_usage_summary` | 某设备某天总时长 + 各应用占比 |
| `petlife_get_app_usage` | 某设备某天应用排行 |
| `petlife_get_usage_sessions` | 某设备某天逐条使用记录（可看具体时间段，分页） |
| `petlife_get_daily_timeline` | 某设备某天全天时间线 |

安全约束（与既有 6 个工具一致）：个人访问密钥即身份，工具参数里**没有**任何
身份字段；`device_id` 必须属于密钥对应用户；MCP 客户端仍然只读（只有 GET）。

## 6. 测试

* `tests/test_statistics.py`（22 项）：单设备/全部设备累计、重叠去重、展示合并、
  跨午夜拆分、日期边界、分页不重不漏、按应用过滤、重复上传幂等、
  未结束会话更新、跨用户设备隔离（404）、无效时区/日期/区间、
  `tz_offset_minutes` 替代、撤销设备不能上传、统计接口**只读**（查询前后表内容不变）、
  响应无隐私字段、区间查询、未认证拒绝、**MCP 与 App 结果逐字段一致**、
  **MCP 密钥不能越权查他人设备**。
* `tests/test_migrations.py`：迁移建出的 schema 与模型逐表一致（含新增的两条索引）。
* 全量：`python -m pytest -q` → **211 passed / 0 failed**（退出码 0）。

## 7. 第 1 ~ 7 章的口径**已冻结**

客户端接入、MCP 接入与后续维护**不需要**再改服务端的表结构、接口签名与时长口径。

# 客户端（步骤 6 / 步骤 7）

## 8. 客户端数据层与界面

### 8.1 数据层（步骤 6，已验收）

| 文件 | 职责 |
|---|---|
| `lib/sync/models/cloud_statistics_models.dart` | 7 个只读模型 + 严格 JSON 解析（时间戳**必须**带显式时区，否则抛 `CloudDataException`）；`formatDurationZh` / `formatLocalHm` / `timezoneKeyForOffset` |
| `lib/sync/cloud_statistics_repository.dart` | `CloudStatisticsRepository` 接口 + `ApiCloudStatisticsRepository`（路径白名单、错误分类映射到 `CloudStatisticsErrorKind`） |
| `lib/sync/cloud_statistics_cache.dart` | 类型化缓存（`buildKey`），只读写 `cloud_statistics_cache` |
| `lib/database/dao/cloud_statistics_cache_dao.dart` | `CloudCacheType` + DAO（`UPDATE` 未命中再 `INSERT`，损坏行自愈） |
| `lib/database/schema.dart` / `lib/core/constants.dart` | 本地 schema **v4**：新增 `cloud_statistics_cache` 表 |
| `lib/sync/cloud_statistics_controller.dart` | 7 态状态机 + 请求去重（`_inFlight`）+ 代次守卫（`_epoch`）防旧响应串页；**只读**，绝不写本机采集表、绝不进 outbox |

### 8.2 云端统计页（步骤 7）

`lib/ui/pages/cloud_statistics_page.dart`：

* **筛选栏**：`前一天 / 日期选择器 / 后一天 / 今天` + 设备下拉（含「全部设备」与「已撤销」标记）+ 手动刷新；已是今天时「后一天」禁用、日期选择器 `lastDate = 今天`，因此**未来日期既点不到也发不出请求**；
* **汇总卡**：累计时长、当前筛选设备、应用数 · 会话数、最近同步、最近刷新、多设备重叠说明；
* **应用统计**：按时长降序（页面侧再做一次防御性排序），点击展开时间段，支持 `加载更多` 分页；展开中只有该行显示局部进度条，单个应用失败不影响整页；
* **时间线**：按开始时间升序，每条带来源设备与合并段数；
* **页面状态**：首次加载 / 刷新中保留旧数据 / 空数据 / 未登录（不发请求）/ 登录失效 / 离线缓存标记 / 无缓存错误 + 重试 / 服务端错误中文提示；
* **布局**：整页只有**一个** `ListView`（`AlwaysScrollableScrollPhysics` + `RefreshIndicator`），应用展开是行内插入，不使用 `Expanded` 或无限高度 `GridView`。

`lib/ui/pages/usage_stats_page.dart`：顶部 `SegmentedButton`「本机 | 云端」，用 `IndexedStack` 保留两侧滚动位置与展开状态；子页选择持久化在 `ui.usageStatsTab`，重启后停在上次那一页。

### 8.3 账户与同步页（步骤 7）

`lib/ui/widgets/cloud_sync_actions.dart` + `lib/ui/pages/account_sync_page.dart`：

* **立即上传本机记录** → `SyncEngineUploadHost.uploadNow()` → `SyncEngine.syncNow(manual: true)`（**上行**）；
* **刷新云端统计** → `CloudControllerRefreshHost.refreshNow()` → `CloudStatisticsController.refresh(manual: true)`（**下行**，不碰 outbox）；
* 两个按钮各自显示待上传数量、最近上传时间、最近云端查询时间，任一动作进行中时按钮禁用；
* 原来的含糊「立即同步」已移除，避免三个按钮语义重叠。

### 8.4 隐私设置

账户页只**展示当前真实能力**，不提供没有实际效果的开关：

```
上传应用名称：已启用
上传应用标识：已启用
上传详细时间线：已启用
窗口标题：当前版本不上传
```

## 9. 测试与验证结果

### 9.1 Flutter

```
flutter analyze --no-pub   → No issues found!
flutter test --no-pub      → 517 passed, 1 skipped, 0 failed
```

Phase 4B 新增/扩充的用例：

| 文件 | 项数 | 覆盖 |
|---|---|---|
| `test/cloud_statistics_models_test.dart` | 22 | 模型解析、显式时区校验、时长/时间格式化 |
| `test/cloud_statistics_cache_test.dart` | 10 | 缓存键、账户隔离、损坏自愈、清除 |
| `test/cloud_statistics_controller_test.dart` | 17 | 7 态机、去重、串页守卫、分页、退出清理 |
| `test/cloud_statistics_page_test.dart` | 17 | 未登录、只初始化一次、设备/日期筛选、未来日期、汇总卡、应用降序展开分页、局部加载、时间线排序、空数据、离线缓存、刷新保留旧数据、旧响应不覆盖新选择、360dp/横屏/字体放大/长名称/50 条时间线无溢出 |
| `test/cloud_sync_actions_test.dart` | 5 | 两个按钮语义互不混淆、禁用态、时间不混用；**真 SyncEngine + 本地假服务端**验证上传、**真 outbox 表**验证刷新云端统计不写 outbox |
| `test/settings_persistence_test.dart` | +3（共 11） | 「本机 / 云端」子页记忆、与其它设置互不影响、非法值回落本机 |

### 9.2 服务端

```
python -m pytest -q   → 211 passed, 0 failed
```

### 9.3 本地 E2E（真实 HTTP，自动部分）

`server/tools/e2e_smoke.py` 新增「8b. Phase 4B 云端统计」小节：真实 `alembic upgrade head`
+ 真实 `uvicorn` + `httpx`，不访问公网。结果 **E2E SMOKE PASSED**，覆盖：

1. 同一账户两台设备（Windows 电脑 + Android 手机）分别上传逐条会话；
2. 全部设备累计 4680s、3 段会话、2 个应用，带重叠说明与最近同步时间；
3. 应用排行按时长降序（Edge 3480s 在前）；
4. 只看 Windows 设备 = 3480s、1 个应用、无重叠说明；
5. 展开 Edge = 2 段，按开始时间升序，每段带正确来源设备，无多余下一页；
6. 时间线 3 条、按开始时间升序、每条带来源设备名、合计与汇总一致（服务端只算一次）；
7. 重复上传同一批会话后累计**不变**（幂等）；
8. 未来日期返回 200 且累计 0（不是报错）；
9. 第二个账户查不到第一个账户的统计；指定他人设备返回 **404**。

### 9.4 未自动验证（必须人工执行）

以下环节无法在无真机/无图形会话的环境里自动完成，**未宣称通过**：

* Windows 客户端真实登录 → 用 Edge / VS Code 产生记录 → 立即上传 → 服务端 `last_synced_at` 更新；
* Android 真机打开「使用统计 → 云端」，选 Windows 设备核对累计时长与具体时间段；
* 断网后客户端展示离线缓存标记与「上次刷新」时间；
* 20 项界面细节（滚动位置保持、字体放大、长设备名等）在日常设备上的观感；
* Windows 客户端本机采集 / 同步 / 桌宠 / 素材库的**人工**回归（自动化部分见 9.1 的 517 项）。

## 10. 构建产物

| 产物 | 路径 | 大小 | 修改时间 | SHA256 |
|---|---|---|---|---|
| Android Debug APK | `petlife/build/app/outputs/flutter-apk/app-debug.apk` | 189081986 B（180.32 MB） | 2026-09-29 19:08:43 | `3A01567F7C5BFF6FAEB0ED0A1D071A6924EE3BAE7F2DBF0B216D5D2E25967608` |
| Windows Release | `petlife/petlife_win_regress_20260929_3/windows/x64/runner/Release/petlife.exe` | 92160 B | 2026-09-29 19:16:53 | — |

> Windows 产物落在 `petlife_win_regress_20260929_3`，原因是旧构建目录里的
> `petlife.exe` 被若干**卡在终止态**的残留进程占用（`LNK1104`），
> 无法就地覆盖。构建完成后 `flutter config --build-dir` 已改回默认值 `build`。

## 11. 服务器部署步骤（人工执行）

```bash
# 0. 前置：准备好生产 .env（PETLIFE_JWT_SECRET、POSTGRES_PASSWORD 必填），不要提交到仓库
cd server

# 1. 数据库迁移：只新增两条统计索引，不建表、不改主键、不动既有数据
docker compose run --rm migrate            # = alembic upgrade head

# 2. 重建并重启 API 容器（migrate 成功后 api 才会启动）
docker compose up -d --build api

# 3. 健康检查
curl -fsS http://127.0.0.1:8000/health     # 期望 {"status":"ok","database":true}

# 4. 统计接口冒烟（真实账户令牌 + 该令牌绑定的设备）
curl -fsS -H "Authorization: Bearer $ACCESS" -H "X-Device-Id: $DEVICE" \
  "http://127.0.0.1:8000/api/v1/statistics/summary?date=$(date +%F)&timezone=Asia/Shanghai"

# 5. 设备列表（App 与 MCP 共用，确认设备确实已绑定）
curl -fsS -H "Authorization: Bearer $ACCESS" -H "X-Device-Id: $DEVICE" \
  "http://127.0.0.1:8000/api/v1/devices"

# 6. MCP：**不是 compose 里的服务**，由 MCP 客户端以子进程启动（stdio），
#    或单独以 HTTP 模式运行后重启该进程即可（本次新增 5 个统计工具）。
python -m mcp_server.main http             # 监听 PETLIFE_MCP_HOST:PETLIFE_MCP_PORT
curl -fsS -H "X-API-Key: $PLK" \
  "http://127.0.0.1:8000/api/v1/integrations/statistics/devices"
```

**回滚**：
* 服务端：`docker compose run --rm migrate alembic downgrade 0003_api_keys`
  （只删两条索引，不动数据）→ `docker compose up -d --build api` 回到上一版镜像；
* MCP：`git checkout <上一版>` 后重启 MCP 进程；
* 客户端：重新分发上一版安装包。客户端 v4 只新增了一张**只读缓存表**，
  回滚到旧版本时该表被忽略（旧版本 schema 版本号更小不会主动降级，数据可空置），
  本机采集数据与 outbox 不受影响。

