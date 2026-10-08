/// PetLife 全局常量。
///
/// 集中放置所有“魔法数字”与限制值，便于后续阶段（服务端 / Android）复用同一套约束。
library;

class AppConstants {
  AppConstants._();

  /// 应用显示名。
  static const String appName = 'PetLife';

  /// 客户端版本号。
  ///
  /// 会在注册/登录/绑定设备时作为 `app_version` 上报给服务端，
  /// 便于排查"某个客户端版本的问题"。与 `pubspec.yaml` 的 version 保持同步即可。
  static const String appVersion = '0.2.0';

  /// 应用数据目录名（位于系统 AppData 下，绝不写入用户素材源目录）。
  static const String appDataFolder = 'PetLife';

  /// 阶段 0 的本地默认用户。代码结构保留 owner_id 概念，服务端接入后直接替换。
  static const String localOwnerId = 'local.default';

  /// 设备本地标识（阶段 0 仅用于 activity_segments 预留字段）。
  static const String localDeviceId = 'desktop.local';

  /// 数据库文件名。
  static const String databaseFileName = 'petlife.db';

  /// 数据库 schema 版本。
  ///
  /// v1 = 阶段 0（素材 / 角色 / 映射 / 设置 / activity_segments 预留表）
  /// v2 = 阶段 1（应用库、活动检查点、每日用量、采集设置）
  /// v3 = Phase 2（账户会话、同步状态、待同步队列）
  /// v4 = Phase 4B（云端统计缓存；与采集/上传表**完全隔离**）
  /// v5 = Phase 4C-6A.1（`emotion_assets.favorite` 收藏标记；只加一列）
  static const int databaseSchemaVersion = 5;

  /// 日志文件名。
  static const String logFileName = 'petlife.log';

  /// 日志文件最大字节数（超出后轮转为 .1）。
  static const int logMaxBytes = 2 * 1024 * 1024;
}

/// 素材相关的限制与约束。
class AssetLimits {
  AssetLimits._();

  /// 允许导入的扩展名（全部小写，不含点）。
  ///
  /// 扩展名仅用于初筛，真实格式一律以 magic bytes + 解码结果为准。
  static const Set<String> allowedExtensions = {
    'png',
    'webp',
    'jpg',
    'jpeg',
    'gif',
  };

  /// 单文件大小上限：64 MiB。
  static const int maxFileBytes = 64 * 1024 * 1024;

  /// 单图像素总量上限：64 MP（防止解压炸弹与超大解码内存）。
  static const int maxPixels = 64 * 1024 * 1024;

  /// 单边尺寸上限。
  static const int maxEdge = 16384;

  /// 单文件帧数上限（防止异常动画文件拖垮渲染）。
  static const int maxFrames = 2048;

  /// ZIP 导入：条目数上限。
  static const int maxZipEntries = 4096;

  /// ZIP 导入：单条目解压后大小上限。
  static const int maxZipEntryBytes = 64 * 1024 * 1024;

  /// ZIP 导入：解压后总大小上限。
  static const int maxZipTotalBytes = 512 * 1024 * 1024;

  /// ZIP 导入：压缩比上限（防 zip bomb）。总解压 / 压缩包体积。
  static const double maxZipRatio = 200.0;

  /// 解码缓存条目数上限（有限缓存，绝不无限缓存全部资源）。
  static const int decodedCacheEntries = 24;

  /// 解码缓存字节上限：192 MiB。
  static const int decodedCacheBytes = 192 * 1024 * 1024;
}

/// 渲染与动画相关的时间常量。
class RenderTimings {
  RenderTimings._();

  /// 淡入淡出时长下限（毫秒）。
  static const int crossFadeMinMs = 150;

  /// 淡入淡出时长上限（毫秒）。
  static const int crossFadeMaxMs = 300;

  /// 淡入淡出默认时长（毫秒）。
  static const int crossFadeDefaultMs = 220;

  /// 等待当前动画播放完一轮的最长等待时间（毫秒），超时后强制切换。
  static const int waitAnimationCycleTimeoutMs = 8000;

  /// 静态图片视为“一轮动画已完成”的时长（毫秒）。
  static const int staticFrameCycleMs = 0;
}

/// 状态防抖默认规则（毫秒）。
class StateDebounce {
  StateDebounce._();

  /// 前台应用稳定多久后才允许改变“应用相关”状态。
  static const int foregoundStableMs = 10 * 1000;

  /// 普通状态最短展示时长。
  static const int normalMinHoldMs = 15 * 1000;

  /// happy 状态最短展示时长。
  static const int happyMinHoldMs = 10 * 1000;

  /// tired 状态最短展示时长。
  static const int tiredMinHoldMs = 5 * 60 * 1000;

  /// 快速窗口切换的抑制窗口：在此时间内的连续切换请求会被合并。
  static const int rapidSwitchSuppressMs = 400;
}

/// Windows 活动采集相关的时间常量（阶段 1）。
///
/// 全部集中在这里，便于测试用同一份数字做断言，也便于后续按真机表现调整。
class ActivityTracking {
  ActivityTracking._();

  /// 默认采样间隔：每 2 秒检查一次当前状态。
  static const int sampleIntervalMs = 2000;

  /// 默认空闲阈值：5 分钟。
  static const int defaultIdleThresholdMs = 5 * 60 * 1000;

  /// 设置页可选的空闲阈值（毫秒）。
  static const List<int> idleThresholdOptionsMs = <int>[
    1 * 60 * 1000,
    3 * 60 * 1000,
    5 * 60 * 1000,
    10 * 60 * 1000,
    15 * 60 * 1000,
  ];

  /// 超过该间隔的采样间隔视为「中断」：休眠、进程被冻结、系统时间跳变等。
  ///
  /// 中断期间**一分一秒都不计入活跃时间**，并按原因结束当前活动段。
  /// 这同时兜住了「程序异常退出/长时间卡死不得生成超长记录」。
  static const int maxSampleGapMs = 30 * 1000;

  /// 墙上时钟比单调时钟多走了这么多 → 判定为系统休眠（单调时钟在睡眠中不走）。
  static const int suspendDetectMs = 5 * 1000;

  /// 单次采样最多计入的活跃毫秒数。
  ///
  /// 采样延迟（GC、磁盘抖动、线程被抢占）不得全部算成用户活跃时间，
  /// 因此把单次计入量夹在 3 倍采样间隔内。
  static const int maxCreditPerTickMs = 3 * sampleIntervalMs;

  /// 系统时间大幅变化（前后跳变超过该值）→ 结束当前段并新开一段。
  static const int clockJumpThresholdMs = 60 * 1000;

  /// 应用切换的确认时长：候选应用需连续存在这么久才真正开新段。
  ///
  /// 作用：抑制快速 alt-tab 造成的碎片段。界面上的「当前应用」仍然按
  /// 采样即时更新（≤1 个采样周期），不受该确认时长影响。
  static const int switchConfirmMs = 1500;

  /// 活动段检查点写入间隔。
  static const int checkpointIntervalMs = 30 * 1000;

  /// 连续活跃时长阈值：达到后切换为 `tired`。
  static const int continuousUsageTiredMs = 90 * 60 * 1000;

  /// 连续活跃时长提醒阈值（可选轻提醒，第一版仅记录）。
  static const int continuousUsageReminderMs = 60 * 60 * 1000;

  /// 连续活跃时长升级为 concerned 的阈值。
  static const int continuousUsageConcernedMs = 120 * 60 * 1000;

  /// 「连续使用」的判定容差：两个活动段间隔小于该值仍视为连续。
  static const int continuousGapToleranceMs = 60 * 1000;

  /// 单实例互斥体名称（避免多个 PetLife 同时记录造成重复数据）。
  static const String singleInstanceMutexName = 'Global\\PetLife.DesktopPet.SingleInstance';
}

/// 使用统计的展示时间范围。
enum UsageRange {
  today('今天'),
  yesterday('昨天'),
  last7Days('最近 7 天'),
  thisWeek('本周');

  const UsageRange(this.label);

  final String label;
}

/// Phase 2：账户与同步的运行参数。
///
/// 与服务端协议相关的数字集中在这里，便于测试用同一份常量做断言
/// （服务端 `PETLIFE_SYNC_MAX_BATCH_SIZE` 默认值也必须与 [maxBatchSize] 一致）。
class SyncConfig {
  SyncConfig._();

  /// 单批最大条数（服务端默认上限也是 200，超出会被 413 拒绝）。
  static const int maxBatchSize = 200;

  /// 连接与整体请求超时。桌面端在网络不可达时应尽快失败并退回本地，
  /// 而不是让同步任务长时间挂住。
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration requestTimeout = Duration(seconds: 25);

  /// 指数退避阶梯（秒）：5 → 15 → 1 分钟 → 5 分钟 → 15 分钟，之后封顶 1 小时。
  static const List<int> backoffSeconds = <int>[5, 15, 60, 300, 900];
  static const int maxBackoffSeconds = 3600;

  /// 后台定时同步间隔。
  static const Duration periodicInterval = Duration(minutes: 5);

  /// 退出前快速同步的严格超时：宁可少传一点，也不能卡住退出。
  static const Duration shutdownTimeout = Duration(seconds: 5);

  /// 默认服务端地址（开发用；用户可在「账户与同步」页修改）。
  static const String defaultServerBaseUrl = 'http://127.0.0.1:8000';

  /// 凭据存储里的条目名前缀。
  ///
  /// 实际条目名形如 `PetLife:account`，只保存**已登录账户的令牌 JSON**。
  static const String credentialTargetPrefix = 'PetLife:';
  static const String credentialAccountKey = 'account';

  /// 单次同步最多连续处理的批次数，防止一次同步把队列吃空导致长时间占用。
  static const int maxBatchesPerRun = 20;

  // --- 代理（Clash / HTTP CONNECT）---

  /// 手动代理默认主机。
  static const String defaultProxyHost = '127.0.0.1';

  /// 手动代理默认端口（Clash Mixed Port 的常见示例值）。
  static const int defaultProxyPort = 7877;

  /// 代理密码在凭据存储里的条目名（形如 `PetLife:proxy`）。
  ///
  /// 与账户令牌一样，**绝不落 SQLite、绝不进日志**。
  static const String credentialProxyKey = 'proxy';

  /// 代理探测（TCP / CONNECT / TLS / health 各阶段的单项超时）。
  static const Duration proxyStageTimeout = Duration(seconds: 8);

  /// 代理探测总超时（四项相加再留余量，避免 UI 长时间无响应）。
  static const Duration proxyProbeTimeout = Duration(seconds: 35);
}

