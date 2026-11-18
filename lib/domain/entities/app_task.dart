import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

import '../values/enums.dart';
import 'param_snapshot.dart';

part 'app_task.g.dart';

/// 任务主表实体（tasks 表，引擎唯一事实源 §7）。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class AppTask {
  const AppTask({
    required this.id,
    required this.sessionId,
    required this.providerId,
    required this.keyId,
    required this.kind,
    required this.prompt,
    required this.paramsJson,
    this.refImagesJson = '[]',
    this.maskPath,
    required this.status,
    required this.idempotencyKey,
    this.remoteTaskId,
    this.remoteExpiresAt,
    this.pollStateJson,
    this.attempts = 0,
    this.downloadAttempts = 0,
    this.errorJson,
    this.usageJson,
    this.resultHintJson,
    required this.createdAt,
    required this.updatedAt,
    this.queuedAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;

  /// 调试日志会话 ID，串联该次创作全部 HTTP 交互。
  final String sessionId;
  final String providerId;
  final String keyId;
  final TaskKind kind;
  final String prompt;

  /// ParamSnapshot 全量 JSON。
  final String paramsJson;
  final String refImagesJson;
  final String? maskPath;
  final TaskStatus status;
  final String idempotencyKey;

  /// 异步平台服务端任务 ID（a6api task_id）。
  final String? remoteTaskId;

  /// 任务查询保留期到期时间（Unix 秒）。
  final int? remoteExpiresAt;
  final String? pollStateJson;
  final int attempts;
  final int downloadAttempts;

  /// 结构化错误：{httpStatus, code, message, raw}。
  final String? errorJson;
  final String? usageJson;

  /// 最后已知结果 url（断点续下载 / 预签名过期重签）。
  final String? resultHintJson;

  final int createdAt;
  final int updatedAt;
  final int? queuedAt;
  final int? startedAt;
  final int? finishedAt;

  ParamSnapshot get params => ParamSnapshot.fromJson(
    paramsJson.isEmpty ? <String, dynamic>{} : _decode(paramsJson),
  );

  static Map<String, dynamic> _decode(String json) {
    // ignore: avoid_dynamic_calls
    return Map<String, dynamic>.from(const JsonCodec().decode(json) as Map);
  }

  factory AppTask.fromJson(Map<String, dynamic> json) =>
      _$AppTaskFromJson(json);

  Map<String, dynamic> toJson() => _$AppTaskToJson(this);
}
