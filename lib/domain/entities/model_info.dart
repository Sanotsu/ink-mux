import 'package:json_annotation/json_annotation.dart';

part 'model_info.g.dart';

/// 平台模型目录条目（缓存于 provider_configs.modelsCacheJson，§5.1）。
/// 保留原始字段 raw 以便未来扩展 caps。
@JsonSerializable(explicitToJson: true)
class ModelInfo {
  const ModelInfo({required this.id, this.display, required this.raw});

  final String id;
  final String? display;

  /// /v1/models 返回的原始条目。
  final Map<String, dynamic> raw;

  factory ModelInfo.fromJson(Map<String, dynamic> json) =>
      _$ModelInfoFromJson(json);

  Map<String, dynamic> toJson() => _$ModelInfoToJson(this);
}

/// 模型目录缓存（整存整取）。
@JsonSerializable(explicitToJson: true)
class ModelCache {
  const ModelCache({required this.fetchedAt, required this.models});

  final int fetchedAt;
  final List<ModelInfo> models;

  factory ModelCache.fromJson(Map<String, dynamic> json) =>
      _$ModelCacheFromJson(json);

  Map<String, dynamic> toJson() => _$ModelCacheToJson(this);

  String encode() => toJson().toString();
}
