import 'package:json_annotation/json_annotation.dart';

part 'prompt_template.g.dart';

/// 提示词模板（prompt_templates 表，M2）。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class PromptTemplate {
  const PromptTemplate({
    required this.id,
    required this.title,
    required this.content,
    this.useCount = 0,
    this.lastUsedAt,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String content;
  final int useCount;
  final int? lastUsedAt;
  final int createdAt;

  factory PromptTemplate.fromJson(Map<String, dynamic> json) =>
      _$PromptTemplateFromJson(json);

  Map<String, dynamic> toJson() => _$PromptTemplateToJson(this);
}
