/// 桌宠宿主机抽象（Phase 4A）。
///
/// 语义：**桌宠组件需要的"窗口级"能力**。
/// * Windows：窗口拖动（`window_manager.startDragging`）与按素材尺寸调整窗口；
/// * Android（Phase 4A）：应用内页面，不需要窗口操作，实现为 no-op；
///   Phase 4C 的应用内桌宠只需要手势拖动，Phase 4D 的悬浮窗再引入新的宿主。
///
/// 抽出来的目的：`ui/pet/pet_view.dart` 不再直接 import `window_manager`，
/// 于是 Android 编译单元不可能拉进桌面窗口库。
abstract interface class PetHost {
  /// 用户按住桌宠开始拖动。
  Future<void> beginDrag();

  /// 按素材尺寸调整宿主大小（Android 上是 no-op）。
  Future<void> resizeForPet({required double width, required double height});
}

/// 什么都不做的实现（Android / 测试）。
class NoopPetHost implements PetHost {
  const NoopPetHost();

  @override
  Future<void> beginDrag() async {}

  @override
  Future<void> resizeForPet({required double width, required double height}) async {}
}
