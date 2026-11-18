import 'package:dio/dio.dart';

import '../../core/error/app_exception.dart';
import '../../domain/entities/model_info.dart';
import '../../domain/values/enums.dart';

/// 平台适配层（§6）：平台差异全部收在 Adapter 内，UI/引擎只面对统一契约。

/// 自定义尺寸校验器：返回 null 表示合法，返回人话文案表示拒绝（提交前本地拦截，§11.2）。
typedef SizeValidator = String? Function(String size);

/// 平台能力声明：UI 据此渲染参数表单、引擎据此决定任务模式。
class ProviderCapabilities {
  const ProviderCapabilities({
    required this.taskMode,
    this.hasAsyncEndpoint = false,
    this.supportsIdempotencyKey = false,
    this.maxN = 5,
    this.maxRefImages = 10,
    this.maxRefTotalMb = 64,
    this.supportsMask = false,
    this.qualities = const ['auto', 'medium', 'high'],
    this.sizePresets = const [
      'auto',
      '1024x1024',
      '1536x1024',
      '1024x1536',
      '2048x2048',
      '1152x2048',
      '2048x1152',
      '3840x2160',
      '2160x3840',
    ],
    this.outputFormats = const ['auto', 'png', 'jpeg', 'webp'],
    this.syncHoldCeiling = const Duration(minutes: 15),
    this.customSizeRule,
  });

  /// 任务模式：同步长连接挂起 / 异步提交+轮询。
  final TaskMode taskMode;
  final bool hasAsyncEndpoint;
  final bool supportsIdempotencyKey;
  final int maxN;
  final int maxRefImages;
  final int maxRefTotalMb;
  final bool supportsMask;
  final List<String> qualities;
  final List<String> sizePresets;
  Set<String> get outputFormatsSet => outputFormats.toSet();
  final List<String> outputFormats;

  /// 同步平台服务端等待上限（超时矩阵依据，§7.5）。
  final Duration syncHoldCeiling;

  /// 自定义尺寸校验（如神稳：16 倍数/≤3840/像素窗/≤3:1，§2.1）；null 表示无本地校验。
  final SizeValidator? customSizeRule;
}

/// 凭据：keyId 用于持久化关联，secret 仅在内存中传递。
class ApiCredential {
  const ApiCredential({required this.keyId, required this.secret});
  final String keyId;
  final String secret;
}

/// 文生图请求规格（引擎组装，adapter 转平台格式）。
class GenerateSpec {
  const GenerateSpec({
    required this.model,
    required this.prompt,
    this.n = 1,
    this.size,
    this.quality,
    this.background,
    this.outputFormat,
    this.outputCompression,
    this.responseFormat,
    this.extra,
    this.idempotencyKey,
  });

  final String model;
  final String prompt;
  final int n;
  final String? size;
  final String? quality;
  final String? background;
  final String? outputFormat;
  final int? outputCompression;

  /// 请求通道偏好（响应仍按实际字段双通道解析，P6）。
  final String? responseFormat;

  /// 用户自定义扩展参数：合并进请求体，覆盖同名标准字段（§2.1 未知参数透传）。
  final Map<String, dynamic>? extra;

  /// 平台支持幂等头时携带（shenwenai）。
  final String? idempotencyKey;
}

/// 编辑请求：生图参数 + 参考图（本地路径）。
class EditSpec extends GenerateSpec {
  const EditSpec({
    required super.model,
    required super.prompt,
    super.n = 1,
    super.size,
    super.quality,
    super.background,
    super.outputFormat,
    super.outputCompression,
    super.responseFormat,
    super.extra,
    super.idempotencyKey,
    this.refImagePaths = const [],
    this.maskPath,
  });

  final List<String> refImagePaths;
  final String? maskPath;
}

/// 单张结果图（双通道原文保留，由 ImageStore 统一落盘 §8.1）。
class ImageItem {
  const ImageItem({
    this.url,
    this.b64Json,
    this.revisedPrompt,
    this.mimeType,
    this.width,
    this.height,
  });
  final String? url;
  final String? b64Json;
  final String? revisedPrompt;
  final String? mimeType;
  final int? width;
  final int? height;

  bool get isEmpty =>
      (url == null || url!.isEmpty) && (b64Json == null || b64Json!.isEmpty);
}

class ImagePayload {
  const ImagePayload({required this.items, this.usageJson});
  final List<ImageItem> items;

  /// 平台返回的原始 usage（费用展示用，不保证存在）。
  final Map<String, dynamic>? usageJson;
}

/// 异步平台服务端任务句柄（持久化到 tasks.remote_task_id / remote_expires_at）。
class RemoteTaskRef {
  const RemoteTaskRef({required this.taskId, this.expiresAtSec, this.pollUrl});
  final String taskId;
  final int? expiresAtSec;
  final String? pollUrl;
}

/// 提交结果：双模式统一出口（sealed，Dart 3 原生）。
sealed class Submission {
  const Submission();

  /// 异步已受理（202）。
  RemoteTaskRef? get ref => null;

  /// 同步完成，直接携带结果。
  ImagePayload? get payload => null;
}

class SubmissionAccepted extends Submission {
  const SubmissionAccepted(this.ref, {this.retryAfter});
  @override
  final RemoteTaskRef ref;

  /// 202 响应 Retry-After 头：引擎据此设定轮询起始间隔（§7.3）；null 用默认 3s。
  final Duration? retryAfter;
}

class SubmissionSyncDone extends Submission {
  const SubmissionSyncDone(this.payload);
  @override
  final ImagePayload payload;
}

/// 轮询结果（仅 asyncTask 平台被调用）。
sealed class PollOutcome {
  const PollOutcome();
}

class PollRunning extends PollOutcome {
  const PollRunning();
}

class PollCompleted extends PollOutcome {
  const PollCompleted(this.payload);
  final ImagePayload payload;
}

class PollFailed extends PollOutcome {
  const PollFailed(this.error);
  final AppException error;
}

/// 任务不存在/过期/令牌不符 → 引擎转 expired。
class PollGone extends PollOutcome {
  const PollGone(this.reason);
  final String reason;
}

abstract interface class ImageProviderAdapter {
  /// 预设标识（provider_configs.preset_key）。
  String get presetKey;

  ProviderCapabilities get caps;

  /// 平台显示名。
  String get displayName;

  /// 模型目录（a6api 过滤 supported_endpoint_types）。
  Future<List<ModelInfo>> listModels(
    String baseUrl,
    ApiCredential cred, {
    String? session,
    CancelToken? cancel,
  });

  /// 文生图提交：syncHold 挂起至结果返回；asyncTask 秒回任务句柄。
  Future<Submission> text2Image(
    String baseUrl,
    GenerateSpec spec,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  });

  /// 参考图编辑（multipart）。
  Future<Submission> editImage(
    String baseUrl,
    EditSpec spec,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  });

  /// 轮询一次远端任务；syncHold 平台抛 UnsupportedError。
  Future<PollOutcome> poll(
    String baseUrl,
    RemoteTaskRef ref,
    ApiCredential cred, {
    String? session,
    String? taskId,
    CancelToken? cancel,
  });
}
