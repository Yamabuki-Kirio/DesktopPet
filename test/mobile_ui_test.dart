import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/platform/android/android_file_import_provider.dart';
import 'package:petlife/platform/android/android_platform_services.dart';
import 'package:petlife/ui/mobile/mobile_platform_notice.dart';

/// Phase 4A：Android 界面（Widget 测试）。
///
/// 覆盖 Android 外壳里**最容易出错、也最需要说清楚**的一处界面语义：
/// 本版没有自动采集，界面必须如实说明，而不是让用户以为数据丢了。
///
/// 为什么不用 `pumpWidget(MobileShell(...))` 直接测整个外壳：
/// 外壳会启动采集定时器与同步引擎、并在构建期读数据库，
/// 这些与 `testWidgets` 的 fake-async + "不得留下 pending Timer" 契约冲突
/// （会变成测框架而不是测界面）。整壳的联调放在真机验收步骤里做，
/// 见 `docs/29-Phase4测试与验收报告.md`。
void main() {
  Future<void> pumpNotice(WidgetTester tester, {required bool collecting}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MobilePlatformNotice(collecting: collecting)),
      ),
    );
  }

  testWidgets('未采集（Phase 4A 的 Android）：明确说明"还没有启用"，并交代替代可用能力',
      (WidgetTester tester) async {
    await pumpNotice(tester, collecting: false);

    expect(find.text(MobilePlatformNotice.pendingBody), findsOneWidget);
    expect(find.textContaining('还没有启用应用使用时长采集'), findsOneWidget);
    // 必须同时说明"什么还能用"，否则用户会以为整个应用都不可用。
    expect(find.textContaining('桌宠、登录、同步'), findsOneWidget);
    // 并交代下一步（授权采集属于 Phase 4B）。
    expect(find.textContaining('授权采集将在下一阶段'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('已采集：切换为确认文案与不同图标', (WidgetTester tester) async {
    await pumpNotice(tester, collecting: true);

    expect(find.text(MobilePlatformNotice.collectingBody), findsOneWidget);
    expect(find.textContaining('还没有启用'), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets('图标与文案一起变化（不靠单一渠道传达状态）', (WidgetTester tester) async {
    await pumpNotice(tester, collecting: false);
    final Icon pendingIcon = tester.widget<Icon>(find.byType(Icon));
    await pumpNotice(tester, collecting: true);
    final Icon collectingIcon = tester.widget<Icon>(find.byType(Icon));
    expect(pendingIcon.icon, isNot(collectingIcon.icon));
  });

  test('Android 能力决定外壳显示哪条说明', () {
    // MobileShell 直接用这个能力决定 collecting 取值；
    // Phase 4A 的 Android 必须是 false（采集属于 Phase 4B）。
    expect(
      AndroidPlatformServices().capabilities.supportsSystemActivityTracking,
      isFalse,
    );
  });

  test('Android 素材导入：只保留 ZIP，不暴露文件夹入口', () {
    const AndroidFileImportProvider provider = AndroidFileImportProvider();
    expect(provider.supportsFolderImport, isFalse);
    // 与能力表保持一致（界面据此隐藏"导入文件夹"）。
    expect(
      AndroidPlatformServices().capabilities.supportsFolderImport,
      provider.supportsFolderImport,
    );
  });
}
