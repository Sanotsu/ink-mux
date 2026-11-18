// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'debug_log_entry.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DebugLogEntry _$DebugLogEntryFromJson(Map<String, dynamic> json) =>
    DebugLogEntry(
      id: (json['id'] as num?)?.toInt(),
      sessionId: json['session_id'] as String,
      taskId: json['task_id'] as String?,
      seq: (json['seq'] as num).toInt(),
      ts: (json['ts'] as num).toInt(),
      kind: $enumDecode(_$LogKindEnumMap, json['kind']),
      direction: $enumDecode(_$LogDirectionEnumMap, json['direction']),
      method: json['method'] as String?,
      url: json['url'] as String?,
      statusCode: (json['status_code'] as num?)?.toInt(),
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      headersJson: json['headers_json'] as String?,
      bodyText: json['body_text'] as String?,
    );

Map<String, dynamic> _$DebugLogEntryToJson(DebugLogEntry instance) =>
    <String, dynamic>{
      'id': instance.id,
      'session_id': instance.sessionId,
      'task_id': instance.taskId,
      'seq': instance.seq,
      'ts': instance.ts,
      'kind': _$LogKindEnumMap[instance.kind]!,
      'direction': _$LogDirectionEnumMap[instance.direction]!,
      'method': instance.method,
      'url': instance.url,
      'status_code': instance.statusCode,
      'duration_ms': instance.durationMs,
      'headers_json': instance.headersJson,
      'body_text': instance.bodyText,
    };

const _$LogKindEnumMap = {
  LogKind.http: 'http',
  LogKind.event: 'event',
  LogKind.error: 'error',
};

const _$LogDirectionEnumMap = {
  LogDirection.req: 'req',
  LogDirection.resp: 'resp',
  LogDirection.info: 'info',
};
