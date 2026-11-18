// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'model_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ModelInfo _$ModelInfoFromJson(Map<String, dynamic> json) => ModelInfo(
  id: json['id'] as String,
  display: json['display'] as String?,
  raw: json['raw'] as Map<String, dynamic>,
);

Map<String, dynamic> _$ModelInfoToJson(ModelInfo instance) => <String, dynamic>{
  'id': instance.id,
  'display': instance.display,
  'raw': instance.raw,
};

ModelCache _$ModelCacheFromJson(Map<String, dynamic> json) => ModelCache(
  fetchedAt: (json['fetchedAt'] as num).toInt(),
  models: (json['models'] as List<dynamic>)
      .map((e) => ModelInfo.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$ModelCacheToJson(ModelCache instance) =>
    <String, dynamic>{
      'fetchedAt': instance.fetchedAt,
      'models': instance.models.map((e) => e.toJson()).toList(),
    };
