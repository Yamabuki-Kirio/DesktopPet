/// 设置页的**七个功能分组**（唯一真相）。
///
/// 需求 §2.6：设置页按以下分组重新排列，每组使用独立圆角卡片，
/// **不再连续堆叠大量灰色设置行**：
///
/// 1. 桌宠 2. 外观与主题 3. 状态联动 4. 账户与同步 5. 权限 6. 高级 7. 诊断
///
/// 抽成枚举而不是散落在 `build` 里的字面量：
/// * 设置页按 [PetLifeSettingsSection.values] 的顺序渲染，顺序不可能写错；
/// * 「设置分组测试」可以直接断言标题、顺序与数量。
enum PetLifeSettingsSection {
  pet('桌宠', '显示、缩放与默认角色'),
  appearance('外观与主题', '主色控制表面，强调色控制交互；两者独立保存'),
  stateLink('状态联动', '前台应用 → 桌宠状态 → 素材'),
  account('账户与同步', '不登录也能使用桌宠与本地统计'),
  permission('权限', '全部权限都只能由你在系统页面里授予'),
  advanced('高级', '启动、轮盘与恢复出厂'),
  diagnostics('诊断', '排查问题时优先看这里');

  const PetLifeSettingsSection(this.title, this.subtitle);

  /// 分组标题（渲染在分组卡片上方）。
  final String title;

  /// 分组说明（一行，解释这一组在管什么）。
  final String subtitle;
}
