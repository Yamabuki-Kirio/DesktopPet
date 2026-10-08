import 'dart:ui' show Rect, Size;

import 'package:window_manager/window_manager.dart';

import '../../menu/wheel_geometry_ownership.dart';
import '../../menu/wheel_window_ops.dart';
import '../../menu/windows_surface_mode.dart';
import '../../ui/pet/pet_host.dart';

/// 默认尺寸 IO：直接走 `window_manager`。
class WindowManagerPetSizeIo implements PetWindowSizeIo {
  const WindowManagerPetSizeIo();

  @override
  Future<Rect?> readBounds() async {
    try {
      return await windowManager.getBounds();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setSize(Size size) => windowManager.setSize(size);
}

/// Windows 桌宠宿主：把拖动与尺寸同步交给 `window_manager`。
///
/// 行为与阶段 0/1 完全一致（原实现直接写在 `ui/pet/pet_view.dart` 里），
/// 只是搬到了平台层，让 `PetView` 不再 import `window_manager`。
///
/// **增量 A 修复**：这里是窗口尺寸写入的**最低层**。UI 层的
/// `manageWindowSize` 布尔量无法取消已经入队的 post-frame 回调，因此本层必须
/// 自己再查一次几何所有权 —— 轮盘过渡 / 展示期间绝不写入窗口尺寸。
class WindowsPetHost implements PetHost {
  const WindowsPetHost({
    PetWindowSizeIo? io,
    WheelSurfaceGeometry? surface,
    WheelGeometryJournal? journal,
  })  : _io = io,
        _surface = surface,
        _journal = journal;

  final PetWindowSizeIo? _io;
  final WheelSurfaceGeometry? _surface;
  final WheelGeometryJournal? _journal;

  PetWindowSizeIo get _sizeIo => _io ?? const WindowManagerPetSizeIo();

  WheelSurfaceGeometry get _ownership => _surface ?? wheelSurfaceGeometry;

  WheelGeometryJournal get _log => _journal ?? wheelGeometryJournal;

  @override
  Future<void> beginDrag() {
    // 模式守卫：只有稳定的桌宠态允许拖动窗口。过渡 / 面板态下丢弃拖动请求，
    // 否则用户可能在切换途中把面板 / 画布拖走。
    if (!windowsSurfaceSession.mode.allowsPetResize) {
      return Future<void>.value();
    }
    return windowManager.startDragging();
  }

  @override
  Future<void> resizeForPet({required double width, required double height}) async {
    // 模式守卫（必须最先查）：过渡 / 面板态下禁止按素材尺寸写窗口。
    if (!windowsSurfaceSession.mode.allowsPetResize) {
      _log.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'source': 'WindowsPetHost.resizeForPet',
          'reason': 'surface_${windowsSurfaceSession.mode.wireName}',
          'w': width,
          'h': height,
        },
      );
      return;
    }
    final WheelSurfaceGeometry ownership = _ownership;
    // 最低层守卫：被抢占时直接丢弃（记录为信息级事件，不是错误）。
    if (!ownership.allowsPetResize) {
      _log.record(
        'pet.resize.dropped',
        fields: <String, Object?>{
          'source': 'WindowsPetHost.resizeForPet',
          'owner': ownership.owner.wireName,
          'generation': ownership.generation,
          'w': width,
          'h': height,
        },
      );
      return;
    }

    final PetWindowSizeIo io = _sizeIo;
    final Rect? before = await io.readBounds();
    await io.setSize(Size(width, height));
    final Rect? after = await io.readBounds();
    _log.recordSizeWrite(
      source: 'WindowsPetHost.resizeForPet',
      generation: ownership.generation,
      owner: ownership.owner,
      requested: Rect.fromLTWH(before?.left ?? 0, before?.top ?? 0, width, height),
      before: before,
      after: after,
    );
  }
}
