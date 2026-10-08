import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/menu/wheel_geometry_ownership.dart';
import 'package:petlife/menu/wheel_window_ops.dart';
import 'package:petlife/platform/windows/windows_pet_host.dart';

/// 增量 A 修复：窗口尺寸写入**最低层守卫**的用例。
///
/// 需求 §2 明确要求：`WindowsPetHost.resizeForPet` 必须**自己**再查一次所有权，
/// 因为 UI 层的 `manageWindowSize` 无法取消已入队的 post-frame 回调。
void main() {
  late _FakeSizeIo io;
  late WheelSurfaceGeometry surface;
  late WheelGeometryJournal journal;

  setUp(() {
    io = _FakeSizeIo()..bounds = const Rect.fromLTWH(600, 400, 256, 192);
    journal = WheelGeometryJournal();
    surface = WheelSurfaceGeometry(journal: journal);
  });

  test('#2 过渡期 resizeForPet 不产生任何窗口写入（记录为 dropped）', () async {
    surface.change(WindowsSurfaceGeometryOwner.wheelTransition, source: 'test');
    final WindowsPetHost host =
        WindowsPetHost(io: io, surface: surface, journal: journal);

    await host.resizeForPet(width: 256, height: 192);

    expect(io.writes, isEmpty, reason: '过渡期绝不能写窗口尺寸');
    expect(journal.contains('pet.resize.dropped'), isTrue);
    expect(journal.contains('geometry.size.write'), isFalse);
  });

  test('#6b 菜单稳定开放（wheel）时同样不得被 pet resize 覆盖', () async {
    surface.change(WindowsSurfaceGeometryOwner.wheel, source: 'test');
    final WindowsPetHost host =
        WindowsPetHost(io: io, surface: surface, journal: journal);

    await host.resizeForPet(width: 256, height: 192);

    expect(io.writes, isEmpty);
    expect(journal.lastOf('pet.resize.dropped')!.fields['owner'], 'wheel');
  });

  test('#11 owner=pet 时正常写入，并记录 before/after 尺寸写入', () async {
    final WindowsPetHost host =
        WindowsPetHost(io: io, surface: surface, journal: journal);

    await host.resizeForPet(width: 300, height: 200);

    expect(io.writes.single, const Size(300, 200));
    final WheelGeometryEvent? write = journal.lastOf('geometry.size.write');
    expect(write, isNotNull);
    expect(write!.fields['source'], 'WindowsPetHost.resizeForPet');
    expect(write.fields['before'], isNotNull);
    expect(write.fields['after'], isNotNull);
  });
}

class _FakeSizeIo implements PetWindowSizeIo {
  final List<Size> writes = <Size>[];
  Rect? bounds;

  @override
  Future<Rect?> readBounds() async => bounds;

  @override
  Future<void> setSize(Size size) async {
    writes.add(size);
  }
}
