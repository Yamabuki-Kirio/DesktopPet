import 'package:flutter/material.dart';

import '../../character/pet_renderer.dart';
import '../../menu/wheel_geometry_ownership.dart';
import 'pet_frame_controller.dart';
import 'pet_host.dart';

/// 桌宠绘制控件。
///
/// 只做两件事：把 [PetRenderer] 的图层画出来、把拖动事件交给 [PetHost]。
/// 缩放、透明度、淡入淡出全部由外部传入，便于换宿主时复用。
///
/// 平台差异全部藏在 [PetHost] 后面：Windows 由 window_manager 拖动窗口，
/// Android 是应用内页面（`NoopPetHost`，不拖动、不改窗口尺寸）。
class PetView extends StatefulWidget {
  const PetView({
    super.key,
    required this.renderer,
    required this.scale,
    required this.smoothScaling,
    required this.opacity,
    required this.lockPosition,
    this.manageWindowSize = true,
    this.host,
    this.onDoubleTap,
    this.onRightClick,
    this.onTap,
  });

  final PetRenderer renderer;

  /// 整数倍缩放（1×~4×）。
  final double scale;

  /// false = 最近邻（像素画默认），true = 平滑插值。
  final bool smoothScaling;

  /// 整体不透明度。
  final double opacity;

  /// 锁定位置时禁用拖动。
  final bool lockPosition;

  /// 是否由本控件负责把宿主尺寸同步为素材尺寸。
  ///
  /// 控制面板里的「实时预览」必须传 false，否则会和桌宠窗口本身互相打架。
  final bool manageWindowSize;

  /// 宿主（窗口级能力）。为 null 时既不拖动也不同步尺寸。
  final PetHost? host;

  final VoidCallback? onDoubleTap;

  /// 右键桌宠：回调收到**指针的全局坐标**（`TapDownDetails.globalPosition`）。
  ///
  /// 为什么要坐标而不是 `VoidCallback`：固定画布模式下 Overlay 尺寸 = 整块画布，
  /// 旧实现只能把菜单锚在画布右下角，离桌宠很远。有了指针坐标就能把菜单锚在
  /// 指针附近（真机回归修复）。
  final ValueChanged<Offset>? onRightClick;

  /// 单击桌宠（Windows 上用于打开轮盘菜单探针）。
  final VoidCallback? onTap;

  @override
  State<PetView> createState() => _PetViewState();
}

class _PetViewState extends State<PetView> {
  double? _lastAppliedW;
  double? _lastAppliedH;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.renderer,
      builder: (BuildContext context, Widget? _) {
        final Size content = widget.renderer.contentSize ?? BuiltinPlaceholder.size;
        final double w = content.width * widget.scale;
        final double h = content.height * widget.scale;

        // 桌面窗口尺寸必须跟随素材尺寸 × 缩放，否则素材会被裁切。
        if (widget.manageWindowSize) _scheduleWindowResize(w, h);

        return Opacity(
          opacity: widget.opacity.clamp(0.0, 1.0),
          // 左键链路审计（真机回归 #1）：把"指针真的到达了桌宠 Widget"这件事记下来。
          // 用 `Listener`（默认 `deferToChild`）**不改变任何命中测试语义**，
          // 只旁路记录，因此不会抢走单击 / 双击 / 右键 / 拖动。
          child: Listener(
            onPointerDown: (PointerDownEvent e) => wheelGeometryJournal.record(
              'pet.pointer.down',
              fields: <String, Object?>{
                'button': e.buttons,
                'kind': e.kind.name,
                'x': e.position.dx,
                'y': e.position.dy,
              },
            ),
            onPointerUp: (PointerUpEvent e) => wheelGeometryJournal.record(
              'pet.pointer.up',
              fields: <String, Object?>{
                'button': e.buttons,
                'kind': e.kind.name,
              },
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap == null
                  ? null
                  : () {
                      wheelGeometryJournal.record(
                        'pet.tap.recognized',
                        fields: <String, Object?>{'hasHandler': true},
                      );
                      widget.onTap!();
                    },
              onDoubleTap: widget.onDoubleTap,
              // 右键菜单锚点需要**指针的全局坐标**，因此在 down 阶段捕获
              // （`onSecondaryTap` 不带坐标，会把菜单钉在 Overlay 右下角）。
              onSecondaryTapDown: widget.onRightClick == null
                  ? null
                  : (TapDownDetails details) =>
                      widget.onRightClick!(details.globalPosition),
              // 无边框窗口没有系统标题栏，拖动必须显式交给宿主。
              onPanStart: (widget.lockPosition || widget.host == null)
                  ? null
                  : (DragStartDetails _) => _startDrag(),
              child: MouseRegion(
                cursor: widget.lockPosition ? SystemMouseCursors.basic : SystemMouseCursors.grab,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: CustomPaint(
                    size: Size(w, h),
                    painter: PetLayerPainter(
                      layers: widget.renderer.layers,
                      smooth: widget.smoothScaling,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _startDrag() async {
    try {
      await widget.host?.beginDrag();
    } catch (_) {
      // 拖动失败（例如窗口已锁定）不影响显示。
    }
  }

  /// 只在尺寸真的变化时才调用宿主，避免每帧触发窗口 API。
  ///
  /// **增量 A 修复（几何所有权竞态）**：post-frame 回调是异步排队的，
  /// 单靠 `manageWindowSize` 布尔量无法取消已入队的回调。这里在调度时**捕获代际**，
  /// 并在回调真正执行前重查全部条件（挂载 / 代际 / 所有权 / 菜单是否打开）；
  /// 任一不满足即**丢弃**该次 resize（信息级日志，不是错误）。
  void _scheduleWindowResize(double w, double h) {
    final PetHost? host = widget.host;
    if (host == null) return;
    if (_lastAppliedW == w && _lastAppliedH == h) return;

    // 过渡期 / 菜单期直接不调度，也不占用"已应用尺寸"标记，
    // 这样所有权回到 pet 后尺寸仍能正确跟随（例如过渡中换了素材）。
    if (!wheelSurfaceGeometry.allowsPetResize) {
      wheelGeometryJournal.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'reason': 'owner_${wheelSurfaceGeometry.owner.wireName}',
          'stage': 'schedule',
          'generation': wheelSurfaceGeometry.generation,
          'w': w,
          'h': h,
        },
      );
      return;
    }

    final int generation = wheelSurfaceGeometry.generation;
    _lastAppliedW = w;
    _lastAppliedH = h;
    wheelGeometryJournal.record(
      'pet.resize.scheduled',
      fields: <String, Object?>{'generation': generation, 'w': w, 'h': h},
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final String? drop = PetResizeDecision.evaluate(
        mounted: mounted,
        scheduledGeneration: generation,
        surface: wheelSurfaceGeometry,
      );
      if (drop != null) {
        wheelGeometryJournal.record(
          'pet.resize.dropped',
          fields: <String, Object?>{
            'reason': drop,
            'stage': 'callback',
            'generation': generation,
            'w': w,
            'h': h,
          },
        );
        return;
      }
      try {
        await host.resizeForPet(width: w, height: h);
        wheelGeometryJournal.record(
          'pet.resize.executed',
          fields: <String, Object?>{'generation': generation, 'w': w, 'h': h},
        );
      } catch (_) {
        // 忽略。
      }
    });
  }
}

/// 把所有图层按顺序画出来。
///
/// 公开（而不是 `_` 私有）是为了让单元测试能够直接构造两个 Painter 并调用
/// [shouldRepaint] 验证「动画帧变化一定会触发重绘」。
class PetLayerPainter extends CustomPainter {
  const PetLayerPainter({required this.layers, required this.smooth});

  final List<PetRenderLayer> layers;
  final bool smooth;

  @override
  void paint(Canvas canvas, Size size) {
    for (final PetRenderLayer layer in layers) {
      if (layer.opacity <= 0.001) continue;

      if (layer.isPlaceholder) {
        _withOpacity(canvas, size, layer.opacity, () => BuiltinPlaceholder.paint(canvas, size));
        continue;
      }

      if (layer is AnimationRenderLayer) {
        final image = layer.image;
        final Paint paint = Paint()
          // 像素画默认最近邻，避免 2×/3×/4× 放大后发虚（验收第 9 项）。
          ..filterQuality = smooth ? FilterQuality.medium : FilterQuality.none
          ..isAntiAlias = smooth;
        _withOpacity(canvas, size, layer.opacity, () {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
            Offset.zero & size,
            paint,
          );
        });
      }
    }
  }

  /// 用 saveLayer 的 alpha 实现整层不透明度（占位图有多次绘制，不能靠 paint.color）。
  void _withOpacity(Canvas canvas, Size size, double opacity, VoidCallback draw) {
    if (opacity >= 0.999) {
      draw();
      return;
    }
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: opacity),
    );
    draw();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PetLayerPainter oldDelegate) {
    if (oldDelegate.smooth != smooth) return true;
    if (oldDelegate.layers.length != layers.length) return true;

    // 动画图层持有的是同一个可变 DecodedAnimation，image / frameIndex 都是实时
    // getter，旧 Painter 与新 Painter 读取到的是同一份「当前状态」，因此
    // identical(image) 永远成立，无法感知帧变化（缺陷：动态 WebP 不重绘）。
    //
    // 只要存在动画图层就一律重绘：帧定时器只在 advance() 真正推进成功后才会
    // notifyListeners()，静态图（frameCount == 1）根本不会启动定时器，因此
    // 这里返回 true 不会造成静态图持续重绘；淡入淡出期间的每步 tick 本身
    // 也确实需要重绘。
    if (layers.any((PetRenderLayer layer) => layer is AnimationRenderLayer)) {
      return true;
    }

    // 无动画图层时（纯占位图 / 空图层）继续细粒度比较。
    for (int i = 0; i < layers.length; i++) {
      final PetRenderLayer a = oldDelegate.layers[i];
      final PetRenderLayer b = layers[i];
      if (a.opacity != b.opacity) return true;
      if (a.isPlaceholder != b.isPlaceholder) return true;
    }
    return false;
  }
}
