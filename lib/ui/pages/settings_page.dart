import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../character/models/character_model.dart';
import '../../character/models/emotion_asset.dart';
import '../../core/constants.dart';
import '../../platform/startup_registrar.dart';
import '../../settings/app_settings.dart';
import '../../settings/startup_registration_service.dart';
import '../desktop/legacy/legacy_settings_page.dart';
import '../library_controller.dart';
import '../overlay_pet_controller.dart';
import '../theme/design_tokens.dart';
import '../theme/petlife_theme.dart';
import '../widgets/fixed_canvas_diagnostics_switches.dart';
import '../widgets/overlay_pet_card.dart';
import '../widgets/petlife/petlife_color_picker.dart';
import '../widgets/petlife/petlife_components.dart';
import '../widgets/petlife/petlife_page.dart';
import '../widgets/wheel_menu_diagnostics_card.dart';
import '../widgets/wheel_settings_card.dart';
import 'diagnostics_page.dart';
import 'settings_sections.dart';
import 'state_asset_mapping_page.dart';

/// 设置页面。
///
/// 按功能分为七组**独立圆角卡片**（需求 §2.6）：
/// 1. 桌宠 2. 外观与主题 3. 状态联动 4. 账户与同步 5. 权限 6. 高级 7. 诊断。
///
/// 不再连续堆叠大量灰色设置行：分组之间用 20dp 间距，组内用行间距，
/// **不使用分割线**组织内容。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.overlay,
    this.library,
    this.onOpenAccount,
  });

  final AppServices services;

  /// Android 悬浮桌宠协调器。
  ///
  /// 只有 Android 外壳会创建它；Windows 上为 null，且
  /// [PlatformCapabilities.supportsFloatingPet] 也是 false，整个分区都不会渲染。
  final OverlayPetController? overlay;

  /// 素材库控制器（「编辑状态素材」快捷入口需要它）。
  final LibraryController? library;

  /// 「账户与同步」分组里的跳转（由外壳提供；为 null 时该行不渲染）。
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) {
    // ⚠ Windows 控制面板与本页共用同一个类：桌面主题里没有 PetLifeTheme 扩展时
    // 原样回落到改造前的实现，保证「Windows UI 不受影响」。
    if (PetLifeTheme.maybeOf(context) == null) {
      return LegacySettingsPage(
        services: services,
        overlay: overlay,
        library: library,
      );
    }
    return ListenableBuilder(
      listenable: services.settings,
      builder: (BuildContext context, Widget? _) {
        final AppSettings s = services.settings.settings;
        final bool floating = services.platform.capabilities.supportsFloatingPet;
        final bool desktop = services.platform.capabilities.isDesktop;

        return PetLifePage(
          title: '设置',
          subtitle: '全部改动立即生效并持久化到本机数据库',
          actions: <Widget>[
            PetLifeHeaderAction(
              icon: Icons.monitor_heart_outlined,
              tooltip: '打开诊断',
              onPressed:
                  library == null ? null : () => _openDiagnostics(context),
            ),
          ],
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              // 分组的标题与顺序由 PetLifeSettingsSection 唯一定义（见 settings_sections.dart）。
              for (final PetLifeSettingsSection section
                  in PetLifeSettingsSection.values)
                ..._section(
                  context,
                  s,
                  section,
                  floating: floating,
                  desktop: desktop,
                ),
              const SizedBox(height: PetLifeSpacing.groupGap),
            ],
          ),
        );
      },
    );
  }

  /// 渲染一个分组。返回空列表表示该分组在当前平台不适用
  /// （例如「外观与主题」「权限」只属于 Android 控制面板）。
  List<Widget> _section(
    BuildContext context,
    AppSettings s,
    PetLifeSettingsSection section, {
    required bool floating,
    required bool desktop,
  }) {
    switch (section) {
      case PetLifeSettingsSection.pet:
        return _petGroup(context, s);
      case PetLifeSettingsSection.appearance:
        if (desktop) return const <Widget>[];
        return _appearanceGroup(context, s);
      case PetLifeSettingsSection.stateLink:
        return _stateLinkGroup(context, s, floating);
      case PetLifeSettingsSection.account:
        return _accountGroup(context, s);
      case PetLifeSettingsSection.permission:
        if (!floating) return const <Widget>[];
        return _permissionGroup(context);
      case PetLifeSettingsSection.advanced:
        return _advancedGroup(context, s, desktop);
      case PetLifeSettingsSection.diagnostics:
        return _diagnosticsGroup(context, s, desktop);
    }
  }

  void _openDiagnostics(BuildContext context) {
    final LibraryController? lib = library;
    if (lib == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => DiagnosticsPage(
          services: services,
          library: lib,
        ),
      ),
    );
  }

  /// 组：标题 + 一张圆角卡片。
  ///
  /// 标题与说明来自 [PetLifeSettingsSection]（唯一真相），
  /// 因此"分组叫什么、顺序如何"不可能与测试断言漂移。
  List<Widget> _group(
    PetLifeSettingsSection section, {
    required List<Widget> rows,
    Widget? footer,
  }) =>
      <Widget>[
        PetLifeSectionTitle(title: section.title, subtitle: section.subtitle),
        PetLifeCard(
          large: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ...rows,
              if (footer != null) ...<Widget>[
                const SizedBox(height: 6),
                footer,
              ],
            ],
          ),
        ),
        const SizedBox(height: PetLifeSpacing.groupGap),
      ];

  // ---------------------------------------------------------------------------
  // 1. 桌宠
  // ---------------------------------------------------------------------------

  List<Widget> _petGroup(BuildContext context, AppSettings s) => _group(
        PetLifeSettingsSection.pet,
        rows: <Widget>[
          PetLifeSliderRow(
            label: '缩放倍率',
            valueLabel: '${s.scale.toInt()}×',
            note: '需求约束：1× ~ 4× 的整数档（像素画在整数倍下最清晰）',
            slider: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final int factor in <int>[1, 2, 3, 4])
                  PetLifeTag(
                    label: '$factor×',
                    selected: s.scale.toInt() == factor,
                    onTap: () async {
                      await services.settings.setScale(factor.toDouble());
                      await services.windowController
                          .applySettings(services.settings.settings);
                    },
                  ),
              ],
            ),
          ),
          PetLifeSwitchRow(
            label: '平滑缩放',
            note: '关闭时使用最近邻缩放 —— 像素画在整数倍放大下更清晰（默认）',
            value: s.smoothScaling,
            onChanged: (bool v) => services.settings.setSmoothScaling(v),
          ),
          PetLifeSliderRow(
            label: '整体透明度',
            valueLabel: '${(s.opacity * 100).round()}%',
            slider: Slider(
              min: 20,
              max: 100,
              divisions: 16,
              value: (s.opacity * 100).clamp(20, 100),
              label: '${(s.opacity * 100).round()}%',
              onChanged: (double v) => services.settings.setOpacity(v / 100),
            ),
          ),
          PetLifeSliderRow(
            label: '状态切换淡入淡出',
            valueLabel: '${s.crossFadeMs} ms',
            note: '需求约束：150 ~ 300 ms',
            slider: Slider(
              min: RenderTimings.crossFadeMinMs.toDouble(),
              max: RenderTimings.crossFadeMaxMs.toDouble(),
              divisions:
                  (RenderTimings.crossFadeMaxMs - RenderTimings.crossFadeMinMs) ~/ 10,
              value: s.crossFadeMs
                  .clamp(RenderTimings.crossFadeMinMs, RenderTimings.crossFadeMaxMs)
                  .toDouble(),
              label: '${s.crossFadeMs} ms',
              onChanged: (double v) => services.settings.setCrossFadeMs(v.round()),
            ),
          ),
          PetLifeSwitchRow(
            label: '动画循环播放',
            note: '关闭后动态图只播放一轮并停在最后一帧',
            value: s.loopAnimation,
            onChanged: (bool v) => services.settings.setLoopAnimation(v),
          ),
          const SizedBox(height: 8),
          if (services.platform.capabilities.supportsWindowManagement) ...<Widget>[
            PetLifeSwitchRow(
              label: '始终置顶',
              note: '桌宠始终显示在其他窗口之上',
              value: s.alwaysOnTop,
              onChanged: (bool v) async {
                await services.settings.setAlwaysOnTop(v);
                await services.windowController
                    .applySettings(services.settings.settings);
              },
            ),
            PetLifeSwitchRow(
              label: '鼠标穿透',
              note: '开启后鼠标点击会落到下层窗口，桌宠变成纯装饰',
              value: s.ignoreMouseEvents,
              onChanged: (bool v) async {
                await services.settings.setIgnoreMouseEvents(v);
                await services.windowController
                    .applySettings(services.settings.settings);
              },
            ),
            PetLifeSwitchRow(
              label: '锁定位置',
              note: '禁止拖动桌宠',
              value: s.lockPosition,
              onChanged: (bool v) async {
                await services.settings.setLockPosition(v);
                await services.windowController
                    .applySettings(services.settings.settings);
              },
            ),
            PetLifeSwitchRow(
              label: '全屏时自动隐藏',
              note: '检测到前台应用全屏时隐藏桌宠',
              value: s.hideOnFullscreen,
              onChanged: (bool v) => services.settings.setHideOnFullscreen(v),
            ),
          ],
          const SizedBox(height: 10),
          _CharacterPicker(services: services, settings: s),
        ],
      );

  // ---------------------------------------------------------------------------
  // 2. 外观与主题（主色与强调色**独立修改、独立保存**）
  // ---------------------------------------------------------------------------

  List<Widget> _appearanceGroup(BuildContext context, AppSettings s) => _group(
        PetLifeSettingsSection.appearance,
        rows: <Widget>[
          PetLifeSettingRow(
            label: '明暗模式',
            note: '默认浅色（白色主题）；「跟随系统」由系统亮暗决定',
            control: PetLifePillSelector<PetLifeThemeMode>(
              options: PetLifeThemeMode.values,
              selected: PetLifeThemeMode.fromWire(s.themeMode),
              labelOf: (PetLifeThemeMode m) => m.labelZh,
              onSelected: (PetLifeThemeMode m) =>
                  services.settings.setThemeMode(m.wireName),
            ),
          ),
          const SizedBox(height: 12),
          PetLifeColorPicker(
            title: '主色',
            subtitle: '页面背景 / 顶部栏 / 卡片表面 / 底部导航 / 弹窗表面',
            value: petLifeColorFromHex(s.themePrimaryColor) ??
                PetLifeColors.primaryDefault,
            defaultColor: PetLifeColors.primaryDefault,
            allowDarkPreset: true,
            presets: const <PetLifeColorPreset>[
              PetLifeColorPreset(name: '白色', color: Color(0xFFFFFFFF)),
              PetLifeColorPreset(name: '浅粉', color: Color(0xFFFFEFF6)),
              PetLifeColorPreset(name: '浅蓝', color: Color(0xFFEEF4FF)),
              PetLifeColorPreset(name: '浅紫', color: Color(0xFFF4EFFF)),
              PetLifeColorPreset(name: '浅绿', color: Color(0xFFEDF9F2)),
              PetLifeColorPreset(name: '深色', color: Color(0xFF1B1620)),
            ],
            onChanged: (Color color) =>
                services.settings.setThemePrimaryColor(petLifeColorToHex(color)),
          ),
          const SizedBox(height: 14),
          PetLifeColorPicker(
            title: '强调色',
            subtitle: '主要按钮 / 当前导航项 / 选中标签 / 图表 / 进度条 / 开关 / 焦点边框',
            value: petLifeColorFromHex(s.themeAccentColor) ??
                PetLifeColors.accentDefault,
            defaultColor: PetLifeColors.accentDefault,
            presets: const <PetLifeColorPreset>[
              PetLifeColorPreset(name: 'P3P 粉', color: Color(0xFFF24D96)),
              PetLifeColorPreset(name: '蓝', color: Color(0xFF3B82F6)),
              PetLifeColorPreset(name: '紫', color: Color(0xFF8B5CF6)),
              PetLifeColorPreset(name: '红', color: Color(0xFFEF4444)),
              PetLifeColorPreset(name: '绿', color: Color(0xFF10B981)),
              PetLifeColorPreset(name: '青', color: Color(0xFF06B6D4)),
            ],
            onChanged: (Color color) =>
                services.settings.setThemeAccentColor(petLifeColorToHex(color)),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: PetLifeSecondaryButton(
              label: '主题恢复默认（白色 + P3P 粉）',
              icon: Icons.restart_alt,
              onPressed: services.settings.resetThemeColors,
            ),
          ),
          const SizedBox(height: 8),
          _ThemePreview(settings: s),
        ],
      );

  // ---------------------------------------------------------------------------
  // 3. 状态联动
  // ---------------------------------------------------------------------------

  List<Widget> _stateLinkGroup(
    BuildContext context,
    AppSettings s,
    bool floating,
  ) {
    final String? characterId = services.stateEngineSnapshot.value.currentCharacter?.id;
    final OverlayPetController? ctl = overlay;
    return <Widget>[
      ..._group(
        PetLifeSettingsSection.stateLink,
        rows: <Widget>[
          if (floating)
            PetLifeSwitchRow(
              label: '根据当前应用自动切换状态与素材',
              note: '关闭后仍照常识别前台应用与采集使用时长，只是不再自动换素材',
              value: s.overlayAutomaticState,
              onChanged: (bool v) => services.settings.setOverlayAutomaticState(v),
            )
          else
            PetLifeSwitchRow(
              label: '全屏时自动隐藏桌宠',
              note: '与「桌宠」分组中的同一开关，此处便于快速访问',
              value: s.hideOnFullscreen,
              onChanged: (bool v) => services.settings.setHideOnFullscreen(v),
            ),
          if (floating)
            PetLifeActionRow(
              label: '编辑当前角色的状态素材映射',
              note: characterId == null
                  ? '尚未选择角色：请先到素材库设为当前桌宠角色'
                  : '决定每个状态显示哪张图，支持预览与手动覆盖',
              icon: Icons.tune,
              onTap: characterId == null || library == null
                  ? null
                  : () => _openMappings(context, characterId),
            ),
        ],
      ),
      // 悬浮桌宠的完整控制（显示/隐藏、大小、权限状态、诊断）——
      // 这是 Android 的既有能力，本轮只把它放进「状态联动」分组，功能一行未减。
      if (floating && ctl != null) ...<Widget>[
        OverlayPetCard(
          controller: ctl,
          services: services,
          library: library,
        ),
        const SizedBox(height: PetLifeSpacing.groupGap),
      ],
    ];
  }

  Future<void> _openMappings(BuildContext context, String characterId) async {
    final LibraryController? lib = library;
    if (lib == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => StateAssetMappingPage(
          library: lib,
          characterId: characterId,
          overlay: overlay,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. 账户与同步
  // ---------------------------------------------------------------------------

  List<Widget> _accountGroup(BuildContext context, AppSettings s) {
    final bool signedIn = services.authenticatedApi.isSignedIn;
    return _group(
      PetLifeSettingsSection.account,
      rows: <Widget>[
        PetLifeKeyValue(
          label: '账户',
          value: signedIn
              ? (services.authenticatedApi.lastAccount?.email ?? '已登录')
              : '未登录',
        ),
        PetLifeKeyValue(
          label: '同步状态',
          value: '${services.syncEngine.status.labelZh}'
              '${services.syncEngine.pendingCount > 0 ? '（待同步 ${services.syncEngine.pendingCount} 条）' : ''}',
        ),
        PetLifeKeyValue(
          label: '服务端',
          value: services.authenticatedApi.baseUrl,
          selectable: true,
        ),
        const SizedBox(height: 8),
        if (onOpenAccount != null)
          PetLifeActionRow(
            label: '打开账户与同步',
            note: '登录、注册、设备管理与网络连接设置',
            icon: Icons.sync,
            onTap: onOpenAccount,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 5. 权限
  // ---------------------------------------------------------------------------

  List<Widget> _permissionGroup(BuildContext context) {
    final OverlayPetController? ctl = overlay;
    if (ctl == null) return const <Widget>[];
    final bool? overlayGranted = ctl.permissions?.overlayGranted;
    final bool? notificationsGranted = ctl.permissions?.notificationsGranted;

    return _group(
      PetLifeSettingsSection.permission,
      rows: <Widget>[
        PetLifeSettingRow(
          label: '悬浮窗权限',
          note: '没有它桌宠无法显示在其他应用之上',
          control: PetLifeTag(
            label: overlayGranted == null
                ? '未知'
                : (overlayGranted ? '已授予' : '未授予'),
            color: overlayGranted == true
                ? PetLifeTheme.of(context).success
                : PetLifeTheme.of(context).warning,
          ),
        ),
        PetLifeActionRow(
          label: '申请悬浮窗权限',
          note: '会跳转到系统设置页，由你手动允许',
          icon: Icons.layers_outlined,
          onTap: () => ctl.requestOverlayPermission(),
        ),
        PetLifeSettingRow(
          label: '通知权限',
          note: '拒绝也能运行，只是通知栏没有控制入口',
          control: PetLifeTag(
            label: notificationsGranted == null
                ? '未知'
                : (notificationsGranted ? '已授予' : '未授予'),
            color: notificationsGranted == true
                ? PetLifeTheme.of(context).success
                : PetLifeTheme.of(context).warning,
          ),
        ),
        PetLifeActionRow(
          label: '申请通知权限',
          icon: Icons.notifications_outlined,
          onTap: () => ctl.requestNotificationPermission(),
        ),
        PetLifeActionRow(
          label: '打开「使用情况访问」设置',
          note: '状态联动需要读取当前前台应用包名',
          icon: Icons.fact_check_outlined,
          onTap: ctl.openUsageAccessSettings,
        ),
        PetLifeActionRow(
          label: '关闭电池优化',
          note: '避免系统在后台清理悬浮桌宠',
          icon: Icons.battery_saver_outlined,
          onTap: ctl.openBatterySettings,
        ),
        PetLifeActionRow(
          label: '打开应用详情',
          icon: Icons.info_outline,
          onTap: ctl.openAppDetails,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 6. 高级
  // ---------------------------------------------------------------------------

  List<Widget> _advancedGroup(
    BuildContext context,
    AppSettings s,
    bool desktop,
  ) =>
      _group(
        PetLifeSettingsSection.advanced,
        rows: <Widget>[
          if (services.platform.capabilities.supportsLaunchAtStartup)
            StartupSwitchTile(service: services.startupRegistration),
          if (desktop) ...<Widget>[
            PetLifeActionRow(
              label: '把桌宠移回屏幕右上角',
              note: '在显示器布局变化后用来找回桌宠',
              icon: Icons.my_location,
              onTap: () => services.windowController.moveTo(0, 0),
            ),
            const SizedBox(height: 8),
            WheelSettingsCard(services: services),
          ],
          const SizedBox(height: 8),
          PetLifeActionRow(
            label: '恢复默认设置',
            note: desktop
                ? '恢复窗口与显示设置为默认值，并清理系统启动项（不会删除素材）'
                : '恢复窗口与显示设置、主题与配色为默认值（不会删除素材）',
            icon: Icons.settings_backup_restore,
            danger: true,
            onTap: () => _confirmReset(context),
          ),
        ],
      );

  Future<void> _confirmReset(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('恢复默认设置'),
        content: const Text(
          '将把所有窗口、显示与主题设置恢复为默认值（主色回到白色、强调色回到 P3P 粉）。\n\n'
          '不会删除素材与使用记录。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          PetLifeDangerButton(
            label: '恢复',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await services.settings.resetToDefaults();
    await services.windowController.applySettings(services.settings.settings);
    // 恢复默认设置时同步删除系统启动项，
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

  // ---------------------------------------------------------------------------
  // 7. 诊断
  // ---------------------------------------------------------------------------

  List<Widget> _diagnosticsGroup(
    BuildContext context,
    AppSettings s,
    bool desktop,
  ) =>
      _group(
        PetLifeSettingsSection.diagnostics,
        rows: <Widget>[
          PetLifeActionRow(
            label: '打开诊断页',
            note: library == null
                ? '桌面外壳在左侧「诊断」页提供同一入口'
                : '运行环境、数据库、采集、同步与代理的真实状态',
            icon: Icons.monitor_heart_outlined,
            onTap: library == null ? null : () => _openDiagnostics(context),
          ),
          if (desktop) ...<Widget>[
            const SizedBox(height: 8),
            const WheelMenuDiagnosticsCard(),
            const FixedCanvasDiagnosticsSwitches(),
          ],
          const SizedBox(height: 10),
          _RawSettingsCard(settings: s),
        ],
      );
}

/// 「当前生效配置」：默认收起，需要时再展开。
class _RawSettingsCard extends StatefulWidget {
  const _RawSettingsCard({required this.settings});

  final AppSettings settings;

  @override
  State<_RawSettingsCard> createState() => _RawSettingsCardState();
}

class _RawSettingsCardState extends State<_RawSettingsCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final PetLifePalette p = PetLifeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PetLifeActionRow(
          label: '当前生效配置（已持久化）',
          note: _expanded ? '点击收起' : '点击展开原始键值对',
          icon: Icons.list_alt,
          trailing: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            color: p.textSecondary,
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.muted,
              borderRadius: PetLifeRadii.cardBorder,
            ),
            child: SelectableText(
              widget.settings.toKeyValues().entries
                  .map((MapEntry<String, String> e) => '${e.key} = ${e.value}')
                  .join('\n'),
              style: TextStyle(
                fontSize: PetLifeText.captionSmall,
                fontFamily: 'monospace',
                color: p.textPrimary,
              ),
            ),
          ),
      ],
    );
  }
}

/// 主题实时预览：颜色 / 圆角 / 组件样例。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const PetLifeSectionTitle(
          title: '实时预览',
          subtitle: '当前主色与强调色组合',
          marker: false,
        ),
        PetLifeCard(
          selected: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '正文与卡片标题',
                style: TextStyle(
                  fontSize: PetLifeText.cardTitle,
                  fontWeight: FontWeight.w600,
                  color: PetLifeTheme.of(context).textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              PetLifeProgressBar(value: 0.62),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  PetLifeTag(label: '选中标签', selected: true),
                  PetLifeTag(label: '普通标签'),
                  PetLifePrimaryButton(label: '主按钮', onPressed: () {}),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(child: PetLifeProgressBar(value: 0.3)),
                  const SizedBox(width: 10),
                  Text(
                    '${settings.themePrimaryColor} / ${settings.themeAccentColor}',
                    style: TextStyle(
                      fontSize: PetLifeText.captionSmall,
                      fontFamily: 'monospace',
                      color: PetLifeTheme.of(context).textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 默认角色 / 默认表情选择（与改造前同一套数据来源）。
class _CharacterPicker extends StatelessWidget {
  const _CharacterPicker({required this.services, required this.settings});

  final AppServices services;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CharacterModel>>(
      future: services.repository.listCharacters(services.ownerId),
      builder: (BuildContext context, AsyncSnapshot<List<CharacterModel>> snap) {
        final List<CharacterModel> chars = snap.data ?? const <CharacterModel>[];
        if (chars.isEmpty) {
          return const PetLifeActionRow(
            label: '默认角色',
            note: '尚未导入任何角色，请先到「素材库」导入素材',
            icon: Icons.person_outline,
          );
        }
        final String? current =
            chars.any((CharacterModel c) => c.id == settings.defaultCharacterId)
                ? settings.defaultCharacterId
                : null;

        return Column(
          children: <Widget>[
            PetLifeSettingRow(
              label: '默认角色',
              note: '应用启动时使用该角色',
              control: DropdownButton<String?>(
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
            if (current != null)
              FutureBuilder<List<EmotionAsset>>(
                future: services.repository.listRenderableAssets(current),
                builder: (
                  BuildContext context,
                  AsyncSnapshot<List<EmotionAsset>> assetSnap,
                ) {
                  final List<EmotionAsset> assets =
                      assetSnap.data ?? const <EmotionAsset>[];
                  return PetLifeSettingRow(
                    label: '默认表情',
                    note: '状态映射未命中时，回退链会用到它',
                    control: DropdownButton<String?>(
                      value: assets.any((EmotionAsset a) => a.id == settings.defaultAssetId)
                          ? settings.defaultAssetId
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
                        await services.repository.setCharacterDefaultAsset(current, v);
                        await services.stateEngine.refresh();
                      },
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// 「开机自动启动」开关（Windows 专属）。
///
/// 它的值来自**系统真实注册状态**（`HKCU\...\Run`），不是 `AppSettings`：
/// 每次重建都读注册表会变成每帧一次 FFI 调用，所以把结果缓存在 State 里；
/// 打开/关闭是异步且**可能失败**的操作，失败时必须把开关**回滚**到真实状态
/// 并把原因显示出来（需求：不能假装成功）。
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
    final String? command =
        _registered ? widget.service.registeredCommandOrNull() : null;
    final PetLifePalette p = PetLifeTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PetLifeSwitchRow(
          label: '开机自动启动',
          note: '登录 Windows 后自动启动桌宠（写入当前用户的启动项，不需要管理员权限）',
          value: _registered,
          onChanged: _busy ? null : _toggle,
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在写入启动项…',
                  style: TextStyle(
                    fontSize: PetLifeText.caption,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        if (command != null)
          Text(
            '已注册：$command',
            style: TextStyle(
              fontSize: PetLifeText.captionSmall,
              fontFamily: 'monospace',
              color: p.textSecondary,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '操作失败：$_error',
              style: TextStyle(fontSize: PetLifeText.caption, color: p.danger),
            ),
          ),
      ],
    );
  }
}
