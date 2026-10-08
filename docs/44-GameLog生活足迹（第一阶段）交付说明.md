# 44 · GameLog「生活足迹」第一阶段交付说明

按定稿的「实施顺序」1–9 条执行完毕。**本机已完成代码与测试，未触碰线上服务器。**

基线：改动前 `pytest` **211 passed**；改动后 **263 passed（+52）**，零回归，无跳过。

> **修订记录**
> - v1：第一阶段首次交付。
> - **v2（2026-10-06 夜）：修复「未登录却不显示登录界面」的前端回归**，详见第九节。
>   该回归由用户真机验收发现，**v1 的登录入口设计有缺陷**，本节记录根因与改法。
> - **v3（2026-10-06 深夜）：API 请求禁用缓存 + 拒绝 HTML 冒充成功响应**，见 9.8。
>   网页资源版本现为 `?v=20261006-3`。

---

## 一、做了什么（对应定稿实施顺序）

| # | 定稿要求 | 落地 |
|---|---|---|
| 1 | 审计本机 PetLife 服务端真实接口和模型 | ✅ 结论见 `docs/43`（含 5 处定稿与真实代码的冲突） |
| 2 | 固化接口契约和统计口径 | ✅ `docs/43` 第二、三节 |
| 3 | 完成 Web Session 后端及测试 | ✅ 4 个接口 + 24 项测试 |
| 4 | 完成历史日期摘要接口及测试 | ✅ `GET /statistics/days` + 28 项测试 |
| 5 | 完成 usage/ 页面 | ✅ `usage/index.html` + `usage.css` + `usage.js` |
| 6 | 修改 game.html，只增加一个入口 | ✅ 5 处改动，均为加法 |
| 7 | 增加 `?demo=1` 演示模式 | ✅ 生产默认禁用，演示时显式标注横幅 |
| 8 | 完成桌面端和手机端响应式测试 | ✅ 1280×900 与 390×844 实测（见第五节） |
| 9 | 输出上传、迁移、Docker 和 Nginx 部署说明 | ✅ 本文第六节 |
| 附加 | 服务端应用归一化（定稿第八节） | ✅ `app/services/app_normalization.py`（不落库，见第 4 节） |

**没有迁移脚本**（重要）：本阶段所有新增能力都建立在既有表上，
`alembic upgrade head` 无需新增版本。下一增量引入应用目录/别名表时才会加 `0005`。

---

## 二、改动文件清单

### 2.1 需要上传到线上的文件

**PetLife 服务端**（上传到 `/www/wwwroot/8.163.22.28/petlife/server/`）

| 文件 | 状态 | 说明 |
|---|---|---|
| `app/core/config.py` | 改 | 新增 3 个 `web_session_*` 配置项 |
| `app/core/errors.py` | 改 | 新增 `csrf_token_invalid` / `web_session_expired` 错误码 |
| `app/security/deps.py` | 改 | 抽出 `_user_from_access_token`；新增 `CurrentWebUser` / `CurrentUserOrWeb` / `WebCsrf` |
| `app/security/web_session.py` | **新** | Cookie 装载 + CSRF 校验 |
| `app/schemas/statistics.py` | 改 | 新增 `DaySummaryOut` / `DaySummaryPageOut` / `DAYS_PAGE_SIZE`；`StatisticsAppOut`、`UsageSessionOut`、`TimelineEntryOut` 增字段 |
| `app/schemas/web_session.py` | **新** | 网页会话 schema（响应体不含明文令牌） |
| `app/services/app_normalization.py` | **新** | 应用归一化（内置表 + 子进程剥离 + 解释） |
| `app/services/auth_service.py` | 改 | `_issue_bundle` / `create_session` / `refresh_session` 增加 `access_ttl_minutes` 可选参数 |
| `app/services/statistics_service.py` | 改 | 新增 `AppNormalizer` 与 `get_day_summaries`；汇总/会话/时间线全部改走归一化 |
| `app/api/v1/devices.py` | 改 | `GET /devices` 支持网页会话身份 |
| `app/api/v1/router.py` | 改 | 挂载 `web_session.router` |
| `app/api/v1/statistics.py` | 改 | 新增 `GET /statistics/days`；4 个统计端点改用 `CurrentUserOrWeb` |
| `app/api/v1/web_session.py` | **新** | `/api/v1/web-session/*` 路由 |

**测试**（上传与否不影响运行，但建议一并上传以便线上复核）

| 文件 | 状态 |
|---|---|
| `tests/conftest.py` | 改（新增两个测试环境变量默认值） |
| `tests/test_web_session.py` | **新**（24 项） |
| `tests/test_statistics_days.py` | **新**（28 项） |

**网页**（上传到 `/www/wwwroot/8.163.22.28/`）

| 文件 | 状态 | 说明 |
|---|---|---|
| `game.html` | 改 | 只新增 1 个导航入口（5 处改动，见 3.1） |
| `usage/index.html` | **新** | 页面结构 |
| `usage/usage.css` | **新** | 主题变量与基础样式取自 game.html，变量名一致 |
| `usage/usage.js` | **新** | 数据与交互 |

**不需要上传**：`C:\下载\_verify\`（本次验收的截图与临时脚本）、`docs/43`、`docs/44`（仓库文档）。

### 2.2 本地验收产物（均不属站点内容，**不要上传**）

```
C:\下载\usage-preview\        # 页面预览截图
├─ 1-桌面端-樱花粉.png
├─ 2-桌面端-深夜黑.png
├─ 3-手机端.png
├─ 4-手机端-未登录.png         # v2 修复后：登录框立即可见
└─ 5-桌面端-未登录.png         # v2 修复后：同上

C:\下载\_mock\
├─ mock_server.py              # 本机自验用的 mock 后端（见第 9.7 节）
└─ serve_html_masquerade.py    # 模拟"代理把 /petlife-api/* 交给静态站点"的故障（见 9.8）
```

---

## 三、逐项实现说明

### 3.1 game.html：只增加一个入口（定稿第 13 条）

5 处改动，全部是加法，**未删除任何一行**：

| 行号 | 改动 |
|---|---|
| 289 | 新增 `.nav-bg-btn.nav-usage { gap: 4px; }` |
| 290 | 新增 `.nav-usage-label { display: none; }`（桌面端不显示文字） |
| 327 | 窄屏媒体查询内：`.nav-bg-btn.nav-usage { width:auto; padding:0 10px; ... }` |
| 328 | 窄屏媒体查询内：`.nav-usage-label { display: inline; }` |
| 1925 | 导航里新增 `<a class="nav-bg-btn nav-usage" href="usage/" title="查看 PetLife 使用记录">⏱<span class="nav-usage-label">生活足迹</span></a>` |

实测（浏览器）：

| 视口 | 结果 |
|---|---|
| 1280×900 | 宽 **36px**、标签 `display:none`（与 🖼📖🌸 一致，纯图标）、底部 Tab `display:none` |
| 390×844 | 宽 **82px**、标签 `display:block`、**y=62 落在导航第二行**、底部 Tab 仍是 **5 项**（日记/笔记/写日记/音乐/主题） |

`href="usage/"` 而非 `usage.html`（定稿第 14 条）——目录形式，
所以**不能**再有根目录的 `usage.html`。

### 3.2 Web Session（定稿第 5、6 条）

四个接口：`POST /api/v1/web-session/{login,refresh,logout}`、`GET /api/v1/web-session/me`。

| Cookie | HttpOnly | Path | 内容 |
|---|---|---|---|
| `pl_web_at` | ✅ | `PETLIFE_WEB_SESSION_COOKIE_PATH`（默认 `/petlife-api/`） | Access JWT |
| `pl_web_rt` | ✅ | 同上 | Refresh 不透明串 |
| `pl_web_csrf` | ❌ | `/` | Double-submit CSRF 对照值 |

三个关键设计决定（都写进了代码注释）：

1. **CSRF Cookie 的 Path 必须是 `/`**：`document.cookie` 只暴露路径匹配当前文档的
   Cookie，页面在 `/usage/`，若它也设成 `/petlife-api/`，页面 JS 读不到，
   Double-submit 直接失效。它本身不是凭据，放宽路径是安全的。
2. **Path 是部署事实，不是代码常量**：反向代理会剥掉 `/petlife-api/`，
   但 `Set-Cookie` 会被原样透传给浏览器，因此这里必须与**浏览器看到的前缀**一致。
   配置项带 `field_validator` 自动补尾斜杠——`Path=/petlife-api`（漏尾斜杠）
   在 RFC 6265 下不匹配 `/petlife-api/api/v1/...`，表现为"登录成功但一直未登录"。
3. **令牌复用既有 `refresh_tokens` 表**：`auth_service` 的签发 / 轮换 / 复用检测 /
   吊销逻辑一行未改，因此"客户端与网页看到同一份数据""注销一处即全局失效"是结构保证。
   网页 Access 有效期为配置里的 30 分钟（客户端仍是 15 分钟），避免长驻标签页频繁续期。

`GET /api/v1/devices` 与 4 个 `/statistics/*` 端点改用 `CurrentUserOrWeb`
（Bearer **或** Cookie），二者最终走同一个 `_user_from_access_token`，
权限判定与账户状态检查完全一致。

### 3.3 历史日期摘要（定稿第 3 条）

```
GET /api/v1/statistics/days?before=2026-10-06&limit=7&device_id=all&tz_offset_minutes=-480
```

- `before` 是**不包含**的上界；`limit` 默认与**上限**都是 7（传 30 会 422，
  避免有人用它绕过"每次只加载 7 天"）；
- 按日期**倒序**；`next_before` 取**本页最后一天**（下一页从此往前，不重不漏）；
- 翻到该账户**最早一条记录**就停，`has_more=false` / `next_before=null`
  ——否则界面会一直显示「加载更早的 7 天」，用户点到手软也没结果；
- 账户一条记录都没有时返回**空页**，而不是 7 个空行
  （后者会让界面出现"7 天都是 0 分钟"的假象）；
- 一次只查一页（最大 7 天），连续区间合并成**一个**查询窗口，不做 N+1；
- **只读**：有测试断言查询前后各表行数不变。

`device_count` 定义为"该日**有活动记录**的设备数"，不是账户设备总数
（已写入 `DaySummaryOut` 的注释）。

### 3.4 应用归一化（定稿第 8 条）

`app/services/app_normalization.py`，纯函数 + 只读，**不落库、不加迁移**。

归一顺序严格照定稿：① 用户应用库（`user_applications`，含用户改过的显示名/分类）
→ ② 主包名精确匹配 → ③ 可执行名/别名精确匹配 → ④ 剥掉子进程后缀
（`:push` / `:tools` / `:service` / `:appbrand0` …，**按分隔符递归剥离**，
不依赖白名单，所以 `:some_new_thing` 也能正确处理）→ ⑤ 都不中则保留原始名并标 `recognized=false`。

**为什么第一阶段不建 `application_catalog` / `application_aliases`**
定稿自己写着"能扩展现有表就不要重复建表"，末尾也明确允许把"完整编辑能力"
拆到下一增量，且要求第一阶段的数据展示必须保留
`raw_app_key` / 当前显示名 / 是否已归一化 / 未识别标记。
本项目因此让 `StatisticsAppOut`、`UsageSessionOut`、`TimelineEntryOut`
都带上 `raw_app_keys` / `recognized` / `normalized`，并且**归一后的 key 直接用于聚合分组**——
所以手机上报的 4 个微信进程名会合成**一条**，时长按区间并集算，不会翻 4 倍。
下一增量把第 ① 步接到新表上即可，**对外字段不用推翻**。

**踩到的真 bug（已修）**：分类枚举是**固定集合**
（`development` / `productivity` / `gaming` / `social` / `entertainment` / `browser` / `system` / `other`），
我最初的内置表写了 `work` / `news` / `shopping` / `game` 这些"看起来合理"的值——
后果不是显示成灰色，而是客户端同步 `user_applications` 时整体 422。
现已重写，并加了两道护栏：模块导入时断言 + `test_builtin_categories_are_within_the_allowed_enum`。

### 3.5 usage/ 页面

布局与加载纪律（定稿第二、四、七节）：

- 顶部导航：`⏱ GameLog` + 生活足迹标签 + `[今日][应用][时间线][总结]` + 设备下拉 + 🌸 + `← 返回日记`；
- 窄屏底栏：`今日｜应用｜时间线｜往日｜总结`（**5 项，无写入按钮**，只读页）；
- 同步状态条：正常显示 `设备名 · 最近同步 21:36`；无数据显示 `… 尚未上传数据`；
- 日期标题栏：`2026年10月6日 · 星期二` + `今天` 徽章 + `‹` `回到今天` `›`（未来日期禁用）；
- 今日主卡：总时长作大标题，其余两列（窄屏单列），底色用极淡主题渐变，
  有 `overlap_warning` 时显式展示提示；
- 今日应用：日记卡片风（非表格），每项显示名称 / 分类 / 时长 / 占比 / 时段数 / 未识别标记；
  默认前 5，可展开全部；归一过的应用可点「查看原始进程（N）」看到
  `com.tencent.mm / com.tencent.mm:tools`；
- 今日时间分布：**先只画四根柱**（凌晨/上午/下午/晚上），点时段才在该视图内筛选
  （时间线本身也是点进「时间线」才请求）；
- 往日记录：默认折叠，展开才第一次请求，每次 7 天，行尾「加载更早的 7 天」；
- 未识别进程：底部不显眼一行 `有 N 个未识别进程  去整理 ›`；
- 今日总结：**规则生成、不调大模型**，一句话状态只给可解释的依据，
  并明确写出"五维评价属于第三阶段，本页不会先给一个无法解释的分数"。

**请求纪律**（实测）：普通访问只发 `web-session/me` + `devices` + `statistics/summary`
三个请求；`statistics/days` **只在展开往日时**出现；`timeline` 只在点「时间线」或
「载入今日时间分布」时出现；已看过的日期缓存在本页，返回时不重复请求。

### 3.6 演示模式（定稿第 15 条）

- 仅 `?demo=1` 启用；`?demo=1` 之外**任何情况都不会回退到假数据**；
- 演示时顶部显示醒目的「演示数据…**不是**你的真实使用记录」横幅，同步条显示"未连接 PetLife 服务端"；
- 实测无 `?demo=1`（且没有反向代理）时的表现：同步条 `无法连接 PetLife 服务`，
  主区域 `⚠️ 请求失败（HTTP 404）/ 接口不存在或该日期没有数据 / 重试`——
  正式错误状态，不是假数据。

### 3.7 密钥隔离（定稿第 7 条）

- `usage/usage.js` 不出现任何密钥，不读 game.html 的管理密钥；
- 网页只走 PetLife 邮箱密码 + HttpOnly Cookie；
- 载荷实测：`Select-String -Pattern "plk_"` 在 `usage/*` 与 `game.html` 上**零命中**；
- 登录卡文案也明确写了"这里的登录与游戏日记的管理密钥互不相通"。

---

## 四、统计口径：没有改动的部分

以下既有口径**一字未改**，并有既有测试守着：

| 口径 | 约束 |
|---|---|
| 全部设备 | 各设备时长**求和不去重**，`overlap_warning` 非空 |
| 同设备同应用 | 区间并集去重（`_effective_seconds`） |
| 时间线展示合并 | 同设备同应用、间隔 ≤ **60s**；前端不再自行合并、不自创阈值 |
| 跨午夜 | 按用户时区本地午夜切分 |
| 会话分页 | `next_cursor`（base64 `started_at\|id`），不重不漏 |
| 时区 | IANA 名优先，缺 tzdata 走内置回退表，都不行报 422；`tz_offset_minutes` −720~840 |
| 只读 | 统计接口不写任何表 |

归一化**没有**改变上述任何一条：它只把"哪些 `app_key` 属于同一个应用"这件事
从"精确相等"改成"归一后相等"，并相应地把分组的第二个键由 `app_key` 换成归一键。
跨设备求和、60s 合并、跨午夜切分的行为都有既有测试与新测试双重覆盖。

---

## 五、验收结果（本机实测）

| 项 | 结果 |
|---|---|
| `pytest` 全量 | **263 passed / 0 failed**（基线 211） |
| 新增测试 | `test_web_session.py` **24 项**、`test_statistics_days.py` **28 项** |
| 桌面端 1280×900 截图 | `_verify/desktop.png`：与 game.html 同一视觉语言（毛玻璃导航、20px 圆角、粉色渐变、光斑、同款滚动条） |
| 手机端 390×844 截图 | `_verify/mobile.png`：`.hero-grid` 单列、底栏 `position:fixed` 且**滚动前后 bottom 都等于视口高度**、`padding-bottom` 66px 不被遮挡 |
| game.html 桌面端 | 入口 36×36 纯图标，底部 Tab 隐藏 |
| game.html 窄屏 | 入口 82×30 落在**第二行**（y=62），底部 Tab 仍 5 项 |
| 时间线抽查 | 09:04—09:17 微信 13分 / 14:10—15:02 VS Code 52分，时段聚合（上午 1时56分、下午 2时03分、晚上 30分、凌晨空）全部正确 |
| 时段筛选 | 点「下午」→ 只留 12:30 后的 4 条；点「凌晨」→ "这个时段没有记录" |
| 应用详情 | 展开显示"设备 · 分类 · 原始会话段数 · 原始进程" |
| 演示模式 | 横幅 ON、同步条"演示模式"、往日 7 天按需加载正常 |
| 非演示 + 无后端 | 显示正式错误状态，**未**回退假数据 |
| 控制台 | 无 JS 错误 |

验收过程中发现并修掉的两个真问题（都是我自己写的，已复测）：

1. **演示时间线的字段映射错位**：原来用数组下标取字段，`platform: r[5]` 实际取到了
   数字 `8`，时间线视图直接抛 `toLowerCase is not a function`。
   已改为对象字面量（顺带让字段名与真实接口对齐），并保留防御——
   服务端 `TimelineEntryOut` **本来就没有** `platform` 字段，前端不得假设它有。
2. **"活跃设备"措辞不准确**：`summary` 不返回"当天有活动的设备"，
   原标签会让人以为"这天用过这台设备"，已改为**账户设备**。

---

## 六、部署步骤（由用户执行）

### 6.1 上传

```
# PetLife 服务端（13 个 app 文件 + 2 个测试，见 2.1）
上传至  /www/wwwroot/8.163.22.28/petlife/server/

# 网页
game.html        →  /www/wwwroot/8.163.22.28/game.html
usage/           →  /www/wwwroot/8.163.22.28/usage/     （整个目录）
```

上传后确认线上**没有**根目录的 `usage.html`（与 `usage/` 同名会误读）。

### 6.2 环境变量

在 `petlife/server/.env` 增加（都有默认值，**可以不改**）：

```ini
# 生产 HTTPS 必须保持 true（默认值）
PETLIFE_WEB_SESSION_COOKIE_SECURE=true
# 反向代理剥掉的前缀，必须与浏览器看到的一致
PETLIFE_WEB_SESSION_COOKIE_PATH=/petlife-api/
# 网页会话 Access 有效期（分钟）
PETLIFE_WEB_SESSION_ACCESS_TTL_MINUTES=30
```

本地 http 调试时把 `COOKIE_SECURE` 设为 `false`，否则浏览器不会回传 Cookie。

### 6.3 迁移

**本阶段没有新增迁移**，但按流程仍建议跑一次（幂等）：

```bash
cd /www/wwwroot/8.163.22.28/petlife
docker compose run --rm migrate
```

### 6.4 重建并启动

```bash
cd /www/wwwroot/8.163.22.28/petlife
docker compose build api
docker compose up -d api
docker compose ps
docker compose logs --tail=80 api
```

冒烟：

```bash
curl -sS http://127.0.0.1:8000/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/v1/web-session/me
# 期望：401（未登录），而不是 404 —— 404 说明路由没挂上
```

### 6.5 Nginx

```nginx
location /petlife-api/ {
    proxy_pass http://127.0.0.1:8000/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 30s;
}
```

`proxy_pass` 末尾的 `/` **必须保留**：它把 `/petlife-api/` 剥掉，
`/petlife-api/api/v1/devices` → `/api/v1/devices`。
`Host` 头不能漏，否则 Cookie 域不匹配、登录态丢失。

**改配置前先验证，不要只凭配置猜**：

```bash
nginx -t && nginx -s reload
curl -sS -i https://<你的域名>/petlife-api/health | head -5
# 期望 200 + {"status":"ok",...}；404 说明前缀没剥对
curl -sS -o /dev/null -w '%{http_code}\n' https://<你的域名>/petlife-api/api/v1/web-session/me
# 期望 401
curl -sS -o /dev/null -w '%{http_code}\n' https://<你的域名>/usage/
# 期望 200
```

### 6.6 真机验收清单

- [ ] 打开 `/game.html`：导航出现 `⏱`（桌面纯图标 / 手机显示「⏱ 生活足迹」在第二行），底部仍是 5 个 Tab
- [ ] 点它跳到 `/usage/`，**视觉上像同一个产品**（毛玻璃导航、20px 圆角、粉色渐变、光斑、滚动条）
- [ ] 未登录时出现 PetLife 登录卡；用 PetLife 邮箱密码登录成功
- [ ] **DevTools Network 只有 3 个请求**：`web-session/me`、`devices`、`statistics/summary`
- [ ] 控制台**没有** `statistics/days` 请求（历史默认折叠、无偷跑）
- [ ] 展开「往日记录」→ 才出现一次 `statistics/days?before=…&limit=7`
- [ ] 点某一天 → 回到今日视图并显示该日数据；返回时不重复请求（缓存命中）
- [ ] 点「时间线」→ 才出现 `statistics/timeline`
- [ ] 点某应用「查看会话明细」→ 才出现 `statistics/sessions?app_id=…`
- [ ] 设备下拉能按 device_id 筛（多台 Windows / 多台 Android 分开列出）
- [ ] 选「全部设备」且 ≥2 台设备时，主卡出现"累计时长可能包含重叠"的提示
- [ ] 手机端（Android）上报的子进程（如 `com.tencent.mm:tools`）已并到「微信」一条；
      点「查看原始进程」能看到原始名
- [ ] 未识别进程显示「未识别」标记 + 底部「去整理」入口
- [ ] 在足迹页切到🌙深夜黑，回 `/game.html` 仍是深夜黑（共用 `gamelog_theme`）
- [ ] 手机端内部列表滚动**不带动整页**错位；底栏不遮挡内容
- [ ] `/usage/?demo=1` 显示「演示数据」横幅；去掉参数后**不出现**任何示例数据
- [ ] 查看 `usage.js` / `usage/index.html` 源码：**grep 不到 `plk_`**
- [ ] 反向验证：只带 GameLog 管理密钥访问 `/usage/`，**读不到**任何 PetLife 数据

---

## 七、遗留与下一增量

**明确未做**（不是遗漏，是定稿允许分期）：

1. **应用目录/别名的落库与编辑**：`application_catalog` + `application_aliases` 表、
   迁移 `0005`、编辑接口、管理界面。当前「去整理」按钮只给说明，不能改。
   前端数据结构已为此预留（`raw_app_keys` / `recognized` / `normalized`），**不需要推翻**。
2. **五维评价**（专注程度 / 使用节律 / 内容结构 / 使用强度 / 跨设备状态）
   与 7 日 / 30 日个人基线：需要 `GET /statistics/insights`。
   本页现在**故意不给分数**——给了就必须能解释出处。
3. **AI 深度总结**按钮（`✨ 生成详细总结`）：可选增强，不是基础功能依赖。
4. 无限滚动、整月日历（定稿明确要求不做）。

**已知限制**：

- 网页会话的静默续期在 Access 过期那一刻会多一次往返（先 401 → 续期 → 重放），
  这是有意为之：前端不信任本地时钟，以服务端 401 为准。
- `days` 的 `has_more` 以"该账户最早一条活动记录"为界；
  若某账户只同步过 `daily_usage` 而没有 `activity_segments`，会被判定为"没有更早数据"。
  这在当前同步链路下不会发生（客户端总是上传逐条会话），但值得记下。
- 本阶段前端不做本地排序/筛选，一切以服务端返回为准。

---

## 九、v2 修复：未登录却不显示登录界面（前端回归）

### 9.1 现象与定性

真机验收：打开 `/usage/` 时**没有**弹出 PetLife 登录框，页面呈"有导航、无内容"的空壳。
当时账户确实没有 PetLife 网页会话，因此 `GET /petlife-api/api/v1/web-session/me`
本就应当返回 401。

**这是前端缺陷，不是数据/服务端问题。** 用户判定验收不通过是正确的。

### 9.2 根因

v1 用的是 **fail-to-blank**：登录框在 HTML 里**默认隐藏**，靠 JavaScript 拿到 401
之后**再去**显示。这条链上任何一环没跑到，页面就停在既无登录框、也无数据的空壳：

| 失效点 | 后果 |
|---|---|
| 身份判定不是 401，而是 404（`/petlife-api/` 尚未反代） | 走"连接失败"分支 → 但若该分支本身没把登录框显示出来，就是空壳 |
| `usage.js` 未执行（缓存旧版 / 404 / 脚本异常） | 根本没有 JS 去显示登录框，页面永久空壳 |
| 首次渲染期间 | 登录框与数据都还没有，用户看到的是空白 |

**设计错误本身**：把"未认证"当成了一个**需要被推导出来的异常**，
而不是**默认状态**。正确的默认假设是"不知道是否已登录 ⇒ 先当未登录处理"。

### 9.3 改法（改为 fail-to-login）

核心原则：**先假设未登录；只有服务端确认过会话，才允许隐藏登录框。**

1. **登录框默认可见**：`usage/index.html` 里改为 `<div class="login-mask show" id="loginMask">`。
   这样即使 `usage.js` 完全没跑起来，用户看到的仍然是登录框（而不是空白）。
2. **身份四态显式化**：新增 `S.auth ∈ {checking, anon, ready, error}`，
   由 `setAuth()` 统一驱动，**"未登录"与"已登录但当天无记录"在代码与文案上彻底分开**。
3. **`verifySession()` 才算已登录**：`GET /web-session/me` 必须成功**且真的带回 `user`**，
   才 `hideLogin()`。登录接口返回 200 **不**代表会话可用——
   Cookie 可能因 `Path` / `Secure` / `SameSite` 不匹配而根本没被浏览器保存。
4. **登录流程按要求重排**：
   `输入邮箱密码 → POST /web-session/login →（服务端写 HttpOnly Cookie）→
   GET /web-session/me 验证 → 隐藏登录框 → 加载设备与今日统计`。
   实测请求顺序确认为 `login → me → devices → summary`。
5. **常驻账户入口**：导航新增 `👤 账户` 下拉。未登录显示「登录 PetLife」、
   已登录显示邮箱 + 刷新/退出、接口异常显示「重新检测」。
   **即使登录弹层被关掉，用户始终有一条明确的登录路径。**
6. **404 与未登录区分开**：404 → 「网页登录接口尚未部署」+「重新检测」；
   401/403 → 正常的登录卡。绝不把两者都渲染成"没有数据"。
7. **运行期会话丢失统一收敛**：新增 `markSessionLost()`，
   任何受保护接口的 401（含续期失败）都走它回到未登录态并清空缓存与视图，
   避免每个调用点各写一套；**登录/续期接口自身的 401 原样抛给调用方**，
   免得把"密码错误"渲染成"会话过期"。
8. **退出登录清干净**：`resetCachedData()` 清 CACHE / DEVICES / 历史列表 / 视图状态，
   防止下一个账户看到上一个账户的残留。
9. **兜底提示**：`index.html` 内联 2.5s 定时器，若 `window.doWebLogin` 仍不存在，
   在登录卡上提示"页面脚本未能加载，请强制刷新"，
   避免用户对着一个没反应的登录框反复试密码。
10. **资源版本**：`usage.css?v=20261006-2` / `usage.js?v=20261006-2`，破浏览器缓存。

顺带修掉两处文案缺陷：登录卡里 `**邮箱和密码**` 的星号被原样显示（HTML 不渲染 Markdown），
已改成 `<b>`；404 的错误提示原为"接口不存在或该日期没有数据"（误导），
已改为"请确认反向代理已把 `/petlife-api/` 转发到 PetLife 服务"。

### 9.4 四种状态的表现（定稿第 5 条）

| 状态 | 登录框 | 状态条 | 主体区 | 账户按钮 |
|---|---|---|---|---|
| 确认中 | **可见**（"正在确认登录状态…"） | 正在确认登录状态… | 骨架屏 | `👤 登录 PetLife` |
| 未登录 | **可见** | 尚未登录 PetLife（+登录） | 🔐 尚未登录 PetLife + 登录按钮 | `👤 登录 PetLife` |
| 已登录、当天无记录 | 隐藏 | `设备名 · 某日 尚无使用记录` | 🌙 今天尚无使用记录 | `👤 邮箱前缀` |
| 服务异常（404 / 返回网页 / 网络故障） | 隐藏（见下） | 无法连接 PetLife 服务（+重新检测） | ⚠️ 具体原因 + 排查提示 + 重试 | `👤 重新检测` |

**为什么"服务异常"要隐藏登录框**：故障不在凭据上，弹一个登录表单只会让用户
反复试密码却永远失败。此时让用户直接看到故障原因与重试按钮，
而登录入口由顶部常驻账户按钮兜住（面板里有「🔑 手动登录」）。
这**不等于**"空壳"：主体区有明确的错误说明与重试、状态条在报故障、
账户按钮也变成了「重新检测」。

### 9.5 本机实测结果

用临时 mock 后端（复现生产同源拓扑：API 挂在 `/petlife-api/` 下、
凭据 Cookie 的 `Path` 也是 `/petlife-api/`、无 Cookie 返回 401）逐态验证：

| 场景 | 结果 |
|---|---|
| A 无 Cookie 打开 `/usage/` | 登录框 **立即可见**（`display:flex`）；状态条「尚未登录 PetLife」；主体「🔐 尚未登录 PetLife」；首屏**只发 1 个请求**（`me` → 401）；无 JS 错误 |
| B 输入邮箱密码登录 | 请求顺序 **`login → me → devices → summary`**（全 200）；登录框隐藏；账号按钮变 `👤 demo`；状态条「我的电脑 + 手机 · 最近同步 21:36」；今日 6小时42分钟、3 条应用 |
| B 账户面板（已登录） | `demo@petlife.local / PetLife 账户 / 🔄 刷新数据 / 🚪 退出登录` |
| C 404（静态服务无 `/petlife-api`） | 登录框隐藏；账号按钮 `👤 重新检测`；状态条「无法连接 PetLife 服务」；主体给**反代排查提示 + 重试**；点「重新检测」不崩、状态保持一致 |
| D `?demo=1` | 演示横幅 ON、**不要求登录**、状态条「演示模式」、数据正常 |
| E 退出登录 | 登录框回到可见 + 「已退出登录」；账号按钮回到 `👤 登录 PetLife`；状态条「尚未登录 PetLife」；**数据与应用条目全部清空**（缓存已清） |
| F **代理把 `/petlife-api/*` 交给静态站点（200 + text/html）** | 见 9.8；**不再误报为"无数据"** |
| 手机端 390×844 | 导航高 87px、**无横向溢出**；账户按钮折叠为 32px 纯图标；设备下拉 42px；登录框可见 |

### 9.6 修复后的验收步骤（请以此为先）

1. 清除该站点 Cookie，或直接用无痕窗口；
2. 打开 `/usage/`；
3. 确认**立即**显示 PetLife 邮箱密码登录框（不是空白页）；
4. 登录成功后才显示设备与统计数据。

**在这四条通过之前，先不要继续验收统计功能。**

### 9.7 本地自验工具（非站点文件，请勿上传）

`C:\下载\_mock\mock_server.py` —— 单文件 mock 后端，
同时提供静态文件与 `/petlife-api/*`（含正确的 Cookie 头），用于**上传前**在本机确认登录闭环：

```bash
python C:\下载\_mock\mock_server.py      # 监听 127.0.0.1:8771
# 然后访问 http://127.0.0.1:8771/usage/
```

它只用于验证前端状态机，**不属于站点内容，不要上传到服务器**。

### 9.8 v3 加固：禁用缓存 + 拒绝"网页内容冒充 API 成功响应"

> 网页资源版本升至 `?v=20261006-3`。

**为什么必须做这两条** —— 它们修的是同一类"静默误导"：

#### (1) 所有 API 请求禁用缓存

```js
return fetch(API_BASE + path, {
  method: method,
  credentials: 'include',
  cache: 'no-store',        // ← 新增
  headers: headers,
  body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  signal: opts.signal
});
```

身份与统计数据一律不吃缓存：宁可多一次往返，也不能显示过期状态
（被缓存住的 401 或旧数据会让界面与真实状态不符，而且在 Network 面板里
看起来"请求成功了"，极难排查）。

#### (2) 拒绝 HTML 冒充成功响应

```js
var contentType = res.headers.get('content-type') || '';
if (res.status !== 204 && !contentType.includes('application/json')) {
  var htmlErr = new Error('PetLife 接口返回了网页内容，请清除缓存或检查反向代理');
  htmlErr.code = 'api_returned_html';
  htmlErr.status = res.status;
  throw htmlErr;
}
```

**这道防线修的是一个真实且隐蔽的 bug。** 反向代理没配好时，
`/petlife-api/*` 会落到静态站点上，返回 **200 + `index.html`（`text/html`）**：
`res.ok` 为真、状态码正常，看起来是一次"成功的请求"。
v2 的代码在这里会执行 `if (res.ok) return json;`，
而 JSON 解析早就失败、`json` 是 `null` —— 于是把 `null` 当作**成功结果**返回，
最终被渲染成"暂无数据"。**那正是要杜绝的"把故障显示成没有数据"。**

拦下来之后：
- `errorBox` 给出可操作的提示（确认反代已把 `/petlife-api/` 转发到 PetLife 服务 + 清缓存重试）；
- `handleAuthFailure` 把它归入"服务异常"（**而不是**"未登录"）——
  否则用户会以为只是没登录，被引到错误方向；
- 登录流程里遇到它，账户状态置为 `error`（「重新检测」），
  因为重试密码在这种情况下毫无意义。

`res.status !== 204` 是一个窄口子：204 按规范无响应体、自然没有 `content-type`，
不能因为"没有 content-type"就判成 HTML。目前接口没有 204，留着以免将来误报。

#### 实测（场景 F）

用 `_mock/serve_html_masquerade.py` 模拟"代理把 `/petlife-api/*` 交给静态站点"：

| 观测项 | 结果 |
|---|---|
| Network 状态码 | **200**（这正是陷阱所在） |
| 响应 `content-type` | `text/html; charset=utf-8` |
| 页面主体 | ⚠️「PetLife 接口返回了网页内容，请清除缓存或检查反向代理」+ 反代排查提示 + 重试 |
| 是否误报"无数据" | **否**（脚本断言 `/暂无数据\|没有记录\|尚无使用记录/` 未命中） |
| 登录框 | 隐藏（属服务异常，非凭据问题） |
| 账户按钮 / 面板 | `👤 重新检测` / 「无法连接 PetLife」+「🔁 重新检测」+「🔑 手动登录」 |
| 回归：正常后端 + 无 Cookie | 登录框可见 ✅ |
| 回归：登录成功 | `login → me → devices → summary` 全 200，数据正常（content-type 校验未误伤 JSON）✅ |
| 回归：`?demo=1` | 演示模式正常 ✅ |
| 点「重新检测」 | 不崩，状态与提示一致 ✅ |

**这类 bug 的教训**：`res.ok` 只说明 HTTP 层成功，**不代表拿到了我们期望的东西**。
凡是"接口返回的必须是结构化数据"的地方，都要显式校验内容类型，
否则代理/网关的任何一层异常都会退化成"看起来正常但没有数据"。
