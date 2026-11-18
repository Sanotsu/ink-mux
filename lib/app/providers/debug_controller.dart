import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../domain/entities/debug_log_entry.dart';
import 'app_services.dart';
import 'repos.dart';

/// 调试页视图状态。
class DebugViewState {
  const DebugViewState({
    this.loading = true,
    this.entries = const [],
    this.reachedStart = false,
    this.errorsOnly = false,
    this.enabled = DebugDefaults.enabled,
    this.total = 0,
    this.hasNew = false,
    this.sessionFilter,
  });

  final bool loading;
  final List<DebugLogEntry> entries;

  /// true = 已到日志起点，无更早内容。
  final bool reachedStart;
  final bool errorsOnly;
  final bool enabled;
  final int total;

  /// 有更新日志待刷新（深分页时不自动重载，由用户手动刷新）。
  final bool hasNew;

  /// 会话过滤（任务行「查看调试日志」进入；null = 全部）。
  final String? sessionFilter;

  DebugViewState copyWith({
    bool? loading,
    List<DebugLogEntry>? entries,
    bool? reachedStart,
    bool? errorsOnly,
    bool? enabled,
    int? total,
    bool? hasNew,
    String? sessionFilter,
    bool clearSessionFilter = false,
  }) => DebugViewState(
    loading: loading ?? this.loading,
    entries: entries ?? this.entries,
    reachedStart: reachedStart ?? this.reachedStart,
    errorsOnly: errorsOnly ?? this.errorsOnly,
    enabled: enabled ?? this.enabled,
    total: total ?? this.total,
    hasNew: hasNew ?? this.hasNew,
    sessionFilter: clearSessionFilter
        ? null
        : (sessionFilter ?? this.sessionFilter),
  );
}

final debugLogProvider = NotifierProvider<DebugLogController, DebugViewState>(
  DebugLogController.new,
);

class DebugLogController extends Notifier<DebugViewState> {
  @override
  DebugViewState build() => const DebugViewState();

  Future<void> load() async {
    final repo = ref.read(debugRepoProvider);
    final prefs = ref.read(appServicesProvider).prefs;
    final enabled =
        prefs.getBool(PrefKeys.debugEnabled) ?? DebugDefaults.enabled;
    state = state.copyWith(
      loading: true,
      enabled: enabled,
      errorsOnly: state.errorsOnly,
      entries: const [],
      reachedStart: false,
      hasNew: false,
    );
    final entries = await repo.latest(
      errorsOnly: state.errorsOnly,
      limit: DebugDefaults.pageSize,
      sessionId: state.sessionFilter,
    );
    final total = state.sessionFilter == null
        ? await repo.countAll()
        : entries.length;
    state = state.copyWith(
      loading: false,
      entries: entries,
      total: total,
      reachedStart: entries.length < DebugDefaults.pageSize,
    );
  }

  /// 定位到指定任务会话（路由 /debug?session=xxx 或任务行跳转）。
  Future<void> setSessionFilter(String sessionId) async {
    state = state.copyWith(sessionFilter: sessionId);
    await load();
  }

  /// 清除会话过滤，回到全部日志。
  Future<void> clearSessionFilter() async {
    state = state.copyWith(clearSessionFilter: true);
    await load();
  }

  /// 轻量刷新：仅对比最新一条 id，有变化才重载。
  /// - 未深入分页（≤1 页）→ 整体重载（实时感）；
  /// - 已深入分页 → 只置 hasNew 横幅，由用户决定是否刷新（不破坏已加载内容）。
  Future<void> refreshIfNewer() async {
    if (state.loading) return;
    // 会话过滤视图不自动刷新提示（全局最新 id 与过滤结果无关，会误报）。
    if (state.sessionFilter != null) return;
    final repo = ref.read(debugRepoProvider);
    final top = await repo.latest(errorsOnly: state.errorsOnly, limit: 1);
    final topId = top.isEmpty ? null : top.first.id;
    final curTop = state.entries.isEmpty ? null : state.entries.first.id;
    if (topId == curTop) return;
    if (state.entries.length <= DebugDefaults.pageSize) {
      await load();
    } else {
      if (!state.hasNew) state = state.copyWith(hasNew: true);
    }
  }

  Future<void> loadOlder() async {
    if (state.reachedStart || state.entries.isEmpty) return;
    final repo = ref.read(debugRepoProvider);
    final older = await repo.latest(
      beforeId: state.entries.last.id,
      errorsOnly: state.errorsOnly,
      limit: DebugDefaults.pageSize,
      sessionId: state.sessionFilter,
    );
    state = state.copyWith(
      entries: [...state.entries, ...older],
      reachedStart: older.length < DebugDefaults.pageSize,
    );
  }

  Future<void> toggleErrorsOnly() async {
    state = state.copyWith(errorsOnly: !state.errorsOnly);
    await load();
  }

  Future<void> setEnabled(bool enabled) async {
    final repo = ref.read(debugRepoProvider);
    final prefs = ref.read(appServicesProvider).prefs;
    await prefs.setBool(PrefKeys.debugEnabled, enabled);
    await repo.setEnabled(enabled);
    state = state.copyWith(enabled: enabled);
  }

  Future<void> clearAll() async {
    await ref.read(debugRepoProvider).clearAll();
    await load();
  }

  Future<String> exportToFile({String? targetPath}) =>
      ref.read(debugRepoProvider).exportToFile(targetPath: targetPath);
}
