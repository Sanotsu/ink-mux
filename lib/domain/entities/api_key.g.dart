// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_key.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ApiKey _$ApiKeyFromJson(Map<String, dynamic> json) => ApiKey(
  id: json['id'] as String,
  providerId: json['provider_id'] as String,
  label: json['label'] as String,
  channelNote: json['channel_note'] as String,
  secretRef: json['secret_ref'] as String,
  isDefault: boolFromInt(json['is_default']),
  disabled: json['disabled'] == null ? false : boolFromInt(json['disabled']),
  lastUsedAt: (json['last_used_at'] as num?)?.toInt(),
  createdAt: (json['created_at'] as num).toInt(),
);

Map<String, dynamic> _$ApiKeyToJson(ApiKey instance) => <String, dynamic>{
  'id': instance.id,
  'provider_id': instance.providerId,
  'label': instance.label,
  'channel_note': instance.channelNote,
  'secret_ref': instance.secretRef,
  'is_default': boolToInt(instance.isDefault),
  'disabled': boolToInt(instance.disabled),
  'last_used_at': instance.lastUsedAt,
  'created_at': instance.createdAt,
};
