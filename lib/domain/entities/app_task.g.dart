// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_task.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppTask _$AppTaskFromJson(Map<String, dynamic> json) => AppTask(
  id: json['id'] as String,
  sessionId: json['session_id'] as String,
  providerId: json['provider_id'] as String,
  keyId: json['key_id'] as String,
  kind: $enumDecode(_$TaskKindEnumMap, json['kind']),
  prompt: json['prompt'] as String,
  paramsJson: json['params_json'] as String,
  refImagesJson: json['ref_images_json'] as String? ?? '[]',
  maskPath: json['mask_path'] as String?,
  status: $enumDecode(_$TaskStatusEnumMap, json['status']),
  idempotencyKey: json['idempotency_key'] as String,
  remoteTaskId: json['remote_task_id'] as String?,
  remoteExpiresAt: (json['remote_expires_at'] as num?)?.toInt(),
  pollStateJson: json['poll_state_json'] as String?,
  attempts: (json['attempts'] as num?)?.toInt() ?? 0,
  downloadAttempts: (json['download_attempts'] as num?)?.toInt() ?? 0,
  errorJson: json['error_json'] as String?,
  usageJson: json['usage_json'] as String?,
  resultHintJson: json['result_hint_json'] as String?,
  createdAt: (json['created_at'] as num).toInt(),
  updatedAt: (json['updated_at'] as num).toInt(),
  queuedAt: (json['queued_at'] as num?)?.toInt(),
  startedAt: (json['started_at'] as num?)?.toInt(),
  finishedAt: (json['finished_at'] as num?)?.toInt(),
);

Map<String, dynamic> _$AppTaskToJson(AppTask instance) => <String, dynamic>{
  'id': instance.id,
  'session_id': instance.sessionId,
  'provider_id': instance.providerId,
  'key_id': instance.keyId,
  'kind': _$TaskKindEnumMap[instance.kind]!,
  'prompt': instance.prompt,
  'params_json': instance.paramsJson,
  'ref_images_json': instance.refImagesJson,
  'mask_path': instance.maskPath,
  'status': _$TaskStatusEnumMap[instance.status]!,
  'idempotency_key': instance.idempotencyKey,
  'remote_task_id': instance.remoteTaskId,
  'remote_expires_at': instance.remoteExpiresAt,
  'poll_state_json': instance.pollStateJson,
  'attempts': instance.attempts,
  'download_attempts': instance.downloadAttempts,
  'error_json': instance.errorJson,
  'usage_json': instance.usageJson,
  'result_hint_json': instance.resultHintJson,
  'created_at': instance.createdAt,
  'updated_at': instance.updatedAt,
  'queued_at': instance.queuedAt,
  'started_at': instance.startedAt,
  'finished_at': instance.finishedAt,
};

const _$TaskKindEnumMap = {
  TaskKind.generate: 'generate',
  TaskKind.edit: 'edit',
};

const _$TaskStatusEnumMap = {
  TaskStatus.queued: 'queued',
  TaskStatus.submitting: 'submitting',
  TaskStatus.waiting: 'waiting',
  TaskStatus.persisting: 'persisting',
  TaskStatus.succeeded: 'succeeded',
  TaskStatus.failed: 'failed',
  TaskStatus.cancelled: 'cancelled',
  TaskStatus.expired: 'expired',
  TaskStatus.unknown: 'unknown',
};
