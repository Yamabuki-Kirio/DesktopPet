# 46 · Phase 2 交付说明（2A 应用整理 + 2B 五维总结 + 2C 趋势）

按定稿「实施顺序」六步执行完毕。**本机已完成代码与测试，未触碰线上服务器。**

基线：Phase 2 开始前 `pytest` **263 passed**；完成后 **311 passed（+48）**，零回归。

| 新增测试文件 | 项数 | 覆盖 |
|---|---|---|
| `tests/test_application_catalog.py` | 21 | 2A 应用身份管理与整理 |
| `tests/test_insights.py` | 14 | 2B 五维评价 |
| `tests/test_trends.py` | 13 | 2C 趋势 |

审计结论与契约冻结见 `docs/45`（第一步的产出）。

---

## 一、第一步：审计与契约冻结（`docs/45`）

审计发现三件影响设计的事，都已写进 `docs/45`：

### 1.1 ⚠️ 统计聚合发生在**两层**，且 Phase 1 只改了一层

| 层 | 服务模块 | 对外接口 | 谁在用 |
|---|---|---|---|
| A | `stats_service` | `/api/v1/stats/*`、`/api/v1/integrations/stats/*` | **MCP**、集成 |
| B | `statistics_service` | `/api/v1/statistics/*` | 网页（生活足迹）、App 云端统计 |

两层各自聚合、互不复用。Phase 1 只给 B 层加了归一化，
因此**MCP 会把 4 个微信子进程显示成 4 条**，直接违反本阶段验收项
「MCP 与网页显示相同应用名称」。
⇒ 2A **必须同时改两层并共用同一个实现**：`app/services/app_identity.py`（新增）。
这是本阶段的必做项，不是可选项。

### 1.2 决策：新增目录表，绝不动 `user_applications`

`user_applications` 的主键是**原始 app_key**，表达不了"一个统一应用对应多个原始名"，
也没有 `icon_key`；更关键的是它由**客户端同步推送**，冲突策略允许
"两边都是人工分类时按 updated_at 较新者胜"——网页写进去会被客户端推回覆盖。

因此新增两张表（迁移 **`0005_application_catalog`**，纯新增，生产数据无损）：

* `application_catalog`：统一应用（display_name / category / icon_key / source）
* `application_aliases`：原始名 → 统一应用，**`(user_id, raw_app_key)` 唯一**

`user_applications` 保持原样继续作为"客户端上传的应用库"，同步协议一字未改
⇒ **旧客户端零影响、历史数据无需重传**。

### 1.3 分类枚举（冻结）

`app/schemas/sync.py:APP_CATEGORIES` 就是全部合法值：
`development / productivity / gaming / social / entertainment / browser / system / other`。
新增的目录与接口一律复用，并有护栏测试守着（Phase 1 曾因自造分类导致客户端整体 422）。

---

## 二、第二步～第三步：2A 应用身份管理

### 2.1 归一优先级（与服务端实现一一对应）

| # | 规则 | 实现位置 |
|---|---|---|
| 1 | 用户手动指定的精确映射 | `application_aliases` 精确命中 → `match_type=alias` |
| 1b | **同一族的子进程跟随** | 内置主包名再查一次别名（见下方"踩坑"） |
| 2 | 内置精确映射 | `app_normalization.BUILTIN_TABLE` |
| 3 | Android 主包名匹配 | 命中项本身即主包名 |
| 4 | 去子进程后缀后匹配 | 递归剥 `:push` / `:tools` / `:service` / `:appbrand0` … |
| 5 | 无法识别 | 保留原始名，`recognized=false` |

`user_applications.display_name` 始终参与**显示名回退**（用户在客户端里改过的名字不丢）。

**归一化键用"代表性原始键"，不加前缀** —— 这是踩坑后的决定，见 2.4。

### 2.2 新增接口

```
GET    /api/v1/applications/catalog          统一应用目录（含别名、原始名、窗口内时长）
GET    /api/v1/applications/unrecognized     未识别进程 + "建议归入"目标
POST   /api/v1/applications/catalog          新建统一应用（可同时归入若干原始名）
PATCH  /api/v1/applications/catalog/{id}     改显示名 / 分类 / 图标
DELETE /api/v1/applications/catalog/{id}     删除（别名级联，原始名回到内置名）
POST   /api/v1/applications/aliases          新增/覆盖映射 —— 「合并到已有应用」走这里
DELETE /api/v1/applications/aliases/{id}     撤销映射（恢复原始显示）
```

身份用 `CurrentUserOrWeb`（网页 Cookie 或客户端 Bearer 都可）；
**写**操作要求 CSRF 对照值，但带 `Authorization` 时自动跳过（见 2.4 第 3 条）。
新增错误码：`catalog_not_found` / `catalog_duplicate` / `alias_not_found` / `alias_conflict`。

目录里的时长只统计**近 30 天**（一次分组查询，无 N+1）；
未识别项若"去掉后缀能命中内置表"会给出**建议目标**，用户点一下即可，不用手打名字。

### 2.3 网页整理界面（应用页 → `去整理 ›`）

右侧抽屉式，包含：

* **未识别进程列表**（最近 30 天）+ 建议归入 + 下拉选择目标 + 「＋ 新建应用…」（露出名称/分类输入）；
* **已归并的应用**：改显示名 / 改分类 / **查看该统一应用包含的所有原始名称**（可逐条撤销）。

保存后调 `afterMappingChanged()`：清空所有统计缓存并刷新当前视图
⇒ **保存即生效**（归一化本身不缓存，每次请求重建索引，代价是 3 条小查询）。

### 2.4 踩到的三个真缺陷（都已修 + 测试覆盖）

**① `app_id` 加前缀会打断"查看会话明细"**
最初把统一键做成 `builtin:xxx` / `raw:xxx`，结果前端把 `app_id` 传回来后，
后端按原始 `app_key` **等值**过滤 ⇒ 查不到任何记录；而且 11 项既有测试立刻变红。

修法：
* 统一键改为**代表性原始键** —— 内置命中 → 内置主包名本身（它也是一条真实原始名，
  所以旧调用方直接拿它过滤仍然有效）；未识别 → 原始名；别名命中 → `str(catalog_id)`；
* 新增 `AppIdentityIndex.matching_raw_keys()`，把统一键展开成它包含的全部原始名，
  `_load_sessions` 改用 `IN (...)`，末尾**总是**把 `app_id` 自己也放进结果
  ⇒ 旧调用方传任意原始名都能查到。

**② 给子进程建别名不会带动整族**
只给 `com.tencent.mm` 建别名时，`com.tencent.mm:tools` 仍走内置分组
⇒「微信」被拆成两条。修法两处：
* `resolve()` 内置命中后再用**内置主包名**查一次别名，让整族跟随；
* `_ensure_catalog_for_key()` 同时给**目标键本身**写一条别名
  （少了它，物化出来的目录行只会影响那一个字符串）。

**③ CSRF 把 Bearer 客户端永久 403**
`WebCsrf` 无条件要求 CSRF cookie，而 Windows / Android 客户端只发 Bearer、
根本没有这个 cookie ⇒ 永远 403，连整理映射都做不到。

修法：`require_web_csrf` 见到 `Authorization` 头即跳过。
理由写进了代码注释：**CSRF 攻击的前提是浏览器会自动附带环境凭据（Cookie）
；Bearer 必须由脚本显式放入请求头，跨站请求根本放不进去**，因此不存在被冒用的可能。

---

## 三、第四步：2B 五维评价

```
GET /api/v1/statistics/insights?date=…&device_id=…&tz_offset_minutes=…
```

### 3.1 五个维度的依据（全部为确定性纯函数）

| 维度 | 依据 | 实现 |
|---|---|---|
| 专注度 `focus` | 最长连续时段、短会话占比、应用切换次数 | `score_focus` |
| 使用节律 `rhythm` | 首末活动时间、四时段分布、深夜占比、与个人基线的**偏离** | `score_rhythm` |
| 使用强度 `intensity` | 设备累计时长 vs 平时、最长连续、段数 | `score_intensity` |
| 内容结构 `structure` | 分类占比、是否过度集中于单一应用、与平时用途差异 | `score_structure` |
| 跨设备 `cross_device` | Windows/Android 比例、多设备重叠、电脑使用时手机切换 | `score_cross_device` |

### 3.2 评分原则（定稿逐条落实）

* 分数 **0~100**；
* **每个分数都能解释**：每个维度至少 1 条 `reasons`，且**每条都含具体数字**
  （有测试逐条断言 `any(ch.isdigit())`）；
* **只与用户自己的近 7 日基线比较**，不使用任何社会标准判断好坏。
  例如"使用节律"不会因为"晚睡"扣分，只有**偏离你自己的常态**才扣分；
* **数据不足时不评分**：当天无记录，或基线有数据的天数 `< 3` ⇒
  `score`/`baseline_score`/`delta` 一律 `null`、`is_sample_sufficient=false`，
  并在 `insufficient_reason` 里说明"至少需要几天"；
  此时仍返回 `reasons`，让用户知道**缺的是什么**；
* 「全部设备」沿用既有 **求和不去重** 口径，`overlap_warning` 原样透出；
* 文字总结**由规则生成，不调用外部大模型** —— 分数要可解释，就要求计算路径完全确定。

界面上每个分数都可点开看「依据」列表，并显示"你自己近 N 天的基线是 X 分"。

---

## 四、第五步：2C 趋势

```
GET /api/v1/statistics/trends?days=7|30&device_id=…&tz_offset_minutes=…
```

返回：逐日总时长、分类占比、专注度趋势、深夜占比、平台比例、使用最多的应用、
无数据天数、多设备重叠提示。

* `days` **只接受 7 或 30**（其它值 422）——放开任意值等于允许一次拉整年；
* 逐日指标与评分**复用 `insights_service`**，不重写一套，避免口径漂移；
* **不为趋势去查每一天的完整时间线**，只做区间聚合（一次查询）。

**加载纪律（实测确认）**：

| 动作 | 请求 |
|---|---|
| 进入 `/usage/` | **不请求** trends、**不请求** insights |
| 打开「总结」页 | 请求 `insights`；趋势默认停在「今天」，**不请求** |
| 点「近 7 日」 | 请求 `trends?days=7` |
| 点「近 30 日」 | 请求 `trends?days=30` |
| 再切回「近 7 日」 | **0 次新请求**（命中页面缓存） |

「总结」页结构：今日文字总结 → 五维评价 → 趋势（今天 / 近 7 日 / 近 30 日）。
手机端底部 5 个 Tab **保持不变**，未新增入口。

### 4.1 前端踩到的一个渲染 bug（截图发现）

趋势柱状图**整排塌成一条线**：`.tb-fill` 用了 `height: X%`，
而父元素 `.tb` 的高度是 `auto` —— 百分比高度找不到确定参照，全部退化成最小值。

改成由 JS 直接给**像素**高度（`renderTrends` 里算 `BAR_MAX_PX`），
并把 `.tb` 设为 `height:100%` + 固定 `.trend-bars` 高度。
实测柱高 `[44,61,36,3,52,96,71]`（其中 3px 是"当天无数据"的灰柱）。

> 教训：**百分比高度依赖父元素的确定高度**，在 flex 布局里尤其容易静默退化——
> 这类问题不会报错、只是"看着不对"，必须靠截图/实测几何来发现。

---

## 五、验收结果

### 5.1 定稿验收标准逐条自查

| 验收项 | 结果 |
|---|---|
| 微信等子进程只显示一条统一应用 | ✅ 网页与 MCP 均只有 1 条（有测试） |
| 原始进程名仍可查看 | ✅ `raw_app_keys` / `raw_app_key`，界面可展开 |
| 用户可以修正错误映射 | ✅ 同一原始名再次提交即改指（测试覆盖） |
| 删除映射后可以恢复原始显示 | ✅ 删别名恢复原始名；删目录项回到内置名 |
| 映射不能影响其他账户 | ✅ 三处 404 测试（读目录 / 改 / 删别名） |
| 历史数据无需重传即可生效 | ✅ 建映射后旧日期立即用新名字 |
| 同一时段不能因子进程归并而重复累计 | ✅ 重叠区间取并集，不翻倍 |
| MCP 与网页显示相同应用名称 | ✅ 两层共用 `AppIdentityIndex`（测试钉死） |
| 五个评分都有计算依据 | ✅ 每条 reason 含数字（测试断言） |
| 数据不足时不生成虚假评价 | ✅ `score=null` + 原因文案 |
| 7 日和 30 日趋势按需加载 | ✅ 实测请求序列见 5.2 |
| 初次打开页面的请求数量不增加 | ✅ 首屏仍是 `me` + `devices` + `summary`（+1 个未识别徽标查询） |
| 现有登录、今日统计、往日分页和时间线无回归 | ✅ 311 passed |
| 禁止修改或覆盖原始活动片段 | ✅ 有测试：建/改/删映射后活动段与应用库**一行未变** |

### 5.2 本机实测（临时 mock 后端，复现生产同源拓扑）

| 场景 | 结果 |
|---|---|
| 首屏 | 只请求 `web-session/me`、`devices`、`summary`、`applications/unrecognized`（徽标用）；**无** insights / trends |
| 应用页 | 「⚠ 发现 1 个未识别进程」，点「去整理」打开抽屉 |
| 整理抽屉 | 未识别进程 + 建议归入 + 目标下拉 + 「＋ 新建应用…」（选中后露出名称/分类输入）；已归并应用可改名 / 改分类 / 查看原始名 / 撤销 |
| 总结页 | 五维评价（5 个分数 + 基线差 + 可展开依据）；总结文字由服务端规则生成；趋势默认「今天」不额外请求 |
| 趋势 7 日 | 请求 `trends?days=7`，柱状图（实测像素高 `[44,61,36,3,52,96,71]`）+ 分类占比 + 平台比例 + 深夜占比 + 最多应用 + 专注度逐日 |
| 趋势 30 日 | 请求 `trends?days=30` |
| 切回 7 日 | **0 次新请求**（页面缓存） |
| 控制台 | 无 JS 错误 |

预览截图：`C:\下载\usage-preview\6-应用整理抽屉.png`、`7-总结页-五维与趋势.png`、`8-应用页.png`。

---

## 六、需要上传的文件

### 6.1 PetLife 服务端

**新增**

```
app/models/application_catalog.py
app/schemas/applications.py
app/services/app_identity.py
app/services/application_catalog_service.py
app/services/insights_service.py
app/services/trends_service.py
app/api/v1/applications.py
migrations/versions/0005_application_catalog.py
```

**改动**

```
app/models/__init__.py           导出新模型
app/schemas/stats.py             导入 uuid/Field；AppUsageOut 增字段
app/schemas/statistics.py        洞察/趋势 schema；StatisticsAppOut 增 icon_key/catalog_id
app/core/errors.py               新增 4 个应用目录错误码
app/security/deps.py             require_web_csrf 支持 Bearer 跳过
app/services/stats_service.py    get_apps/get_categories 接入归一化
app/services/statistics_service.py  改用 AppIdentityIndex；统一键展开过滤；UsageSession 增 platform
app/api/v1/statistics.py         新增 insights / trends 路由
app/api/v1/router.py             挂载 applications.router
tests/test_migrations.py         EXPECTED_TABLES 增两张表
```

**测试（建议一并上传）**：`tests/test_application_catalog.py`、`tests/test_insights.py`、`tests/test_trends.py`

### 6.2 网页

```
game.html           无改动（Phase 2 不需要再动它）
usage/index.html    新增五维/趋势区块与整理抽屉；资源版本 → ?v=20261006-4
usage/usage.css     分段控件、五维、趋势、抽屉样式
usage/usage.js      2A/2B/2C 全部前端逻辑
```

---

## 七、部署步骤

### 7.1 上传

按 6.1 / 6.2 上传到 `/www/wwwroot/8.163.22.28/` 对应位置。

### 7.2 ⚠️ 必须执行迁移（本阶段新增了表）

```bash
cd /www/wwwroot/8.163.22.28/petlife
docker compose run --rm migrate
```

**这次不是幂等空跑**：`0005_application_catalog` 会建 `application_catalog`
与 `application_aliases` 两张表。不跑迁移的话，应用目录相关接口会因缺表而 500。

验证：

```bash
docker compose run --rm api alembic current
# 期望输出 0005_application_catalog (head)
```

### 7.3 重建并启动

```bash
docker compose build api
docker compose up -d api
docker compose logs --tail=80 api
```

冒烟：

```bash
curl -sS http://127.0.0.1:8000/health
# 新接口未登录应 401（而不是 404 —— 404 说明路由没挂上）
for p in applications/catalog applications/unrecognized \
         "statistics/insights?date=2026-10-06" "statistics/trends?days=7"; do
  curl -s -o /dev/null -w "$p -> %{http_code}\n" "http://127.0.0.1:8000/api/v1/$p"
done
```

### 7.4 Nginx

**无需改动**（仍是 `/petlife-api/` 同一前缀）。

### 7.5 验收步骤

1. 清除站点 Cookie 或用无痕窗口，打开 `/usage/`；
2. 确认**立即**出现 PetLife 登录框，登录成功后才显示数据（这两条是上一轮修复的）
3. 进「应用」页 → 确认 `⚠ 发现 N 个未识别进程` 与 `去整理 ›`；
4. 打开整理抽屉 → 选一个未识别进程 → 归入「微信」→ 保存；
5. 回「今日」页确认它已并入「微信」一条（**没有重传任何数据**）；
6. 回抽屉点「查看原始名」确认原始进程名仍可追溯；点「撤销」确认恢复原始显示；
7. 进「总结」页 → 确认五维分数与依据（样本不足时应显示"样本不足"而非 0 分）；
8. 点「近 7 日」「近 30 日」→ 用 DevTools Network 确认**只有点击时才请求** `trends`；
9. 用 MCP 查询应用排行，确认与网页显示**同名同量**；
10. 用另一个账户登录，确认看不到上面建立的映射。

---

## 八、遗留与下一增量

**已知限制**：

* 趋势里的「专注度趋势」用**窗口内均值**作为比较口径（不是"该日之前的 7 日"）。
  这样能让窗口内每天都可比；若改成逐日前推基线，前几天的基线会为空、
  几乎全是"样本不足"。已在代码注释里说明。
* 「使用节律」的时间偏离用普通平均（未处理跨午夜），对极端夜型作息会有偏差；
  文案里给出的是"比平时晚/早 X 分钟"，可解释性优先于精确性。
* 应用目录的时长窗口固定为 30 天（`window_days` 可传参但不对外暴露）。
* 多设备"手机在电脑使用期间的切换次数"只在两平台会话有时间交集时统计，
  这是一个**保守下界**（不是精确的注意力切换次数）。

**下一增量候选**（本阶段未做，定稿也未要求）：

* `✨ 生成详细总结`（AI 深度总结）—— 可选增强，不是基础功能依赖；
* 整理界面的**批量整理**（一次把多个未识别进程归到同一应用）与
  "以后自动归并"（把用户规则提升为账号级默认）；
* 目录项的**图标可视化**（当前 `icon_key` 已下发，前端仅作标识使用）。
