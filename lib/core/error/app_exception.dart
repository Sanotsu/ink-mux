import 'package:dio/dio.dart';

/// 统一错误体系（§11）：sealed 多态 + 平台错误码 → 人话映射。
/// [retryable] 仅表示"幂等保护下引擎可自动重试"的语义。
sealed class AppException implements Exception {
  const AppException(
    this.message, {
    this.platformCode,
    this.httpStatus,
    this.raw,
    this.retryable = false,
  });

  /// 人话文案（UI 直接展示）。
  final String message;

  /// 平台错误码（如 image_task_notfound）。
  final String? platformCode;
  final int? httpStatus;

  /// 平台原始响应（错误卡"平台原文"折叠区）。
  final String? raw;
  final bool retryable;

  @override
  String toString() => message;
}

/// 网络层异常（断网/超时/连接失败）：幂等保护下可自动重试。
class NetworkException extends AppException {
  const NetworkException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
    super.retryable = true,
    this.dioType,
  });
  final DioExceptionType? dioType;
}

/// Key 无效（401）。
class AuthException extends AppException {
  const AuthException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 余额/额度不足（402 / 403 insufficient_*）。
class QuotaException extends AppException {
  const QuotaException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 模型权限（403 model_not_allowed）。
class PermissionException extends AppException {
  const PermissionException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 限流/排队满（429）：retryAfter 来自响应头，可空（a6 image_task_limit 无头）。
class RateLimitException extends AppException {
  const RateLimitException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
    this.retryAfter,
  }) : super(retryable: true);
  final Duration? retryAfter;
}

/// 幂等 key 冲突（409）：架构上不应出现，出现即 bug。
class IdempotencyConflictException extends AppException {
  const IdempotencyConflictException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 内容政策拒绝：不自动重试。
class ContentPolicyException extends AppException {
  const ContentPolicyException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 异步任务不存在/过期/令牌不符（404 image_task_notfound）。
class TaskGoneException extends AppException {
  const TaskGoneException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 平台未开异步（404 image_task_disabled）。
class TaskDisabledException extends AppException {
  const TaskDisabledException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 请求参数问题（400 系）：不重试，修正后手动重试。
class BadRequestException extends AppException {
  const BadRequestException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 上游 5xx / 异步执行超时（504）/ 转存失败（502）：幂等保护下可退避重试。
class UpstreamException extends AppException {
  const UpstreamException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
    super.retryable = true,
  });
}

/// 响应无图（两通道皆空）等协议异常。
class EmptyResultException extends AppException {
  const EmptyResultException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
  });
}

/// 本地 IO（写盘/缩略图失败）。
class LocalIoException extends AppException {
  const LocalIoException(super.message, {super.raw});
}

/// 未归类平台错误。
class UnknownPlatformException extends AppException {
  const UnknownPlatformException(
    super.message, {
    super.platformCode,
    super.httpStatus,
    super.raw,
    super.retryable,
  });
}

/// dio 异常 → AppException（无响应=网络类；有响应走平台码映射）。
AppException appExceptionFromDio(DioException e) {
  final resp = e.response;
  if (resp == null) {
    final msg = switch (e.type) {
      DioExceptionType.connectionTimeout => '连接超时',
      DioExceptionType.sendTimeout => '发送超时',
      DioExceptionType.receiveTimeout => '响应超时',
      DioExceptionType.connectionError => '网络连接失败',
      DioExceptionType.cancel => '请求已取消',
      _ => e.message ?? '未知网络错误',
    };
    return NetworkException(msg, dioType: e.type);
  }
  return mapPlatformError(
    status: resp.statusCode,
    body: resp.data,
    retryAfterHeader: resp.headers.value('Retry-After'),
  );
}

/// 平台错误体 → AppException（§11.1 映射表全量）。
AppException mapPlatformError({
  int? status,
  Object? body,
  String? retryAfterHeader,
}) {
  String? code;
  String? serverMsg;
  String rawText;
  if (body is Map<String, dynamic>) {
    final err = body['error'];
    if (err is Map<String, dynamic>) {
      code = err['code']?.toString();
      serverMsg = err['message']?.toString();
    } else if (err is String) {
      serverMsg = err;
    }
    code ??= body['code']?.toString();
    serverMsg ??= body['message']?.toString();
    rawText = _shortRaw(body);
  } else {
    rawText = body?.toString() ?? '';
  }
  final s = status ?? 0;
  final retryAfter = _parseRetryAfter(retryAfterHeader);

  switch (code) {
    case 'invalid_api_key':
      return AuthException(
        'API Key 无效，请到设置页检查',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'insufficient_quota':
    case 'insufficient_user_quota':
    case 'token_quota_exhausted':
      return QuotaException(
        '平台额度不足，请充值后重试',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'model_not_allowed':
    case 'access_denied':
    case 'group_access_denied':
      return PermissionException(
        '当前 Key 无该模型权限，请更换 Key 或模型',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'idempotency_key_in_use':
      return IdempotencyConflictException(
        '幂等 Key 冲突（不应出现，请反馈开发者）',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_queue_full':
    case 'image_user_queue_full':
    case 'image_queue_timeout':
      return RateLimitException(
        '平台排队已满，稍后自动重试',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
        retryAfter: retryAfter,
      );
    case 'image_task_limit':
      return RateLimitException(
        '平台任务积压，稍后自动重试（该错误不带 Retry-After）',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'model_not_found':
      return BadRequestException(
        '模型 ID 无效：必须完整（如 gpt-image-2.5-flare），且该 Key 已开通生图',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_notfound':
      return TaskGoneException(
        '任务不存在、已过期（24h 查询期）或令牌不符——请确认用提交时的同一把 Key',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_disabled':
      return TaskDisabledException(
        '该平台未开放异步任务端点',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_stream':
      return BadRequestException(
        '异步提交不允许 stream（预设已禁用，出现即 bug）',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_body':
    case 'image_task_invalid':
    case 'invalid_image_request_body':
      return BadRequestException(
        '请求体格式被平台拒绝',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_model_required':
      return BadRequestException(
        '缺少模型参数',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_prompt_required':
      return BadRequestException(
        '提示词不能为空',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_input_required':
      return BadRequestException(
        '编辑请求缺少有效参考图',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_size_invalid':
      return BadRequestException(
        '尺寸不在模型支持范围（注意用半角 x，如 1024x1024）',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_timeout':
      return UpstreamException(
        '异步执行超时（平台上限 30 分钟）；重新生成 = 新任务新费用',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'image_task_store':
    case 'image_task_response':
      return UpstreamException(
        '平台转存/解析结果失败——请先核对平台扣费记录再重试，避免盲目重复生成',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'upstream_content_policy_reject':
      return ContentPolicyException(
        '内容被平台政策拒绝，请修改提示词或素材（不会自动重试）',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'upstream_rate_limited':
      return RateLimitException(
        '平台限流中，稍后自动重试',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
        retryAfter: retryAfter,
      );
    case 'upstream_timeout':
      return UpstreamException(
        '上游响应超时，稍后自动重试',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'upstream_image_capability_mismatch':
      return PermissionException(
        '平台商家不支持该图像能力，请换模型',
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
    case 'upstream_image_ambiguous_4xx':
      return UpstreamException(
        serverMsg == null || serverMsg.isEmpty
            ? '上游渠道拒绝了图片请求（归责不明，平台会尝试其他渠道）'
            : serverMsg,
        platformCode: code,
        httpStatus: s,
        raw: rawText,
      );
  }

  // 未知错误码但平台给了明确 message：原样透出（附错误码），不再吞进
  // 泛化文案（实测 A6 failed 轮询体带完整 message/reason/solution）。
  if (serverMsg != null && serverMsg.isNotEmpty) {
    return UnknownPlatformException(
      code == null || code.isEmpty ? serverMsg : '$serverMsg（$code）',
      platformCode: code,
      httpStatus: s,
      raw: rawText,
      retryable: true,
    );
  }

  // 无错误码：按 HTTP 状态兜底。
  if (s >= 500) {
    return UpstreamException(
      '平台服务异常（HTTP $s），稍后自动重试',
      httpStatus: s,
      raw: rawText,
    );
  }
  if (s == 401) {
    return AuthException('API Key 无效，请到设置页检查', httpStatus: s, raw: rawText);
  }
  if (s == 429) {
    return RateLimitException(
      '请求被限流（HTTP 429）',
      httpStatus: s,
      raw: rawText,
      retryAfter: retryAfter,
    );
  }
  if (s >= 400) {
    return BadRequestException(
      serverMsg == null || serverMsg.isEmpty
          ? '请求被拒绝（HTTP $s）'
          : '请求被拒绝：$serverMsg',
      httpStatus: s,
      raw: rawText,
    );
  }
  return UnknownPlatformException(
    '未知平台错误（HTTP $s）',
    httpStatus: s,
    raw: rawText,
    retryable: true,
  );
}

/// AppException → 持久化 errorJson。
Map<String, Object?> encodeError(AppException e) => {
  'type': e.runtimeType.toString(),
  'message': e.message,
  'code': e.platformCode,
  'httpStatus': e.httpStatus,
  // U-29：入库统一截断——raw 可能携带完整响应体（含 b64_json 数 MB），
  // 超过 Android CursorWindow 2MB 单行限制会让 tasks 整表读不出来
  // （备份导出/任务列表全崩）。
  'raw': e.raw == null ? null : _shortRaw(e.raw!),
  'retryable': e.retryable,
};

AppException? decodeError(Map<String, dynamic>? json) {
  if (json == null) return null;
  return UnknownPlatformException(
    json['message']?.toString() ?? '未知错误',
    platformCode: json['code']?.toString(),
    httpStatus: json['httpStatus'] as int?,
    raw: json['raw']?.toString(),
    retryable: json['retryable'] == true,
  );
}

Duration? _parseRetryAfter(String? header) {
  if (header == null) return null;
  final sec = int.tryParse(header.trim());
  return sec == null ? null : Duration(seconds: sec);
}

String _shortRaw(Object body) {
  final text = body.toString();
  return text.length <= 2048 ? text : '${text.substring(0, 2048)}…[截断]';
}
