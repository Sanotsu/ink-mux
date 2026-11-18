import 'package:json_annotation/json_annotation.dart';

import '../values/enums.dart';

part 'debug_log_entry.g.dart';

/// 调试日志条目（debug_logs 表，§9）。bodyText 已脱敏截断，落库即安全。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class DebugLogEntry {
  const DebugLogEntry({
    this.id,
    required this.sessionId,
    this.taskId,
    required this.seq,
    required this.ts,
    required this.kind,
    required this.direction,
    this.method,
    this.url,
    this.statusCode,
    this.durationMs,
    this.headersJson,
    this.bodyText,
  });

  final int? id;
  final String sessionId;
  final String? taskId;

  /// 会话内序号。
  final int seq;
  final int ts;
  final LogKind kind;
  final LogDirection direction;
  final String? method;
  final String? url;
  final int? statusCode;
  final int? durationMs;

  /// 已脱敏的 JSON 字符串。
  final String? headersJson;

  /// 已截断的最终文本。
  final String? bodyText;

  factory DebugLogEntry.fromJson(Map<String, dynamic> json) =>
      _$DebugLogEntryFromJson(json);

  Map<String, dynamic> toJson() => _$DebugLogEntryToJson(this);

  bool get hasError =>
      kind == LogKind.error || (statusCode != null && statusCode! >= 400);
}
