/// **人物视觉边界（alpha 包围盒）** —— C1.1 的坐标管线起点。
///
/// 为什么必须有这个文件
/// ------------------
/// 真机验收（2026-10-07）暴露的根因之一：Windows 一直用**素材文件尺寸**
/// （或"Widget 矩形 × 0.86"）当作"人物可见区域"。而 Ace Attorney 立绘
/// 普遍带大量透明留白 —— 实测 `Maya_Cheerful_1.webp`：
///
/// * 文件尺寸 `256×192`；
/// * 9 帧 alpha 并集只有 `92×156`（占宽 35.9%、占高 81.3%）；
/// * 且**偏下**：上边在 18.75%，下边贴到 100%。
///
/// 用 256×192（或 220×165）当可见区，会让轮盘中央缺口核半径
/// （`visible × 1.05 / 2 + 10dp`）凭空放大 2.4 倍，环半径被这个下界顶住，
/// 于是"用户把轮盘调到 60% 仍然巨大"，缺口中心也与人物视觉中心差 18px。
///
/// Android 的做法（`PetContentBounds.kt`）是**采样解码一次**量 alpha 包围盒，
/// 结果以**相对比例**（0~1）缓存 —— 它只取决于素材本身，与窗口尺寸 / 缩放 /
/// DPI 都无关。本文件是该口径在 Dart 侧的实现，并额外满足需求 §二：
///
/// * **动态素材**：逐帧测量，取"整段动画所有帧的**稳定并集**"（避免播放时抖动）；
/// * **缓存**：按 `(assetId, frameIndex)` 缓存，绝不对同一帧重复扫像素；
/// * **纯函数**：包围盒计算与 `dart:ui` 解码分离，可在 `flutter_tester` 直接单测。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;

/// 归一化的**视觉边界**：四个分量都是相对素材文件的 0~1 比例。
///
/// 之所以用比例而不是像素：同一份测量结果要能喂给任意窗口尺寸 / 缩放 / DPI 的
/// 场景，且与旋转、多显示器无关，可以长期缓存。
@immutable
class PetVisualBounds {
  const PetVisualBounds(this.left, this.top, this.right, this.bottom);

  /// 整张素材（无法测量时的兜底）。
  static const PetVisualBounds full = PetVisualBounds(0, 0, 1, 1);

  /// 边界必须至少占素材的这个比例，否则视为测量失真（防"全透明素材 → 0 面积"）。
  static const double minSpanRatio = 0.05;

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 宽度比例（**夹到** [minSpanRatio, 1]）。
  double get width => (right - left).clamp(minSpanRatio, 1.0);

  /// 高度比例（**夹到** [minSpanRatio, 1]）。
  double get height => (bottom - top).clamp(minSpanRatio, 1.0);

  double get centerX => left + width / 2;

  double get centerY => top + height / 2;

  /// 是否等于整张素材（没量到 / 量失败）。
  bool get isFull =>
      left <= 0.001 && top <= 0.001 && right >= 0.999 && bottom >= 0.999;

  /// 把归一化边界映射到**任意矩形**（Widget 矩形 / 素材像素矩形）。
  ///
  /// 顺序里只有这一处乘法：`rect.left + rect.width * left`。
  /// 不引入 DPR、不再叠任何缩放。
  ui.Rect toRect(ui.Rect rect) => ui.Rect.fromLTRB(
        rect.left + rect.width * left,
        rect.top + rect.height * top,
        rect.left + rect.width * right,
        rect.top + rect.height * bottom,
      );

  /// 多帧并集（稳定并集：取各帧的最小左/上、最大右/下）。
  PetVisualBounds union(PetVisualBounds other) => PetVisualBounds(
        math.min(left, other.left),
        math.min(top, other.top),
        math.max(right, other.right),
        math.max(bottom, other.bottom),
      );

  /// 日志 / 持久化取值（`0.305,0.188,0.664,1.000`）。
  String describe() => '${left.toStringAsFixed(4)},${top.toStringAsFixed(4)},'
      '${right.toStringAsFixed(4)},${bottom.toStringAsFixed(4)}';

  @override
  bool operator ==(Object other) =>
      other is PetVisualBounds &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PetVisualBounds(${describe()})';
}

/// alpha 包围盒**测量器**（纯函数 + 一次 `ui.Image` 取像素）。
///
/// 与 Android `PetAlphaBounds` 同口径：
/// * alpha ≤ [alphaThreshold] 视为透明（抗锯齿边缘会产生 1~10 的噪声）；
/// * 全透明素材 → 返回 [PetVisualBounds.full]（此时缺口大小已无意义，但不能返回 0 面积）；
/// * 大图**降采样扫描**（步长采样），并把边界**外扩一个步长**，
///   保证结果是保守的（宁可略大，也不能漏掉人物边缘）。
abstract final class PetAlphaBoundsScanner {
  /// alpha 低于该值视为透明。
  static const int alphaThreshold = 12;

  /// 单次扫描的像素预算（超过则按步长采样）。
  static const int maxScanPixels = 1 << 20; // 1M

  /// 从 **RGBA8888** 字节量出包围盒。
  ///
  /// [rgba] 长度必须 ≥ `width * height * 4`（`ui.Image.toByteData(rawRgba)` 的布局）。
  static PetVisualBounds measureRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int threshold = alphaThreshold,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return PetVisualBounds.full;
    }
    final int total = width * height;
    // 步长采样：预算内逐像素扫；超预算时按 sqrt 比例跳采（保守外扩）。
    final int stride =
        total <= maxScanPixels ? 1 : math.sqrt(total / maxScanPixels).ceil();

    int minX = width;
    int minY = height;
    int maxX = -1;
    int maxY = -1;
    for (int y = 0; y < height; y += stride) {
      final int rowBase = y * width;
      for (int x = 0; x < width; x += stride) {
        final int alpha = rgba[(rowBase + x) * 4 + 3];
        if (alpha <= threshold) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0 || maxY < 0) return PetVisualBounds.full;

    // 采样命中会偏内 → 外扩一个步长，结果保守（宁可略大）。
    final int pad = stride - 1;
    final double l = (math.max(0, minX - pad)) / width;
    final double t = (math.max(0, minY - pad)) / height;
    final double r = (math.min(width, maxX + 1 + pad)) / width;
    final double b = (math.min(height, maxY + 1 + pad)) / height;
    return PetVisualBounds(l, t, r, b);
  }

  /// 从已解码图像量出包围盒（解码失败 / 已释放 → 回退 [PetVisualBounds.full]）。
  static Future<PetVisualBounds> measureImage(ui.Image image) async {
    try {
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return PetVisualBounds.full;
      return measureRgba(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
      );
    } catch (_) {
      // 图像在测量完成前被释放（动画推进会 dispose 旧帧）—— 视为"没量到"。
      return PetVisualBounds.full;
    }
  }
}

/// 每素材的视觉边界**缓存**（逐帧并集）。
///
/// 关键语义：
/// * `record(assetId, frame, bounds)` 只累加并集，**不会**因为某帧更小就缩小；
/// * [boundsOf] 返回当前并集；没量到过（或只量到全透明帧）时返回 `null`，
///   由调用方决定回退策略 —— **不要**在这里偷偷用 0.86 之类的假值。
class PetVisualBoundsCache {
  PetVisualBoundsCache({this.maxAssets = 32, this.maxFramesPerAsset = 240});

  /// 最多缓存多少个素材（LRU 淘汰）。
  final int maxAssets;

  /// 单素材最多记多少帧（防病态素材把内存吃光）。
  final int maxFramesPerAsset;

  final Map<String, _AssetBounds> _assets = <String, _AssetBounds>{};

  /// 记一帧的边界并累加并集。
  void record(String assetId, int frameIndex, PetVisualBounds bounds) {
    if (assetId.isEmpty) return;
    final _AssetBounds entry = _assets.putIfAbsent(assetId, _AssetBounds.new);
    if (!entry.frames.add(frameIndex)) return; // 该帧已量过
    if (entry.frames.length > maxFramesPerAsset) {
      // 超过上限：只保留并集（并集本身已经稳定，丢掉帧号即可）。
      entry.overflowed = true;
      entry.frames.clear();
    }
    entry.union = entry.union == null ? bounds : entry.union!.union(bounds);
    entry.touched = DateTime.now();
    _evictIfNeeded();
  }

  /// 当前并集（没量到过返回 null）。
  PetVisualBounds? boundsOf(String assetId) => _assets[assetId]?.union;

  /// 是否已经量过（至少一帧）。
  bool hasMeasured(String assetId) => _assets[assetId]?.union != null;

  /// 该素材的这一帧是否已经量过（避免重复扫同一帧的像素）。
  bool hasMeasuredFrame(String assetId, int frameIndex) =>
      _assets[assetId]?.frames.contains(frameIndex) ?? false;

  /// 某素材已量到的帧数（诊断用）。
  int measuredFrames(String assetId) => _assets[assetId]?.frames.length ?? 0;

  /// 该素材的帧数是否已达上限并溢出（诊断用）。
  bool overflowed(String assetId) => _assets[assetId]?.overflowed ?? false;

  /// 已缓存的素材数（诊断 / 测试用）。
  int get assetCount => _assets.length;

  /// 清空（素材被替换 / 变更时调用）。
  void invalidate(String assetId) => _assets.remove(assetId);

  /// 全部清空（退出 / 测试）。
  void clear() => _assets.clear();

  void _evictIfNeeded() {
    while (_assets.length > maxAssets) {
      String? oldestKey;
      DateTime? oldest;
      for (final MapEntry<String, _AssetBounds> e in _assets.entries) {
        if (oldest == null || e.value.touched.isBefore(oldest)) {
          oldest = e.value.touched;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) return;
      _assets.remove(oldestKey);
    }
  }
}

class _AssetBounds {
  PetVisualBounds? union;
  final Set<int> frames = <int>{};
  DateTime touched = DateTime.now();
  bool overflowed = false;
}
