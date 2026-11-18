import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/app_services.dart';
import '../../../app/providers/orchestrator.dart';
import '../../../app/providers/studio_import.dart';
import '../../../domain/entities/app_task.dart';
import '../../../domain/values/enums.dart';
import '../tasks/task_detail_dialog.dart';

/// 创作历史详情页（跨会话任务存档）：完整提示词/参数/时间线/元数据展示。
/// 底部固定操作行：去画廊 · 再次生成 · 仅重试保存（persist 失败且结果
/// 仍可恢复时出现，U-44）· 删除。
/// 返回值：true = 记录已删除（列表移除）；'changed' = 记录被就地更新
/// （仅重试保存成功，列表行刷新状态）。
class HistoryDetailPage extends ConsumerStatefulWidget {
  const HistoryDetailPage({
    super.key,
    required this.task,
    required this.providerName,
  });

  final AppTask task;
  final String providerName;

  @override
  ConsumerState<HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends ConsumerState<HistoryDetailPage> {
  late AppTask _task = widget.task;

  /// 仅重试保存资格（U-44，结构化信号 + 旧数据兜底）：
  /// ① persisting 阶段落盘的 result_hint_json 带 payload_ready/urls
  ///    （预签名直链仍在有效期内即可恢复下载）；
  /// ② 旧数据：错误文案含「仅重试保存」（同步任务 data URI 场景 hint
  ///    可能为空，但同进程内 runner 仍持有 lastPayload 可直接落盘）。
  bool get _canRetryPersist {
    if (_task.status != TaskStatus.failed) return false;
    final hint = _task.resultHintJson;
    if (hint != null && hint.isNotEmpty) {
      try {
        final decoded = jsonDecode(hint);
        if (decoded is Map<String, dynamic>) {
          final urls = (decoded['urls'] as List<dynamic>? ?? const []).length;
          if (decoded['payload_ready'] == true || urls > 0) return true;
        }
      } on FormatException {
        // ignore：脏数据按无 hint 处理。
      }
    }
    return _errorMessage.contains('仅重试保存');
  }

  String get _errorMessage {
    final raw = _task.errorJson;
    if (raw == null || raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded['message']?.toString() ?? '';
      }
    } on FormatException {
      // ignore：脏数据按无错误处理。
    }
    return '';
  }

  /// 仅重试保存：重下/重写盘（不重新生成、不重复扣费）。完成后回读任务
  /// 刷新本页（状态/出图数），并 pop('changed') 让列表行同步刷新。
  Future<void> _retryPersist() async {
    final orch = ref.read(orchestratorProvider.notifier);
    final services = ref.read(appServicesProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await orch.retryPersist(_task.id);
    final fresh = await services.tasks.byId(_task.id);
    if (!mounted) return;
    if (fresh != null) setState(() => _task = fresh);
    messenger?.showSnackBar(
      const SnackBar(content: Text('已重新执行保存；若仍失败请看任务状态中的最新错误')),
    );
    Navigator.of(context).pop('changed');
  }

  /// 再次生成：按原任务类型回填创作页——文生图→文生图（提示词+参数）；
  /// 参考图编辑→编辑模式并带回原参考图（本地文件缺失的自动剔除）。
  /// 全新任务/全新幂等 Key。
  void _regenerate() {
    var refImages = const <String>[];
    try {
      final decoded = jsonDecode(_task.refImagesJson);
      if (decoded is List) {
        refImages = decoded.whereType<String>().toList();
      }
    } on FormatException {
      // ignore：脏数据按无参考图处理。
    }
    ref
        .read(studioImportProvider.notifier)
        .request(
          StudioImport(
            refImagePaths: refImages,
            kind: _task.kind,
            prompt: _task.prompt,
            params: _task.params,
            token: 0,
          ),
        );
    context.go('/studio');
  }

  /// 去画廊（U-45）：有图的任务带 task 过滤定位该组图；无图（失败/
  /// 未产出/已删光）直接看全部——避免落进"该任务暂无图片"的空过滤页。
  Future<void> _goGallery() async {
    final dao = ref.read(appServicesProvider).images;
    final n = await dao.countByTask(_task.id);
    if (!mounted) return;
    context.go(n > 0 ? '/gallery?task=${_task.id}' : '/gallery');
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该条创作历史？'),
        content: const Text(
          '仅删除任务记录（参数/状态/错误等）；画廊中该任务产出的图片保留'
          '（磁盘文件不动）。此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(appServicesProvider).tasks.delete(_task.id);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canRetry = _canRetryPersist;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: MediaQuery.sizeOf(context).width < 600 ? 48 : 56,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
          '${widget.providerName} · ${_task.params.model}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        // 落库张数实时对账（上游未按 n 出全时详情页可见）；
        // 仅重试保存后 ValueKey 变化触发重算（U-44）。
        child: FutureBuilder<int>(
          key: ValueKey('${_task.id}:${_task.updatedAt}'),
          future: ref.read(appServicesProvider).images.countByTask(_task.id),
          builder: (context, snap) => TaskDetailContent(
            task: _task,
            providerName: widget.providerName,
            doneImages: snap.data,
          ),
        ),
      ),
      // 底部固定操作行（用户指定 去画廊/再次生成/删除 + U-44 仅重试保存）。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _goGallery,
                  child: const Text('去画廊'),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                child: TextButton(
                  onPressed: _regenerate,
                  child: const Text('再次生成'),
                ),
              ),
              const SizedBox(width: 1),
              if (canRetry) ...[
                Expanded(
                  child: TextButton(
                    onPressed: _retryPersist,
                    child: const Text('重试保存'),
                  ),
                ),
                const SizedBox(width: 1),
              ],
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    side: BorderSide(
                      color: scheme.error.withValues(alpha: 0.5),
                    ),
                  ),
                  onPressed: _confirmDelete,
                  child: const Text('删除'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
