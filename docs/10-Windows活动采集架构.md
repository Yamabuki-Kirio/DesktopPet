# 10 · Windows 活动采集架构

> 适用范围：**PetLife 阶段 1**（Windows 前台应用采集 + 使用统计 + 桌宠自动状态联动）。
> 本文件描述当前代码的真实结构，不描述规划中的结构。

## 1. 闭环与职责边界

```text
Win32 采样（每 2 秒）
   ↓  GetForegroundWindow / GetWindowThreadProcessId / OpenProcess /
      QueryFullProcessImageNameW / GetLastInputInfo / OpenInputDesktop
ActivityTracker（编排：组装采样 → 交给状态机 → 交给状态映射）
   ↓
ActivitySegmentService（状态机：合并成段 / 计时 / 检查点 / 崩溃恢复）
   ↓                                    ↘
SQLite（activity_segments /         ActivityStateMapper（应用分类 + 空闲 + 连续时长 → 系统状态）
daily_usage / activity_checkpoints）      ↘
   ↓                                    DefaultStateEngine（阶段 0 已有，未改动）
UsageAnalyticsService（今日 / 本周 / 分类 / 排行）      ↘
   ↓                                          PetPresenter → PetFrameController（淡入淡出）
使用统计页面 / 托盘 / 桌宠右键菜单
```

**关键边界**：

| 层 | 负责 | 明确不负责 |
|---|---|---|
| `win32/` | 只调 Win32 API，失败返回 null / 保守值 | 业务规则、分类、落库 |
| `*_provider.dart` | 把平台调用抽象成可替换接口 | 合并、计时 |
| `ActivitySegmentService` | 活动段合并 / 计时 / 检查点 / 恢复 | 平台调用、UI、状态决策 |
| `ActivityStateMapper` | 纯函数：上下文 → 系统状态 | 落库、防抖（防抖仍在阶段 0 的 `StateDebouncer`） |
| `ActivityTracker` | 编排采样与状态请求 | 业务规则 |
| `UsageAnalyticsService` | 只读统计查询 | 写入 |

## 2. 为什么用 Dart FFI 而不是 C++ 插件

阶段 0 的进程 CPU / 内存 / 句柄采样已经用 **Dart FFI 直连 `kernel32.dll` / `psapi.dll`**
（`lib/diagnostics/win32_process_stats.dart`）在真机稳定跑过。阶段 1 沿用同一条路径：

| 方案 | 结论 |
|---|---|
| Dart FFI 直连 | **采用**。不新增 CMake 目标与插件注册，不动 `windows/` 脚手架，风险最低 |
| 新建 C++ 插件 | 未采用。需要改 `CMakeLists.txt` 与 `generated_plugin_registrant`，构建面变大 |

需求原文允许「C++ 插件**或** Dart FFI」，两者都合规，选择前者是为了**不触碰已经稳定的构建链路**。

需要注册会话/电源通知（`WTSRegisterSessionNotification`、`RegisterSuspendResumeNotification`）
时都需要一个真实窗口句柄，会侵入 runner 的窗口实现；因此改为：

- **锁屏**：轮询 `OpenInputDesktop`（锁屏时输入桌面切到 Winlogon，普通进程打开会失败）；
- **休眠/恢复**：用「单调时钟 vs 墙上时钟」的差值判定，见 §4。

采集本身就是 2 秒轮询，这两种方式的成本都可以忽略，且不需要任何原生窗口改动。

## 3. 模块清单

`lib/activity_tracking/` 共 **2,692 行**：

| 文件 | 职责 |
|---|---|
| `models/activity_enums.dart` | `AppCategory`（8 类）、`SegmentEndReason`（10 种）、`TrackingStatus` |
| `models/activity_sample.dart` | `ActivitySample` / `ForegroundAppInfo` / `TrackedApplication` / `ActivityCheckpoint` |
| `models/tracking_settings.dart` | 采集设置、`DailyUsage`（设备级每日用量） |
| `models/usage_stats.dart` | `UsageWindow` / `UsageOverview` / `AppUsageRow` / `CategoryUsageRow` / `UsageSummary` |
| `app_keys.dart` | `app_key` 规范化（唯一主键来源） |
| `tracking_clock.dart` | `MonotonicClock` / `WallClock` 抽象 + 假时钟（可测性基础） |
| `win32/win32_activity_native.dart` | Win32 FFI 绑定（唯一的平台代码） |
| `foreground_app_provider.dart` | 前台应用提供者接口 + Win32 实现 + 测试替身 |
| `idle_detector.dart` | 空闲检测接口 + Win32 实现 + 测试替身 |
| `session_state_provider.dart` | 锁屏状态接口 + Win32 实现 + 测试替身 |
| `application_classifier.dart` | 内置分类规则 + 路径特征 + 人工优先裁决 |
| `application_repository.dart` | 应用库内存视图（采样路径零 SQL） |
| `activity_segment_service.dart` | **核心状态机**：合并 / 计时 / 检查点 / 崩溃恢复 |
| `activity_tracker.dart` | 采样定时器 + 状态请求编排 |
| `activity_state_mapper.dart` | 采集上下文 → 系统状态（纯函数） |
| `usage_analytics_service.dart` | 统计查询（今日 / 周 / 分类 / 排行） |

`core/single_instance.dart`：Win32 命名互斥体，避免多实例重复记录。

## 4. 采样与计时模型

### 4.1 单次采样内容

`ActivitySample` 每次携带：墙上时间、单调毫秒、前台应用（句柄/PID/进程名/完整路径）、
空闲时长、是否锁屏、是否暂停。

**刻意不包含**窗口标题、文档名、网页标题、键盘输入、鼠标内容、剪贴板、截图。

### 4.2 双时钟

| 时钟 | 用途 |
|---|---|
| 墙上时钟 `DateTime` | 写库（`started_at` / `ended_at`）、跨日归属 |
| 单调时钟 `Stopwatch` | 计算持续时长，不受系统时间调整影响 |

### 4.3 三类异常时间的处理

| 情形 | 判据 | 处理 |
|---|---|---|
| 休眠 / 进程被冻结 | `monoDelta > 30s` 或 `wallDelta > 30s` | **一分一秒都不计入**，按原因结束当前段：`skew > 5s` → `system_suspend`；否则锁屏 → `session_locked`，否则 `process_unavailable` |
| 系统时间被改动 | `abs(wallDelta − monoDelta) > 60s` 且未触发上一条 | 按单调时钟结算后结束当前段（`clock_changed`）并重新开段 |
| 采样延迟（GC / 抢占） | 单次 `monoDelta > 6s` | 只计入 6 秒（`maxCreditPerTickMs = 3 × 2s`），其余丢弃 |

这三条同时兜住了需求里的两句话：
「采样延迟不能直接全部算入活跃时间」与
「程序异常退出时不能生成持续数小时的错误记录」。

### 4.4 空闲边界精确到毫秒

检测到 `idle ≥ 阈值` 时，当前段的结束时间**不是**本次采样时刻，而是
`采样时刻 − (idle − 阈值)`，即用户真正「越过阈值」的那一刻。设备级的活跃/空闲拆分同理：

```
activePortion = clamp(credit − max(0, idle − 阈值), 0, credit)
idlePortion   = credit − activePortion
```

## 5. 活动段合并与碎片抑制

### 5.1 合并

连续使用同一应用只产生**一条**记录（`started_at` → `ended_at`），
不会每 2 秒插一行。段结束原因见 `SegmentEndReason`：

```
foreground_changed / user_idle / session_locked / system_suspend /
tracking_paused / app_excluded / client_shutdown / process_unavailable /
crash_recovery / clock_changed
```

### 5.2 切换确认（抑制 alt-tab 碎片）

- **当前没有进行中的段** → 立即开段（没有碎片可抑制，延迟只会白丢时间）；
- **已有段在计时，前台换成别的应用** → 记为「候选」，候选需连续存在
  `switchConfirmMs = 1500ms` 才真正结束旧段、开新段；
- 候选期间的时间仍归属旧应用，新段从候选**首次出现**的时刻起算（时间守恒，不丢不重）；
- 闪切（每次不到 1.5 秒就切走）永不确认 → 只产生 1 段，而不是 10 个碎片。

界面上的「当前应用」按采样即时更新（≤1 个采样周期），**不受确认时长影响**。

### 5.3 写入频率

| 时机 | 写入 |
|---|---|
| 开段 | `activity_segments` 插一行（`active_seconds = 0`） |
| 每秒采样 | **不写库** |
| 每 30 秒 | 覆盖写 `activity_checkpoints` 一行 + 更新所属段的 `active_seconds` + 覆盖写当日 `daily_usage` 一行 + 回写 `applications.last_seen_at` |
| 段结束 | 关闭该段 + 删除其检查点 |
| 用户暂停 / 正常退出 | 立即执行一次上述落盘 |

因此**进行中的段在数据库里的 `active_seconds` 最多落后 30 秒**（设计如此）；
统计页在查询前会先调 `flushNow()`，因此用户看到的数字总是最新的。

## 6. 崩溃恢复

1. 每 30 秒为进行中的段写一行检查点（段 ID、墙上时刻、已累计秒数）；
2. 启动时查 `ended_at IS NULL` 的段：
   - 有检查点 → 用检查点的时刻与秒数关闭，`end_reason = crash_recovery`；
   - 无检查点（开段后 30 秒内就崩） → 用 `started_at` 关闭、活跃 0 秒；
3. 清理孤儿检查点。

「没有检查点就按 0 秒关闭」是刻意的保守选择：**宁可为空，也不虚报一整段**。

## 7. 隐私约束（实现层面的保证）

| 约束 | 落点 |
|---|---|
| 不保存窗口标题 / 文档名 / 网页标题 | `ForegroundAppInfo` 结构里根本没有这些字段 |
| 不记录键盘输入 | 只读 `GetLastInputInfo` 的**时刻**，不装钩子 |
| 不记录鼠标内容 / 轨迹 | 同上 |
| 不截图 | 全流程无任何屏幕抓取 API |
| 不读剪贴板 | 无剪贴板 API |
| 不上传 | 阶段 1 无任何网络代码；`sync_status` 只是为阶段 2 预留的列 |
| 不做窗口标题猜测分类 | 分类只认 `app_key` 与**安装路径特征** |

## 8. 单实例

`SingleInstanceGuard.tryAcquire()` 用 `CreateMutexW("Global\\PetLife.DesktopPet.SingleInstance")`
+ `GetLastError() == ERROR_ALREADY_EXISTS` 判断。在 `main()` 的**最早**时机执行：

- 返回 `true`：唯一实例，继续启动；
- 返回 `false`：写 stderr 后 `exit(0)`（此时日志系统尚未初始化，因此不写日志文件）；
- 返回 `null`（非 Windows / 互斥体不可用）：**放行启动**，不因保护机制失败而拒绝服务。

互斥体随进程退出自动释放，不产生需要人工清理的锁文件。

## 9. 降级与容错

| 情形 | 行为 |
|---|---|
| 非 Windows / DLL 加载失败 | 三个提供者退化为「不可用」实现，`ActivityTracker.isAvailable = false`，**不驱动桌宠状态**，桌宠与素材功能完全不受影响 |
| `GetForegroundWindow` 返回空 | 当前段以 `process_unavailable` 结束，不虚构应用名 |
| 无权限读高权限进程 | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` 失败后改用 Toolhelp 快照按 PID 取进程名；仍失败则整条采样返回 null |
| 进程在读取时退出 | 同上，走 `process_unavailable` |
| 数据库写入失败 | 内存继续计时，只记 `consecutiveFailures`；连续 ≥3 次且恢复失败 → 状态映射判定 `error` |
| UWP / 多进程应用 | 以实际持有前台窗口的那个进程为准；同一 `app_key` 的多个进程共享同一条应用记录 |
| 用户开启鼠标穿透 | 采集与渲染无关，不受影响 |

## 10. 与阶段 0 的关系

**零改动**：素材导入、解码、动画渲染、窗口、托盘、状态引擎、防抖规则全部保持原样。
阶段 1 的改动只有：

1. 新增 `lib/activity_tracking/`（不修改阶段 0 逻辑）；
2. `schema.dart` 增加 v2 迁移（只新增表与索引，**不改动任何阶段 0 表**）；
3. `app_scope.dart` 增加装配与诊断字段；
4. `control_panel.dart` 增加「使用统计」页签；
5. `tray_service.dart` / `pet_view_wrapper.dart` 增加菜单项；
6. `main.dart` 增加单实例检查。
