import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/util/convert.dart';
import '../../data/adapters/adapter.dart';
import '../../data/adapters/registry.dart';
import '../../data/db/daos/image_dao.dart';
import '../../data/notifications/notify_service.dart';
import '../../data/storage/image_store.dart';
import '../../domain/entities/app_task.dart';
import '../../domain/entities/debug_log_entry.dart';
import '../../domain/entities/param_snapshot.dart';
import '../../domain/values/enums.dart';
import 'app_services.dart';

/// 任务引擎（§7）：统一状态机 + 并发闸门 + 轮询 + 恢复。
/// DB 是唯一事实源（迁移先落库再改 VM）；UI 只读 [TaskVm]。

class TaskVm {
  const TaskVm({
    required this.id,
    required this.sessionId,
    required this.status,
    required this.kind,
    required this.providerName,
    required this.model,
    required this.prompt,
    required this.n,
    required this.createdAt,
    this.remoteTaskId,
    this.doneImages = 0,
    this.errorMessage,
    this.errorCode,
    this.errorRetryable = false,
    this.phaseHint,
    this.startedAt,
    this.finishedAt,
    this.canRetryPersist = false,
  });

  final String id;
  final String sessionId;
  final TaskStatus status;
  final TaskKind kind;
  final String providerName;
  final String model;
  final String prompt;
  final int n;
  final int createdAt;
  final String? remoteTaskId;
  final int doneImages;
  final String? errorMessage;
  final String? errorCode;
  final bool errorRetryable;

  /// 阶段提示（排队重试倒计时等）。
  final String? phaseHint;
  final int? startedAt;
  final int? finishedAt;

  /// persist 失败且结果仍可恢复（结果已就绪，可「仅重试保存」，U-44）。
  /// 结构化信号：由 _transition 在 persist 失败迁移时置位，替代脆弱的
  /// errorMessage 字符串匹配（该匹配保留作旧数据兜底）。
  final bool canRetryPersist;

  bool get isActive => status.isActive;

  TaskVm copyWith({
    TaskStatus? status,
    String? remoteTaskId,
    int? doneImages,
    String? errorMessage,
    bool clearError = false,
    String? errorCode,
    bool? errorRetryable,
    String? phaseHint,
    bool clearPhaseHint = false,
    int? startedAt,
    int? finishedAt,
    bool? canRetryPersist,
  }) => TaskVm(
    id: id,
    sessionId: sessionId,
    status: status ?? this.status,
    kind: kind,
    providerName: providerName,
    model: model,
    prompt: prompt,
    n: n,
    createdAt: createdAt,
    remoteTaskId: remoteTaskId ?? this.remoteTaskId,
    doneImages: doneImages ?? this.doneImages,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    errorCode: clearError ? null : (errorCode ?? this.errorCode),
    errorRetryable: errorRetryable ?? this.errorRetryable,
    phaseHint: clearPhaseHint ? null : (phaseHint ?? this.phaseHint),
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    canRetryPersist: canRetryPersist ?? this.canRetryPersist,
  );
}

class OrchestratorState {
  const OrchestratorState({this.tasks = const {}, this.bootstrapped = false});

  /// 内存中的任务视图（活跃 + 近期终态；历史走 DB 分页）。
  final Map<String, TaskVm> tasks;
  final bool bootstrapped;

  int get activeCount => tasks.values.where((t) => t.isActive).length;

  List<TaskVm> get orderedByCreatedDesc {
    final list = tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  OrchestratorState copyWith({
    Map<String, TaskVm>? tasks,
    bool? bootstrapped,
  }) => OrchestratorState(
    tasks: tasks ?? this.tasks,
    bootstrapped: bootstrapped ?? this.bootstrapped,
  );
}

/// 每任务运行时（不进 state：CancelToken / 定时器 / payload 缓存）。
class _Runner {
  _Runner(this.taskId);

  final String taskId;
  final CancelToken httpCancel = CancelToken();
  bool cancelled = false;
  bool finished = false;

  /// 最近一次成功 payload（persisting 失败后"仅重试保存"用；进程死亡丢失属预期）。
  ImagePayload? lastPayload;

  /// 轮询等待：定时器到期或 wake()（回前台/取消）提前完成。
  Completer<void>? waitGate;
  Timer? _sleepTimer;

  /// 睡眠被 wake() 提前打断（回前台）：轮询循环据此重置退避间隔（§7.3）。
  bool wokeFromSleep = false;

  Future<void> sleep(Duration d) {
    final gate = Completer<void>();
    waitGate = gate;
    _sleepTimer = Timer(d, () {
      if (!gate.isCompleted) gate.complete();
    });
    return gate.future;
  }

  void wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final g = waitGate;
    if (g != null && !g.isCompleted) {
      wokeFromSleep = true;
      g.complete();
    }
  }

  void cancel() {
    cancelled = true;
    wake();
    if (!httpCancel.isCancelled) httpCancel.cancel();
  }
}

final orchestratorProvider =
    NotifierProvider<TaskOrchestrator, OrchestratorState>(TaskOrchestrator.new);

/// 成功任务计数（画廊等页面据此刷新）。
final orchestratorDoneTickProvider = Provider<int>((ref) {
  return ref.watch(
    orchestratorProvider.select(
      (s) =>
          s.tasks.values.where((t) => t.status == TaskStatus.succeeded).length,
    ),
  );
});

class TaskOrchestrator extends Notifier<OrchestratorState> {
  static const Uuid _uuid = Uuid();
  static final math.Random _random = math.Random();

  final Map<String, _Runner> _runners = {};

  AppServices get _s => ref.read(appServicesProvider);

  AdapterRegistry? _registryCache;

  AdapterRegistry get _registry =>
      // 复用容器级单例（app_services），适配器实例与 extraJson 解析缓存全局唯一。
      _registryCache ??= _s.registry;

  /// 并发闸门（§7.2）：设置页可调，实时读 prefs（M3 设置化）。
  int get perProviderLimit =>
      _s.prefs.getInt(PrefKeys.concurrencyPerProvider) ??
      EngineDefaults.perProvider;
  int get globalLimit =>
      _s.prefs.getInt(PrefKeys.concurrencyGlobal) ?? EngineDefaults.global;

  @override
  OrchestratorState build() {
    Future<void>.microtask(bootstrap);
    return const OrchestratorState();
  }

  // ===================== 对外 API =====================

  /// 创建任务并入队；返回 taskId。
  Future<String> enqueue({
    required String providerId,
    required String keyId,
    required TaskKind kind,
    required ParamSnapshot params,
    List<String> refImagePaths = const [],
    String? maskPath,
  }) async {
    final now = nowMs();
    final task = AppTask(
      id: _uuid.v4(),
      sessionId: _uuid.v4(),
      providerId: providerId,
      keyId: keyId,
      kind: kind,
      prompt: params.prompt,
      paramsJson: jsonEncode(params.toJson()),
      refImagesJson: jsonEncode(refImagePaths),
      maskPath: maskPath,
      status: TaskStatus.queued,
      idempotencyKey: _uuid.v4(),
      createdAt: now,
      updatedAt: now,
      queuedAt: now,
    );
    await _s.tasks.insert(task);
    await _logEvent(
      task.sessionId,
      task.id,
      '任务入队（${kind == TaskKind.edit ? '编辑' : '生图'} · ${params.model} · 幂等 ${task.idempotencyKey.substring(0, 8)}）',
    );
    _putVm(task, providerName: await _providerName(providerId));
    _pump();
    return task.id;
  }

  /// 用户取消（服务端可能仍扣费，文案由 UI 呈现）。
  void cancel(String taskId) {
    final runner = _runners[taskId];
    final vm = state.tasks[taskId];
    if (vm == null) return;
    if (vm.status == TaskStatus.queued) {
      runner?.cancel();
      unawaited(_transition(taskId, TaskStatus.cancelled));
      _pump();
      return;
    }
    runner?.cancel();
  }

  /// 失败/未知重试（§7.4/§7.6）。
  /// **异步任务结果找回（2026-11-16 新增）**：failed 且有 remoteTaskId 时
  /// 优先查一轮远端——看门狗/轮询网络失败判死的任务，上游可能早已完成
  /// （**已扣费**），直接重新提交 = 二次扣费且旧结果永久丢失；凭
  /// remoteTaskId + 同令牌查询即可零费用找回（completed 直接落盘 /
  /// running 恢复轮询）。远端已失败/不存在/查询网络失败 → 照常重提。
  /// unknown（App 提交中死亡）无 remoteTaskId → 同幂等 key 重提：同步幂等
  /// 平台命中上游缓存不重复扣费；无幂等平台（a6）等同重新生成。
  Future<void> retry(String taskId) async {
    final task = await _s.tasks.byId(taskId);
    final status = task?.status;
    if (task == null ||
        (status != TaskStatus.failed && status != TaskStatus.unknown)) {
      return;
    }
    if (status == TaskStatus.failed && task.remoteTaskId != null) {
      final notExpired =
          task.remoteExpiresAt == null ||
          nowMs() < task.remoteExpiresAt! * 1000;
      if (notExpired && await _resumeRemoteTask(task)) return;
    }
    await _transition(taskId, TaskStatus.queued, extra: {'queued_at': nowMs()});
    _pump();
  }

  /// failed 任务的结果找回：凭 remoteTaskId + 同令牌查询一轮远端状态。
  /// 返回 true = 已接管（completed 已落盘 / running 已恢复轮询），
  /// false = 远端已失败/不存在/查询异常，调用方应走正常重提路径。
  Future<bool> _resumeRemoteTask(AppTask task) async {
    final provider = await _s.providers.byId(task.providerId);
    final secret = provider == null ? null : await _s.vault.read(task.keyId);
    if (provider == null || secret == null) return false;
    try {
      final adapter = _registry.ofProvider(provider);
      final outcome = await adapter.poll(
        provider.baseUrl,
        RemoteTaskRef(
          taskId: task.remoteTaskId!,
          expiresAtSec: task.remoteExpiresAt,
        ),
        ApiCredential(keyId: task.keyId, secret: secret),
        session: task.sessionId,
        taskId: task.id,
      );
      switch (outcome) {
        case PollCompleted(:final payload):
          await _logEvent(task.sessionId, task.id, '重试找回：远端已完成，直接落盘（免重复扣费）');
          await _doPersist(task, payload);
          return true;
        case PollRunning():
          await _logEvent(task.sessionId, task.id, '重试找回：远端仍在执行，恢复轮询');
          await _transition(task.id, TaskStatus.waiting);
          final fresh = await _s.tasks.byId(task.id);
          if (fresh != null) {
            unawaited(
              _pollLoop(
                fresh,
                RemoteTaskRef(
                  taskId: task.remoteTaskId!,
                  expiresAtSec: task.remoteExpiresAt,
                ),
              ),
            );
          }
          return true;
        case PollFailed(:final error):
          await _logEvent(
            task.sessionId,
            task.id,
            '重试找回：远端任务已失败（${error.message}），转重新提交',
          );
        case PollGone(:final reason):
          await _logEvent(
            task.sessionId,
            task.id,
            '重试找回：远端任务不存在/已过期（$reason），转重新提交',
          );
      }
    } on AppException catch (e) {
      await _logEvent(task.sessionId, task.id, '重试找回：查询失败（${e.message}），转重新提交');
    }
    return false;
  }

  /// 换 Key 重试（M2 多 Key 轮流备用）：Auth/Quota 失败后换同平台下一把 Key。
  /// 返回 false 表示没有可用的其他 Key（调用方应给出用户可见的提示，
  /// U-43：此前静默返回 false，菜单点了毫无反应）。
  Future<bool> retryAlternateKey(String taskId) async {
    final task = await _s.tasks.byId(taskId);
    if (task == null || task.status != TaskStatus.failed) return false;
    final keys = await _s.keys.listByProvider(task.providerId);
    final others =
        keys
            .where((k) => k.id != task.keyId && !k.disabled) // 停用 Key 不参与轮换
            .toList()
          ..sort((a, b) {
            // 默认 Key 优先，其余按创建时间。
            final d = (b.isDefault ? 1 : 0).compareTo(a.isDefault ? 1 : 0);
            return d != 0 ? d : a.createdAt.compareTo(b.createdAt);
          });
    if (others.isEmpty) return false;
    final next = others.first;
    await _s.tasks.patch(
      taskId,
      task.status,
      extra: {'key_id': next.id},
      now: nowMs(),
    );
    await _logEvent(task.sessionId, task.id, '换 Key 重试 → ${next.label}');
    await retry(taskId);
    return true;
  }

  /// 仅重试保存（persisting 失败 / 链接过期重新取链，§8.2）。
  Future<void> retryPersist(String taskId) async {
    final task = await _s.tasks.byId(taskId);
    if (task == null) return;
    final runner = _runners[taskId] ??= _Runner(taskId);
    var payload = runner.lastPayload;
    if (payload == null && task.remoteTaskId != null) {
      // 重新 poll 一轮拿新 payload（预签名每次查询重签，最可靠）。
      // 返回 null = 状态已由 _rePollOnce 处理（failed/expired/已恢复轮询），
      // 不再继续（否则会用兜底 hint 覆盖刚迁移的状态）。
      payload = await _rePollOnce(task);
      if (payload == null) return;
    }
    payload ??= _payloadFromHint(task);
    if (payload == null) {
      await _transition(
        taskId,
        TaskStatus.failed,
        error: LocalIoException('原始结果已不可恢复，请重新生成'),
      );
      return;
    }
    await _doPersist(task, payload);
  }

  /// 从 result_hint_json（最后已知 url）构造下载 payload（§8.2）：
  /// 查询链路不可用（Key 失效/任务过期）但预签名 url 仍在有效期内时的兜底。
  ImagePayload? _payloadFromHint(AppTask task) {
    final hint = task.resultHintJson;
    if (hint == null || hint.isEmpty) return null;
    try {
      final decoded = jsonDecode(hint);
      if (decoded is! Map<String, dynamic>) return null;
      final urls = (decoded['urls'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((u) => u.isNotEmpty)
          .toList();
      if (urls.isEmpty) return null;
      return ImagePayload(items: [for (final u in urls) ImageItem(url: u)]);
    } on FormatException {
      return null;
    }
  }

  /// App 回前台：立即补一轮 poll（§7.6）。
  void onAppResumed() {
    for (final vm in state.tasks.values) {
      if (vm.status == TaskStatus.waiting) _runners[vm.id]?.wake();
    }
  }

  /// 从视图中移除终态任务（不动 DB 记录；历史由任务页 DB 分页补齐，M2 完善）。
  void forget(String taskId) {
    if (state.tasks[taskId]?.isActive ?? true) return;
    _runners.remove(taskId);
    final next = Map<String, TaskVm>.of(state.tasks)..remove(taskId);
    state = state.copyWith(tasks: next);
  }

  // ===================== 启动恢复（§7.6） =====================

  Future<void> bootstrap() async {
    if (state.bootstrapped) return;
    final pendings = await _s.tasks.nonTerminal();
    for (final task in pendings) {
      final providerName = await _providerName(task.providerId);
      switch (task.status) {
        case TaskStatus.queued:
          _putVm(task, providerName: providerName);
        case TaskStatus.submitting:
          // 提交在途死亡：结果不可知（神稳有幂等可安全重试）。
          _putVm(task, providerName: providerName);
          await _transition(
            task.id,
            TaskStatus.unknown,
            error: UpstreamException(
              'App 在提交过程中被关闭，结果不可知；'
              '同一幂等 Key 重试可避免重复扣费（若平台支持）',
            ),
          );
        case TaskStatus.waiting:
          final expMs = (task.remoteExpiresAt ?? 0) * 1000;
          if (task.remoteTaskId == null || nowMs() > expMs) {
            _putVm(task, providerName: providerName);
            await _transition(task.id, TaskStatus.expired);
          } else {
            _putVm(task, providerName: providerName);
            await _logEvent(
              task.sessionId,
              task.id,
              '启动恢复：继续轮询 ${task.remoteTaskId}',
            );
            unawaited(
              _pollLoop(
                task,
                RemoteTaskRef(
                  taskId: task.remoteTaskId!,
                  expiresAtSec: task.remoteExpiresAt,
                ),
              ),
            );
          }
        case TaskStatus.persisting:
          _putVm(task, providerName: providerName);
          await retryPersist(task.id);
        default:
          break;
      }
    }
    state = state.copyWith(bootstrapped: true, tasks: Map.of(state.tasks));
    _pump();
  }

  // ===================== 内部：调度与提交 =====================

  void _pump() {
    final queued =
        state.tasks.values.where((t) => t.status == TaskStatus.queued).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    // 闸门只统计真正运行中的任务（submitting/waiting/persisting）。
    // queued 不占名额（历史 bug：queued 也算 active，同平台排队任务
    // 自己堵死自己的名额，导致除首个外永远"排队中"）。
    // 循环内本地计数兜底异步窗口：_run 未及迁移状态前，后续 queued
    // 也能正确判断是否超额。
    final running = state.tasks.values.where(_isRunning).toList();
    var runningGlobal = running.length;
    final runningByProvider = <String, int>{};
    for (final t in running) {
      runningByProvider[t.providerName] =
          (runningByProvider[t.providerName] ?? 0) + 1;
    }
    for (final vm in queued) {
      if (runningGlobal >= globalLimit) break;
      final same = runningByProvider[vm.providerName] ?? 0;
      if (same >= perProviderLimit) continue;
      runningGlobal++;
      runningByProvider[vm.providerName] = same + 1;
      unawaited(_run(vm.id));
    }
  }

  /// 任务已进入实际执行链路（提交/等待结果/落盘）。
  bool _isRunning(TaskVm t) =>
      t.status == TaskStatus.submitting ||
      t.status == TaskStatus.waiting ||
      t.status == TaskStatus.persisting;

  Future<void> _run(String taskId) async {
    var task = await _s.tasks.byId(taskId);
    if (task == null || task.status != TaskStatus.queued) return;
    final runner = _runners[taskId] ??= _Runner(taskId);
    final provider = await _s.providers.byId(task.providerId);
    if (provider == null) {
      await _transition(
        taskId,
        TaskStatus.failed,
        error: LocalIoException('平台配置不存在'),
      );
      return;
    }
    final secret = await _s.vault.read(task.keyId);
    if (secret == null || secret.isEmpty) {
      await _transition(
        taskId,
        TaskStatus.failed,
        error: AuthException('密钥已不可用，请到设置页重新保存 Key'),
      );
      return;
    }
    final cred = ApiCredential(keyId: task.keyId, secret: secret);
    final adapter = _registry.ofProvider(provider);
    final params = task.params;
    final supportsIdem = adapter.caps.supportsIdempotencyKey;
    final maxAttempts = supportsIdem ? 3 : 1;

    await _transition(
      taskId,
      TaskStatus.submitting,
      extra: {'started_at': nowMs()},
    );

    // 提交重试（§7.4）：429 豁免幂等要求（提交被拒不扣费），其余按
    // 有幂等 3 次 / 无幂等 1 次；神稳同步挂起 ≤15min（§7.5 超时矩阵）。

    var attempt = 0;
    while (true) {
      if (runner.cancelled) {
        await _transition(taskId, TaskStatus.cancelled);
        return;
      }
      try {
        final Submission submission;
        if (task.kind == TaskKind.edit) {
          final spec = EditSpec(
            model: params.model,
            prompt: params.prompt,
            n: params.n,
            size: params.size,
            quality: params.quality,
            background: params.background,
            outputFormat: params.outputFormat,
            outputCompression: params.outputCompression,
            responseFormat: params.responseFormat ?? 'url',
            extra: params.extras,
            idempotencyKey: task.idempotencyKey,
            refImagePaths: (jsonDecode(task.refImagesJson) as List)
                .cast<String>(),
            maskPath: task.maskPath,
          );
          submission = await adapter.editImage(
            provider.baseUrl,
            spec,
            cred,
            session: task.sessionId,
            taskId: task.id,
            cancel: runner.httpCancel,
          );
        } else {
          submission = await adapter.text2Image(
            provider.baseUrl,
            _generateSpec(task, params),
            cred,
            session: task.sessionId,
            taskId: task.id,
            cancel: runner.httpCancel,
          );
        }
        switch (submission) {
          case SubmissionSyncDone(:final payload):
            await _doPersist(task, payload);
          case SubmissionAccepted(:final ref, :final retryAfter):
            await _logEvent(
              task.sessionId,
              task.id,
              '已受理 task_id=${ref.taskId}',
            );
            await _transition(
              taskId,
              TaskStatus.waiting,
              extra: {
                'remote_task_id': ref.taskId,
                if (ref.expiresAtSec != null)
                  'remote_expires_at': ref.expiresAtSec,
              },
            );
            final fresh = await _s.tasks.byId(taskId);
            if (fresh != null) {
              unawaited(_pollLoop(fresh, ref, initialInterval: retryAfter));
            }
        }
        return;
      } on AppException catch (e) {
        if (runner.cancelled) {
          await _transition(taskId, TaskStatus.cancelled);
          return;
        }
        attempt++;
        // 429 平台限流（如 a6 image_task_limit / 神稳 image_queue_*）：提交被拒、
        // 任务未被受理不会扣费，无论有无幂等头都可安全自动重提（§7.4），
        // 上限 3 次；其余错误维持"有幂等 3 次 / 无幂等 1 次"的防重复扣费规则。
        final rateLimited = e is RateLimitException;
        final limit = rateLimited ? 3 : maxAttempts;
        final canRetry = e.retryable && attempt < limit;
        await _logEvent(
          task.sessionId,
          task.id,
          '提交失败($attempt/$limit)：${e.message}${canRetry ? ' → 退避后重试' : ''}',
        );
        if (canRetry) {
          final wait = switch (e) {
            RateLimitException(:final retryAfter) =>
              retryAfter ??
                  // 无 Retry-After（a6 image_task_limit）：本地 10s→30s→60s 递增。
                  Duration(
                    seconds: switch (attempt) {
                      1 => 10,
                      2 => 30,
                      _ => 60,
                    },
                  ),
            _ => Duration(seconds: attempt == 1 ? 5 : 15),
          };
          _patchVm(
            taskId,
            phaseHint: '退避 ${wait.inSeconds}s 后重试（$attempt/$limit）',
          );
          try {
            await runner.sleep(wait);
          } on Exception {
            // ignore：sleep 不会被 error 完成。
          }
          continue;
        }
        await _transition(taskId, TaskStatus.failed, error: e);
        _pump();
        return;
      }
    }
  }

  // ===================== 内部：轮询（§7.3） =====================

  /// 文生图 spec（普通提交与流式提交共用）。
  GenerateSpec _generateSpec(AppTask task, ParamSnapshot params) =>
      GenerateSpec(
        model: params.model,
        prompt: params.prompt,
        n: params.n,
        size: params.size,
        quality: params.quality,
        background: params.background,
        outputFormat: params.outputFormat,
        outputCompression: params.outputCompression,
        responseFormat: params.responseFormat ?? 'url',
        extra: params.extras,
        idempotencyKey: task.idempotencyKey,
      );

  Future<void> _pollLoop(
    AppTask task,
    RemoteTaskRef ref, {
    Duration? initialInterval,
  }) async {
    final runner = _runners[task.id] ??= _Runner(task.id);
    // 起始间隔取 202 响应 Retry-After（a6api 为 3s），下限 3s（§7.3）。
    final baseIntervalMs = math.max(
      initialInterval?.inMilliseconds ?? 3000,
      3000,
    );
    var intervalMs = baseIntervalMs;
    var pollFailStreak = 0;
    final provider = await _s.providers.byId(task.providerId);
    if (provider == null) {
      await _transition(
        task.id,
        TaskStatus.failed,
        error: LocalIoException('平台配置不存在'),
      );
      return;
    }
    final secret = await _s.vault.read(task.keyId);
    if (secret == null) {
      await _transition(
        task.id,
        TaskStatus.failed,
        error: AuthException('密钥已不可用'),
      );
      return;
    }
    final adapter = _registry.ofProvider(provider);
    final cred = ApiCredential(keyId: task.keyId, secret: secret);

    // 看门狗（§7.3）：上游长时间无终态（服务端悬挂）→ 自动失败并释放并发名额，
    // 避免单个卡死任务阻塞整条队列（排队任务在终态 迁移时由 _pump 自动补位）。
    // ⚠️ 计时起点 = 本轮轮询启动（2026-11-16 修复）：
    // 原来用 task.startedAt（首次提交时刻）——提交失败 → failed → 用户隔数分钟点重试 → waiting
    // 后看门狗第一轮循环立即误杀（"上游超过 10 分钟未返回"，一次 poll 都没跑，平台实际几十秒已完成）。
    // 失败滞留时间不应计入本轮等待。
    final watchdogMs = EngineDefaults.watchdog.inMilliseconds;
    final startMs = nowMs();

    while (!runner.cancelled && !runner.finished) {
      if (nowMs() - startMs > watchdogMs) {
        await _logEvent(
          task.sessionId,
          task.id,
          '看门狗：上游超过 ${EngineDefaults.watchdog.inMinutes} 分钟未返回结果，自动失败',
        );
        await _transition(
          task.id,
          TaskStatus.failed,
          error: UpstreamException(
            '上游超过 ${EngineDefaults.watchdog.inMinutes} 分钟未返回结果，已自动失败（可重试）',
          ),
        );
        return;
      }
      final expMs = (ref.expiresAtSec ?? 0) * 1000;
      if (ref.expiresAtSec != null && nowMs() > expMs) {
        await _transition(task.id, TaskStatus.expired);
        return;
      }
      try {
        await runner.sleep(Duration(milliseconds: intervalMs));
      } on Exception {
        break;
      }
      if (runner.cancelled) break;
      // 回前台唤醒（§7.3）：立即补一轮 poll，并把退避重置回起始间隔。
      if (runner.wokeFromSleep) {
        runner.wokeFromSleep = false;
        intervalMs = baseIntervalMs;
      }

      try {
        final outcome = await adapter.poll(
          provider.baseUrl,
          ref,
          cred,
          session: task.sessionId,
          taskId: task.id,
          cancel: runner.httpCancel,
        );
        pollFailStreak = 0;
        switch (outcome) {
          case PollRunning():
            // 指数退避 ×1.8 封顶 15s + ±20% 抖动（§7.3）。
            final jitter = 0.8 + _random.nextDouble() * 0.4;
            intervalMs = math.min((intervalMs * 1.8 * jitter).round(), 15000);
            _patchVm(task.id, clearPhaseHint: true);
          case PollCompleted(:final payload):
            // result_hint_json 由 _doPersist 统一写入（覆盖同步/流式路径）。
            await _doPersist(task, payload);
            return;
          case PollFailed(:final error):
            await _logEvent(task.sessionId, task.id, '任务失败：${error.message}');
            await _transition(task.id, TaskStatus.failed, error: error);
            return;
          case PollGone(:final reason):
            // §7.3：查询期内 404 → 异常丢失（failed 可重试）；超期 → expired。
            final expMs = (ref.expiresAtSec ?? 0) * 1000;
            if (ref.expiresAtSec == null || nowMs() < expMs) {
              await _logEvent(task.sessionId, task.id, '任务查询 404：未超查询期，判定异常丢失');
              await _transition(
                task.id,
                TaskStatus.failed,
                error: UpstreamException('$reason（未超查询期，疑似结果异常丢失）'),
              );
            } else {
              await _transition(
                task.id,
                TaskStatus.expired,
                error: UpstreamException(reason),
              );
            }
            return;
        }
      } on AppException catch (e) {
        if (runner.cancelled) break;
        pollFailStreak++;
        if (pollFailStreak >= 3) {
          await _transition(
            task.id,
            TaskStatus.failed,
            error: NetworkException('轮询连续失败：${e.message}'),
          );
          return;
        }
        await runner.sleep(const Duration(seconds: 3));
      }
    }
    if (runner.cancelled && !runner.finished) {
      await _transition(task.id, TaskStatus.cancelled);
    }
  }

  /// retryPersist 用的单轮 poll：completed → payload；failed/expired → 迁移并返回 null。
  Future<ImagePayload?> _rePollOnce(AppTask task) async {
    final provider = await _s.providers.byId(task.providerId);
    final secret = provider == null ? null : await _s.vault.read(task.keyId);
    if (provider == null || secret == null) {
      await _transition(
        task.id,
        TaskStatus.failed,
        error: AuthException('密钥已不可用'),
      );
      return null;
    }
    final adapter = _registry.ofProvider(provider);
    final outcome = await adapter.poll(
      provider.baseUrl,
      RemoteTaskRef(
        taskId: task.remoteTaskId!,
        expiresAtSec: task.remoteExpiresAt,
      ),
      ApiCredential(keyId: task.keyId, secret: secret),
      session: task.sessionId,
      taskId: task.id,
    );
    switch (outcome) {
      case PollCompleted(:final payload):
        return payload;
      case PollFailed(:final error):
        await _transition(task.id, TaskStatus.failed, error: error);
      case PollGone(:final reason):
        // 与 _pollLoop 同规则（§7.3）：查询期内 404 → 异常丢失，超期 → expired。
        final expMs = (task.remoteExpiresAt ?? 0) * 1000;
        if (task.remoteExpiresAt == null || nowMs() < expMs) {
          await _transition(
            task.id,
            TaskStatus.failed,
            error: UpstreamException('$reason（未超查询期，疑似结果异常丢失）'),
          );
        } else {
          await _transition(
            task.id,
            TaskStatus.expired,
            error: UpstreamException(reason),
          );
        }
      case PollRunning():
        // 仍在执行 → 恢复轮询（2026-11-16 改进：原来直接 failed"请稍后
        // 再次重试保存"，需要用户反复手动点；现在转回 waiting 自动续取）。
        await _transition(task.id, TaskStatus.waiting);
        await _logEvent(task.sessionId, task.id, '重试保存：远端仍在执行，恢复轮询');
        final fresh = await _s.tasks.byId(task.id);
        if (fresh != null) {
          unawaited(
            _pollLoop(
              fresh,
              RemoteTaskRef(
                taskId: task.remoteTaskId!,
                expiresAtSec: task.remoteExpiresAt,
              ),
            ),
          );
        }
    }
    return null;
  }

  // ===================== 内部：落盘（§8） =====================

  Future<void> _doPersist(
    AppTask task,
    ImagePayload payload, {
    bool allowRepoll = true,
  }) async {
    final runner = _runners[task.id] ??= _Runner(task.id);
    runner.lastPayload = payload;
    // 最后已知 url 入库（§8.2）：进程死亡后恢复下载/重签兜底的数据源。
    // ⚠️ 仅收 http(s) 直链——神稳实测会在 url 字段直接返回 data URI （整图 base64，3MB+），
    // 入库会把单行撑爆 Android CursorWindow 2MB 上限（U-29，SELECT * 全崩）；
    // data URI 属内存态，进程死亡后本就无意义。
    final hintUrls = [
      for (final i in payload.items)
        if (i.url != null && i.url!.startsWith('http')) i.url!,
    ];
    // payload_ready：persist 失败后「仅重试保存」的结构化资格信号（U-44）——
    // 历史详情据此判断（曾靠 errorMessage 字符串匹配，脆弱）。
    await _transition(
      task.id,
      TaskStatus.persisting,
      extra: {
        if (hintUrls.isNotEmpty)
          'result_hint_json': jsonEncode({
            'urls': hintUrls,
            'payload_ready': true,
          }),
      },
    );
    try {
      final store = ImageStore(_s.dioHub, ImageDao(_s.db.database));
      final assets = await store.persist(
        taskId: task.id,
        sessionId: task.sessionId,
        payload: payload,
        prompt: task.prompt,
        paramsJson: task.paramsJson,
        onProgress: (done, total) => _patchVm(task.id, doneImages: done),
        cancel: runner.httpCancel,
      );
      // 上游未按 n 出全（实测 A6：n=2 有时只回 1 张，平台按实际产出计费）：
      // 记事件供任务详情核对；不自动补拍——补拍是新请求新扣费，必须用户手动。
      if (assets.length < task.params.n) {
        await _logEvent(
          task.sessionId,
          task.id,
          '上游仅返回 ${assets.length}/${task.params.n} 张（上游未按 n 出全）',
        );
      }
      await _logEvent(task.sessionId, task.id, '落盘完成：${assets.length} 张');
      // 落盘快照写入 hint（2026-11-15）：
      // - persist=实际落库张数 → 用量统计"历史产出"口径（用户删图后统计
      //   不回溯降数；旧任务无此字段，COALESCE 回退 images COUNT）；
      // - shortfall=上游未按 n 出全标记 → 任务详情警示只读此信号。原因：
      //   用户手动删图后 COUNT < n 与上游少出无法区分，COUNT 对账必误报。
      await _transition(
        task.id,
        TaskStatus.succeeded,
        extra: {
          'finished_at': nowMs(),
          if (payload.usageJson != null)
            'usage_json': jsonEncode(payload.usageJson),
          'result_hint_json': jsonEncode({
            'urls': hintUrls,
            'persist': assets.length,
            if (assets.length < task.params.n) 'shortfall': true,
          }),
        },
      );
    } on AppException catch (e) {
      if (runner.cancelled) {
        await _transition(task.id, TaskStatus.cancelled);
        return;
      }
      // 预签名链接可能已过期（§8.2）：异步任务自动 re-poll 换新链重下一轮，
      // 仍失败才判 failed（allowRepoll 防递归）。
      if (allowRepoll && task.remoteTaskId != null) {
        await _logEvent(task.sessionId, task.id, '下载失败（${e.message}），重新轮询换新链接');
        final fresh = await _rePollOnce(task);
        if (fresh != null) {
          await _doPersist(task, fresh, allowRepoll: false);
          return;
        }
      }
      await _transition(
        task.id,
        TaskStatus.failed,
        canRetryPersist: true,
        error: LocalIoException('${e.message}（结果已就绪，可"仅重试保存"）'),
      );
    } catch (e) {
      await _transition(
        task.id,
        TaskStatus.failed,
        canRetryPersist: true,
        error: LocalIoException('写盘失败：$e（可"仅重试保存"）'),
      );
    }
  }

  // ===================== 内部：迁移与视图 =====================

  Future<void> _transition(
    String taskId,
    TaskStatus status, {
    Map<String, Object?>? extra,
    AppException? error,
    bool canRetryPersist = false,
  }) async {
    final now = nowMs();
    final dbExtra = {...?extra};
    if (status.isTerminal) dbExtra['finished_at'] = now;
    if (error != null) dbExtra['error_json'] = jsonEncode(encodeError(error));
    await _s.tasks.patch(taskId, status, extra: dbExtra, now: now);
    final vm = state.tasks[taskId];
    if (vm != null) {
      var next = vm.copyWith(
        status: status,
        clearError: error == null,
        errorMessage: error?.message,
        errorCode: error?.platformCode,
        errorRetryable: error?.retryable ?? false,
        clearPhaseHint: true,
        finishedAt: status.isTerminal ? now : null,
        canRetryPersist: canRetryPersist,
      );
      if (extra != null && extra.containsKey('remote_task_id')) {
        next = next.copyWith(remoteTaskId: extra['remote_task_id'] as String);
      }
      state = state.copyWith(tasks: {...state.tasks, taskId: next});
    }
    if (status.isTerminal) {
      final runner = _runners[taskId];
      runner?.finished = true;
      _notifyIfBackgrounded(vm, status, error);
      _pump();
    }
  }

  /// 后台完成/失败 → 本地通知（§14 M2；前台不扰民）。
  void _notifyIfBackgrounded(
    TaskVm? vm,
    TaskStatus status,
    AppException? error,
  ) {
    if (vm == null) return;
    if (!Platform.isAndroid && !Platform.isWindows) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.resumed) return;
    final label = '${vm.providerName} · ${vm.model}';
    switch (status) {
      case TaskStatus.succeeded:
        NotifyService.showTaskDone(title: '任务完成 · ${vm.n} 张已保存', body: label);
      case TaskStatus.failed:
        NotifyService.showTaskDone(
          title: '任务失败',
          body: '$label\n${error?.message ?? ''}',
        );
      default:
        break;
    }
  }

  void _patchVm(
    String taskId, {
    int? doneImages,
    String? phaseHint,
    bool clearPhaseHint = false,
  }) {
    final vm = state.tasks[taskId];
    if (vm == null) return;
    state = state.copyWith(
      tasks: {
        ...state.tasks,
        taskId: vm.copyWith(
          doneImages: doneImages,
          phaseHint: phaseHint,
          clearPhaseHint: clearPhaseHint,
        ),
      },
    );
  }

  void _putVm(AppTask task, {required String providerName}) {
    state = state.copyWith(
      tasks: {
        ...state.tasks,
        task.id: TaskVm(
          id: task.id,
          sessionId: task.sessionId,
          status: task.status,
          kind: task.kind,
          providerName: providerName,
          model: task.params.model,
          prompt: task.prompt,
          n: task.params.n,
          createdAt: task.createdAt,
          remoteTaskId: task.remoteTaskId,
          startedAt: task.startedAt,
          finishedAt: task.finishedAt,
        ),
      },
    );
  }

  Future<String> _providerName(String providerId) async {
    final p = await _s.providers.byId(providerId);
    return p?.displayName ?? providerId.substring(0, 8);
  }

  Future<void> _logEvent(
    String sessionId,
    String? taskId,
    String message,
  ) async {
    _s.logSink.add(
      DebugLogEntry(
        sessionId: sessionId,
        taskId: taskId,
        seq: _s.logSink.nextSeq(sessionId),
        ts: nowMs(),
        kind: LogKind.event,
        direction: LogDirection.info,
        url: message,
      ),
    );
  }
}
