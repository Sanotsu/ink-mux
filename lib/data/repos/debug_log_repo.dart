import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/debug_log_entry.dart';
import '../db/daos/debug_log_dao.dart';
import '../network/debug_log_sink.dart';

/// 调试日志仓储：查询分页 / 清空 / 导出文件（§9.3/9.4）。
class DebugLogRepo {
  DebugLogRepo(this._dao, this._sink);

  final DebugLogDao _dao;
  final DebugLogSink _sink;

  Future<List<DebugLogEntry>> latest({
    int? beforeId,
    bool errorsOnly = false,
    int limit = 100,
    String? sessionId,
  }) => _dao.latest(
    beforeId: beforeId,
    errorsOnly: errorsOnly,
    limit: limit,
    sessionId: sessionId,
  );

  Future<int> countAll() => _dao.countAll();

  Future<void> clearAll() async {
    await _sink.flush();
    await _dao.clearAll();
  }

  Future<void> setEnabled(bool enabled) async {
    _sink.enabled = enabled;
    if (!enabled) await _sink.flush();
  }

  void setRingLimit(int limit) => _sink.ringLimit = limit;

  /// 导出为可读时间线 txt（已脱敏）。
  /// 返回写入的文件路径；[targetPath] 为空时落私有文档目录
  /// {文档目录}/InkMux/logs/——该目录用户不可见（U-46），设置页入口由
  /// UI 先行选目录/请求存储授权后传入 targetPath 直写用户位置，私有
  /// 目录仅作兜底 + 分享面板转存。
  /// 上限取当前环形容量（设置可调 1000~20000，默认 5000）——
  /// 与环形裁剪共用同一上限，调大后导出不再静默截断。
  Future<String> exportToFile({String? targetPath}) async {
    await _sink.flush();
    final entries = await _dao.exportAll(limit: _sink.ringLimit);
    final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final String filePath;
    if (targetPath != null) {
      filePath = targetPath;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(path.join(dir.path, 'InkMux', 'logs'));
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      filePath = path.join(logDir.path, 'inkmux-debug-$stamp.txt');
    }
    final file = File(filePath);
    final buf = StringBuffer()
      ..writeln('InkMux 调试日志导出 · ${DateTime.now()} · ${entries.length} 条（已脱敏）')
      ..writeln('=' * 72);
    for (final e in entries) {
      buf.writeln(describeEntry(e));
    }
    await file.writeAsString(buf.toString(), flush: true);
    return file.path;
  }

  /// 单条条目的可读文本（列表详情 / 复制 / 导出共用）。
  static String describeEntry(DebugLogEntry e, {bool withBody = true}) {
    final time = DateFormat('HH:mm:ss.SSS')
        .format(DateTime.fromMillisecondsSinceEpoch(e.ts));
    final head =
        '[$time] #${e.seq} ${e.kind.name}/${e.direction.name} '
        '${e.method ?? ''} ${e.url ?? ''} '
        '${e.statusCode == null ? '' : '→ ${e.statusCode}'}'
        '${e.durationMs == null ? '' : ' (${e.durationMs}ms)'}';
    if (!withBody) return head;
    final headers = e.headersJson;
    return '$head\n  --- headers ---\n${headers ?? '(无)'}\n  --- body ---\n'
        '${e.bodyText ?? '(无)'}';
  }
}
