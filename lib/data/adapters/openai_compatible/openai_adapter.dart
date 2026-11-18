import 'package:dio/dio.dart';

import '../../../core/error/app_exception.dart';
import '../../../domain/entities/model_info.dart';
import '../../../domain/values/enums.dart';
import '../../../data/network/dio_hub.dart';
import '../adapter.dart';
import 'presets.dart';

/// OpenAI Images 兼容适配器：两站共用，差异由 [preset] 驱动（§6.2）。
class OpenAiCompatibleAdapter implements ImageProviderAdapter {
  OpenAiCompatibleAdapter(this.preset, this.dio);

  final OpenAiPreset preset;
  final Dio dio;

  @override
  String get presetKey => preset.presetKey;

  @override
  String get displayName => preset.displayName;

  @override
  ProviderCapabilities get caps => preset.caps;

  /// 统一走 DioHub.options（§3.4-⑤）：鉴权/幂等头、extra 会话标识、
  /// 分级超时全部单点维护，适配层只声明业务参数。
  Options _opts({
    required ApiCredential cred,
    String? session,
    String? taskId,
    Duration? receiveTimeout,
    Duration? connectTimeout,
    String? idempotencyKey,
    String? contentType,
    ResponseType? responseType,
    Map<String, String>? extraHeaders,
  }) => DioHub.options(
    bearer: cred.secret,
    session: session,
    taskId: taskId,
    // 幂等头仅注入支持平台（shenwenai）；无幂等平台提交不自动重试由引擎保证。
    idempotencyKey: idempotencyKey != null && caps.supportsIdempotencyKey
        ? idempotencyKey
        : null,
    receiveTimeout: receiveTimeout,
    connectTimeout: connectTimeout,
    contentType: contentType,
    responseType: responseType,
    extraHeaders: extraHeaders,
  );

  @override
  Future<List<ModelInfo>> listModels(
    String baseUrl,
    ApiCredential cred, {
    String? session,
    CancelToken? cancel,
  }) async {
    try {
      final resp = await dio.get(
        '$baseUrl/models',
        options: _opts(
          cred: cred,
          session: session,
          receiveTimeout: DioHub.modelsReceive,
        ),
        cancelToken: cancel,
      );
      final data = resp.data;
      final list = data is Map<String, dynamic>
          ? (data['data'] as List<dynamic>? ?? const [])
          : const <dynamic>[];
      var models = <ModelInfo>[];
      for (final item in list) {
        if (item is Map<String, dynamic> && item['id'] != null) {
          models.add(
            ModelInfo(
              id: item['id'].toString(),
              display: item['display_name']?.toString(),
              raw: item,
            ),
          );
        }
      }
      final filter = preset.filterModels;
      return filter == null ? models : filter(models);
    } on DioException catch (e) {
      throw appExceptionFromDio(e);
    }
  }

  @override
  Future<Submission> text2Image(
    String baseUrl,
    GenerateSpec spec,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  }) async {
    final body = <String, dynamic>{
      'model': spec.model,
      'prompt': spec.prompt,
      'n': spec.n,
      if (spec.size != null && spec.size != 'auto') 'size': spec.size,
      if (spec.quality != null && spec.quality != 'auto')
        'quality': spec.quality,
      if (spec.background != null) 'background': spec.background,
      if (spec.outputFormat != null && spec.outputFormat != 'auto')
        'output_format': spec.outputFormat,
      if (spec.outputCompression != null)
        'output_compression': spec.outputCompression,
      // 响应仍按实际字段双通道解析（P6），url 只是省一次解码的偏好。
      if (spec.responseFormat != null) 'response_format': spec.responseFormat,
      // 扩展参数最后合并：用户显式配置覆盖同名标准字段。
      ...?spec.extra,
    };
    final isAsync = caps.taskMode == TaskMode.asyncTask;
    final path = isAsync ? '/images/generations/async' : '/images/generations';
    try {
      final resp = await dio.post(
        '$baseUrl$path',
        data: body,
        options: _opts(
          cred: cred,
          session: session,
          taskId: taskId,
          idempotencyKey: spec.idempotencyKey,
          // 超时矩阵（§7.5）：异步提交 60s；同步挂起 = 服务端上限 + 缓冲（DioHub 单点）。
          receiveTimeout: isAsync
              ? DioHub.asyncSubmitReceive
              : caps.syncHoldCeiling + DioHub.syncHoldGrace,
        ),
        cancelToken: cancel,
      );
      if (isAsync) {
        return SubmissionAccepted(
          _parseAccepted(resp.data, location: resp.headers.value('location')),
          retryAfter: _parseRetryAfterHeader(resp.headers.value('Retry-After')),
        );
      }
      return SubmissionSyncDone(_parsePayload(resp.data));
    } on DioException catch (e) {
      throw appExceptionFromDio(e);
    }
  }

  @override
  Future<Submission> editImage(
    String baseUrl,
    EditSpec spec,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  }) async {
    final form = FormData();
    form.fields
      ..add(MapEntry('model', spec.model))
      ..add(MapEntry('prompt', spec.prompt));
    if (spec.n != 1) form.fields.add(MapEntry('n', spec.n.toString()));
    if (spec.size != null && spec.size != 'auto') {
      form.fields.add(MapEntry('size', spec.size!));
    }
    if (spec.quality != null && spec.quality != 'auto') {
      form.fields.add(MapEntry('quality', spec.quality!));
    }
    if (spec.outputFormat != null && spec.outputFormat != 'auto') {
      form.fields.add(MapEntry('output_format', spec.outputFormat!));
    }
    // multipart 扩展参数：仅原始类型可入表单；复杂值跳过并记调试事件。
    spec.extra?.forEach((k, v) {
      if (v is String || v is num || v is bool) {
        form.fields.add(MapEntry(k, v.toString()));
      }
    });
    for (final path in spec.refImagePaths) {
      form.files.add(
        MapEntry(preset.editImageField, await MultipartFile.fromFile(path)),
      );
    }
    if (spec.maskPath != null) {
      form.files.add(
        MapEntry('mask', await MultipartFile.fromFile(spec.maskPath!)),
      );
    }

    final isAsync = caps.taskMode == TaskMode.asyncTask;
    final path = isAsync ? '/images/edits/async' : '/images/edits';
    try {
      final resp = await dio.post(
        '$baseUrl$path',
        data: form,
        options: _opts(
          cred: cred,
          session: session,
          taskId: taskId,
          idempotencyKey: spec.idempotencyKey,
          receiveTimeout: isAsync
              ? DioHub.asyncSubmitReceive
              : caps.syncHoldCeiling + DioHub.syncHoldGrace,
        ),
        cancelToken: cancel,
      );
      if (isAsync) {
        return SubmissionAccepted(
          _parseAccepted(resp.data, location: resp.headers.value('location')),
          retryAfter: _parseRetryAfterHeader(resp.headers.value('Retry-After')),
        );
      }
      return SubmissionSyncDone(_parsePayload(resp.data));
    } on DioException catch (e) {
      throw appExceptionFromDio(e);
    }
  }

  @override
  Future<PollOutcome> poll(
    String baseUrl,
    RemoteTaskRef ref,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  }) async {
    // 优先用 202 响应给出的 poll_url（Location），仅接受 http(s)；否则按标准端点拼接。
    final pollUrl = ref.pollUrl;
    final url =
        (pollUrl != null &&
            pollUrl.length > 8 &&
            (pollUrl.startsWith('http://') || pollUrl.startsWith('https://')))
        ? pollUrl
        : '$baseUrl/images/tasks/${ref.taskId}';
    try {
      final resp = await dio.get(
        url,
        options: _opts(
          cred: cred,
          session: session,
          taskId: taskId,
          receiveTimeout: DioHub.pollReceive,
          connectTimeout: DioHub.pollConnect,
        ),
        cancelToken: cancel,
      );
      final body = resp.data;
      if (body is! Map<String, dynamic>) {
        return PollFailed(
          EmptyResultException('任务查询响应格式异常', raw: body.toString()),
        );
      }
      final status = body['status']?.toString();
      switch (status) {
        case 'completed':
          return PollCompleted(_parsePayload(body['result']));
        case 'failed':
          // http_status 为 snake_case（实测 A6 failed 响应体），兼容 camelCase；
          // error 对象整体交给映射器（其内部取 code/message）。
          final hsRaw = body['http_status'] ?? body['httpStatus'];
          final hs = hsRaw is int
              ? hsRaw
              : int.tryParse(hsRaw?.toString() ?? '');
          final err = mapPlatformError(status: hs, body: body['error']);
          return PollFailed(err);
        case 'processing':
          return const PollRunning();
        default:
          return PollFailed(
            EmptyResultException('未知任务状态：$status', raw: body.toString()),
          );
      }
    } on DioException catch (e) {
      final mapped = appExceptionFromDio(e);
      if (mapped is TaskGoneException) {
        return PollGone(mapped.message);
      }
      return PollFailed(mapped);
    }
  }

  // ---- 解析 ----

  /// Retry-After 响应头（秒）→ Duration；非法/缺失返回 null。
  Duration? _parseRetryAfterHeader(String? header) {
    if (header == null) return null;
    final sec = int.tryParse(header.trim());
    return sec == null ? null : Duration(seconds: sec);
  }

  /// 202 响应 → RemoteTaskRef。
  /// poll_url 优先取响应体字段，缺失时回退 Location 响应头（§2.2：
  /// `Location`=poll_url）；仅接受 http(s)，异常数据回退标准端点拼接。
  RemoteTaskRef _parseAccepted(Object? data, {String? location}) {
    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final taskId = map['task_id']?.toString() ?? map['id']?.toString();
    if (taskId == null || taskId.isEmpty) {
      throw EmptyResultException('异步受理响应缺少 task_id', raw: data.toString());
    }
    final rawPollUrl = map['poll_url']?.toString() ?? location;
    final pollUrl =
        (rawPollUrl != null &&
            (rawPollUrl.startsWith('http://') ||
                rawPollUrl.startsWith('https://')))
        ? rawPollUrl
        : null;
    return RemoteTaskRef(
      taskId: taskId,
      expiresAtSec: map['expires_at'] as int?,
      pollUrl: pollUrl,
    );
  }

  /// Images 响应 data[]（同步）或 result（异步 completed）→ ImagePayload。
  ImagePayload _parsePayload(Object? data) {
    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final list = map['data'];
    if (list is! List || list.isEmpty) {
      throw EmptyResultException('响应 data 为空（无图）', raw: data.toString());
    }
    final items = <ImageItem>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      items.add(
        ImageItem(
          url: e['url']?.toString(),
          b64Json: e['b64_json']?.toString(),
          revisedPrompt: e['revised_prompt']?.toString(),
          mimeType: e['mime_type']?.toString(),
          width: e['width'] as int?,
          height: e['height'] as int?,
        ),
      );
    }
    if (items.every((i) => i.isEmpty)) {
      throw EmptyResultException(
        '响应图片字段为空（url/b64_json 均无）',
        raw: data.toString(),
      );
    }
    final usage = map['usage'];
    return ImagePayload(
      items: items,
      usageJson: usage is Map<String, dynamic> ? usage : null,
    );
  }
}
