import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/providers/app_services.dart';

/// 用量统计页（M3，2026-11-14 由弹窗改为整页）：近 30 天按「本地日期 × 平台」
/// 汇总成功任务数 / 张数 / tokens（json_extract usage.total_tokens）。
/// 整页滚动 + 行式自适应布局，窄屏不溢出（§10.9）。
class UsageStatsPage extends ConsumerWidget {
  const UsageStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('用量统计（近 30 天）')),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: ref.read(appServicesProvider).tasks.usageByDay(days: 30),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                '统计查询失败：${snap.error}\n（详情见调试日志）',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            );
          }
          final rows = snap.data ?? const <Map<String, Object?>>[];
          if (rows.isEmpty) {
            return const Center(child: Text('近 30 天暂无成功任务'));
          }

          // 折叠为 day → 平台行列表；同时累计 30 天总览。
          final byDay = <String, List<Map<String, Object?>>>{};
          var totalTasks = 0;
          var totalImages = 0;
          var totalTokens = 0;
          for (final row in rows) {
            byDay.putIfAbsent(row['day']?.toString() ?? '', () => []).add(row);
            totalTasks += (row['tasks'] as num?)?.toInt() ?? 0;
            totalImages += (row['images'] as num?)?.toInt() ?? 0;
            final t = row['tokens'];
            if (t is num) totalTokens += t.toInt();
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // 30 天总览卡。
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _total(context, '$totalTasks', '任务'),
                      _total(context, '$totalImages', '出图'),
                      _total(context, _tokensShort(totalTokens), 'tokens'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in byDay.entries)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_dayLabel(entry.key), style: textTheme.titleSmall),
                        const SizedBox(height: 4),
                        for (final row in entry.value)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${row['provider']?.toString() ?? '-'} · '
                                    '${row['tasks']} 任务 · ${row['images']} 图',
                                    style: textTheme.bodyMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _tokensLabel(row['tokens']),
                                  style: textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'ⓘ tokens 取平台 usage.total_tokens；无 usage 数据的平台不计入',
                style: textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _total(BuildContext context, String value, String label) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          value,
          style: textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }

  String _dayLabel(String day) {
    if (day.isEmpty) return '未知日期';
    final date = DateTime.tryParse(day);
    if (date == null) return day;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = today.difference(target).inDays;
    final prefix = switch (diff) {
      0 => '今天',
      1 => '昨天',
      _ => '',
    };
    return prefix.isEmpty
        ? DateFormat('yyyy-MM-dd（EEEE）', 'zh').format(date)
        : '$prefix · ${DateFormat('MM-dd').format(date)}';
  }

  String _tokensLabel(Object? tokens) {
    if (tokens is! num || tokens <= 0) return '';
    return _tokensShort(tokens.toInt());
  }

  String _tokensShort(int tokens) {
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return '$tokens';
  }
}
