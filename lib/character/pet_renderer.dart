import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models/emotion_asset.dart';
import 'pet_visual_bounds.dart';

/// 桌宠渲染层抽象。
///
/// 职责：把「当前应该显示哪个素材」变成「当前这一帧要画什么」。
/// 不关心状态是怎么决定的（那是 StateEngine 的事），也不关心窗口（那是 WindowController 的事）。
abstract class PetRenderer extends ChangeNotifier {
  /// 当前正在展示的素材 ID；为 null 表示显示内置占位图。
  String? get currentAssetId;

  /// 当前是否在播放多帧动画。
  bool get isAnimated;

  /// 当前动画帧序号；无动画图层（占位图）时为 null。
  ///
  /// 供诊断页目视确认动画帧确实在推进。
  int? get currentFrameIndex;

  /// 当前动画还有多少毫秒走完一轮（用于「等动画播完一轮再切换」）。
  int get remainingMsInCycle;

  /// 素材原始尺寸。
  ui.Size? get contentSize;

  /// 当前素材的**视觉边界**（alpha 包围盒，归一化 0~1）。
  ///
  /// 这是"人物可见区域"的**唯一**来源（C1.1 需求 §二）。它由渲染器在帧推进时
  /// 逐帧测量并取稳定并集，因此动画播放期间不会抖动。
  ///
  /// 返回 null 表示"还没量到"（首帧尚未解码 / 测量失败）—— 调用方应改用
  /// [ensureVisualBounds] 等一次，而**不要**用素材尺寸或 Widget 矩形顶替。
  PetVisualBounds? get visualBounds;

  /// 保证至少量到一帧的视觉边界（幂等，可重复调用）。
  ///
  /// 规划固定画布 / 打开轮盘前必须 `await` 它，否则缺口会按素材整张尺寸算。
  /// 永远会在"最短一轮测量"内返回：测量失败时回退 [PetVisualBounds.full]。
  Future<PetVisualBounds> ensureVisualBounds();

  /// 正在渲染的图层（用于自定义绘制）。
  List<PetRenderLayer> get layers;

  /// 切换显示某个素材。传 null 表示显示内置占位图。
  Future<void> display(EmotionAsset? asset, {bool immediate = false});

  /// 是否循环播放动画。
  void setLoop(bool loop);

  /// 淡入淡出时长（毫秒）。
  void setCrossFadeMs(int ms);

  /// 清空全部图层并释放原生资源。
  Future<void> clear();
}

/// 一个渲染图层。
///
/// 交叉淡入淡出的两个素材会同时存在为两个图层，`opacity` 由渲染器在
/// [PetRenderer] 内部按时间推进，因此「同一张图片不会反复重新加载、重新起播」。
abstract class PetRenderLayer {
  const PetRenderLayer({required this.assetId, required this.opacity});

  /// 素材 ID；占位图图层为 null。
  final String? assetId;

  /// 当前不透明度（0~1）。
  final double opacity;

  /// 是否是内置占位图图层。
  bool get isPlaceholder;
}

/// 内置占位图。
///
/// 需求：没有默认图片时使用内置占位图。
/// 这里**用代码绘制**而不是打包一张 PNG——
/// 这样即使 assets 资源加载失败，占位图也一定可用（这正是它存在的意义）。
class BuiltinPlaceholder {
  BuiltinPlaceholder._();

  static const ui.Size size = ui.Size(256, 192);

  static void paint(Canvas canvas, ui.Size target) {
    final double w = target.width;
    final double h = target.height;
    final Rect body = Rect.fromLTWH(w * 0.18, h * 0.14, w * 0.64, h * 0.72);

    final Paint fill = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF8FB8DE).withValues(alpha: 0.85);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (w * 0.012).clamp(1.5, 6.0)
      ..color = const Color(0xFF2F4A63);

    final RRect rounded = RRect.fromRectAndRadius(body, Radius.circular(w * 0.06));
    canvas
      ..drawRRect(rounded, fill)
      ..drawRRect(rounded, stroke);

    // 两只眼睛
    final double eyeR = w * 0.035;
    final Paint eye = Paint()..color = const Color(0xFF2F4A63);
    canvas
      ..drawCircle(Offset(w * 0.38, h * 0.44), eyeR, eye)
      ..drawCircle(Offset(w * 0.62, h * 0.44), eyeR, eye);

    // 嘴巴：一条短横线，表明这是"占位"
    final Paint mouth = Paint()
      ..color = const Color(0xFF2F4A63)
      ..strokeWidth = (w * 0.012).clamp(1.5, 6.0)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.44, h * 0.62), Offset(w * 0.56, h * 0.62), mouth);
  }
}

/// 供渲染器复用：判断缩放是否需要走最近邻。
ui.FilterQuality filterQualityFor({required bool smooth}) =>
    smooth ? ui.FilterQuality.medium : ui.FilterQuality.none;
