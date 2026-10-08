import 'package:flutter_test/flutter_test.dart';
import 'package:petlife/activity_tracking/app_keys.dart';
import 'package:petlife/activity_tracking/application_classifier.dart';
import 'package:petlife/activity_tracking/models/activity_enums.dart';

void main() {
  const ApplicationClassifier classifier = ApplicationClassifier();

  group('app_key 规范化（需求 六）', () {
    test('取可执行文件名、小写、去 .exe', () {
      expect(normalizeAppKey(r'C:\Program Files\Microsoft VS Code\Code.exe'), 'code');
      expect(normalizeAppKey(r'C:\Apps\Chrome.EXE'), 'chrome');
      expect(normalizeAppKey('Telegram.exe'), 'telegram');
      // 兼容 POSIX 分隔符，便于在任意平台跑测试。
      expect(normalizeAppKey('/usr/bin/firefox'), 'firefox');
    });

    test('不产生空键（宁可不记录也不写虚假应用名）', () {
      expect(normalizeAppKey(null), isNull);
      expect(normalizeAppKey('   '), isNull);
      expect(normalizeAppKey(r'C:\Apps\'), isNull);
      expect(normalizeAppKey('.exe'), isNull);
    });

    test('展示名保留原始大小写并去掉扩展名', () {
      expect(displayNameFromExecutable(r'C:\Apps\Code.exe'), 'Code');
      expect(displayNameFromExecutable('Telegram.EXE'), 'Telegram');
    });
  });

  group('内置分类规则（需求 七）', () {
    test('17. 开发工具 → development', () {
      for (final String key in <String>['code', 'devenv', 'idea64', 'pycharm64', 'rider64']) {
        final ClassificationResult r = classifier.classify(appKey: key);
        expect(r.category, AppCategory.development, reason: key);
        expect(r.source, ClassificationSource.builtInRule);
      }
    });

    test('18. 通信应用 → social', () {
      for (final String key in <String>['telegram', 'discord', 'wechat']) {
        expect(classifier.classify(appKey: key).category, AppCategory.social, reason: key);
      }
    });

    test('16. 游戏 → gaming', () {
      for (final String key in <String>['steam', 'valorant', 'cyberpunk2077']) {
        expect(classifier.classify(appKey: key).category, AppCategory.gaming, reason: key);
      }
    });

    test('浏览器 → browser，系统应用 → system', () {
      for (final String key in <String>['chrome', 'msedge', 'firefox']) {
        expect(classifier.classify(appKey: key).category, AppCategory.browser, reason: key);
      }
      for (final String key in <String>['explorer', 'taskmgr']) {
        expect(classifier.classify(appKey: key).category, AppCategory.system, reason: key);
      }
    });

    test('配置文件对应的进程名全部命中，说明规则表可用', () {
      // 抽查需求文档里逐条列出的映射，避免规则表被误删。
      expect(kBuiltInCategoryRules['code'], AppCategory.development);
      expect(kBuiltInCategoryRules['devenv'], AppCategory.development);
      expect(kBuiltInCategoryRules['idea64'], AppCategory.development);
      expect(kBuiltInCategoryRules['pycharm64'], AppCategory.development);
      expect(kBuiltInCategoryRules['rider64'], AppCategory.development);
      expect(kBuiltInCategoryRules['telegram'], AppCategory.social);
      expect(kBuiltInCategoryRules['discord'], AppCategory.social);
      expect(kBuiltInCategoryRules['wechat'], AppCategory.social);
      expect(kBuiltInCategoryRules['chrome'], AppCategory.browser);
      expect(kBuiltInCategoryRules['msedge'], AppCategory.browser);
      expect(kBuiltInCategoryRules['firefox'], AppCategory.browser);
      expect(kBuiltInCategoryRules['explorer'], AppCategory.system);
      expect(kBuiltInCategoryRules['taskmgr'], AppCategory.system);
    });

    test('未知应用归入 other，绝不猜测', () {
      final ClassificationResult r = classifier.classify(appKey: 'someunknownapp');
      expect(r.category, AppCategory.other);
      expect(r.source, ClassificationSource.fallback);
    });
  });

  group('游戏识别不依赖窗口标题（需求 七）', () {
    test('命中 Steam / Epic 等安装路径特征', () {
      const String steamGame =
          r'D:\SteamLibrary\steamapps\common\SomeGame\Game.exe';
      final ClassificationResult r = classifier.classify(
        appKey: 'somegame',
        executablePath: steamGame,
      );
      expect(r.category, AppCategory.gaming);
      expect(r.source, ClassificationSource.pathHeuristic);

      expect(
        looksLikeGamePath(r'C:\Program Files\Epic Games\Foo\Foo.exe'),
        isTrue,
      );
      expect(looksLikeGamePath(r'C:\Program Files\Microsoft VS Code\Code.exe'), isFalse);
      expect(looksLikeGamePath(null), isFalse);
    });

    test('路径特征只在没有内置规则时才生效', () {
      // Code.exe 被装在 Games 目录里也不应变成游戏——内置规则优先。
      final ClassificationResult r = classifier.classify(
        appKey: 'code',
        executablePath: r'C:\Games\VS Code\Code.exe',
      );
      expect(r.category, AppCategory.development);
    });
  });

  group('人工设置优先与排除（需求 七/八）', () {
    test('14. 用户手工分类优先于内置规则', () {
      final ClassificationResult r = classifier.classify(
        appKey: 'code',
        userOverridden: true,
        userCategory: AppCategory.entertainment,
      );
      expect(r.category, AppCategory.entertainment);
      expect(r.source, ClassificationSource.userOverride,
          reason: '必须能看出分类来自人工设定');
    });

    test('人工未覆盖时仍然走内置规则', () {
      final ClassificationResult r = classifier.classify(
        appKey: 'code',
        userOverridden: false,
        userCategory: AppCategory.entertainment,
      );
      expect(r.category, AppCategory.development);
    });

    test('PetLife 自身与用户排除的应用都标记为 excluded', () {
      expect(classifier.classify(appKey: 'petlife').excluded, isTrue);
      expect(isBuiltInExcluded('PetLife'), isTrue);
      expect(
        classifier.classify(appKey: 'code', userExcluded: true).excluded,
        isTrue,
      );
      expect(classifier.classify(appKey: 'code').excluded, isFalse);
    });

    test('排除与分类互相独立：排除的应用仍然有分类', () {
      final ClassificationResult r =
          classifier.classify(appKey: 'chrome', userExcluded: true);
      expect(r.excluded, isTrue);
      expect(r.category, AppCategory.browser);
    });
  });

  group('分类枚举', () {
    test('八类齐全且 wireName 稳定', () {
      expect(AppCategory.values.length, 8);
      expect(AppCategory.development.wireName, 'development');
      expect(AppCategory.productivity.wireName, 'productivity');
      expect(AppCategory.gaming.wireName, 'gaming');
      expect(AppCategory.social.wireName, 'social');
      expect(AppCategory.entertainment.wireName, 'entertainment');
      expect(AppCategory.browser.wireName, 'browser');
      expect(AppCategory.system.wireName, 'system');
      expect(AppCategory.other.wireName, 'other');
    });

    test('未知 wireName 回退到 other', () {
      expect(AppCategory.fromWire('nope'), AppCategory.other);
      expect(AppCategory.fromWire(null), AppCategory.other);
    });

    test('结束原因 wireName 与需求文档一致', () {
      expect(SegmentEndReason.foregroundChanged.wireName, 'foreground_changed');
      expect(SegmentEndReason.userIdle.wireName, 'user_idle');
      expect(SegmentEndReason.sessionLocked.wireName, 'session_locked');
      expect(SegmentEndReason.systemSuspend.wireName, 'system_suspend');
      expect(SegmentEndReason.trackingPaused.wireName, 'tracking_paused');
      expect(SegmentEndReason.appExcluded.wireName, 'app_excluded');
      expect(SegmentEndReason.clientShutdown.wireName, 'client_shutdown');
      expect(SegmentEndReason.processUnavailable.wireName, 'process_unavailable');
      expect(SegmentEndReason.crashRecovery.wireName, 'crash_recovery');
    });
  });
}
