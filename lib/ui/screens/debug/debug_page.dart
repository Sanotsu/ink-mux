import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers/debug_controller.dart';
import '../../../core/theme/density.dart';
import '../../../data/repos/debug_log_repo.dart';
import '../../../domain/entities/debug_log_entry.dart';
import '../../../domain/values/enums.dart';

/// 调试日志页（§9.4）：会话分组 + 100 条分页 + 仅看错误 + 详情 + 清除/导出。
/// [session]：任务行「查看调试日志」定位到该任务会话（/debug?session=xxx）。
class DebugPage extends ConsumerStatefulWidget {
  const DebugPage({super.key, this.session});

  final String? session;

  @override
  ConsumerState<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends ConsumerState<DebugPage> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = widget.session;
      final ctrl = ref.read(debugLogProvider.notifier);
      if (session != null && session.isNotEmpty) {
        ctrl.setSessionFilter(session);
      } else {
        ctrl.load();
      }
    });
    // 实时刷新：轻查询对比最新 id，有新日志才重载（§9.4）。
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) ref.read(debugLogProvider.notifier).refreshIfNewer();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(debugLogProvider);
    final ctrl = ref.read(debugLogProvider.notifier);
    final d = AppDensity.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final scheme = Theme.of(context).colorScheme;

    final groups = _group(state.entries);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: compact ? 48 : 56,
        leading: compact
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.go('/settings'),
              )
            : null,
        title: Text('调试日志 · ${state.total} 条'),
        actions: [
          FilterChip(
            label: const Text('仅看错误'),
            selected: state.errorsOnly,
            onSelected: (_) => ctrl.toggleErrorsOnly(),
            showCheckmark: false,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: state.enabled ? '记录中（点击暂停）' : '已暂停（点击恢复）',
            onPressed: () => ctrl.setEnabled(!state.enabled),
            icon: Icon(
              state.enabled
                  ? Icons.radio_button_checked
                  : Icons.pause_circle_outline,
              color: state.enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'clear' => _confirmClear(context),
              'save' => _export(context),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', child: Text('保存为文件')),
              PopupMenuItem(value: 'clear', child: Text('清除全部')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : state.entries.isEmpty
          ? Center(
              child: Text(
                state.enabled ? '暂无日志\n（设置页"测试连通"或发起请求后产生）' : '记录已暂停',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          : Column(
              children: [
                if (state.sessionFilter != null)
                  Material(
                    color: scheme.tertiaryContainer,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.filter_alt_outlined,
                        size: 18,
                        color: scheme.onTertiaryContainer,
                      ),
                      title: Text(
                        '仅显示会话 ${state.sessionFilter!.substring(0, 8)} 的日志',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () => ctrl.clearSessionFilter(),
                        child: const Text('查看全部'),
                      ),
                    ),
                  ),
                if (state.hasNew)
                  Material(
                    color: scheme.primaryContainer,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.new_releases_outlined,
                        size: 18,
                        color: scheme.onPrimaryContainer,
                      ),
                      title: Text(
                        '有新日志',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () => ctrl.load(),
                        child: const Text('刷新'),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.all(d.screenH),
                    itemCount: groups.length + (state.reachedStart ? 0 : 1),
                    itemBuilder: (context, i) {
                      if (i == groups.length) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: OutlinedButton(
                              onPressed: () => ctrl.loadOlder(),
                              child: const Text('加载更早 100 条'),
                            ),
                          ),
                        );
                      }
                      return _SessionGroupView(
                        group: groups[i],
                        onTapEntry: (e) => _openDetail(context, e),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  List<_SessionGroup> _group(List<DebugLogEntry> entries) {
    final groups = <String, _SessionGroup>{};
    for (final e in entries) {
      final g = groups.putIfAbsent(
        e.sessionId,
        () => _SessionGroup(sessionId: e.sessionId, taskId: e.taskId),
      );
      g.entries.add(e);
      if (e.hasError) g.hasError = true;
    }
    return groups.values.toList();
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部日志？'),
        content: const Text('所有会话的请求/响应记录将被删除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(debugLogProvider.notifier).clearAll();
    }
  }

  Future<void> _export(BuildContext context) async {
    final ctrl = ref.read(debugLogProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await ctrl.exportToFile();
      messenger.showSnackBar(SnackBar(content: Text('已导出：$path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _openDetail(BuildContext context, DebugLogEntry entry) {
    return showDialog<void>(
      context: context,
      builder: (_) => _LogDetailDialog(entry: entry),
    );
  }
}

class _SessionGroup {
  _SessionGroup({required this.sessionId, this.taskId});

  final String sessionId;
  final String? taskId;
  final List<DebugLogEntry> entries = [];
  bool hasError = false;
}

class _SessionGroupView extends StatelessWidget {
  const _SessionGroupView({required this.group, required this.onTapEntry});

  final _SessionGroup group;
  final void Function(DebugLogEntry) onTapEntry;

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final scheme = Theme.of(context).colorScheme;
    final first = group.entries.first;
    final time = DateFormat('MM-dd HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(first.ts));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                group.hasError
                    ? Icons.warning_amber_rounded
                    : Icons.dns_outlined,
                size: 16,
                color: group.hasError ? scheme.error : scheme.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$time · 会话 ${group.sessionId.substring(0, 8)} · ${group.entries.length} 条'
                  '${group.taskId == null ? '' : ' · 任务 ${group.taskId!.substring(0, 8)}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final e in group.entries)
                _EntryTile(entry: e, onTap: () => onTapEntry(e)),
            ],
          ),
        ),
        SizedBox(height: d.cardGap),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final DebugLogEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = DateFormat('HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(entry.ts));
    final uri = Uri.tryParse(entry.url ?? '');
    final path = uri == null || uri.host.isEmpty
        ? (entry.url ?? '')
        : '${uri.host}${uri.path}';

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: onTap,
      leading: SizedBox(
        width: 56,
        child: Text(time, style: Theme.of(context).textTheme.bodySmall),
      ),
      title: Row(
        children: [
          Icon(
            switch (entry.direction) {
              LogDirection.req => Icons.north_east,
              LogDirection.resp => Icons.south_west,
              LogDirection.info => Icons.info_outline,
            },
            size: 14,
            color: entry.hasError ? scheme.error : scheme.outline,
          ),
          const SizedBox(width: 4),
          if (entry.method != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                entry.method!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          Expanded(
            child: Text(
              path.isEmpty ? '(非 HTTP 事件)' : path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
      trailing: Text(
        [
          if (entry.statusCode != null) '${entry.statusCode}',
          if (entry.durationMs != null) '${entry.durationMs}ms',
        ].join(' · '),
        style: TextStyle(
          fontSize: 11,
          color: entry.hasError ? scheme.error : scheme.outline,
        ),
      ),
    );
  }
}

/// 详情弹窗：长文本默认渲染前 100 行，滚动到底/按钮加载下 100 行，可展开全部（§9.4）。
class _LogDetailDialog extends StatefulWidget {
  const _LogDetailDialog({required this.entry});

  final DebugLogEntry entry;

  @override
  State<_LogDetailDialog> createState() => _LogDetailDialogState();
}

class _LogDetailDialogState extends State<_LogDetailDialog> {
  static const int _chunkLines = 100;
  int _visibleHeaders = _chunkLines;
  int _visibleBody = _chunkLines;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final headerLines = e.headersJson?.split('\n') ?? const <String>[];
    final bodyLines = e.bodyText?.split('\n') ?? const <String>[];

    return AlertDialog(
      // 桌面定宽大窗（调试日志允许大弹窗，但固定宽不随窗口拉伸）。
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      title: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          '${e.method ?? e.kind.name} '
          '${e.statusCode ?? ''}',
          style: const TextStyle(fontSize: 16),
        ),
        subtitle: Text(
          e.url ?? '(非 HTTP 事件)',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ),
      content: SizedBox(
        width: 720,
        height: 560,
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#${e.seq} · ${e.kind.name}/${e.direction.name}'
                  '${e.durationMs == null ? '' : ' · ${e.durationMs}ms'}',
                ),
                const Divider(height: 16),
                const Text(
                  '── headers ──',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                _chunked(
                  headerLines,
                  _visibleHeaders,
                  () => setState(() => _visibleHeaders += _chunkLines),
                ),
                const SizedBox(height: 12),
                const Text(
                  '── body ──',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: _chunked(
                    bodyLines,
                    _visibleBody,
                    () => setState(() => _visibleBody += _chunkLines),
                    scrollable: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(
              ClipboardData(text: DebugLogRepo.describeEntry(e)),
            );
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('已复制（脱敏文本）')));
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('复制'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _chunked(
    List<String> lines,
    int visible,
    VoidCallback more, {
    bool scrollable = false,
  }) {
    final view = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines.take(visible)) Text(l, softWrap: true),
        if (lines.length > visible)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 12,
              children: [
                TextButton(onPressed: more, child: const Text('再显示 100 行')),
                TextButton(
                  onPressed: () => setState(() {
                    if (scrollable) {
                      _visibleBody = lines.length;
                    } else {
                      _visibleHeaders = lines.length;
                    }
                  }),
                  child: const Text('展开全部'),
                ),
              ],
            ),
          ),
      ],
    );
    if (!scrollable) return Flexible(child: SingleChildScrollView(child: view));
    return SingleChildScrollView(child: view);
  }
}
