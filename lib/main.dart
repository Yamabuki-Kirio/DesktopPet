import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'core/error_handler.dart';
import 'core/logger.dart';
import 'platform/platform_services.dart';

/// 应用入口。
///
/// 启动顺序：平台准备（单实例 / SQLite 后端 / 设备信息）→ 错误兜底 →
/// 目录/日志 → SQLite → 仓储 → 窗口 → 渲染 → 状态引擎 → 活动采集 → UI。
///
/// Phase 4A：入口本身**平台无关**——单实例检查、窗口、托盘、凭据、数据库后端
/// 全部由 [PlatformServices] 提供（Windows 与 Android 各一套实现）。
void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final PlatformServices platform = platformServices;

      // 平台准备必须最先做。Windows 上包含单实例互斥体判定：两个实例同时写
      // activity_segments 会把同一段时间记录两次，而且第二个实例打开 SQLite
      // 也可能与第一个实例抢锁。Android 上由系统保证单实例，恒为 true。
      if (await platform.prepareForStartup() == false) {
        // 已有实例在运行：直接退出，不建托盘图标、不写库、不采集。
        // 这里用 stderr 而不是日志文件，是因为此时日志系统尚未初始化。
        stderr.writeln('PetLife 已在运行，本次启动退出（避免重复记录使用时长）。');
        exit(0);
      }

      // 先装错误兜底，保证启动阶段的问题也能被记录，而不是静默退出。
      ErrorHandler.install();

      try {
        final AppServices services =
            await AppServices.bootstrap(platform: platform);
        runApp(PetLifeApp(services: services));
      } catch (e, st) {
        ErrorHandler.record('bootstrap', e, st);
        // 启动失败时至少给用户一个能看懂的界面，而不是什么都没有。
        runApp(_StartupFailureApp(
          error: e.toString(),
          logFile: AppLog.logFilePath,
          desktop: platform.capabilities.isDesktop,
        ));
      }
    },
    (Object error, StackTrace stack) {
      ErrorHandler.record('zone', error, stack);
    },
  );
}

/// 启动失败兜底界面。
///
/// 需求「十二」要求记录未处理异常；直接用 Flutter 默认的红屏在 release 下
/// 是一片空白，因此这里给一个可读的失败页并指出日志位置。
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({
    required this.error,
    this.logFile,
    this.desktop = false,
  });

  final String error;
  final String? logFile;

  /// 桌面平台才提供"打开日志所在位置"（Android 上是应用私有目录）。
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF4F6F9),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'PetLife 启动失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(error, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 12),
                  if (logFile != null)
                    SelectableText('日志文件：$logFile',
                        style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 16),
                  Text(
                    desktop
                        ? '常见原因：\n'
                            '· 应用数据目录不可写（系统 AppData 权限）\n'
                            '· SQLite 原生库缺失\n'
                            '· 上一次运行残留了数据库锁\n'
                            '请把上面的错误与日志文件一并反馈。'
                        : '常见原因：\n'
                            '· 应用私有目录不可写（存储空间不足）\n'
                            '· 上一次运行异常退出导致数据库锁残留\n'
                            '请把上面的错误与日志文件一并反馈。',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (desktop && logFile != null) ...<Widget>[
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () async {
                        await Process.run('explorer', <String>['/select,$logFile']);
                      },
                      child: const Text('打开日志所在位置'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
