// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'provider_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ProviderConfig _$ProviderConfigFromJson(Map<String, dynamic> json) =>
    ProviderConfig(
      id: json['id'] as String,
      presetKey: json['preset_key'] as String,
      displayName: json['display_name'] as String,
      baseUrl: json['base_url'] as String,
      enabled: boolFromInt(json['enabled']),
      extraJson: json['extra_json'] as String?,
      modelsCacheJson: json['models_cache_json'] as String?,
      sort: (json['sort'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num).toInt(),
    );

Map<String, dynamic> _$ProviderConfigToJson(ProviderConfig instance) =>
    <String, dynamic>{
      'id': instance.id,
      'preset_key': instance.presetKey,
      'display_name': instance.displayName,
      'base_url': instance.baseUrl,
      'enabled': boolToInt(instance.enabled),
      'extra_json': instance.extraJson,
      'models_cache_json': instance.modelsCacheJson,
      'sort': instance.sort,
      'created_at': instance.createdAt,
    };
