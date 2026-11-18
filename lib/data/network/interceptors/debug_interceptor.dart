import 'package:dio/dio.dart';

import '../../../core/log/sanitizer.dart';
import '../../../core/util/convert.dart';
import '../../../domain/entities/debug_log_entry.dart';
import '../../../domain/values/enums.dart';
import '../debug_log_sink.dart';

/// 全链路调试拦截器（§9.1）：请求/响应/异常/取消全捕获，
/// 通过 extra 携带会话与任务标识，与业务解耦。
class DebugInterceptor extends Interceptor {
  DebugInterceptor(this.sink);

  final DebugLogSink sink;

  static const String kExtraSession = 'inkmux.session';
  static const String kExtraTask = 'inkmux.task';
  static const String _kExtraT0 = 'inkmux.t0';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kExtraT0] = DateTime.now();
    final session = _session(options);
    if (session != null) {
      sink.add(
        DebugLogEntry(
          sessionId: session,
          taskId: _task(options),
          seq: sink.nextSeq(session),
          ts: nowMs(),
          kind: LogKind.http,
          direction: LogDirection.req,
          method: options.method,
          url: options.uri.toString(),
          headersJson: _encodeHeaders(
            LogSanitizer.sanitizeHeaders(options.headers),
          ),
          bodyText: LogSanitizer.sanitizeBody(options.data),
        ),
      );
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final session = _session(response.requestOptions);
    if (session != null) {
      sink.add(
        DebugLogEntry(
          sessionId: session,
          taskId: _task(response.requestOptions),
          seq: sink.nextSeq(session),
          ts: nowMs(),
          kind: LogKind.http,
          direction: LogDirection.resp,
          method: response.requestOptions.method,
          url: response.requestOptions.uri.toString(),
          statusCode: response.statusCode,
          durationMs: _elapsedMs(response.requestOptions),
          headersJson: _encodeHeaders(
            LogSanitizer.sanitizeRespHeaders(response.headers.map),
          ),
          bodyText: LogSanitizer.sanitizeBody(response.data),
        ),
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    final session = _session(options);
    if (session != null) {
      final resp = err.response;
      sink.add(
        DebugLogEntry(
          sessionId: session,
          taskId: _task(options),
          seq: sink.nextSeq(session),
          ts: nowMs(),
          kind: resp == null ? LogKind.error : LogKind.http,
          direction: LogDirection.resp,
          method: options.method,
          url: options.uri.toString(),
          statusCode: resp?.statusCode,
          durationMs: _elapsedMs(options),
          headersJson: resp == null
              ? null
              : _encodeHeaders(
                  LogSanitizer.sanitizeRespHeaders(resp.headers.map),
                ),
          bodyText: resp != null
              ? LogSanitizer.sanitizeBody(resp.data)
              : LogSanitizer.sanitizeErrorText(
                  'DioException[${err.type.name}] ${err.message ?? ''}'
                  '${err.error == null ? '' : '\n${err.error}'}'
                  '\ncancel: ${err.type == DioExceptionType.cancel}',
                ),
        ),
      );
    }
    handler.next(err);
  }

  String? _session(RequestOptions o) {
    final s = o.extra[kExtraSession];
    return s is String && s.isNotEmpty ? s : null;
  }

  String? _task(RequestOptions o) {
    final t = o.extra[kExtraTask];
    return t is String && t.isNotEmpty ? t : null;
  }

  int? _elapsedMs(RequestOptions o) {
    final t0 = o.extra[_kExtraT0];
    return t0 is DateTime ? DateTime.now().difference(t0).inMilliseconds : null;
  }

  String _encodeHeaders(Map<String, String> headers) {
    return headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }
}
