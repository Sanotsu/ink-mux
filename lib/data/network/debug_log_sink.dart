import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/log/sanitizer.dart';
import '../../domain/entities/debug_log_entry.dart';
import '../../domain/values/enums.dart';
import '../db/daos/debug_log_dao.dart';

/// 调试日志汇聚点（§9.1/9.5）：内存 FIFO + 微批落库（10 条或 500ms）+
/// 开发期终端镜像（与入库内容同源同脱敏，单条截 2KB）。
class DebugLogSink {
  DebugLogSink(this._dao, {this.enabled = true, this.ringLimit = 5000});

  final DebugLogDao _dao;

  bool enabled;
  int ringLimit;

  final Map<String, int> _seqBySession = {};
  final List<DebugLogEntry> _buffer = [];
  Timer? _timer;
  bool _flushing = false;
  int _flushCount = 0;

  /// 会话内递增序号。
  int nextSeq(String sessionId) =>
      _seqBySession.update(sessionId, (v) => v + 1, ifAbsent: () => 1);

  void add(DebugLogEntry entry) {
    if (!enabled) return;
    _buffer.add(entry);
    _mirrorToConsole(entry);
    if (_buffer.length >= 10) {
      unawaited(flush());
    } else {
      _timer ??= Timer(const Duration(milliseconds: 500), () {
        unawaited(flush());
      });
    }
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty || _flushing) return;
    _flushing = true;
    final batch = List<DebugLogEntry>.of(_buffer);
    _buffer.clear();
    try {
      await _dao.insertBatch(batch);
      _flushCount++;
      if (_flushCount % 20 == 0) {
        await _dao.prune(ringLimit);
      }
    } finally {
      _flushing = false;
    }
  }

  void _mirrorToConsole(DebugLogEntry e) {
    if (!kDebugMode) return;
    final buf = StringBuffer();
    switch (e.direction) {
      case LogDirection.req:
        buf.write('[HTTP] → ${e.method ?? ''} ${e.url ?? ''}');
      case LogDirection.resp:
        buf.write(
          '[HTTP] ← ${e.statusCode ?? '?'} ${e.durationMs ?? 0}ms ${e.url ?? ''}',
        );
      case LogDirection.info:
        buf.write(
          '[${e.kind == LogKind.error ? 'ERR ]' : 'INFO'}] ${e.url ?? ''}',
        );
    }
    final body = e.bodyText;
    if (body != null && body.isNotEmpty) {
      buf.write('\n${LogSanitizer.forConsole(body)}');
    }
    debugPrint(buf.toString());
  }
}
