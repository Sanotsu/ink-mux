import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers/app_services.dart';
import '../../../data/db/daos/task_dao.dart';
import '../../../domain/entities/app_task.dart';
import '../../../domain/values/enums.dart';
import '../tasks/tasks_page.dart';
import 'history_detail_page.dart';

/// 创作历史（跨会话任务存档）：DB 终态记录分页 · 详情页 · 再次生成 · 删除。
/// 与任务页（会话任务，内存态）本质不同：这里只读存档，操作
/// [再次生成]（复制参数发起全新任务）/ [删除]（真删 DB，不动图片文件）。
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  final _items = <TaskHistoryItem>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;

  static const int _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    if (_items.isEmpty) {
      setState(() => _loading = true);
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await ref
          .read(appServicesProvider)
          .tasks
          .history(limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _exhausted = page.length < _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 行点击 → 详情页；返回 true = 记录已删除（列表移除）；
  /// 'changed' = 记录被就地更新（仅重试保存成功，U-44 → 刷新该行）。
  Future<void> _openDetail(TaskHistoryItem item) async {
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) =>
            HistoryDetailPage(task: item.task, providerName: item.providerName),
      ),
    );
    if (result == true) {
      setState(() {
        _items.removeWhere((e) => e.task.id == item.task.id);
      });
    } else if (result == 'changed') {
      final fresh = await ref
          .read(appServicesProvider)
          .tasks
          .byId(item.task.id);
      if (!mounted || fresh == null) return;
      final i = _items.indexWhere((e) => e.task.id == item.task.id);
      if (i >= 0) {
        setState(() {
          _items[i] = TaskHistoryItem(
            task: fresh,
            providerName: item.providerName,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: MediaQuery.sizeOf(context).width < 600 ? 48 : 56,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('创作历史'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(
              child: Text('（暂无创作历史）\n任务完成后自动存档', textAlign: TextAlign.center),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _items.length + 1,
              itemBuilder: (context, i) {
                if (i < _items.length) {
                  return _HistoryTile(
                    item: _items[i],
                    onTap: () => _openDetail(_items[i]),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: _exhausted
                        ? Text(
                            '已全部加载（${_items.length} 条）',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          )
                        : OutlinedButton(
                            onPressed: _loadingMore ? null : _loadMore,
                            child: _loadingMore
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('加载更多'),
                          ),
                  ),
                );
              },
            ),
    );
  }
}

/// 历史任务行：摘要展示，点击进详情页。
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.item, required this.onTap});

  final TaskHistoryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = item.task;
    final isEdit = t.kind == TaskKind.edit;
    final model = t.params.model;
    final time = DateFormat(
      'MM-dd HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(t.finishedAt ?? t.updatedAt));
    final error = _errorMessageOf(t);

    return ListTile(
      onTap: onTap,
      leading: Icon(
        isEdit
            ? Icons.photo_size_select_large_outlined
            : Icons.palette_outlined,
        color: scheme.outline,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${item.providerName} · $model',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          taskStatusBadgeOf(context, t.status),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            [
              t.prompt.isEmpty ? '' : t.prompt,
              '${t.params.n} 张',
              time,
              if (error != null) '✗ $error',
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: error != null ? scheme.error : scheme.outline,
            ),
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
    );
  }
}

String? _errorMessageOf(AppTask task) {
  final raw = task.errorJson;
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded['message']?.toString();
    }
  } on FormatException {
    // ignore：脏数据按无错误处理。
  }
  return null;
}
