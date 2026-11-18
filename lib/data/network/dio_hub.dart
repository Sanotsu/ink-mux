import 'package:dio/dio.dart';

import 'debug_log_sink.dart';
import 'interceptors/debug_interceptor.dart';

/// 唯一 HTTP 出口（§3.4-⑤）：超时矩阵按请求分级（§7.5）、
/// 拦截器链（调试日志入库+终端镜像）、会话/任务标识注入。
class DioHub {
  DioHub._(this.dio, this.sink);

  final Dio dio;
  final DebugLogSink sink;

  /// 超时矩阵（§7.5）。
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration modelsReceive = Duration(seconds: 30);
  static const Duration asyncSubmitReceive = Duration(seconds: 60);

  /// 同步挂起请求的接收缓冲：实际 receive = caps.syncHoldCeiling + 此缓冲，
  /// 保持"略大于服务端上限"的矩阵语义（§7.5：神稳 15min → 16min）。
  static const Duration syncHoldGrace = Duration(minutes: 1);
  static const Duration pollReceive = Duration(seconds: 20);
  static const Duration pollConnect = Duration(seconds: 10);
  static const Duration downloadReceive = Duration(seconds: 120);
  static const Duration sendTimeout = Duration(seconds: 120);

  factory DioHub.create(DebugLogSink sink) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: connectTimeout,
        receiveTimeout: modelsReceive,
        sendTimeout: sendTimeout,
        responseType: ResponseType.json,
      ),
    );
    dio.interceptors.add(DebugInterceptor(sink));
    return DioHub._(dio, sink);
  }

  /// 统一请求 Options 构造：鉴权头 + 幂等头 + 会话/任务标识 + 分级超时。
  /// 适配层与下载链路共用，避免散落的裸字符串 extra key（§3.4-⑤）。
  static Options options({
    String? bearer,
    String? session,
    String? taskId,
    String? idempotencyKey,
    Duration? receiveTimeout,
    Duration? connectTimeout,
    String? contentType,
    ResponseType? responseType,
    Map<String, String>? extraHeaders,
  }) => Options(
    headers: {
      if (bearer != null) 'Authorization': 'Bearer $bearer',
      'Idempotency-Key': ?idempotencyKey,
      ...?extraHeaders,
    },
    receiveTimeout: receiveTimeout,
    sendTimeout: sendTimeout,
    connectTimeout: connectTimeout,
    contentType: contentType,
    responseType: responseType,
    extra: {
      DebugInterceptor.kExtraSession: ?session,
      DebugInterceptor.kExtraTask: ?taskId,
    },
  );
}
