import 'package:sqflite/sqflite.dart';

import '../../../domain/entities/app_task.dart';
import '../../../domain/values/enums.dart';

class TaskDao {
  TaskDao(this.db);

  final Database db;

  static const String _t = 'tasks';

  Future<void> insert(AppTask task) async {
    await db.insert(
      _t,
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> update(AppTask task) async {
    await db.update(_t, task.toJson(), where: 'id = ?', whereArgs: [task.id]);
  }

  /// 状态迁移统一入口：局部列更新 + updatedAt。
  Future<void> patch(
    String id,
    TaskStatus status, {
    Map<String, Object?>? extra,
    int? now,
  }) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    await db.update(
      _t,
      {...?extra, 'status': status.name, 'updated_at': ts},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 单行读取。
  ///
  /// ⚠️ 防御（U-29）：先只读各 TEXT 列 length() 测行体（CursorWindow 永远安全），超过 1MB 的行改走窄列 SELECT 并将大列置 null。
  /// 历史 bug：神稳 data URI 曾被写入 result_hint_json（单行 3MB+），SELECT * 直接抛 "Row too big to fit into CursorWindow"，
  /// 任务详情/引擎重试全崩。
  Future<AppTask?> byId(String id) async {
    final sizes = await measureRow(id);
    final total = sizes.values.fold(0, (a, b) => a + b);
    if (total <= 1024 * 1024) {
      final rows = await db.query(
        _t,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : AppTask.fromJson(rows.first);
    }
    final rows = await db.rawQuery(
      '''
      SELECT id, session_id, provider_id, key_id, kind, prompt, params_json,
             ref_images_json, status, idempotency_key, remote_task_id,
             remote_expires_at, attempts, download_attempts,
             created_at, updated_at, queued_at, started_at, finished_at
      FROM $_t WHERE id = ? LIMIT 1
    ''',
      [id],
    );
    if (rows.isEmpty) return null;
    // 大列（error/usage/result_hint/poll_state）丢弃：诊断信息以调试日志为准。
    final r = Map<String, Object?>.of(rows.first)
      ..['error_json'] = null
      ..['usage_json'] = null
      ..['result_hint_json'] = null
      ..['poll_state_json'] = null;
    return AppTask.fromJson(r);
  }

  /// 幂等键查重（备份恢复"跳过已存在"用：idx_tasks_idem 唯一索引，
  /// 不同 id 同幂等键的 INSERT OR REPLACE 会顶掉本地行，须提前拦截）。
  Future<AppTask?> byIdempotencyKey(String key) async {
    final rows = await db.query(
      _t,
      where: 'idempotency_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : AppTask.fromJson(rows.first);
  }

  /// 行大小体检：只读各 TEXT 列的 length()（不传大列本体，CursorWindow
  /// 永远安全）→ 返回 id → 总字符数。用于导出前防御 + 日志定位大列。
  /// （全表 SELECT * 已删除：单行超 Android CursorWindow 2MB 会直接抛异常，
  /// 导出一律走 measureRows 体检 + listByIds 白名单，U-29/U-30。）
  Future<Map<String, int>> measureRows() async {
    final rows = await db.rawQuery('''
      SELECT id,
        length(prompt) AS s_prompt,
        length(params_json) AS s_params,
        length(ref_images_json) AS s_refs,
        length(mask_path) AS s_mask,
        length(poll_state_json) AS s_poll,
        length(error_json) AS s_error,
        length(usage_json) AS s_usage,
        length(result_hint_json) AS s_hint
      FROM $_t ORDER BY created_at ASC
    ''');
    int num(dynamic v) => (v as int?) ?? 0;
    return {
      for (final r in rows)
        r['id'] as String:
            num(r['s_prompt']) +
            num(r['s_params']) +
            num(r['s_refs']) +
            num(r['s_mask']) +
            num(r['s_poll']) +
            num(r['s_error']) +
            num(r['s_usage']) +
            num(r['s_hint']),
    };
  }

  /// 单行各列长度明细（定位超限字段用）。
  Future<Map<String, int>> measureRow(String id) async {
    final rows = await db.rawQuery(
      '''
      SELECT
        length(prompt) AS s_prompt,
        length(params_json) AS s_params,
        length(ref_images_json) AS s_refs,
        length(mask_path) AS s_mask,
        length(poll_state_json) AS s_poll,
        length(error_json) AS s_error,
        length(usage_json) AS s_usage,
        length(result_hint_json) AS s_hint
      FROM $_t WHERE id = ?
    ''',
      [id],
    );
    if (rows.isEmpty) return const {};
    final r = rows.first;
    return {for (final e in r.entries) e.key: (e.value as int?) ?? 0};
  }

  /// 按 id 白名单读取（导出跳过超限行时用）。
  Future<List<AppTask>> listByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      _t,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'created_at ASC',
    );
    return rows.map(AppTask.fromJson).toList();
  }

  /// 旧库清洗（2026-11-15）：超限大列置空，防 CursorWindow 崩溃。
  /// 幂等；启动时 bootstrap 调用（恢复扫描之前）。正常数据（预签名直链
  /// 提示 <2KB、error_json encodeError 已截断）远低于阈值，不受影响。
  Future<int> sanitizeOversizedRows() async {
    var touched = 0;
    touched += await db.update(
      _t,
      {'result_hint_json': null},
      where: 'length(result_hint_json) > ?',
      whereArgs: [65536],
    );
    touched += await db.update(
      _t,
      {'error_json': null},
      where: 'length(error_json) > ?',
      whereArgs: [131072],
    );
    return touched;
  }

  /// 删除任务记录（真删）：images.task_id 为 ON DELETE SET NULL（§5.2
  /// 「无任务图」语义，U-42）——删除时图片记录自动解除关联并**保留在画廊**；
  /// 磁盘图片文件与 debug_logs 均不动。
  Future<void> delete(String id) async {
    await db.delete(_t, where: 'id = ?', whereArgs: [id]);
  }

  /// 备份恢复 upsert（id 相同跳过由调用方判断；replace 兜底）。
  Future<void> upsert(AppTask task) async {
    await db.insert(
      _t,
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AppTask>> byStatuses(List<TaskStatus> statuses) async {
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.query(
      _t,
      where: 'status IN ($placeholders)',
      whereArgs: statuses.map((s) => s.name).toList(),
      orderBy: 'created_at ASC',
    );
    return rows.map(AppTask.fromJson).toList();
  }

  /// 启动恢复扫描：全部非终态（§7.6）。
  Future<List<AppTask>> nonTerminal() =>
      byStatuses(TaskStatus.values.where((s) => s.isActive).toList());

  Future<int> countByKey(String keyId) async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_t WHERE key_id = ?', [keyId]),
      ) ??
      0;

  /// 平台引用计数（删除自定义平台拦截用）。
  Future<int> countByProvider(String providerId) async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_t WHERE provider_id = ?', [
          providerId,
        ]),
      ) ??
      0;

  /// usage 统计（M3）：近 N 天按「天 × 平台」汇总成功任务的张数与 tokens。
  ///
  /// 张数口径 = **历史产出**（2026-11-15 定）：优先 result_hint_json.persist
  /// （引擎落盘成功时写入的实际张数快照——用户删图后统计不回溯降数）；
  /// 旧任务无该字段 COALESCE 回退 images 表 COUNT（=现存，未删过即产出）。
  /// 演进记录：最初取 params_json 的提交 n（上游未按 n 出全时虚高，且
  /// tasks 无 n 列——更早历史 bug：SUM(t.n) 抛 no such column，异常被
  /// FutureBuilder 吞成"暂无成功任务"）；
  /// usage_json 由引擎在 succeeded 时写入（OpenAI usage 原样）；
  /// 无 usage 的平台（或旧任务）tokens 计 NULL，SUM 自动忽略。
  Future<List<Map<String, Object?>>> usageByDay({int days = 30}) async {
    final since = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return db.rawQuery(
      r'''
      SELECT date(finished_at / 1000, 'unixepoch', 'localtime') AS day,
             COALESCE(p.display_name, t.provider_id) AS provider,
             COUNT(*) AS tasks,
             SUM(COALESCE(
               CAST(json_extract(t.result_hint_json, '$.persist') AS INTEGER),
               (SELECT COUNT(*) FROM images i WHERE i.task_id = t.id)
             )) AS images,
             SUM(CAST(json_extract(t.usage_json, '$.total_tokens') AS INTEGER)) AS tokens
      FROM tasks t
      LEFT JOIN provider_configs p ON p.id = t.provider_id
      WHERE t.status = ? AND t.finished_at >= ?
      GROUP BY day, provider
      ORDER BY day DESC, provider
    ''',
      [TaskStatus.succeeded.name, since],
    );
  }

  /// 历史任务分页（跨会话终态记录）：按完成时间倒序，join 平台显示名。
  /// 内存态（活跃 + 本次会话终态）由 orchestrator VM 提供；此查询补齐
  /// 跨会话历史（任务页「历史」tab）。
  Future<List<TaskHistoryItem>> history({
    int limit = 50,
    int offset = 0,
  }) async {
    final terminal = TaskStatus.values
        .where((s) => !s.isActive)
        .map((s) => s.name)
        .toList();
    final placeholders = List.filled(terminal.length, '?').join(',');
    final rows = await db.rawQuery(
      '''
      SELECT t.*, COALESCE(p.display_name, t.provider_id) AS _provider_name
      FROM tasks t
      LEFT JOIN provider_configs p ON p.id = t.provider_id
      WHERE t.status IN ($placeholders)
      ORDER BY COALESCE(t.finished_at, t.updated_at) DESC
      LIMIT ? OFFSET ?
    ''',
      [...terminal, limit, offset],
    );
    return [
      for (final r in rows)
        TaskHistoryItem(
          task: AppTask.fromJson(r),
          providerName: r['_provider_name']?.toString() ?? '-',
        ),
    ];
  }
}

/// 历史任务行：任务实体 + 平台显示名（SQL join 补齐，AppTask 无此字段）。
class TaskHistoryItem {
  const TaskHistoryItem({required this.task, required this.providerName});

  final AppTask task;
  final String providerName;
}
