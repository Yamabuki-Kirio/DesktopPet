import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/petlife/petlife_components.dart';

/// 移动端「平台能力说明」卡片。
///
/// 存在的理由：**必须让用户知道这一版有没有在采集**。
/// 如果不写清楚，用户会以为"数据丢了"。
///
/// 抽成独立组件有两个好处：
/// * 桌面外壳不会误用移动端文案（反之亦然）；
/// * 可以用纯 Widget 测试覆盖"有没有采集"两种文案。
///
/// 视觉：使用统一设计系统的卡片与主题色（不再硬编码蓝灰色）。
class MobilePlatformNotice extends StatelessWidget {
  const MobilePlatformNotice({super.key, required this.collecting});

  /// 当前平台是否已在采集系统前台应用。
  final bool collecting;

  /// 未采集时的说明文案（同时被测试引用，避免文案与断言漂移）。
  static const String pendingBody =
      '这一版（Phase 4A）还没有启用应用使用时长采集：'
      '桌宠、登录、同步与已上传的统计都可以正常使用，'
      '但本机不会新增使用记录。授权采集将在下一阶段（Phase 4B）提供，'
      '届时需要你手动授予「使用情况访问权限」。';

  /// 已采集时的说明文案。
  static const String collectingBody = '已启用系统前台应用采集。';

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    final Color tone = collecting ? p.success : p.onAccentSoft;
    return PetLifeCard(
      color: tone.withValues(alpha: 0.06),
      borderColor: tone.withValues(alpha: 0.35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            collecting ? Icons.check_circle_outline : Icons.info_outline,
            size: 16,
            color: tone,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              collecting ? collectingBody : pendingBody,
              style: TextStyle(
                fontSize: PetLifeText.caption,
                color: p.textPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
