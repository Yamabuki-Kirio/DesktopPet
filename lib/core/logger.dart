import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';

/// 日志门面。
///
/// 规则：
/// - 统一走 [log]，禁止使用 `print`（analysis_options 已将其提升为 error）。
/// - 必须包含的日志点见需求「十二、错误处理与日志」。
/// - 绝不写入访问令牌、密码等敏感信息；[redact] 提供兜底脱敏。
///
/// 除了写文件，还在内存中保留一个环形缓冲区，供「状态调试器 / 诊断」页面展示，
/// 避免为了看日志去翻磁盘。
class AppLog {
  AppLog._();

  static const int _ringCapacity = 500;

  static final Queue<LogRecord> _ring = Queue<LogRecord>();
  static IOSink? _sink;
  static File? _file;
  static bool _initialized = false;

  /// 内存中的最近日志（新的在最后）。
  static List<LogRecord> get recent => List<LogRecord>.unmodifiable(_ring);

  static Stream<LogRecord> get stream => Logger.root.onRecord;

  /// 初始化日志：设置级别、文件输出与环形缓冲。
  ///
  /// [logFile] 为 null 时只输出到内存与 stderr。
  static Future<void> initialize({File? logFile, Level level = Level.INFO}) async {
    if (_initialized) return;
    _initialized = true;

    Logger.root.level = level;

    if (logFile != null) {
      try {
        await logFile.parent.create(recursive: true);
        // 简单轮转：超过上限时把当前文件挪为 .1
        if (await logFile.exists() && await logFile.length() > 0) {
          final int size = await logFile.length();
          if (size > 2 * 1024 * 1024) {
            final File rolled = File('${logFile.path}.1');
            if (await rolled.exists()) await rolled.delete();
            await logFile.rename(rolled.path);
          }
        }
        _file = logFile;
        _sink = logFile.openWrite(mode: FileMode.append);
      } catch (_) {
        // 日志初始化失败不能影响应用启动。
        _sink = null;
      }
    }

    Logger.root.onRecord.listen((LogRecord record) {
      _ring.addLast(record);
      while (_ring.length > _ringCapacity) {
        _ring.removeFirst();
      }
      final IOSink? sink = _sink;
      if (sink != null) {
        try {
          sink.writeln(format(record));
        } catch (_) {
          // 忽略写入失败，避免日志本身造成崩溃。
        }
      }
    });
  }

  /// 关闭日志文件句柄（正常退出时调用）。
  static Future<void> dispose() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {
      // ignore
    }
    _sink = null;
    _initialized = false;
  }

  /// 单行日志格式：`2026-09-27 17:31:18.123 [INFO] petlife.scan: 文本`。
  ///
  /// **所有输出（文件、内存环形缓冲、诊断页、导出文本）都经 [format]，
  /// 而 [format] 一定会调用 [redact]**。这样脱敏只有一处实现，
  /// 不会出现「文件脱敏了但界面没脱敏」这种漏口。
  static String format(LogRecord r) {
    final String ts = r.time.toIso8601String();
    final String body = '$ts [${r.level.name}] ${r.loggerName}: ${r.message}'
        '${r.error != null ? ' | error=${r.error}' : ''}'
        '${r.stackTrace != null ? ' | stack=${r.stackTrace.toString().split('\n').first}' : ''}';
    return redact(body);
  }

  /// 把内存环形缓冲里的日志导出为可复制的纯文本。
  ///
  /// 诊断页「查看最近日志」以及验收时导出问题现场都用它；
  /// 不依赖日志文件是否成功落盘。
  static String exportRecentLogText() {
    final List<LogRecord> records = recent;
    if (records.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    sb.writeln('# PetLife 运行日志（内存缓冲，最多 ${records.length} 条）');
    sb.writeln('# 导出时间：${DateTime.now().toIso8601String()}');
    if (_file != null) {
      sb.writeln('# 日志文件：${_file!.path}');
    }
    sb.writeln();
    for (final LogRecord r in records) {
      sb.writeln(format(r));
    }
    return sb.toString();
  }

  /// 兜底脱敏：抹掉 Authorization、access/refresh token、密码等敏感值。
  ///
  /// 与服务端 `app/core/logging.py` 的规则保持一致：
  ///
  /// 1. **先**处理 `Bearer xxx` / `Basic xxx`——这类值里带空格，
  ///    如果先跑 `key=value` 规则只会吃掉 `Bearer`，把令牌留在日志里；
  /// 2. 再处理裸的三段式 JWT（没有键名的情况）；
  /// 3. 最后处理 `key=value` / `key: value` / `"key": "value"` 形式。
  static final RegExp _bearer = RegExp(
    r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}',
    caseSensitive: false,
  );

  static final RegExp _jwt = RegExp(
    r'\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\b',
  );

  static final RegExp _keyValue = RegExp(
    r'(["\x27]?(?:proxy[_-]?authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|'
    r'token|password|passwd|secret|authorization|api[_-]?key|credential)["\x27]?\s*[:=]\s*)'
    r'(["\x27]?)([^\s,;"\x27}\)]+)',
    caseSensitive: false,
  );

  static String redact(String input) {
    String out = input.replaceAllMapped(_bearer, (Match m) => '${m.group(1)} <redacted>');
    out = out.replaceAll(_jwt, '<redacted>');
    out = out.replaceAllMapped(
      _keyValue,
      (Match m) => '${m.group(1)}${m.group(2)}<redacted>',
    );
    return out;
  }

  /// 各模块统一使用的 logger 工厂。
  static Logger of(String name) => Logger('petlife.$name');

  /// 当前日志文件路径（可能为 null）。
  static String? get logFilePath => _file?.path;
}

/// 模块级 logger 常量，避免各处重复写字符串前缀。
class Loggers {
  Loggers._();

  static final Logger app = AppLog.of('app');
  static final Logger scan = AppLog.of('scan');
  static final Logger decode = AppLog.of('decode');
  static final Logger importer = AppLog.of('import');
  static final Logger character = AppLog.of('character');
  static final Logger state = AppLog.of('state');
  static final Logger window = AppLog.of('window');
  static final Logger settings = AppLog.of('settings');
  static final Logger db = AppLog.of('db');

  /// 阶段 1：前台应用采集与活动段。
  static final Logger activity = AppLog.of('activity');

  /// Phase 2：账户与同步。
  ///
  /// 注意：该日志器的输出同样经过全局脱敏过滤器，
  /// 令牌 / Authorization / 密码都不会落盘。
  static final Logger sync = AppLog.of('sync');

  /// Phase 2：凭据存储（只记录条目名与后端类型，绝不记录凭据内容）。
  static final Logger credential = AppLog.of('credential');

  /// Phase 2 补充：代理（只记录模式、地址、阶段结果，绝不记录代理密码）。
  static final Logger proxy = AppLog.of('proxy');
}
