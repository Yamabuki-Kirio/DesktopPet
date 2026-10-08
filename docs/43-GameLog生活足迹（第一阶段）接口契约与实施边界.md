# 43 · GameLog「生活足迹」第一阶段：接口契约与实施边界

> 本文是**审计结论 + 契约固化**，不是交付说明（交付说明见 `docs/44`）。
> 审计对象：`C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\server`（真实源码，非推测）。
> 基线：改动前 `pytest -q` **211 passed / 0 failed**。

关键结论一句话：定稿里写的接口**全部真实存在**，但**字段名有几处与定稿不同**，
且**设备接口存在两种形状**——照定稿直接写前端会踩坑。以下是逐条对齐结果。

---

## 一、真实接口清单（逐一核对，带源码位置）

### 1.1 认证

| 方法 | 路径 | 源码 | 身份 |
|---|---|---|---|
| POST | `/api/v1/auth/register` | `api/v1/auth.py:83` | 匿名 |
| POST | `/api/v1/auth/login` | `api/v1/auth.py:105` | 匿名 |
| POST | `/api/v1/auth/refresh` | `api/v1/auth.py:119` | 匿名（凭 refresh_token） |
| POST | `/api/v1/auth/logout` | `api/v1/auth.py:142` | 匿名 |
| POST | `/api/v1/auth/logout-all` | `api/v1/auth.py:169` | **Bearer** |
| GET | `/api/v1/me` | `api/v1/auth.py:180` | **Bearer** |
| PATCH | `/api/v1/me` | `api/v1/auth.py:186` | **Bearer** |
| POST | `/api/v1/me/password` | `api/v1/auth.py:199` | **Bearer** |
| DELETE | `/api/v1/me` | `api/v1/auth.py:218` | **Bearer** |

登录请求体（`schemas/auth.py:38`）：

```jsonc
{ "email": "a@b.com", "password": "...", "device": { /* 可选，DeviceRegisterRequest */ } }
```

登录响应体（`api/v1/auth.py:47-59`，**不是** `LoginResponse` 模型，是 dict）：

```jsonc
{
  "access_token": "…",              // JWT HS256
  "token_type": "bearer",
  "expires_in": 900,                // 秒
  "refresh_token": "…",             // 不透明随机串
  "refresh_expires_at": "2026-11-05T…Z",
  "user": { "id":…, "email":…, "display_name":…, "status":…, "created_at":…, "updated_at":… },
  "device_id": "…" | null
}
```

> ⚠️ 定稿写的 `GET /api/v1/devices` 存在 ✓，但**返回的是裸数组**（`api/v1/devices.py:62`），
> 不是 `{items:[…]}`。见 §四。

### 1.2 跨设备统计（Bearer，`api/v1/statistics.py`）

| 方法 | 路径 | 源码行 | 响应模型 |
|---|---|---|---|
| GET | `/api/v1/statistics/summary` | `:85` | `StatisticsSummaryOut` |
| GET | `/api/v1/statistics/apps` | `:105` | **同一个** `StatisticsSummaryOut` |
| GET | `/api/v1/statistics/sessions` | `:130` | `UsageSessionPageOut` |
| GET | `/api/v1/statistics/timeline` | `:164` | `TimelineOut` |

**关键差异：`/statistics/apps` 与 `/statistics/summary` 响应结构完全相同**
（`statistics.py:105-127` 调的就是同一个 `get_summary`）。定稿把它当成两个不同的东西，
前端**不能**期望 `/apps` 返回一个数组——要取 `body.apps`。

统一查询参数（四端点通用，`statistics.py:58-82`）：

| 参数 | 类型 | 说明 |
|---|---|---|
| `device_id` | str | 不传 / `all` = 全部设备；指定时必须属于当前用户，否则 404 |
| `date` | `YYYY-MM-DD` | 单日；**与 date_from/date_to 互斥**（同用报 422） |
| `date_from` / `date_to` | `YYYY-MM-DD` | 区间，含两端，最多 92 天（`MAX_QUERY_DAYS`） |
| `timezone` | IANA 名 | 如 `Asia/Shanghai`；无效时区**报 422**（不静默按 UTC 算） |
| `tz_offset_minutes` | int | −720~840，`timezone` 的等价替代 |
| `app_id` | str | 仅 sessions / timeline |
| `cursor` / `limit` | str / int | 仅 sessions（limit 1~500，默认 100） |

**注意：`device_id` 是 UUID**。`resolve_device_scope` 会 `uuid.UUID()` 解析，
非 UUID 直接 `invalid_uuid`（400）。

### 1.3 集成版（`plk_` 密钥，**网页禁止使用**）

`api/v1/statistics.py:221-351` 的 5 个 `/api/v1/integrations/statistics/*`，
外加 `api/v1/integrations.py` 的 `/integrations/stats/{summary,apps,categories,devices}`、
`/integrations/compare`、`/integrations/sync-status`——**全部只认 `X-API-Key: plk_…`**。

定稿第 5、7 条要求网页只能用邮箱密码 + 会话，**因此这些端点在本项目中一律不出现**。
（它们与 Bearer 版共用同一批服务函数，所以"两处结果不一致"在服务端层面不可能发生。）

---

## 二、真实字段名（照抄，禁止再猜）

```jsonc
// StatisticsSummaryOut  (schemas/statistics.py:80)
{
  "date": "2026-09-29", "date_from": "2026-09-29", "date_to": "2026-09-29",
  "timezone": "Asia/Shanghai",
  "device_id": null,                  // 全部设备时为 null
  "total_duration_seconds": 3480,     // ← 不是 total_seconds
  "session_count": 2, "app_count": 1,
  "last_synced_at": "2026-10-06T13:36:00Z",   // ← 界面「最近同步」用它
  "apps": [{ "app_id": "msedge", "app_name": "Microsoft Edge",
             "category": "browser", "duration_seconds": 3480,
             "session_count": 2 }],
  "overlap_warning": null             // 仅「全部设备且 ≥2 台」时非空
}

// UsageSessionPageOut  (schemas/statistics.py:114)
{
  "date": …, "date_from": …, "date_to": …, "timezone": …, "device_id": …,
  "items": [{ "id": "…", "local_record_id": "…", "device_id": "…",
              "device_name": "我的电脑", "platform": "windows",
              "app_id": "code", "app_name": "Visual Studio Code",
              "category": "development",
              "started_at": "2026-09-29T01:00:00Z", "ended_at": "…Z",
              "duration_seconds": 1800 }],
  "next_cursor": null                 // null = 没有更多
}

// TimelineOut  (schemas/statistics.py:141) —— 时间线
{
  "date": …, "date_from": …, "date_to": …, "timezone": …, "device_id": …,
  "items": [{ "app_id": "code", "app_name": "…", "category": "…",
              "device_id": "…", "device_name": "…",
              "started_at": "…Z", "ended_at": "…Z",
              "duration_seconds": 3120,
              "merged_session_count": 2 }],   // 由几条原始会话合并
  "total_duration_seconds": …,
  "overlap_warning": null
}
```

**时间格式**：一律 `…Z` 的 UTC ISO8601（`schemas/common.py:56` `to_iso`）。
界面要显示本地时间必须自行按浏览器时区换算——**不能直接截字符串**。

**错误体**（`core/errors.py:143`）：

```jsonc
{ "error": { "code": "invalid_credentials", "message": "邮箱或密码错误", "request_id": "…" } }
```

前端只需依赖 `error.code`：`invalid_credentials` / `unauthorized` / `token_expired` /
`token_invalid` / `account_disabled` / `device_not_found` / `validation_error` / `invalid_cursor` …

---

## 三、统计口径（已固化，不可擅自改动）

源码：`services/statistics_service.py`，测试：`tests/test_statistics.py`。

1. **计数单位**：`active_seconds` 按窗口重叠比例折算（`:380-406`），与 `stats_service` 同口径。
2. **同设备同应用重叠去重**：先取区间并集，再按活跃占比折算（`_effective_seconds` `:409`）。
   无重叠时 == 逐条相加（不改变既有口径）。
3. **全部设备 = 求和，不去重**（`:513` `total = sum(per_app.values())`），
   且 `overlap_warning` 非空（`:538`）。定稿第 10 条正确，**照此实现**。
   现有回归测试：`test_all_devices_sums_without_dedup_and_warns`（`tests/test_statistics.py:125`）
   → 两设备各 1800s，全部设备必须是 **3600**，且 `overlap_warning` 为真。
4. **展示合并**：时间线里同设备同应用、间隔 ≤ **60s**（`DISPLAY_MERGE_GAP_SECONDS`，
   `schemas/statistics.py:44`）的相邻会话合并成一条；合并项时长仍按并集算（`:693`）。
   **前端不得再自行合并，也不得自创阈值。**
5. **跨午夜**：按用户时区本地午夜切分（`:234`），一条 23:50→00:20 在两天各出现被裁剪那段。
6. **分页**：`next_cursor` 是 base64（`started_at|record_id`），按 `started_at` 升序 +
   `id` 升序，保证不重不漏（`:553-568`）。
7. **时区**：`timezone` 优先；缺 tzdata 时走 `_FALLBACK_OFFSETS` 内置表；
   都不行**报 422**。`tz_offset_minutes` 范围 −720~840。
8. **只读**：统计接口**不写任何表**（回归测试 `test_statistics_reads_do_not_write_anything:550`）。

---

## 四、⚠️ 定稿与真实代码的 5 处冲突（已按"以真实代码为准"处理）

| # | 定稿写法 | 真实情况 | 本项目的处理 |
|---|---|---|---|
| 1 | `GET /api/v1/statistics/apps` 返回应用数组 | 返回**与 summary 完全相同**的对象，应用在 `.apps` | 前端统一调 `summary`，只读 `.apps`（少一次请求） |
| 2 | `GET /api/v1/devices` | 返回**裸数组**，字段是 `device_name` / `revoked_at` / `device_local_id`（`schemas/device.py:72`） | 前端按裸数组解析；**不用** `statistics.DeviceListOut`（那个 `{items:[…]}` 形状只属于 plk_ 的 `/integrations/statistics/devices`） |
| 3 | 新接口 `/statistics/days` 参数 `before` / `limit` / `device_id` | 未实现 | 按定稿实现（见 `docs/44`），并**复用**既有 `resolve_timezone` / `resolve_window` / `resolve_device_scope`，保证口径不漂移 |
| 4 | `days` 返回 `top_apps: []` | 无既有约定 | 返回 `top_apps: [{app_id, app_name}]` —— 界面要显示"Chrome / 微信"，只有 id 没法直接显示 |
| 5 | `device_count`（`days`） | 无既有约定 | 用"该日**有活动记录**的设备数"，不是账号设备总数 |

另外两点**必须遵守的硬约束**：

- `tests/test_statistics.py:585` 有一道**隐私字段扫描**：响应文本里不得出现
  `window_title` / `title` / `url` / `executable_path` / `path` / `file_path`
  这几个**子串**。所以新增字段名里**不能含 `path`、不能含 `title`**。
- `schemas/common.py` 的 `StrictModel` 是 `extra="forbid"`：
  请求体多传字段直接 422，前端提交的 JSON 必须严格。

---

## 五、应用归一化：现状与第一阶段边界

**现状（重要）**

- 只有 `user_applications`（`models/activity.py:157`）：主键 `(user_id, app_key)`，
  字段 `display_name` / `category` / `user_overridden` / `updated_at` / `change_seq`。
  **没有** `application_catalog`、**没有** `application_aliases`。
- `activity_segments.app_key`（`models/activity.py:96`）注释写明是"规范化后的可执行文件名，**不含完整路径**"，
  Android 侧等于 **package name**（`docs/27-Android使用统计口径.md:28`：`com.tencent.mm`）。
- 显示名解析在 `statistics_service._app_catalog` + `:517`：
  `user_applications.display_name`，查不到就**回退成 app_key 原文**。
  → **没有任何别名/子进程归并逻辑。**

**第一阶段做法（本项目的决策，理由随附）**

新增 `app/services/app_normalization.py`：**服务端**归一化模块，不落库、不加迁移。

- 归一顺序严格照定稿第 8 条：① 用户级 override（`user_applications.user_overridden`）
  → ② 内置精确表 → ③ Android 主包名 → ④ 去掉 `:push` / `:tools` / `:service` /
  `:appbrand0` 等子进程后缀后匹配 → ⑤ 都不中则保留原始名，标记未识别。
- 对外显式给出 4 个字段：`app_id`（归一后主键）、`app_name`（当前显示名）、
  `normalized`（是否经归一）、`recognized`（是否被识别），
  外加 `raw_app_keys`（合并进来的原始进程名，**满足"原始名称可追溯"**）。

**为什么第一阶段不建 `application_catalog` / `application_aliases` 两张表**

定稿末尾明确允许："应用归一化的完整编辑能力可以拆为紧接下一增量"，同时要求
"第一阶段的数据展示必须保留 raw_app_key / 当前显示名 / 是否已归一化 / 未识别标记"。
且定稿第 8 条自己写着"能扩展现有表就不要重复建表"。

所以第一阶段：**归一规则放在服务端模块（不写死在前端 ✓）**，展示字段齐备；
**用户可编辑的目录与别名（落库 + 编辑接口 + 管理界面）作为下一个增量**，
届时新增 `0005` 迁移建表，本阶段的响应结构**不需要推翻**
（`raw_app_keys` / `recognized` 已经在契约里了）。

---

## 六、Web Session 设计（新增，不破坏既有接口）

定稿第 5、6 条：桌面/手机客户端继续用 JSON Token，**网页额外走 HttpOnly 会话**。

复用现有的 `refresh_tokens` 表与 `auth_service`（**零迁移**）：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/web-session/login` | 邮箱密码 → 下发 3 个 Cookie，正文只回 `user` |
| POST | `/api/v1/web-session/refresh` | 凭 refresh Cookie 轮换（复用 `refresh_session`） |
| POST | `/api/v1/web-session/logout` | 吊销当前 refresh 链 + 清 Cookie |
| GET | `/api/v1/web-session/me` | 读 access Cookie → 当前账户 |

Cookie（`Path=/petlife-api/`，与定稿一致）：

| 名 | HttpOnly | 内容 | 作用 |
|---|---|---|---|
| `pl_web_at` | ✅ | Access JWT | 统计读取鉴权 |
| `pl_web_rt` | ✅ | Refresh 不透明串 | 静默续期 |
| `pl_web_csrf` | ❌（JS 需读） | 随机串 | Double-submit CSRF |

`Secure` 由新增配置 `PETLIFE_WEB_SESSION_COOKIE_SECURE` 控制，**默认 True**，
开发/自签环境可关掉；`SameSite=Lax`。

> ⚠️ CSRF Cookie 若也设 `Path=/petlife-api/`，页面的 JS（在 `/usage/`）**读不到它**——
> `document.cookie` 只暴露路径匹配当前文档的 Cookie。因此 CSRF Cookie 单独设 `Path=/`。
> 这一条是实现期必须踩对的细节。

CSRF 校验：所有**写**方法（POST/PATCH/DELETE）比对「`pl_web_csrf` Cookie」与
`X-CSRF-Token` 头是否一致且非空；本阶段写操作只有 login/refresh/logout，读接口不校验。

---

## 七、第一阶段做什么 / 不做什么

**做**（= 定稿"实施顺序" 1–9 条）
1. ✅ 审计真实接口与模型（本文）
2. ✅ 固化契约与口径（本文）
3. Web Session 4 个接口 + 测试
4. `GET /statistics/days`（日期游标、倒序、默认与最大 limit=7）+ 测试
5. `/usage/`（index.html + usage.css + usage.js）
6. `game.html` **只加一个**导航入口
7. `?demo=1` 演示模式（生产默认禁止 MOCK）
8. 桌面端 + 手机端响应式
9. 上传 / 迁移 / Docker / Nginx 部署说明（`docs/44`）
- 附带：服务端应用归一化模块（§五）

**不做**（明确留给下个增量）
- 应用目录/别名的**落库与编辑**（`application_catalog` / `application_aliases` 表、迁移 0005、管理界面）
- 五维洞察接口 `/statistics/insights` 与 `?summary` 的 AI 深度总结
- 7 日 / 30 日个人基线
- infinite scroll / 整月日历

---

## 八、验收自检锚点

| 要求 | 判定方式 |
|---|---|
| 首次进入只加载今天 | 打开 `/usage/`，DevTools Network 只有 `web-session/me` + `devices` + `summary` |
| 历史默认折叠且无偷跑请求 | 同上，无 `statistics/days` 请求 |
| 每次只加载 7 天 | `days?before=…&limit=7`，`has_more` 为真才显示「加载更早的 7 天」 |
| 时间线按点击加载 | 点「时间线」才出现 `statistics/timeline` |
| 全部设备不去重且有提示 | 选「全部设备」时正文含 `overlap_warning` 文案 |
| 评分依据可查看 | 五维每行可展开「为什么」 |
| 密钥隔离 | 全站源码 grep 不到 `plk_`；game.html 管理密钥无法读 PetLife |
| 源码无个人密钥 | `Select-String -Pattern "plk_"` 在 game.html / usage/\* 上零命中 |
