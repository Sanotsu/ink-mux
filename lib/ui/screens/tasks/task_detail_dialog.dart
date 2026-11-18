import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../domain/entities/app_task.dart';
import '../../../domain/entities/param_snapshot.dart';
import '../../../domain/values/enums.dart';
import 'tasks_page.dart';

/// 任务详情弹窗（会话任务行）：完整参数、时间线、usage、错误与跳转。
/// 内容区为共享组件 [TaskDetailContent]（创作历史详情页复用）。
/// 查看调试日志入口在任务行操作菜单（/debug?session=），弹窗内不重复提供。
Future<void> showTaskDetailDialog(
  BuildContext context,
  WidgetRef ref,
  AppTask task,
  String providerName, {
  int? doneImages,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _TaskDetailDialog(
      task: task,
      providerName: providerName,
      doneImages: doneImages,
    ),
  );
}

class _TaskDetailDialog extends StatelessWidget {
  const _TaskDetailDialog({
    required this.task,
    required this.providerName,
    this.doneImages,
  });

  final AppTask task;
  final String providerName;

  /// 实际落库张数（会话任务行 VM 已知时传入）。
  final int? doneImages;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    final actions = _actions(context, includeClose: !mobile);
    final title = _titleRow(context);

    // 移动端：全屏弹窗（与创作历史详情页同构——Scaffold + AppBar +
    // 全内容滚动 + 底部操作），长错误信息可滚动查看不溢出（§10.9）。
    if (mobile) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: title,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: TaskDetailContent(task: task, doneImages: doneImages),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: actions,
              ),
            ),
          ),
        ),
      );
    }

    // 桌面：定宽 520 弹窗；内容限高滚动，长错误不撑破视口。
    return AlertDialog(
      title: title,
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: TaskDetailContent(task: task, doneImages: doneImages),
          ),
        ),
      ),
      actions: actions,
    );
  }

  List<Widget> _actions(BuildContext context, {required bool includeClose}) => [
    // 画廊入口仅成功任务有意义（失败/未知任务无产出图，跳过去是空过滤页）。
    if (task.status == TaskStatus.succeeded)
      TextButton(
        onPressed: () {
          Navigator.of(context).pop();
          context.go('/gallery?task=${task.id}');
        },
        child: const Text('在画廊中查看'),
      ),
    if (includeClose)
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
  ];

  Widget _titleRow(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      taskStatusBadgeOf(context, task.status, total: task.params.n),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          '$providerName · ${task.params.model}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

class TaskDetailContent extends StatelessWidget {
  const TaskDetailContent({
    super.key,
    required this.task,
    this.providerName,
    this.doneImages,
  });

  final AppTask task;
  final String? providerName;

  /// 实际落库张数（会话任务取 VM doneImages、历史详情取 images COUNT）；
  /// 上游未按 n 出全时与提交 n 对账展示，缺失则不出此行。
  final int? doneImages;

  ParamSnapshot get _params => task.params;

  String? get errorMessage {
    final raw = task.errorJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded['message']?.toString();
    } on FormatException {
      // ignore：脏数据按无错误处理。
      return null;
    }
  }

  /// 上游未按 n 出全标记（引擎落盘时写入 result_hint_json.shortfall）。
  /// 警示只读此信号——若用「落库张数 < n」对账，用户手动删图后同样
  /// count < n，与上游少出无法区分，必然误报。
  bool get _shortfall {
    final raw = task.resultHintJson;
    if (raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> && decoded['shortfall'] == true;
    } on FormatException {
      return false;
    }
  }

  /// 用量展示（§8.4，以平台结算为准）：总数 + 输入/输出拆分（A6 返回
  /// usage 明细；神稳无 usage 字段时不展示）。
  String? get _usageLabel {
    final raw = task.usageJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      int? of(String key) => (decoded[key] as num?)?.toInt();
      final total = of('total_tokens');
      final input = of('input_tokens');
      final output = of('output_tokens');
      if (total == null && input == null && output == null) return null;
      final buf = StringBuffer();
      if (total != null) buf.write('$total tokens');
      if (input != null && output != null) {
        buf.write('（输入 $input · 输出 $output）');
      }
      return buf.toString();
    } on FormatException {
      return null;
    }
  }

  String _fmt(int? ms) => ms == null
      ? '—'
      : DateFormat('yyyy-MM-dd HH:mm:ss')
            .format(DateTime.fromMillisecondsSinceEpoch(ms));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final p = _params;
    final error = errorMessage;
    final startedAt = task.startedAt;
    final finishedAt = task.finishedAt;
    final elapsed = startedAt != null && finishedAt != null
        ? '${((finishedAt - startedAt) / 1000).toStringAsFixed(0)}s'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _section(context, '提示词'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            task.prompt.isEmpty ? '（无）' : task.prompt,
            style: textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: task.prompt));
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(const SnackBar(content: Text('已复制提示词')));
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('复制', style: TextStyle(fontSize: 12)),
          ),
        ),
        _section(context, '参数'),
        if (providerName != null)
          _kv(context, '平台模型', '$providerName · ${p.model}'),
        _kv(context, '类型', task.kind == TaskKind.edit ? '图片编辑' : '文生图'),
        _kv(context, '数量', '${p.n} 张'),
        // 出图行 = 实时可见张数（会话 VM 计数 / 历史详情 COUNT，删图后减少）；
        // 未出全警示只读引擎落盘 shortfall 信号（不受删图影响）。
        if (doneImages != null) _kv(context, '出图', '$doneImages 张'),
        if (_shortfall)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '上游未按 n 出全（提交 ${p.n} 张，实际落库少于该数），'
              '平台按实际产出计费；如需补齐请手动再次生成',
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        if (p.size != null) _kv(context, '尺寸', p.size!),
        if (p.quality != null) _kv(context, '质量', p.quality!),
        if (p.background != null) _kv(context, '背景', p.background!),
        if (p.outputFormat != null) _kv(context, '输出格式', p.outputFormat!),
        if (p.outputCompression != null)
          _kv(context, '压缩', '${p.outputCompression}'),
        if (p.responseFormat != null) _kv(context, '响应格式', p.responseFormat!),
        if (p.extras != null && p.extras!.isNotEmpty)
          _kv(context, '扩展参数', p.extras!.keys.join('、')),
        _section(context, '时间线'),
        _kv(context, '创建', _fmt(task.createdAt)),
        _kv(context, '开始', _fmt(startedAt)),
        _kv(context, '完成', _fmt(finishedAt)),
        if (elapsed != null) _kv(context, '耗时', elapsed),
        _section(context, '元数据'),
        _kv(context, '任务 ID', task.id),
        _kv(context, '幂等 Key', task.idempotencyKey),
        if (task.remoteTaskId != null)
          _kv(context, '平台任务 ID', task.remoteTaskId!),
        if (_usageLabel != null) _kv(context, '用量', _usageLabel!),
        if (error != null) ...[
          _section(context, '错误'),
          Text(
            error,
            style: textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _kv(BuildContext context, String label, String v) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(v, style: textTheme.bodySmall)),
        ],
      ),
    );
  }
}
