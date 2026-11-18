import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/guard.dart';
import '../../app/providers/orchestrator.dart';
import '../../domain/values/enums.dart';

/// 同步生成守卫弹窗（§10.8 精确规格）：
/// 全屏遮罩不可点关；mm:ss 计时；阶段显示；取消按钮 >30s 左下角弱化出现并二次确认；
/// 最小化按钮策略按模式；ESC/返回键弹三选项；终态自动转换。
class GuardOverlay extends ConsumerStatefulWidget {
  const GuardOverlay({super.key});

  @override
  ConsumerState<GuardOverlay> createState() => _GuardOverlayState();
}

class _GuardOverlayState extends ConsumerState<GuardOverlay> {
  Timer? _ticker;
  int _elapsedSec = 0;
  final FocusNode _focusNode = FocusNode();

  List<TaskVm> get _active {
    final tasks =
        ref
            .read(orchestratorProvider)
            .tasks
            .values
            .where((t) => t.isActive)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return tasks;
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orchestrator = ref.watch(orchestratorProvider);
    final active = orchestrator.tasks.values.where((t) => t.isActive).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (active.isEmpty) return const SizedBox.shrink();
    final first = active.first;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 计时：首个活跃任务从创建起累计。
    _elapsedSec =
        (DateTime.now().millisecondsSinceEpoch - first.createdAt) ~/ 1000;
    final mm = (_elapsedSec ~/ 60).toString().padLeft(2, '0');
    final ss = (_elapsedSec % 60).toString().padLeft(2, '0');

    // 模式判定：异步已受理（waiting + remoteTaskId）→ 可安全离开。
    final asyncAccepted = active.any(
      (t) => t.status == TaskStatus.waiting && t.remoteTaskId != null,
    );
    final anySyncActive = active.any(
      (t) => t.status == TaskStatus.queued || t.status == TaskStatus.submitting,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showBackChoices(context);
      },
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _showBackChoices(context);
          }
        },
        child: Material(
          color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.86),
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 24,
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PhaseIndicator(task: first),
                    const SizedBox(height: 20),
                    Text(
                      '$mm:$ss',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontFeatures: [const FontFeature.tabularFigures()],
                          ),
                    ),
                    const SizedBox(height: 12),
                    if (asyncAccepted && !anySyncActive) ...[
                      Icon(
                        Icons.cloud_done_outlined,
                        color: scheme.primary,
                        size: 18,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '任务已提交服务端\n可随时最小化 / 切页面 / 关闭 App\n重新打开会自动继续取结果',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else ...[
                      Text(
                        '请保持应用运行\n复杂请求耗时较长属正常，服务端最长等待 15 分钟',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_elapsedSec > 120) ...[
                      const SizedBox(height: 8),
                      Text(
                        '已等待较久，仍在生成…',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.tertiary),
                      ),
                    ],
                    if (active.length > 1) ...[
                      const SizedBox(height: 8),
                      Text(
                        '共 ${active.length} 个任务进行中（首个计时）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 取消：>30s 才出现（左下角弱化）。
                        if (_elapsedSec > 30)
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: scheme.outline,
                            ),
                            onPressed: () => _confirmCancel(context, first),
                            child: const Text(
                              '取消等待',
                              style: TextStyle(fontSize: 12),
                            ),
                          )
                        else
                          const SizedBox(width: 8),
                        // 最小化：异步已受理常驻；同步 30s 后出现。
                        if (asyncAccepted || _elapsedSec > 30)
                          TextButton.icon(
                            onPressed: () =>
                                ref.read(guardOpenProvider.notifier).minimize(),
                            icon: const Icon(Icons.minimize, size: 14),
                            label: Text(
                              anySyncActive ? '最小化(有风险)' : '最小化',
                              style: const TextStyle(fontSize: 12),
                            ),
                          )
                        else
                          const SizedBox(width: 8),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showBackChoices(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Text('生成进行中'),
        content: const SizedBox(width: 340, child: Text('任务仍在执行，要如何处理？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续等待'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(guardOpenProvider.notifier).minimize();
            },
            child: const Text('最小化到后台'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(ctx);
              final active = _active;
              if (active.isNotEmpty) {
                ref.read(orchestratorProvider.notifier).cancel(active.first.id);
              }
            },
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
  }

  void _confirmCancel(BuildContext context, TaskVm task) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Text('确定取消？'),
        content: const SizedBox(
          width: 340,
          child: Text('任务可能已在服务端开始处理，取消不保证避免扣费。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续等待'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(orchestratorProvider.notifier).cancel(task.id);
            },
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  const _PhaseIndicator({required this.task});

  final TaskVm task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = switch (task.status) {
      TaskStatus.queued => (
        Icons.schedule,
        '排队中${task.phaseHint == null ? '' : ' · ${task.phaseHint}'}',
      ),
      TaskStatus.submitting => (
        Icons.upload_outlined,
        '提交中${task.phaseHint == null ? '' : ' · ${task.phaseHint}'}',
      ),
      TaskStatus.waiting => (Icons.cloud_sync_outlined, '生成中（服务端执行）'),
      TaskStatus.persisting => (
        Icons.download_outlined,
        task.n > 1 ? '保存中 ${task.doneImages}/${task.n}' : '保存中',
      ),
      _ => (Icons.hourglass_empty, task.status.name),
    };
    return Column(
      children: [
        SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.outline),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${task.providerName} · ${task.model}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
