import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/proxy/proxy_models.dart';
import 'package:petlife/sync/proxy/proxy_resolver.dart';
import 'package:petlife/sync/proxy/system_proxy.dart';
import 'package:petlife/sync/sync_preferences.dart';
import 'package:petlife/ui/pages/ai_access_card.dart';

import 'support/fake_petlife_server.dart';
import 'support/sqlite_test_bootstrap.dart';

/// 「AI 数据访问」卡片的 Widget 测试。
///
/// 全部走**真实链路**：卡片 → `AuthenticatedApi` → 真实本地 HTTP →
/// `FakePetLifeServer` → 真实 SQLite（账户/偏好）。网络层没有被打桩，
/// 因此"取消后不生成密钥""撤销失败不假装成功""明文不落库"这类断言才有意义。
///
/// 两个必须遵守的测试约束（都踩过坑）：
///
/// 1. **真实 I/O 必须放进 `tester.runAsync`**。`testWidgets` 的测试体运行在
///    fake-async 区里，真实 socket / sqflite 的回调不会被派发，直接 `await`
///    会把测试挂死。
/// 2. **不能只用固定等待**。HTTP 往返的完成时机不确定，用 `awaitUntil` 轮询
///    目标 widget 更稳，也能在失败时给出明确原因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();
  // 需要真实 HTTP：清掉测试框架对 HttpClient 的替身
  HttpOverrides.global = null;

  late FakePetLifeServer server;

  setUp(() async {
    server = await FakePetLifeServer.start();
  });

  tearDown(() async {
    await server.close(force: true);
  });

  // --- 装置 -----------------------------------------------------------------

  /// 在 `testWidgets` 里跑**真实** I/O。
  Future<T> real<T extends Object>(WidgetTester tester, Future<T> Function() body) async {
    final T? result = await tester.runAsync<T>(body);
    if (result == null) throw StateError('runAsync 没有返回结果');
    return result;
  }

  Future<void> realVoid(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync<void>(body);
  }

  /// 用真实 SQLite + 真实 HTTP 建一个已登录的客户端。
  Future<_Harness> boot({
    String email = 'ai-card@example.com',
    ProxyResolver? resolver,
  }) async {
    final Directory dir = Directory.systemTemp.createTempSync('petlife_ai_card');
    await AppDatabase.close();
    final AppDatabase db = await AppDatabase.open(path: p.join(dir.path, 'ai.db'));
    final AuthenticatedApi api = AuthenticatedApi(
      credentialStore: InMemoryCredentialStore(),
      accountSessionDao: AccountSessionDao(db.raw),
      deviceIdentity: DeviceIdentity(db),
      preferences: SyncPreferences(db),
      proxyResolver: resolver ?? AlwaysDirectProxyResolver(),
    );
    await api.load();
    await api.signIn(
      baseUrl: server.baseUrl,
      email: email,
      password: 'password-123',
      registerInsteadOfLogin: true,
    );
    return _Harness(dir: dir, db: db, api: api);
  }

  /// 让真实 HTTP 往返有机会完成，然后把界面刷出来。
  Future<void> flush(WidgetTester tester) async {
    await realVoid(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// 当前界面上所有可见文本（排在 `awaitUntil` 之前：Dart 的局部函数
  /// 声明不能被前面的代码引用）。
  String visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((Text t) => t.data ?? '')
      .where((String s) => s.trim().isNotEmpty)
      .join('\n');

  /// 弹窗里的按钮：卡片上可能有同名按钮，必须限定在 AlertDialog 之内才不歧义。
  Finder dialogButton(String label) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, label),
      );

  /// 轮询等待某个 widget 出现（真实时间，最长 [timeout]）。
  ///
  /// 失败时把当前界面上所有文本一并抛出——否则只能看到"某某没出现"，
  /// 完全不知道界面当时到底是什么状态。
  Future<void> awaitUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await flush(tester);
      if (finder.evaluate().isNotEmpty) return;
    }
    throw StateError(
      '等待超时：$finder 仍未出现。\n当前界面文本：\n${visibleText(tester)}',
    );
  }

  Future<void> pumpCard(
    WidgetTester tester,
    AuthenticatedApi api, {
    required bool signedIn,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AiAccessCard(api: api, isSignedIn: signedIn),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  /// 让刚关闭的对话框**彻底退场**。
  ///
  /// 这里不能用 `pumpAndSettle`：点确认后卡片立刻进入 `_busy`，
  /// 而 `CircularProgressIndicator` 是永不停止的动画，`pumpAndSettle` 永远等不到静止。
  /// 显式推进 400ms（大于路由默认的 300ms 转场）才既确定又安全。
  Future<void> settleRoute(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 走完"点生成 → 填名字 → 确认"。
  Future<void> generateKey(
    WidgetTester tester, {
    String? name,
    String confirmLabel = '生成',
  }) async {
    await tester.tap(find.text('生成密钥'));
    // 此时还没有网络请求，界面是静止的，可以安全 settle
    await tester.pumpAndSettle();
    if (name != null) {
      await tester.enterText(find.byType(TextField), name);
      await tester.pumpAndSettle();
    }
    await tester.tap(dialogButton(confirmLabel));
    await settleRoute(tester);
  }

  /// 统一的测试包装：负责建环境，并在**测试体之内**清干净。
  ///
  /// 清理必须在测试体内完成：flutter_test 的 "A Timer is still pending" 检查
  /// 发生在测试体结束之后、`tearDown` 之前 —— 放到 tearDown 里就太晚了。
  /// 需要销毁的东西主要是 `dart:io` 在连接池上留下的 15 秒 keep-alive
  /// 空闲计时器（关掉 HttpClient 才会消失）。
  void cardTest(
    String description,
    Future<void> Function(WidgetTester tester, _Harness h) body, {
    ProxyResolver? resolver,
  }) {
    testWidgets(
      description,
      (WidgetTester tester) async {
        _Harness? harness;
        addTearDown(() async {
          if (harness != null) await harness.dispose();
        });
        try {
          harness = await real(tester, () => boot(resolver: resolver));
          await body(tester, harness);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          final _Harness? h = harness;
          if (h != null) {
            await realVoid(tester, () async => h.api.dispose());
          }
          await tester.pump();
        }
      },
      // 兜底超时：万一将来又在 fake-async 区里直接 await 真实 I/O，
      // 应当明确失败，而不是把整条测试流水线挂住（踩过一次）。
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  // --- 未登录 ---------------------------------------------------------------

  cardTest('未登录：只给提示，且不发任何请求', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: false);

    expect(find.text('AI 数据访问'), findsOneWidget);
    expect(find.textContaining('登录 PetLife 账户后即可生成密钥'), findsOneWidget);
    expect(find.textContaining('不登录也可以正常使用桌宠'), findsOneWidget);
    // 未登录时不该有任何密钥请求
    expect(server.apiKeyListRequests, 0);
    expect(server.apiKeyCreateRequests, 0);
    expect(find.text('生成密钥'), findsNothing);
  });

  // --- 列表状态 -------------------------------------------------------------

  cardTest('已登录但还没有密钥：显示空数据文案', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);

    expect(server.apiKeyListRequests, 1);
    expect(find.text('还没有生成任何密钥'), findsOneWidget);
    expect(find.text('生成密钥'), findsOneWidget);
  });

  cardTest('已有密钥：只显示前缀与状态，不出现完整密钥',
      (WidgetTester tester, _Harness h) async {
    server.seedApiKey(id: 'key-1', name: 'AstrBot', lastUsedAt: '2026-09-28T09:00:00Z');
    server.seedApiKey(id: 'key-2', name: '旧密钥', revoked: true);
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.text('AstrBot'));

    expect(find.textContaining('plk_key-1'), findsOneWidget);
    expect(find.textContaining('只读统计'), findsWidgets);
    expect(find.textContaining('最近使用 '), findsOneWidget);
    expect(find.text('（有效）'), findsOneWidget);
    expect(find.text('（已撤销）'), findsOneWidget);
    expect(find.textContaining('撤销于 '), findsOneWidget);
    // 已撤销的密钥不再提供撤销按钮
    expect(find.widgetWithText(TextButton, '撤销'), findsOneWidget);

    // 界面上不应出现 PetLife 内部 user_id
    final String rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .join('|');
    expect(rendered.contains(h.api.lastAccount!.userId), isFalse);
  });

  cardTest('刷新按钮会重新拉取列表', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);
    expect(server.apiKeyListRequests, 1);

    // 期间服务端多了一把密钥
    server.seedApiKey(id: 'key-9', name: '后加的');
    await tester.tap(find.text('刷新'));
    await awaitUntil(tester, find.text('后加的'));

    expect(server.apiKeyListRequests, 2);
  });

  // --- 生成密钥 -------------------------------------------------------------

  cardTest('生成密钥：明文只显示一次，复制的是完整密钥',
      (WidgetTester tester, _Harness h) async {
    final List<MethodCall> platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );

    await pumpCard(tester, h.api, signedIn: true);
    await generateKey(tester, name: '家里的助手');
    await awaitUntil(tester, find.textContaining('只显示这一次'));
    // 等列表也刷出来：这证明创建之后的刷新已完成，卡片不再处于 busy（按钮可点）
    await awaitUntil(tester, find.text('家里的助手'));

    expect(server.apiKeyCreateRequests, 1);
    final String key = server.issuedApiKeys.single;
    expect(key.startsWith('plk_'), isTrue);
    expect(find.text(key), findsOneWidget);
    expect(find.text('复制密钥'), findsOneWidget);
    // 生成后列表里立刻能看到这把密钥（只带前缀）
    expect(find.textContaining('plk_fake-key…'), findsOneWidget);

    await tester.tap(find.text('复制密钥'));
    await flush(tester);

    final MethodCall copy = platformCalls.lastWhere(
      (MethodCall c) => c.method == 'Clipboard.setData',
    );
    expect((copy.arguments as Map<Object?, Object?>)['text'], key);
  });

  cardTest('生成对话框取消：不发请求、界面不变', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);

    await tester.tap(find.text('生成密钥'));
    await tester.pumpAndSettle();
    expect(find.text('生成 API 密钥'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(server.apiKeyCreateRequests, 0);
    expect(find.text('还没有生成任何密钥'), findsOneWidget);
  });

  cardTest('名称为空：明确报错且不发请求', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);

    await generateKey(tester, name: '   ');
    await awaitUntil(tester, find.textContaining('请先给密钥起个名字'));

    expect(server.apiKeyCreateRequests, 0);
  });

  cardTest('「我已保存」收起明文，但列表仍保留该密钥',
      (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);
    await generateKey(tester);
    await awaitUntil(tester, find.textContaining('只显示这一次'));
    // 等列表也刷出来：这证明卡片已退出 busy 状态，按钮可以点
    await awaitUntil(tester, find.text('AstrBot'));
    final String key = server.issuedApiKeys.single;
    expect(find.text(key), findsOneWidget);

    await tester.tap(find.text('我已保存'));
    await flush(tester);

    expect(find.text(key), findsNothing, reason: '明文必须从界面消失');
    expect(find.textContaining('只显示这一次'), findsNothing);
    expect(find.text('AstrBot'), findsOneWidget, reason: '列表里的记录应保留');
    expect(find.textContaining('已收起密钥'), findsOneWidget);
  });

  // --- 撤销 -----------------------------------------------------------------

  cardTest('撤销：二次确认后列表立即变为已撤销', (WidgetTester tester, _Harness h) async {
    server.seedApiKey(id: 'key-1', name: 'AstrBot');
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.text('AstrBot'));

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.textContaining('撤销后'), findsOneWidget);

    await tester.tap(dialogButton('撤销'));
    await settleRoute(tester);
    await awaitUntil(tester, find.text('（已撤销）'));
    // 等确认框彻底退场，否则它的按钮仍在树里，会让下面的 findsNothing 误判
    await tester.pumpAndSettle();

    expect(server.apiKeyRevokeRequests, 1);
    expect(find.widgetWithText(TextButton, '撤销'), findsNothing,
        reason: '已撤销的密钥不再显示撤销按钮');
    expect(find.textContaining('已撤销密钥「AstrBot」'), findsOneWidget);
  });

  cardTest('撤销取消：不发请求、状态不变', (WidgetTester tester, _Harness h) async {
    server.seedApiKey(id: 'key-1', name: 'AstrBot');
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.text('AstrBot'));

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(server.apiKeyRevokeRequests, 0);
    expect(find.text('（有效）'), findsOneWidget);
  });

  cardTest('撤销失败（服务端 500）：如实报错，且不假装已撤销',
      (WidgetTester tester, _Harness h) async {
    server.seedApiKey(id: 'key-1', name: 'AstrBot');
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.text('AstrBot'));

    server.forcedApiKeyStatus = 500;
    server.forcedApiKeyErrorCode = 'internal_error';

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tap(dialogButton('撤销'));
    await settleRoute(tester);
    await awaitUntil(tester, find.textContaining('服务端错误'));

    expect(find.text('（有效）'), findsOneWidget, reason: '撤销失败必须保持原状态');
    expect(find.text('（已撤销）'), findsNothing);
  });

  // --- 错误状态 -------------------------------------------------------------

  cardTest('服务端错误：显示可读错误而不是崩溃', (WidgetTester tester, _Harness h) async {
    server.forcedApiKeyStatus = 500;
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.textContaining('服务端错误'));

    expect(tester.takeException(), isNull);
  });

  cardTest('登录失效（401 + 刷新失败）：提示需要重新登录',
      (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);

    server.forcedApiKeyStatus = 401;
    server.forcedApiKeyErrorCode = 'token_expired';
    server.rejectRefresh = true; // 刷新也失败 → 进入"需要重新登录"

    await tester.tap(find.text('刷新'));
    await awaitUntil(tester, find.textContaining('需要重新登录'));

    // 401 重试一次后仍失败 → 抛的是最初那个 unauthorized（文案"登录已失效"）
    expect(find.textContaining('登录已失效'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  cardTest('服务器不可达：显示网络错误且不崩溃', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);

    await realVoid(tester, () => server.close(force: true));
    await tester.tap(find.text('刷新'));
    await awaitUntil(tester, find.textContaining('网络不可达'));

    expect(tester.takeException(), isNull);
  });

  // --- 生命周期与回归 -------------------------------------------------------

  cardTest('退出登录：明文密钥与列表都被清除', (WidgetTester tester, _Harness h) async {
    server.seedApiKey(id: 'key-1', name: 'AstrBot');
    await pumpCard(tester, h.api, signedIn: true);
    await generateKey(tester);
    await awaitUntil(tester, find.textContaining('只显示这一次'));

    final String key = server.issuedApiKeys.single;
    expect(find.text(key), findsOneWidget);

    // 模拟退出登录：父组件把 isSignedIn 变成 false
    await pumpCard(tester, h.api, signedIn: false);

    expect(find.text(key), findsNothing, reason: '明文密钥必须随退出登录清除');
    expect(find.text('AstrBot'), findsNothing, reason: '密钥列表必须清除');
    expect(find.textContaining('登录 PetLife 账户后即可生成密钥'), findsOneWidget);

    // 重新登录后明文不会"复活"（它只活在内存里）
    await pumpCard(tester, h.api, signedIn: true);
    await awaitUntil(tester, find.text('AstrBot'));
    expect(find.text(key), findsNothing);
  });

  cardTest(
    '切换代理后卡片仍能正常拉取（连接池重建回归）',
    (WidgetTester tester, _Harness h) async {
      server.seedApiKey(id: 'key-1', name: 'AstrBot');

      // 拿一个确定没人监听的端口当"坏代理"（真实 I/O，必须走 runAsync）
      final int deadPort = await real(tester, () async {
        final ServerSocket spare =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final int port = spare.port;
        await spare.close();
        return port;
      });

      await pumpCard(tester, h.api, signedIn: true);
      await awaitUntil(tester, find.text('AstrBot'));

      // 1) 切到不可达的手动代理 → 请求失败，且错误指向代理
      await realVoid(
        tester,
        () => h.api.applyProxySettings(ProxySettings(
          mode: ProxyMode.manualHttp,
          host: '127.0.0.1',
          port: deadPort,
          bypassLocalhost: false,
        )),
      );
      await tester.tap(find.text('刷新'));
      await awaitUntil(tester, find.textContaining('代理不可达'));

      // 2) 切回直连 → 连接池重建后必须恢复正常
      await realVoid(
        tester,
        () => h.api.applyProxySettings(const ProxySettings(mode: ProxyMode.direct)),
      );
      // 注意：加载中不会清空旧列表，所以"AstrBot 还在"证明不了这次刷新完成。
      // 往服务端加一把新密钥，等它出现才算这次请求真的回来了。
      server.seedApiKey(id: 'key-2', name: '切代理之后');
      await tester.tap(find.text('刷新'));
      await awaitUntil(tester, find.text('切代理之后'));

      expect(find.text('AstrBot'), findsOneWidget);
      expect(find.textContaining('代理不可达'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    resolver: ProxySettingsResolver(
      settings: const ProxySettings(mode: ProxyMode.direct),
      systemReader: const StaticSystemProxyReader(
        SystemProxyInfo(source: '测试', available: true, enabled: false),
      ),
    ),
  );

  cardTest('明文密钥不写入本地数据库（只在内存里）', (WidgetTester tester, _Harness h) async {
    await pumpCard(tester, h.api, signedIn: true);
    await generateKey(tester);
    await awaitUntil(tester, find.textContaining('只显示这一次'));
    final String key = server.issuedApiKeys.single;

    // 直接扫库文件：密钥明文不能出现
    final String raw = await real(tester, () async {
      await AppDatabase.close();
      final List<int> bytes =
          await File(p.join(h.dir.path, 'ai.db')).readAsBytes();
      return String.fromCharCodes(bytes);
    });
    expect(raw.contains(key), isFalse, reason: '密钥明文绝不能落 SQLite');
  });
}

class _Harness {
  _Harness({required this.dir, required this.db, required this.api});

  final Directory dir;
  final AppDatabase db;
  final AuthenticatedApi api;

  Future<void> dispose() async {
    api.dispose();
    await AppDatabase.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
