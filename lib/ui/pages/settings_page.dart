import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../core/constants.dart';
import '../../platform/startup_registrar.dart';
import '../../settings/app_settings.dart';
import '../../settings/startup_registration_service.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../widgets/fixed_canvas_diagnostics_switches.dart';
import '../widgets/overlay_pet_card.dart';
import '../widgets/wheel_menu_diagnostics_card.dart';
import '../widgets/wheel_settings_card.dart';

/// 设置页面（需求 9.5）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.overlay,
    this.library,
  });

  final AppServices services;

  /// Android 悬浮桌宠协调器（Phase 4C）。
  ///
  /// 只有 Android 外壳会创建它；Windows 上为 null，且
  /// [PlatformCapabilities.supportsFloatingPet] 也是 false，整个分区都不会渲染。
  final OverlayPetController? overlay;

  /// 素材库控制器（Phase 4C-6A.1：「编辑状态素材」快捷入口需要它）。
  ///
  /// 可为 null：既有测试与旧调用点只关心其它设置项。
  final LibraryController? library;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (BuildContext context, Widget? _) {
        final AppSettings s = services.settings.settings;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            _section('窗口'),
            _switchTile(
              title: '始终置顶',
              subtitle: '桌宠始终显示在其他窗口之上',
              value: s.alwaysOnTop,
              onChanged: (bool v) async {
                await services.settings.setAlwaysOnTop(v);
                await services.windowController.applySettings(services.settings.settings);
              },
            ),
            _switchTile(
              title: '鼠标穿透',
              subtitle: '开启后鼠标点击会落到下层窗口，桌宠变成纯装饰',
              value: s.ignoreMouseEvents,
              onChanged: (bool v) async {
                await services.settings.setIgnoreMouseEvents(v);
                await services.windowController.applySettings(services.settings.settings);
              },
            ),
            _switchTile(
              title: '锁定位置',
              subtitle: '禁止拖动桌宠',
              value: s.lockPosition,
              onChanged: (bool v) async {
                await services.settings.setLockPosition(v);
                await services.windowController.applySettings(services.settings.settings);
              },
            ),
            _switchTile(
              title: '全屏时自动隐藏',
              subtitle: '检测到前台应用全屏时隐藏桌宠（阶段 1 接入检测后生效，'
                  '阶段 0 仅保存该偏好）',
              value: s.hideOnFullscreen,
              onChanged: (bool v) => services.settings.setHideOnFullscreen(v),
            ),
            const SizedBox(height: 12),
            _section('显示'),
            ListTile(
              title: const Text('缩放倍率'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('当前 ${s.scale.toInt()}×'
                      '（${s.smoothScaling ? '平滑缩放' : '最近邻缩放'}）'),
                  const SizedBox(height: 4),
                  SegmentedButton<int>(
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(value: 1, label: Text('1×')),
                      ButtonSegment<int>(value: 2, label: Text('2×')),
                      ButtonSegment<int>(value: 3, label: Text('3×')),
                      ButtonSegment<int>(value: 4, label: Text('4×')),
                    ],
                    selected: <int>{s.scale.toInt()},
                    onSelectionChanged: (Set<int> v) async {
                      await services.settings.setScale(v.first.toDouble());
                      await services.windowController
                          .applySettings(services.settings.settings);
                    },
                  ),
                ],
              ),
            ),
            _switchTile(
              title: '平滑缩放',
              subtitle: '关闭时使用最近邻缩放 —— 像素画在整数倍放大下更清晰（默认）',
              value: s.smoothScaling,
              onChanged: (bool v) => services.settings.setSmoothScaling(v),
            ),
            ListTile(
              title: Text('整体透明度 ${(s.opacity * 100).round()}%'),
              subtitle: Slider(
                min: 20,
                max: 100,
                divisions: 16,
                value: (s.opacity * 100).clamp(20, 100),
                label: '${(s.opacity * 100).round()}%',
                onChanged: (double v) => services.settings.setOpacity(v / 100),
              ),
            ),
            ListTile(
              title: Text('切换淡入淡出 ${s.crossFadeMs} ms'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Slider(
                    min: RenderTimings.crossFadeMinMs.toDouble(),
                    max: RenderTimings.crossFadeMaxMs.toDouble(),
                    divisions: (RenderTimings.crossFadeMaxMs - RenderTimings.crossFadeMinMs) ~/ 10,
                    value: s.crossFadeMs
                        .clamp(RenderTimings.crossFadeMinMs, RenderTimings.crossFadeMaxMs)
                        .toDouble(),
                    label: '${s.crossFadeMs} ms',
                    onChanged: (double v) => services.settings.setCrossFadeMs(v.round()),
                  ),
                  const Text('需求约束：150 ~ 300 ms', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            _switchTile(
              title: '动画循环播放',
              subtitle: '关闭后动态图只播放一轮并停在最后一帧',
              value: s.loopAnimation,
              onChanged: (bool v) => services.settings.setLoopAnimation(v),
            ),
            const SizedBox(height: 12),
            _section('角色'),
            _buildCharacterPicker(context, s),
            const SizedBox(height: 12),
            // 「开机自动启动」是 Windows 专属能力（写 HKCU\...\Run）：
            // Android 上没有等价机制，按能力表**隐藏**整个分区，而不是显示一个点了会报错的开关。
            if (services.platform.capabilities.supportsLaunchAtStartup) ...<Widget>[
              _section('启动'),
              StartupSwitchTile(service: services.startupRegistration),
            ],
            // 「悬浮桌宠」是 Android 专属能力（系统级悬浮窗，Phase 4C）：
            // Windows 的桌宠本身就是独立窗口，不需要这一分区。
            if (services.platform.capabilities.supportsFloatingPet &&
                overlay != null) ...<Widget>[
              const SizedBox(height: 12),
              _section('悬浮桌宠'),
              OverlayPetCard(
                controller: overlay!,
                services: services,
                library: library,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () async {
                    await services.windowController.moveTo(0, 0);
                  },
                  icon: const Icon(Icons.my_location, size: 16),
                  label: const Text('把桌宠移回屏幕右上角'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final bool? ok = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext ctx) => AlertDialog(
                        title: const Text('恢复默认设置'),
                        content: const Text('将把所有窗口与显示设置恢复为默认值（不会删除素材）。'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('恢复'),
                          ),
                        ],
                      ),
                    );
                    if (ok ?? false) {
                      await services.settings.resetToDefaults();
                      await services.windowController
                          .applySettings(services.settings.settings);
                      // 需求 9：恢复默认设置时同步删除系统启动项，
                      // 否则会出现"设置说没开启、系统登录时仍然自动启动"。
                      try {
                        await services.startupRegistration.removeForReset();
                      } on StartupRegistrationException catch (e) {
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (BuildContext ctx) => AlertDialog(
                            title: const Text('开机自启未清理'),
                            content: Text('设置已恢复默认，但删除系统启动项失败：\n${e.message}'),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('知道了'),
                              ),
                            ],
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.settings_backup_restore, size: 16),
                  label: const Text('恢复默认设置'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              color: const Color(0xFFF3F6FA),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('当前生效配置（已持久化到 SQLite local_settings 表）',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    SelectableText(
                      s.toKeyValues().entries
                          .map((MapEntry<String, String> e) => '${e.key} = ${e.value}')
                          .join('\n'),
                      style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                    ),
                  ],
                ),
              ),
            ),
            // 增量 B：正式 P3P 轮盘（仅桌面）。字段语义与 Android 完全一致。
            if (services.platform.capabilities.isDesktop) ...<Widget>[
              const SizedBox(height: 12),
              _section('桌宠轮盘'),
              WheelSettingsCard(services: services),
            ],
            // 增量 A：轮盘菜单几何诊断（仅桌面；非侵入式，放在设置页最下方）。
            if (services.platform.capabilities.isDesktop) ...<Widget>[
              const SizedBox(height: 12),
              _section('轮盘菜单诊断'),
              const WheelMenuDiagnosticsCard(),
              const FixedCanvasDiagnosticsSwitches(),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCharacterPicker(BuildContext context, AppSettings s) {
    return FutureBuilder<List<CharacterModel>>(
      future: services.repository.listCharacters(services.ownerId),
      builder: (BuildContext context, AsyncSnapshot<List<CharacterModel>> snap) {
        final List<CharacterModel> chars = snap.data ?? const <CharacterModel>[];
        if (chars.isEmpty) {
          return const ListTile(
            title: Text('默认角色'),
            subtitle: Text('尚未导入任何角色，请先到「素材库」导入素材'),
          );
        }
        final String? current = chars.any((CharacterModel c) => c.id == s.defaultCharacterId)
            ? s.defaultCharacterId
            : null;

        return Column(
          children: <Widget>[
            ListTile(
              title: const Text('默认角色'),
              subtitle: const Text('应用启动时使用该角色'),
              trailing: DropdownButton<String?>(
                value: current,
                hint: const Text('跟随上次使用'),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(child: Text('跟随上次使用')),
                  for (final CharacterModel c in chars)
                    DropdownMenuItem<String?>(
                      value: c.id,
                      child: Text(c.displayName),
                    ),
                ],
                onChanged: (String? v) => services.settings.setDefaultCharacter(v),
              ),
            ),
            ListTile(
              title: const Text('默认表情'),
              subtitle: const Text('状态映射未命中时，回退链会用到它（等价于角色默认图片）'),
              trailing: FutureBuilder<List<EmotionAsset>>(
                future: current == null
                    ? Future<List<EmotionAsset>>.value(const <EmotionAsset>[])
                    : services.repository.listRenderableAssets(current),
                builder: (
                  BuildContext context,
                  AsyncSnapshot<List<EmotionAsset>> assetSnap,
                ) {
                  final List<EmotionAsset> assets =
                      assetSnap.data ?? const <EmotionAsset>[];
                  return DropdownButton<String?>(
                    value: assets.any((EmotionAsset a) => a.id == s.defaultAssetId)
                        ? s.defaultAssetId
                        : null,
                    hint: const Text('未设置'),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(child: Text('未设置')),
                      for (final EmotionAsset a in assets)
                        DropdownMenuItem<String?>(
                          value: a.id,
                          child: Text('${a.emotionName} / ${a.variantName}'),
                        ),
                    ],
                    onChanged: (String? v) async {
                      await services.settings.setDefaultAsset(v);
                      if (current != null) {
                        await services.repository.setCharacterDefaultAsset(current, v);
                        await services.stateEngine.refresh();
                      }
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2F4A63),
          ),
        ),
      );

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        dense: true,
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        value: value,
        onChanged: onChanged,
      );
}

/// 「开机自动启动」开关（Windows 专属）。
///
/// 为什么单独一个 StatefulWidget
/// ----------------------------
/// 它的值来自**系统真实注册状态**（`HKCU\...\Run`），不是 `AppSettings`：
///
/// * 每次重建都去读注册表会变成每帧一次 FFI 调用，所以把结果缓存在 State 里；
/// * 打开/关闭是异步且**可能失败**的操作，失败时必须把开关**回滚**到真实状态
///   并把原因显示出来（需求 8："不能假装成功"）；
/// * 监听 [StartupRegistrationService]（它是 `ChangeNotifier`）：这样
///   「恢复默认设置」清掉启动项之后，开关会重新按系统实况渲染。
class StartupSwitchTile extends StatefulWidget {
  const StartupSwitchTile({super.key, required this.service});

  final StartupRegistrationService service;

  @override
  State<StartupSwitchTile> createState() => _StartupSwitchTileState();
}

class _StartupSwitchTileState extends State<StartupSwitchTile> {
  bool _registered = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _registered = widget.service.isRegistered();
    widget.service.addListener(_syncWithSystem);
  }

  @override
  void dispose() {
    widget.service.removeListener(_syncWithSystem);
    super.dispose();
  }

  /// 系统状态可能变了（开关本身、启动对齐、恢复默认设置）→ 重新读一次实况。
  void _syncWithSystem() {
    if (!mounted) return;
    final bool registered = widget.service.isRegistered();
    if (registered != _registered) {
      setState(() => _registered = registered);
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    String? failure;
    try {
      await widget.service.setEnabled(value);
    } on StartupRegistrationException catch (e) {
      failure = e.message;
    }

    if (!mounted) return;
    setState(() {
      // 不论成功失败都以**系统实况**为准：失败时这就是"回滚"。
      _registered = widget.service.isRegistered();
      _error = failure;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? command = _registered ? widget.service.registeredCommandOrNull() : null;
    return SwitchListTile(
      dense: true,
      value: _registered,
      onChanged: _busy ? null : _toggle,
      title: Row(
        children: <Widget>[
          const Text('开机自动启动', style: TextStyle(fontSize: 13)),
          if (_busy) ...<Widget>[
            const SizedBox(width: 8),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '登录 Windows 后自动启动桌宠（写入当前用户的启动项，不需要管理员权限）',
            style: TextStyle(fontSize: 11),
          ),
          if (command != null)
            Text(
              '已注册：$command',
              style: const TextStyle(fontSize: 10, fontFamily: 'Consolas'),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '操作失败：$_error',
                style: const TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
              ),
            ),
        ],
      ),
    );
  }
}
