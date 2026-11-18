import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_mux/core/error/app_exception.dart';
import 'package:ink_mux/core/log/sanitizer.dart';
import 'package:ink_mux/data/storage/image_store.dart';

void main() {
  group('LogSanitizer：data URI 与错误文本（用户实测反馈）', () {
    test('data URI（url 字段返回整段）截前 64 字符', () {
      final uri = 'data:image/png;base64,${base64Encode(List.filled(3000, 7))}';
      final text = LogSanitizer.sanitizeBody({
        'data': [uri],
      });
      expect(text.contains('[base64 截断，原'), isTrue);
      expect(text.length, lessThan(500));
    });

    test('超长非 base64 文本（>8KB）兜底截断', () {
      // 含中文（不匹配 base64 正则）→ 走长文本兜底（'测试内容。'=5 字符 ×2250=11250）。
      final text = LogSanitizer.sanitizeBody({'note': '测试内容。' * 2250});
      expect(text.contains('长文本截断，原 11250 字符'), isTrue);
    });

    test('prompt 常见量级（几百字符）不被兜底截断', () {
      final prompt = '一只橘猫' * 100;
      final text = LogSanitizer.sanitizeBody({'prompt': prompt});
      expect(text.contains('截断'), isFalse);
    });

    test('sanitizeErrorText：内嵌 data URI 的异常文本逐行截断', () {
      final uri = 'data:image/png;base64,${base64Encode(List.filled(5000, 9))}';
      final err = 'Error: Invalid argument(s): No host specified in URI $uri';
      final text = LogSanitizer.sanitizeErrorText(err);
      expect(text.length, lessThan(600));
      expect(text.contains('错误文本截断'), isTrue);
    });
  });

  group('ImageStore.decodeDataUri', () {
    test('标准 data URI → bytes + mime', () {
      final raw = base64Encode([1, 2, 3, 250]);
      final r = ImageStore.decodeDataUri('data:image/png;base64,$raw');
      expect(r, isNotNull);
      expect(r!.$1, [1, 2, 3, 250]);
      expect(r.$2, 'image/png');
    });

    test('非法 base64 → null', () {
      expect(ImageStore.decodeDataUri('data:image/png;base64,!!!!'), isNull);
      expect(ImageStore.decodeDataUri('https://example.com/a.png'), isNull);
    });
  });

  group('LogSanitizer.sanitizeBody：字节数组摘要（防逐行渲染卡死）', () {
    test('大数组单行摘要：总数 + 前 16 项', () {
      final bytes = List<int>.generate(200, (i) => i & 0xFF);
      final text = LogSanitizer.sanitizeBody(bytes);
      expect(text.contains('字节数组 200 项'), isTrue);
      expect(text.contains('前 16 项'), isTrue);
      expect(text.contains('\n'), isFalse, reason: '必须单行');
      expect(text.length, lessThan(200));
    });

    test('小数组完整列出且单行', () {
      final text = LogSanitizer.sanitizeBody([50, 112, 97]);
      expect(text, '[字节数组 3 项] 50, 112, 97');
    });

    test('JSON Map 仍走递归脱敏（base64 截 64）', () {
      final body = {'b64_json': 'A' * 1000};
      final text = LogSanitizer.sanitizeBody(body);
      expect(text.contains('base64 截断，原 1000 字符'), isTrue);
    });

    test('String 携带 JSON 数组文本时按解析结果处理', () {
      final text = LogSanitizer.sanitizeBody(
        '[${List.filled(100, '7').join(',')}]',
      );
      expect(text.contains('字节数组 100 项'), isTrue);
    });
  });

  group('mapPlatformError：§11.1 错误码全表映射', () {
    AppException map({
      required int status,
      String? code,
      Map<String, dynamic>? body,
    }) {
      return mapPlatformError(
        status: status,
        body: {
          if (code != null) 'error': {'code': code, 'message': '平台原文'},
        },
        retryAfterHeader: body?['retryAfter'] as String?,
      );
    }

    test('鉴权与额度', () {
      expect(map(status: 401, code: 'invalid_api_key'), isA<AuthException>());
      expect(
        map(status: 402, code: 'insufficient_quota'),
        isA<QuotaException>(),
      );
      expect(
        map(status: 403, code: 'insufficient_user_quota'),
        isA<QuotaException>(),
      );
      expect(
        map(status: 403, code: 'token_quota_exhausted'),
        isA<QuotaException>(),
      );
      expect(
        map(status: 403, code: 'model_not_allowed'),
        isA<PermissionException>(),
      );
    });

    test('幂等冲突（架构性 bug 信号）', () {
      final e = map(status: 409, code: 'idempotency_key_in_use');
      expect(e, isA<IdempotencyConflictException>());
      expect(e.retryable, isFalse);
    });

    test('限流：神稳排队系（带 Retry-After）与 a6 image_task_limit（无头）', () {
      final queued = mapPlatformError(
        status: 429,
        body: const {
          'error': {'code': 'image_queue_full'},
        },
        retryAfterHeader: '30',
      );
      expect(queued, isA<RateLimitException>());
      expect(
        (queued as RateLimitException).retryAfter,
        const Duration(seconds: 30),
      );
      expect(queued.retryable, isTrue);

      final limit = map(status: 429, code: 'image_task_limit');
      expect(limit, isA<RateLimitException>());
      expect((limit as RateLimitException).retryAfter, isNull);
    });

    test(
      '异步任务系：notfound→TaskGone / disabled→TaskDisabled / timeout→Upstream',
      () {
        expect(
          map(status: 404, code: 'image_task_notfound'),
          isA<TaskGoneException>(),
        );
        expect(
          map(status: 404, code: 'image_task_disabled'),
          isA<TaskDisabledException>(),
        );
        expect(
          map(status: 504, code: 'image_task_timeout'),
          isA<UpstreamException>(),
        );
        expect(
          map(status: 502, code: 'image_task_store'),
          isA<UpstreamException>(),
        );
      },
    );

    test('参数系（不重试）', () {
      for (final code in [
        'model_not_found',
        'image_task_stream',
        'image_task_body',
        'image_model_required',
        'image_prompt_required',
        'image_input_required',
        'image_size_invalid',
      ]) {
        final e = map(status: 400, code: code);
        expect(e, isA<BadRequestException>(), reason: code);
        expect(e.retryable, isFalse, reason: code);
      }
    });

    test('内容政策拒绝（不重试）与上游系（可重试）', () {
      expect(
        map(status: 400, code: 'upstream_content_policy_reject'),
        isA<ContentPolicyException>(),
      );
      expect(map(status: 503, code: 'upstream_timeout').retryable, isTrue);
      expect(map(status: 500).retryable, isTrue); // 5xx 兜底
    });

    test('error 文案包含人话与平台原文', () {
      final e = map(status: 400, code: 'image_size_invalid');
      expect(e.message, contains('半角'));
      expect(e.raw, contains('平台原文'));
      expect(e.platformCode, 'image_size_invalid');
      expect(e.httpStatus, 400);
    });
  });

  group('appExceptionFromDio', () {
    test('无响应 → NetworkException 可重试', () {
      final e = appExceptionFromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(e, isA<NetworkException>());
      expect(e.retryable, isTrue);
      expect(e.message, '连接超时');
    });

    test('取消 → NetworkException（引擎按 runner.cancelled 优先判）', () {
      final e = appExceptionFromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.cancel,
        ),
      );
      expect(e, isA<NetworkException>());
    });

    test('带响应 → 走平台码映射', () {
      final resp = Response<dynamic>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 429,
        data: {
          'error': {'code': 'image_user_queue_full'},
        },
      );
      final e = appExceptionFromDio(
        DioException(requestOptions: resp.requestOptions, response: resp),
      );
      expect(e, isA<RateLimitException>());
    });
  });

  test('encodeError/decodeError 往返保留关键字段', () {
    final origin = const RateLimitException(
      '排队已满',
      platformCode: 'image_queue_full',
      httpStatus: 429,
      retryAfter: null,
    );
    final encoded = encodeError(origin);
    expect(encoded['retryable'], isTrue);
    final decoded = decodeError(encoded)!;
    expect(decoded.message, '排队已满');
    expect(decoded.platformCode, 'image_queue_full');
    expect(decoded.httpStatus, 429);
  });
}
