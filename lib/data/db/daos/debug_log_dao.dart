import 'package:sqflite/sqflite.dart';

import '../../../domain/entities/debug_log_entry.dart';

class DebugLogDao {
  DebugLogDao(this.db);

  final Database db;

  static const String _t = 'debug_logs';

  Future<void> insertBatch(List<DebugLogEntry> entries) async {
    if (entries.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in entries) {
        final map = e.toJson();
        if (e.id == null) map.remove('id');
        batch.insert(_t, map);
      }
      await batch.commit(noResult: true);
    });
  }

  /// 最新日志分页（默认 100 条，向上翻更早）；sessionId 过滤用于
  /// 任务行「查看调试日志」定位到该任务会话（idx_logs_session 索引）。
  Future<List<DebugLogEntry>> latest({
    int limit = 100,
    int? beforeId,
    bool errorsOnly = false,
    String? sessionId,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (sessionId != null && sessionId.isNotEmpty) {
      where.add('session_id = ?');
      args.add(sessionId);
    }
    if (beforeId != null) {
      where.add('id < ?');
      args.add(beforeId);
    }
    if (errorsOnly) {
      where.add(
        "(kind = 'error' OR (status_code IS NOT NULL AND status_code >= 400))",
      );
    }
    final rows = await db.query(
      _t,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(DebugLogEntry.fromJson).toList();
  }

  Future<int> countAll() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_t')) ?? 0;

  Future<void> clearAll() async {
    await db.delete(_t);
  }

  /// 环形裁剪：只保留最新 [keep] 条（§9.3，单条 SQL 完成）。
  Future<void> prune(int keep) async {
    await db.rawDelete(
      'DELETE FROM $_t WHERE id <= (SELECT id FROM $_t ORDER BY id DESC LIMIT 1 OFFSET ?)',
      [keep],
    );
  }

  /// 导出全量（时间线正序）；调用方应传入当前环形容量（DebugLogSink.ringLimit）。
  Future<List<DebugLogEntry>> exportAll({int limit = 5000}) async {
    final rows = await db.query(_t, orderBy: 'id ASC', limit: limit);
    return rows.map(DebugLogEntry.fromJson).toList();
  }
}
