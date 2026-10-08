import 'package:uuid/uuid.dart';

/// ID 生成。
///
/// 关键设计：素材相关的 ID 必须**确定性**生成（uuid v5）。
/// 否则每次重新扫描同一个文件夹都会产生新的 pack/character/asset 记录，
/// 用户配置的状态映射会全部失效。
class Ids {
  Ids._();

  static const Uuid _uuid = Uuid();

  /// PetLife 命名空间（固定常量，永远不要修改）。
  ///
  /// ⚠️ 必须是一个**合法 UUID**，否则 `Uuid.v5()` 会直接抛异常。
  /// `uuid` 包的 `v5()` 默认按 `ValidationMode.strictRFC9562` 校验命名空间，
  /// 其形态要求等价于正则：
  ///
  /// ```
  /// ^[0-9a-f]{8}-[0-9a-f]{4}-[0-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$
  /// ```
  ///
  /// 也就是：**第三段首字符必须落在 `0-8`**（version 位），
  /// **第四段首字符必须落在 `8/9/a/b`**（variant 位）。
  ///
  /// 事故记录（缺陷 D-01）：本常量最初误写为
  /// `6f9619ff-8b86-d011-b42d-00c04fc964ff`，第三段首字符是 `d`，
  /// 不满足 version 位约束，`Uuid.v5()` 抛
  /// `FormatException: The provided UUID is invalid.`，
  /// 导致导入 Ace Attorney 文件夹时 13 个文件**全部**失败。
  /// 详见 `docs/09-验收报告.md`。
  ///
  /// 注意：本命名空间第四段用的是原值 `b42d`（variant 位 `b` 本就合法），
  /// 只修正了非法的 version 位，改动面最小。
  ///
  /// 🚫 一旦库中已存在由本命名空间生成的素材 ID，此值**永不可再变**：
  /// 它是 uuid v5 的输入之一，改动会让全部 pack/character/asset ID 漂移，
  /// 用户配置的状态映射会随之全部失效。
  static const String namespace = '6f9619ff-8b86-4011-b42d-00c04fc964ff';

  /// 命名空间是否通过严格校验。
  ///
  /// 供给启动自检与单元测试使用：命名空间不合法时**每一次导入都会失败**，
  /// 这个不变量必须是可自动化断言的对象，而不是靠人眼比对字符串
  /// （缺陷 D-01 正是因为缺少这层断言才漏到人工验证阶段）。
  static bool get isNamespaceValid => Uuid.isValidUUID(fromString: namespace);

  /// 启动自检：命名空间非法时**立刻**抛错。
  ///
  /// 放在应用装配阶段调用，让配置错误在启动瞬间就暴露，
  /// 而不是等用户导入素材时逐条报 `FormatException`。
  static void assertNamespaceValid() {
    if (!isNamespaceValid) {
      throw StateError(
        'Ids.namespace 不是合法 UUID，uuid v5 会抛 FormatException，'
        '所有素材导入都会失败。当前值：$namespace',
      );
    }
  }

  /// 随机 ID，用于日志会话、临时对象等非持久标识。
  static String random() => _uuid.v4();

  /// 确定性 ID（RFC 4122 / RFC 9562 的 v5：SHA-1 + 命名空间）。
  ///
  /// [parts] 之间用 NUL 连接而不是普通分隔符，避免
  /// `['ab', 'c']` 与 `['a', 'bc']` 这类拼接歧义产生同一个 ID。
  static String deterministic(List<String> parts) =>
      _uuid.v5(namespace, parts.join('\u0000'));

  /// 作品包 ID：同一用户下同名作品包视为同一个包。
  static String packId(String ownerId, String packName) =>
      deterministic(['pack', ownerId, packName.toLowerCase()]);

  /// 角色 ID：同一作品包内同名角色视为同一个角色。
  static String characterId(String packIdValue, String internalName) =>
      deterministic(['character', packIdValue, internalName.toLowerCase()]);

  /// 素材 ID：同一角色下 (情绪, 变体) 唯一。
  ///
  /// 这样用户用同名文件覆盖导入时是“更新”而不是“新增重复项”。
  static String assetId(String characterIdValue, String emotion, String variant) =>
      deterministic(['asset', characterIdValue, emotion.toLowerCase(), variant.toLowerCase()]);

  /// 状态映射 ID：同一角色 + 同一系统状态 + 同一条目唯一。
  static String stateMappingId(String characterIdValue, String systemState, int ordinal) =>
      deterministic(['mapping', characterIdValue, systemState, '$ordinal']);

  /// 状态**显式主素材**映射 ID（Phase 4C-6A.1 编辑器口径）。
  ///
  /// 用固定词 `explicit` 而不是序号：同一个 (角色, 状态) 无论被设置多少次，
  /// 都得到**同一个 ID**，因此重复保存是"更新同一行"而不是不断新增
  /// （需求 §7：同状态更新不产生重复记录）。
  static String explicitStateMappingId(String characterIdValue, String systemState) =>
      deterministic(['mapping', characterIdValue, systemState, 'explicit']);

  /// 活动段 ID。
  ///
  /// 由 (owner, 设备, app_key, 起点毫秒) 确定，因此**重复处理同一次开段
  /// 不会产生两条记录**（例如异常退出后按检查点重放）。
  /// 同一应用的两段必然被至少一个采样周期隔开，起点毫秒不会相同。
  static String segment(String ownerId, String deviceLocalId, String appKey, DateTime startedAt) =>
      deterministic([
        'segment',
        ownerId,
        deviceLocalId,
        appKey,
        '${startedAt.millisecondsSinceEpoch}',
      ]);

  /// 原生（Android）使用会话导入时使用的活动段 ID。
  ///
  /// 由「本机设备标识 + 原生 session_id」确定 —— 原生 journal 里的同一条记录
  /// 无论被重复读取多少次、Flutter 在导入后是否崩溃，都只会得到**同一个 ID**，
  /// 因此 `activity_segments` 的主键天然保证"不重复累计"（Phase 4C-5.1B 需求 §6.2）。
  ///
  /// 为什么不用 `segment(...)`：原生会话的起点由原生状态机决定（含切换确认偏移），
  /// 与 Dart 侧按采样推算的起点不完全一致；用原生自己的 session_id 更稳定、更可追溯。
  static String usageSession(String deviceLocalId, String sessionId) =>
      deterministic(['android-usage-session', deviceLocalId, sessionId]);
}
