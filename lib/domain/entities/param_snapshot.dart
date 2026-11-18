import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'param_snapshot.g.dart';

/// 任务完整参数快照（tasks.paramsJson）：重试 / 复现 / "用此参数再来一张" 全靠它。
@JsonSerializable(explicitToJson: true)
class ParamSnapshot {
  const ParamSnapshot({
    required this.model,
    required this.prompt,
    this.n = 1,
    this.size,
    this.quality,
    this.background,
    this.outputFormat,
    this.outputCompression,
    this.stream,
    this.responseFormat,
    this.extraJson,
  });

  final String model;
  final String prompt;
  final int n;
  final String? size;
  final String? quality;
  final String? background;
  final String? outputFormat;
  final int? outputCompression;

  /// 流式偏好：§7.8 已整链路移除（2026-11-15），仅为旧任务快照解码兼容
  /// 保留字段；新任务恒 null 且 toJson 不写出（includeIfNull）。
  @JsonKey(includeIfNull: false)
  final bool? stream;
  final String? responseFormat;

  /// 用户自定义扩展参数（JSON 对象字符串）：透传平台，覆盖同名标准字段
  /// （shenwenai 明确支持未知参数透传 §2.1）。
  final String? extraJson;

  Map<String, dynamic>? get extras {
    final t = extraJson?.trim();
    if (t == null || t.isEmpty) return null;
    final v = jsonDecode(t);
    return v is Map<String, dynamic> ? v : null;
  }

  factory ParamSnapshot.fromJson(Map<String, dynamic> json) =>
      _$ParamSnapshotFromJson(json);

  Map<String, dynamic> toJson() => _$ParamSnapshotToJson(this);
}
