# 45 · Phase 2 审计结论与契约冻结（2A / 2B / 2C）

> 第一步「审计和契约冻结」的产出。**动数据库与统计之前先把契约定死**，
> 否则一次改到迁移 + 聚合 + 页面 + 趋势，回归无法定位。
>
> 审计对象：`C:\Users\Administrator\WorkBuddy\DesktopPet\petlife\server`（真实源码）。
> 基线：本阶段开始前 `pytest` **263 passed**。

---

## 一、审计结论（带源码位置）

### 1.1 现有应用模型

**只有一张表**：`user_applications`（`app/models/activity.py:157`）

```
(user_id, app_key)  复合主键
display_name        显示名
category            分类
user_overridden     用户手工分类标记
updated_at / server_received_at / change_seq
```

**没有** `icon_key`（图标标识）字段；**没有**独立的应用目录与别名表。
`app_key` 语义是"规范化后的可执行名/包名，不含路径"（`:96` 注释），
Android 侧等于 package name（`docs/27:28`）。

**冲突策略**（`services/sync_service.py:367-417`，`_push_application`）：
`user_overridden=True` 的记录不会被非 overridden 的覆盖；
两边都是 overridden 时按 `updated_at` 较新者胜。

> ⚠️ **由此得到一条硬约束**：网页写入的映射**不能只靠 `user_overridden` 保护**。
> 如果网页把用户的选择写进 `user_applications`，客户端之后推送一条
> `user_overridden=true` 且 `updated_at` 更新的记录就会把它覆盖掉。
> 因此网页的映射必须落在**独立的表**里（见 1.4 的决策）。

### 1.2 分类枚举（已确认，冻结）

`app/schemas/sync.py:18`

```python
APP_CATEGORIES = (
    "development", "productivity", "gaming", "social",
    "entertainment", "browser", "system", "other",
)
```

**这就是全部合法值**，`AppRecordIn.category` 与 `ActivitySegmentIn.category`
都会严格校验它。Phase 1 曾因为内置表写了 `work`/`news` 这类值导致客户端上传整体 422，
现已有护栏（`app_normalization._assert_categories_are_valid`）。
**Phase 2 新增的应用目录必须复用同一个枚举**，不得自造。

### 1.3 ⚠️ 统计聚合发生在**两层**（这是本次审计最重要的发现）

| 层 | 服务模块 | 对外接口 | 谁在用 |
|---|---|---|---|
| **A. 本地/单设备** | `app/services/stats_service.py` | `/api/v1/stats/*`、`/api/v1/integrations/stats/*` | **MCP**、集成 |
| **B. 跨设备云端** | `app/services/statistics_service.py` | `/api/v1/statistics/*`、`/api/v1/integrations/statistics/*` | 网页（生活足迹）、App 云端统计 |

**两层各自聚合、互不复用**，且**只有 B 层做了应用归一化**（Phase 1 加的）。
证据：`services/integration_stats_service.py:95` `list_apps` → `stats_service.get_apps`，
而 `stats_service.py:320-341` 是**按原始 `app_key` 分组**、
显示名直接取 `user_applications.display_name`，**没有任何子进程归并**。

**后果**：现在如果手机上报了 `com.tencent.mm` 与 `com.tencent.mm:tools`，
网页（B 层）显示 1 条「微信」，**MCP（A 层）会显示 2 条**。
这直接违反 Phase 2 的验收项「MCP 与网页显示相同应用名称」。

**因此 2A 必须同时改 A 层与 B 层**，且两层的归一化要共用同一个实现，
否则将来又会漂移。这是本阶段的**必做项**，不是可选项。

### 1.4 决策：新增目录表，但不动 `user_applications`

定稿说"优先扩展现有结构，避免重复建表"，同时要求具备
「统一应用 + 显示名 + 分类 + 图标标识 + 平台 + 多个原始别名」。
`user_applications` 的主键是**原始 `app_key`**，天然无法表达
"一个统一应用对应多个原始名"，也缺 `icon_key`。

**决策（冻结）**：
- **保留 `user_applications` 原样**，继续作为"客户端上传的应用库"，
  同步协议一字不改 ⇒ **旧客户端零影响**；
- 新增 `application_catalog`（统一应用）+ `application_aliases`（原始名 → 统一应用）；
- 归一化时 `user_applications.display_name` 参与**显示名回退**
  （用户/客户端已有的命名不被丢弃），但**网页写入的别名优先级最高**。

这样既满足"避免重复建表"（没有重建已有的东西），
又解决 1.1 的覆盖隐患（网页映射落在独立表里，客户端推送碰不到它）。

---

## 二、冻结的数据模型

### 2.1 `application_catalog`

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | 目录项 id（接口里的 `{id}`） |
| `user_id` | UUID FK→users, NOT NULL | **用户隔离的第一道** |
| `display_name` | String(128) | 统一显示名（如「微信」） |
| `category` | String(32) | 必须是 `APP_CATEGORIES` 之一 |
| `icon_key` | String(64) NULL | 图标标识（如 `wechat`），不存图片 |
| `source` | String(16) | `builtin` / `user` —— 是内置推导出来的还是用户手工建的 |
| `created_at` / `updated_at` | UTCDateTime | |

约束：`UniqueConstraint(user_id, display_name)` —— 同一账户下显示名不重复，
避免用户手滑建出两个「微信」而无法区分。索引 `(user_id)`。

### 2.2 `application_aliases`

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `user_id` | UUID FK→users, NOT NULL | 用户隔离 |
| `catalog_id` | UUID FK→application_catalog, ON DELETE CASCADE | |
| `raw_app_key` | String(128) | **原始名**（`com.tencent.mm:tools` / `WeChat.exe`） |
| `platform` | String(32) NULL | `windows` / `android` / NULL=不限 |
| `match_type` | String(16) | `exact` / `subprocess` / `manual` |
| `priority` | Integer | 越小越优先，默认 100 |
| `created_at` | UTCDateTime | |

约束：**`UniqueConstraint(user_id, raw_app_key)`**
—— 一个原始名在同一账户下只能指向一个统一应用。
这条约束让「合并到已有应用」的语义无歧义，也天然防止重复映射。

> 迁移号 **`0005_application_catalog`**，`down_revision = "0004_usage_stats_indexes"`。
> 纯新增表，不动既有列 ⇒ 对生产数据无损。

---

## 三、冻结的归一优先级

严格照定稿，并明确每一步落在哪张表/哪张内置表上：

| # | 规则 | 数据来源 | `match_type` |
|---|---|---|---|
| 1 | **用户手动指定的精确映射** | `application_aliases` 精确命中 `raw_app_key` | `manual` |
| 2 | **内置精确映射** | `app_normalization.BUILTIN_TABLE` 主包名 / 可执行名精确命中 | — |
| 3 | **Android 主包名匹配** | 命中项本身即主包名（`com.tencent.mm`） | — |
| 4 | **去子进程后缀后匹配** | 递归剥 `:push` / `:tools` / `:service` / `:appbrand0` … 再查内置表 | `subprocess` |
| 5 | **无法识别** | 保留原始名，`recognized=false` | — |

补充两条（与 Phase 1 一致，不改变语义）：

- `user_applications.display_name` 作为**显示名回退**：命中内置表但该账户的
  应用库里有自定义名时，用应用库里的名字；
- **禁止修改或覆盖原始活动片段**：`activity_segments` 一行都不改，
  归一化只发生在查询与展示层（有测试断言）。

---

## 四、冻结的接口契约

### 4.1 应用目录（2A，全部要求认证、全部按账户隔离）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/applications/catalog` | 列出本账户的统一应用（含别名与使用统计） |
| GET | `/api/v1/applications/unrecognized` | 未识别原始名 + 出现次数/时长/设备 |
| POST | `/api/v1/applications/catalog` | 新建统一应用，可同时携带 alias |
| PATCH | `/api/v1/applications/catalog/{id}` | 改显示名 / 分类 / 图标 |
| DELETE | `/api/v1/applications/catalog/{id}` | 删除统一应用（别名级联删除 → 该原始名回到未识别或内置名） |
| POST | `/api/v1/applications/aliases` | 新增/覆盖一条别名映射（**合并到已有应用**走这里） |
| DELETE | `/api/v1/applications/aliases/{id}` | 撤销映射（**恢复原始显示**） |

响应要点（冻结）：

```jsonc
// GET /applications/catalog
{
  "items": [{
    "id": "uuid",
    "display_name": "微信",
    "category": "social",
    "icon_key": "wechat",
    "source": "builtin",              // builtin | user
    "aliases": [{
      "id": "uuid", "raw_app_key": "com.tencent.mm:tools",
      "platform": "android", "match_type": "manual", "priority": 100
    }],
    "total_seconds": 9180,            // 该应用在各原始名上的时长合计（近 30 天）
    "raw_app_key_count": 3
  }],
  "unrecognized_count": 6
}
```

```jsonc
// GET /applications/unrecognized
{
  "items": [{
    "raw_app_key": "com.vendor.unknown:worker",
    "platform": "android",
    "total_seconds": 1800,
    "segment_count": 2,
    "suggested_catalog_id": null,      // 若去后缀后能命中内置表，给出建议目标
    "suggested_display_name": null
  }],
  "total": 1
}
```

错误码沿用既有 `ErrorCode`；新增：
- `catalog_not_found`（404）
- `catalog_duplicate`（409，同账户同名）
- `alias_conflict`（409，该原始名已映射到别的统一应用）

### 4.2 五维洞察（2B）

```
GET /api/v1/statistics/insights?date=2026-10-06&device_id=all&tz_offset_minutes=480
```

响应冻结（`dimensions` 顺序固定，前端按序渲染）：

```jsonc
{
  "date": "2026-10-06",
  "timezone": "Asia/Shanghai",
  "device_id": null,
  "sample_days": 7,                 // 基线实际用到的天数（不足 7 天则为实际值）
  "is_sample_sufficient": true,     // false 时所有 score 为 null
  "insufficient_reason": null,      // 样本不足时的原因文案
  "dimensions": [{
    "key": "focus",                 // focus | rhythm | intensity | structure | cross_device
    "label": "专注度",
    "score": 82,                    // null = 样本不足
    "baseline_score": 73,           // null = 无基线
    "delta": 9,                     // score - baseline_score，null 表示无从比较
    "direction": "up",              // up | down | flat | null
    "reasons": ["最长连续使用 52 分钟", "短会话占比 18%"]   // 必须能解释
  }],
  "highlights": [],
  "observations": [],
  "suggestions": [],
  "summary_text": "…",              // 规则生成，不调用大模型
  "overlap_warning": null           // 多设备时沿用既有口径
}
```

**评分规则（冻结）**：

- 分数 `0~100`，**全部与用户自己的近 7 日基线比较**，不使用社会标准；
- `sample_days < 3`（即除当天外可用基线不足） ⇒ `score`/`baseline_score`/`delta`
  一律 `null`，`is_sample_sufficient=false`，界面显示「样本不足」；
- 当天无任何记录 ⇒ 同样按样本不足处理，**不产出虚假评价**；
- 每个分数都必须带 ≥1 条 `reasons`，且 reason 里必须含**具体数字**；
- 「全部设备」时 `total_duration_seconds` 沿用既有求和不去重口径，
  `overlap_warning` 原样透出。

### 4.3 趋势（2C）

```
GET /api/v1/statistics/trends?days=7&device_id=all&tz_offset_minutes=480
GET /api/v1/statistics/trends?days=30&device_id=all&tz_offset_minutes=480
```

```jsonc
{
  "days": 7,
  "timezone": "Asia/Shanghai",
  "device_id": null,
  "from": "2026-09-30",
  "to": "2026-10-06",
  "daily": [{ "date": "2026-09-30", "total_seconds": 0, "has_data": false }],
  "categories": [{ "category": "development", "total_seconds": 8280, "ratio": 0.34 }],
  "focus_scores": [{ "date": "2026-09-30", "score": null }],
  "late_night_ratio": 0.12,          // 23:00–05:00 占比
  "platform_split": [{ "platform": "windows", "total_seconds": 18000, "ratio": 0.75 }],
  "top_apps": [{ "app_id": "com.tencent.mm", "app_name": "微信", "total_seconds": 9180 }],
  "insufficient_days": 0             // 无数据的天数，供界面标注
}
```

`days` 只接受 **7 或 30**（其它值 422）——定稿只要求这两档，
放开任意值等于允许一次拉整年。

**加载纪律（冻结，与定稿一致）**：
- 进入 `/usage/` **不**请求趋势；
- 打开「总结」页才请求 7 日；
- 点「近30日」才请求 30 日；
- 结果在当前页面缓存，切回不重复请求；
- **绝不**为趋势去请求每一天的完整时间线。

---

## 五、兼容性（冻结）

1. **旧客户端**：`/sync/push` 的 `applications` 协议不变，`user_applications` 表不变
   ⇒ Windows / Android 无需升级，**历史数据无需重传**；
2. **响应字段只增不减**：`StatisticsAppOut` / `AppUsageOut` 等只做加法，
   现有解析逻辑不受影响；
3. **归并影响面**（定稿要求"保存后立即生效"）：
   今日应用排行、往日应用排行、时间线、会话明细、设备对比、MCP 查询结果、后续总结
   —— 全部经由 1.3 的 A/B 两层归一化，因此只要两层都接上，就同时生效。
   实现上通过**不缓存归一结果**来保证"保存即生效"（每次请求重建映射表）。

---

## 六、实施与验收对应

| 步骤 | 内容 | 本文对应 |
|---|---|---|
| 第一步 | 审计与契约冻结 | 本文 |
| 第二步 | 应用目录持久化（迁移 + 服务层 + 隔离 + 优先级 + 归一 + 测试） | 第二、三节 |
| 第三步 | 应用整理界面 | 4.1 |
| 第四步 | 五维评价（规则 + 基线 + 原因 + 样本不足 + 测试） | 4.2 |
| 第五步 | 趋势页面（7/30 + 懒加载 + 缓存 + 手机适配） | 4.3 |
| 第六步 | 统一验证（网页 / 云端统计 / MCP / 隔离 / 归一 / 部署） | 交付文档逐条自查 |
