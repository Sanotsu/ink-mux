// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'prompt_template.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PromptTemplate _$PromptTemplateFromJson(Map<String, dynamic> json) =>
    PromptTemplate(
      id: json['id'] as String,
      title: json['title'] as String,
      content: json['content'] as String,
      useCount: (json['use_count'] as num?)?.toInt() ?? 0,
      lastUsedAt: (json['last_used_at'] as num?)?.toInt(),
      createdAt: (json['created_at'] as num).toInt(),
    );

Map<String, dynamic> _$PromptTemplateToJson(PromptTemplate instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'content': instance.content,
      'use_count': instance.useCount,
      'last_used_at': instance.lastUsedAt,
      'created_at': instance.createdAt,
    };
