import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/app_services.dart';
import '../../../app/providers/orchestrator.dart';
import '../../../domain/values/enums.dart';
import 'task_detail_dialog.dart';
import 'usage_stats_page.dart';

/// 任务页（§10.4）：会话任务（活跃 + 本次会话终态，内存态）。
/// 状态投影 + 过滤 + unknown 横幅 + 操作；跨会话存档见「创作历史」（/history）。
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  /// 已确认（「知道了」）的 unknown 任务 id：横幅不再提示；
  /// 新产生的 unknown（新 id）仍会重新弹出。
  final Set<String> _ackedUnknownIds = {};

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(orchestratorProvider);
    final unknown = state.tasks.values
        .where(
          (t) =>
              t.status == TaskStatus.unknown &&
              !_ackedUnknownIds.contains(t.id),
        )
        .toList();
    final tasks = state.orderedByCreatedDesc;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: MediaQuery.sizeOf(context).width < 600 ? 48 : 56,
          title: const Text('任务'),
          actions: [
            IconButton(
              tooltip: '创作历史（跨会话存档）',
              onPressed: () => context.push('/history'),
              icon: const Icon(Icons.history, size: 20),
            ),
            IconButton(
              tooltip: '用量统计',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const UsageStatsPage()),
              ),
              icon: const Icon(Icons.insights_outlined, size: 20),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '全部'),
              Tab(text: '进行中'),
              Tab(text: '失败'),
              Tab(text: '未知'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (unknown.isNotEmpty)
              Material(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.warning_amber_rounded,
                    color: Theme.of(context).colorScheme.onTertiaryContainer,
                  ),
                  title: Text(
                    '${unknown.length} 个任务结果不可知（App 在提交过程中被关闭）',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                      fontSize: 13,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          final ctrl = ref.read(orchestratorProvider.notifier);
                          for (final t in unknown) {
                            ctrl.retry(t.id);
                          }
                        },
                        child: const Text('安全重试（同幂等 Key）'),
                      ),
                      // 知道了：不重试，仅确认提示（横幅收起；新 unknown 仍会提示）。
                      TextButton(
                        onPressed: () => setState(() {
                          _ackedUnknownIds.addAll(unknown.map((t) => t.id));
                        }),
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _list(context, ref, tasks, emptyHint: '暂无任务\n创作页提交后在此跟踪'),
                  _list(
                    context,
                    ref,
                    tasks.where((t) => t.isActive).toList(),
                    emptyHint: '（无进行中任务）',
                  ),
                  _list(
                    context,
                    ref,
                    tasks.where((t) => t.status == TaskStatus.failed).toList(),
                    emptyHint: '（无失败任务）',
                  ),
                  _list(
                    context,
                    ref,
                    tasks.where((t) => t.status == TaskStatus.unknown).toList(),
                    emptyHint: '（无未知任务）',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref,
    List<TaskVm> tasks, {
    String emptyHint = '（空）',
  }) {
    if (tasks.isEmpty) {
      return Center(child: Text(emptyHint, textAlign: TextAlign.center));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: tasks.length,
      itemBuilder: (context, i) => _TaskTile(task: tasks[i]),
    );
  }
}

/// 会话任务行（内存态 TaskVm 投影）：状态徽标 + 阶段文案 + 按状态操作。
class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});

  final TaskVm task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(orchestratorProvider.notifier);
    final isEdit = task.kind == TaskKind.edit;
    final elapsed = task.startedAt == null
        ? null
        : ((task.finishedAt ?? DateTime.now().millisecondsSinceEpoch) -
                  task.startedAt!) ~/
              1000;

    return ListTile(
      onTap: () async {
        // 行点击 → 详情弹窗（读 DB 完整任务：参数/时间线/usage/错误）。
        // doneImages 取 VM 实时值：详情「出图 X/N」对账上游未按 n 出全。
        final full = await ref.read(appServicesProvider).tasks.byId(task.id);
        if (!context.mounted) return;
        if (full == null) return;
        await showTaskDetailDialog(
          context,
          ref,
          full,
          task.providerName,
          doneImages: task.doneImages,
        );
      },
      leading: Icon(
        isEdit
            ? Icons.photo_size_select_large_outlined
            : Icons.palette_outlined,
        color: task.isActive ? scheme.primary : scheme.outline,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${task.providerName} · ${task.model}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          taskStatusBadgeOf(
            context,
            task.status,
            done: task.doneImages,
            total: task.n,
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            [
              task.prompt.isEmpty ? '' : task.prompt,
              if (task.isActive && task.phaseHint != null) task.phaseHint!,
              if (task.isActive && task.startedAt != null)
                '已耗时 ${elapsed ?? 0}s',
              if (task.errorMessage != null) '✗ ${task.errorMessage}',
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: task.errorMessage != null ? scheme.error : scheme.outline,
            ),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        itemBuilder: (_) => [
          if (task.isActive)
            const PopupMenuItem(value: 'cancel', child: Text('取消')),
          if (task.status == TaskStatus.failed)
            const PopupMenuItem(value: 'retry', child: Text('重试（同幂等 Key）')),
          if (task.status == TaskStatus.failed &&
              (task.errorCode != null || task.errorRetryable))
            const PopupMenuItem(value: 'retryAltKey', child: Text('换 AK 重试')),
          if (task.status == TaskStatus.failed &&
              // U-44：结构化信号（persist 失败迁移置位）+ 旧数据字符串兜底。
              (task.canRetryPersist ||
                  (task.errorMessage?.contains('仅重试保存') ?? false)))
            const PopupMenuItem(value: 'retryPersist', child: Text('仅重试保存')),
          if (task.errorMessage != null)
            const PopupMenuItem(value: 'copyError', child: Text('复制错误信息')),
          const PopupMenuItem(value: 'debug', child: Text('查看调试日志')),
          const PopupMenuItem(value: 'delete', child: Text('删除记录（仅视图）')),
        ],
        onSelected: (v) => switch (v) {
          'cancel' => ctrl.cancel(task.id),
          'retry' => ctrl.retry(task.id),
          'retryAltKey' => () async {
            // U-43：失败必须给用户可见反馈（此前静默 false = 毫无反应）。
            // 文案用「AK」与「幂等 Key」（请求 uuid）区分，避免歧义。
            final ok = await ctrl.retryAlternateKey(task.id);
            if (!ok && context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('换 AK 重试不可用：该平台没有其他可用 AK（可到「平台管理」为平台添加）'),
                ),
              );
            }
          }(),
          'retryPersist' => ctrl.retryPersist(task.id),
          'copyError' => Clipboard.setData(
            ClipboardData(text: task.errorMessage ?? ''),
          ),
          'debug' => context.go('/debug?session=${task.sessionId}'),
          'delete' => ref.read(orchestratorProvider.notifier).forget(task.id),
          _ => null,
        },
      ),
    );
  }
}

/// 状态徽标（任务行共用；会话行与历史行同一套配色文案）。
Widget taskStatusBadgeOf(
  BuildContext context,
  TaskStatus status, {
  int done = 0,
  int total = 0,
}) {
  final scheme = Theme.of(context).colorScheme;
  final (label, fg, bg) = switch (status) {
    TaskStatus.queued => (
      '排队中',
      scheme.onSurfaceVariant,
      scheme.surfaceContainerHighest,
    ),
    TaskStatus.submitting => ('提交中', scheme.primary, scheme.primaryContainer),
    TaskStatus.waiting => ('等待结果', scheme.primary, scheme.primaryContainer),
    TaskStatus.persisting => (
      '保存中 $done/$total',
      scheme.primary,
      scheme.primaryContainer,
    ),
    TaskStatus.succeeded => (
      '完成',
      scheme.onPrimaryContainer,
      scheme.primaryContainer,
    ),
    TaskStatus.failed => ('失败', scheme.onErrorContainer, scheme.errorContainer),
    TaskStatus.cancelled => (
      '已取消',
      scheme.onSurfaceVariant,
      scheme.surfaceContainerHighest,
    ),
    TaskStatus.expired => (
      '已过期',
      scheme.onTertiaryContainer,
      scheme.tertiaryContainer,
    ),
    TaskStatus.unknown => (
      '未知',
      scheme.onTertiaryContainer,
      scheme.tertiaryContainer,
    ),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(label, style: TextStyle(fontSize: 11, color: fg)),
  );
}
