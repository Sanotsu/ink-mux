// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'param_snapshot.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ParamSnapshot _$ParamSnapshotFromJson(Map<String, dynamic> json) =>
    ParamSnapshot(
      model: json['model'] as String,
      prompt: json['prompt'] as String,
      n: (json['n'] as num?)?.toInt() ?? 1,
      size: json['size'] as String?,
      quality: json['quality'] as String?,
      background: json['background'] as String?,
      outputFormat: json['outputFormat'] as String?,
      outputCompression: (json['outputCompression'] as num?)?.toInt(),
      stream: json['stream'] as bool?,
      responseFormat: json['responseFormat'] as String?,
      extraJson: json['extraJson'] as String?,
    );

Map<String, dynamic> _$ParamSnapshotToJson(ParamSnapshot instance) =>
    <String, dynamic>{
      'model': instance.model,
      'prompt': instance.prompt,
      'n': instance.n,
      'size': instance.size,
      'quality': instance.quality,
      'background': instance.background,
      'outputFormat': instance.outputFormat,
      'outputCompression': instance.outputCompression,
      'stream': ?instance.stream,
      'responseFormat': instance.responseFormat,
      'extraJson': instance.extraJson,
    };
