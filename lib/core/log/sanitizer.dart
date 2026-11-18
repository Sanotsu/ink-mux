import 'dart:convert';

import 'package:dio/dio.dart';

/// 调试日志脱敏/截断器（§9.2）：入库前完成，落库即安全。
///
/// 规则：
/// 1. 敏感头（Authorization / x-api-key / cookie）掩码为 "Bearer •••• abcd"（保留末 4 位）；
/// 2. JSON 递归走查：已知图片字段（b64_json/image/mask…）或任意 >=256 的疑似 base64
///    长串，仅保留前 64 字符并标注原始长度；
/// 3. multipart 不记文件二进制，仅记字段名 + 文件元信息；
/// 4. 单条 body 上限 256KB。
class LogSanitizer {
  LogSanitizer._();

  static const int b64Keep = 64;
  static const int bodyMaxChars = 256 * 1024;
  static const int consoleMaxChars = 2 * 1024;

  static final RegExp _b64Like = RegExp(r'^[A-Za-z0-9+/=]{256,}$');
  static final RegExp _dataUri = RegExp(
    r'^data:[^;,]{0,64};base64,',
    caseSensitive: false,
  );

  /// 任意单行超长文本兜底截断（>8KB，防未来平台返回奇怪长串）。
  static const int _longTextCap = 8192;

  static const Set<String> _mediaKeys = {
    'b64_json',
    'image',
    'images',
    'mask',
    'image_b64',
    'thumbnail',
  };

  /// 掩码请求/响应头。
  static Map<String, String> sanitizeHeaders(Map<String, dynamic> headers) {
    final out = <String, String>{};
    headers.forEach((k, v) {
      final key = k.toLowerCase();
      final value = v?.toString() ?? '';
      if (key == 'authorization' ||
          key == 'x-api-key' ||
          key == 'cookie' ||
          key == 'proxy-authorization') {
        out[k] = _maskSecret(value);
      } else {
        out[k] = value;
      }
    });
    return out;
  }

  /// 响应头（`Map<String, List<String>>`）扁平化后掩码。
  static Map<String, String> sanitizeRespHeaders(
    Map<String, List<String>> headers,
  ) => sanitizeHeaders(headers.map((k, v) => MapEntry(k, v.join('; '))));

  /// 清洗请求/响应体为可入库文本。FormData 只记元信息。
  ///
  /// 字节数组（ResponseType.bytes 下载图片等）特判：单行摘要（前 16 项 + 总数），
  /// 避免逐行数字渲染拖垮详情页（§9.2）。
  static String sanitizeBody(Object? data) {
    if (data == null) return '';
    Object? node = data;
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          node = jsonDecode(trimmed);
        } catch (_) {
          node = data;
        }
      }
    }
    final String text;
    if (node is FormData) {
      text = const JsonEncoder.withIndent('  ').convert(_formMeta(node));
    } else if (node is List && node.isNotEmpty && node.every((e) => e is num)) {
      final bytes = node.cast<num>();
      text = bytes.length <= 64
          ? '[字节数组 ${bytes.length} 项] ${bytes.join(', ')}'
          : '[字节数组 ${bytes.length} 项] 前 16 项: '
                '${bytes.take(16).join(', ')} …（其余省略）';
    } else if (node is Map || node is List) {
      text = const JsonEncoder.withIndent('  ').convert(_walk(node));
    } else {
      text = node.toString();
    }
    return _cap(text);
  }

  /// 控制台镜像用：在入库文本基础上再截到 2KB。
  static String forConsole(String body) {
    if (body.length <= consoleMaxChars) return body;
    return '${body.substring(0, consoleMaxChars)}…[控制台截断，原 ${body.length} 字符]';
  }

  /// 错误描述文本清洗：异常 toString 可能内嵌整个 data URI / 超长串，
  /// 逐行处理：含 base64/data URI 的行截前 64+标注；单行 >512 截前 128。
  static String sanitizeErrorText(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    for (final line in lines) {
      if (_dataUri.hasMatch(line) || line.length > 512) {
        final head = line.length > 128 ? line.substring(0, 128) : line;
        out.add('$head…[错误文本截断，原 ${line.length} 字符]');
      } else {
        out.add(line);
      }
    }
    return out.join('\n');
  }

  static String _maskSecret(String value) {
    if (value.length <= 8) return '••••';
    final tail = value.length >= 4 ? value.substring(value.length - 4) : '';
    final head = value.toLowerCase().startsWith('bearer') ? 'Bearer ' : '';
    return '$head•••• $tail';
  }

  static Object? _walk(Object? node, [String? key]) {
    if (node is Map) {
      return node.map((k, v) => MapEntry(k, _walk(v, k.toString())));
    }
    if (node is List) {
      return node.map((e) => _walk(e)).toList();
    }
    if (node is String) {
      final isMediaField =
          key != null && _mediaKeys.contains(key.toLowerCase());
      final isDataUri = _dataUri.hasMatch(node);
      final looksB64 = _b64Like.hasMatch(node);
      if ((isMediaField || isDataUri || looksB64) && node.length > b64Keep) {
        return '${node.substring(0, b64Keep)}…[base64 截断，原 ${node.length} 字符]';
      }
      // 兜底：任何超长文本（>8KB，不含 prompt 常见量级）截断防噪。
      if (node.length > _longTextCap) {
        return '${node.substring(0, b64Keep)}…[长文本截断，原 ${node.length} 字符]';
      }
      return node;
    }
    return node;
  }

  static Map<String, Object> _formMeta(FormData form) {
    final fields = <String, Object>{};
    for (final e in form.fields) {
      fields[e.key] = e.value;
    }
    final files = <Map<String, Object?>>[];
    for (final f in form.files) {
      files.add({
        'field': f.key,
        'filename': f.value.filename,
        'contentType': f.value.contentType.toString(),
        'length': f.value.length,
      });
    }
    return {'_formFields': fields, '_formFiles': files};
  }

  static String _cap(String text) {
    if (text.length <= bodyMaxChars) return text;
    return '${text.substring(0, bodyMaxChars)}…[截断，原 ${text.length} 字符]';
  }
}
