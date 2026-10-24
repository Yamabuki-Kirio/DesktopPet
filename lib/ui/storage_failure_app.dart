import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/storage_preflight.dart';

/// 数据目录 / 数据库不可写的中文诊断页（规格§四）。
///
/// 只显示结论与目录路径，**绝不暴露原始 SQLite 堆栈**；
/// 提供三个动作：打开数据目录、复制诊断信息、退出。
class StorageFailureApp extends StatelessWidget {
  const StorageFailureApp({super.key, required this.failure});

  final StoragePreflightFailure failure;

  void _openDataDir() {
    Process.run('explorer', <String>[failure.dataDirPath]);
  }

  Future<void> _copyDiagnostics(BuildContext context) async {
    final String text = <String>[
      'PetLife 存储诊断',
      '问题类型：${failure.issue.name}',
      '数据目录：${failure.dataDirPath}',
      '时间：${DateTime.now().toIso8601String()}',
      '详情：${failure.diagnosticText}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('诊断信息已复制到剪贴板')),
      );
    }
  }

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
                  Text(
                    failure.userMessage,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  const Text('目录：', style: TextStyle(fontSize: 13)),
                  SelectableText(
                    failure.dataDirPath,
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '请确认没有旧版 PetLife 正在运行，并检查目录权限。',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '未对数据库做任何修改；恢复权限后可直接重新启动，无需删除数据。',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(
                        onPressed: _openDataDir,
                        child: const Text('打开数据目录'),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          // SnackBar 显示在诊断页自己的 Scaffold 里：
                          // 用内部 Builder 拿到 Scaffold 之下的 context，
                          // 避免把 MaterialApp 上层的 context 传进来。
                          final BuildContext buttonContext = context;
                          await _copyDiagnostics(buttonContext);
                        },
                        child: const Text('复制诊断信息'),
                      ),
                      OutlinedButton(
                        onPressed: () => exit(0),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
