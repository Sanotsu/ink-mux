import 'package:json_annotation/json_annotation.dart';

import '../../core/util/convert.dart';

part 'provider_config.g.dart';

/// 平台实例（provider_configs 表）。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.presetKey,
    required this.displayName,
    required this.baseUrl,
    required this.enabled,
    this.extraJson,
    this.modelsCacheJson,
    this.sort = 0,
    required this.createdAt,
  });

  final String id;

  /// 'shenwenai' | 'a6api' | 'openai_custom' | ...
  final String presetKey;
  final String displayName;
  final String baseUrl;

  @JsonKey(fromJson: boolFromInt, toJson: boolToInt)
  final bool enabled;

  final String? extraJson;
  final String? modelsCacheJson;
  final int sort;
  final int createdAt;

  factory ProviderConfig.fromJson(Map<String, dynamic> json) =>
      _$ProviderConfigFromJson(json);

  Map<String, dynamic> toJson() => _$ProviderConfigToJson(this);
}
