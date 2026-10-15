/// PetLife 设计令牌（唯一真相）。
///
/// 本文件**只放常量**，不含任何业务逻辑，也不依赖 `AppServices`：
/// 页面、公共组件与主题生成器都从这里取值，禁止再各自硬编码圆角 / 间距 / 时长。
///
/// 设计目标（本轮 Android UI 增量）：
/// **白色为主色 + P3P 粉为强调色**，P3P 图形语言 + Animeko 信息层级 +
/// Kazumi 卡片布局。颜色相关的派生逻辑在 `petlife_theme.dart`。
library;

import 'package:flutter/widgets.dart';

/// 默认配色（需求 §4「视觉规范 / 默认颜色」）。
///
/// 这些值同时是**持久化默认值**与「恢复默认」的目标值：
/// 任何一处单独改都会让两者脱节，因此只能在这一个地方定义。
abstract final class PetLifeColors {
  /// 页面主色：控制页面背景 / 顶部栏 / 卡片表面 / 底部导航表面 / 弹窗表面。
  static const Color primaryDefault = Color(0xFFFFFFFF);

  /// 强调色：控制主要按钮 / 当前导航项 / 选中标签 / 图表 / 进度条 /
  /// 开关 / 焦点边框 / 少量 P3P 装饰线。
  static const Color accentDefault = Color(0xFFF24D96);

  /// 次级背景（主色派生：强调色 5% 叠在主色上，白底时≈#FFF7FB）。
  static const Color surfaceMutedDefault = Color(0xFFFFF7FB);

  static const Color textPrimaryDefault = Color(0xFF2A1530);
  static const Color textSecondaryDefault = Color(0xFF6F6170);
  static const Color dangerDefault = Color(0xFFE5484D);
  static const Color successDefault = Color(0xFF27A866);

  /// 警告高光。**只用于短线、选中提示和少量装饰，禁止铺成大面积背景**。
  static const Color warningDefault = Color(0xFFFFD42A);
}

/// 圆角（需求 §4「圆角」）。
abstract final class PetLifeRadii {
  /// 大卡片：状态卡 / 概览卡 / 素材大卡。
  static const double largeCard = 20;

  /// 普通卡片 / 输入框 / 分组卡片。
  static const double card = 16;

  /// 按钮。
  static const double button = 14;

  /// 输入框。
  static const double field = 14;

  /// 弹窗。
  static const double dialog = 24;

  /// 胶囊标签：高度的一半（用 [StadiumBorder] 表达，不写死半径）。
  static const double pill = 999;

  static const Radius radiusLarge = Radius.circular(largeCard);
  static const Radius radiusCard = Radius.circular(card);
  static const Radius radiusButton = Radius.circular(button);
  static const Radius radiusField = Radius.circular(field);
  static const Radius radiusDialog = Radius.circular(dialog);

  static const BorderRadius largeCardBorder = BorderRadius.all(radiusLarge);
  static const BorderRadius cardBorder = BorderRadius.all(radiusCard);
  static const BorderRadius buttonBorder = BorderRadius.all(radiusButton);
  static const BorderRadius fieldBorder = BorderRadius.all(radiusField);
  static const BorderRadius dialogBorder = BorderRadius.all(radiusDialog);
}

/// 间距（需求 §4「间距」）。
abstract final class PetLifeSpacing {
  /// 页面左右边距。
  static const double page = 16;

  /// 顶部内容区与标题区之间的距离。
  static const double topContent = 12;

  /// 卡片内部边距。
  static const double cardInner = 16;

  /// 卡片之间。
  static const double cardGap = 12;

  /// 功能分组之间。
  static const double groupGap = 20;

  /// 最小触摸区域（需求 §9：不得有小于 48dp 的按钮）。
  static const double minTouch = 48;

  /// 顶部标题区高度（保证 48dp 触摸区与视觉留白同时成立）。
  static const double headerHeight = 56;

  static const EdgeInsets pagePadding = EdgeInsets.symmetric(horizontal: page);
  static const EdgeInsets pageInsets = EdgeInsets.fromLTRB(page, 0, page, page);
  static const EdgeInsets cardInsets = EdgeInsets.all(cardInner);
}

/// 动效时长（需求 §6「动画要求」）。
///
/// 上界刻意压在 240ms：既满足 180～240ms 的要求，又不会延迟业务响应。
abstract final class PetLifeDurations {
  /// 页面切换。
  static const Duration pageSwitch = Duration(milliseconds: 200);

  /// 卡片出现（淡入 + 轻微上移）。
  static const Duration cardIn = Duration(milliseconds: 180);

  /// 底部导航胶囊背景移动。
  static const Duration navPill = Duration(milliseconds: 200);

  /// 按钮按压。
  static const Duration press = Duration(milliseconds: 90);

  /// 主题切换（颜色渐变，不整页闪白）。
  static const Duration themeChange = Duration(milliseconds: 240);

  /// 弹窗。
  static const Duration dialog = Duration(milliseconds: 220);

  /// 素材选中（边框 + 对勾 + 轻微缩放）。
  static const Duration select = Duration(milliseconds: 160);

  /// 统一缓动曲线（开关、标签、胶囊共用）。
  static const Curve easing = Curves.easeOutCubic;

  /// 卡片出现用「先快后缓」的减速曲线。
  static const Curve cardEasing = Curves.easeOutQuad;
}

/// 字阶（需求 §3「字体层级」）。
///
/// 只定义**层级**，具体字号由页面按语义引用；不要在卡片里堆叠大量同字号文字。
abstract final class PetLifeText {
  /// 页面标题：22sp，粗体。
  static const double pageTitle = 22;

  /// 卡片标题：17sp，半粗体。
  static const double cardTitle = 17;

  /// 重要数据：28～34sp，粗体。
  static const double display = 30;
  static const double displayLarge = 34;

  /// 正文：14～16sp。
  static const double body = 15;
  static const double bodySmall = 14;

  /// 说明文字：12～13sp。
  static const double caption = 12.5;
  static const double captionSmall = 11.5;
}
