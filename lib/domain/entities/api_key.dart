import 'package:json_annotation/json_annotation.dart';

import '../../core/util/convert.dart';

part 'api_key.g.dart';

/// API Key 条目（api_keys 表）。密文本体在 secure storage，这里只存引用。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class ApiKey {
  const ApiKey({
    required this.id,
    required this.providerId,
    required this.label,
    required this.channelNote,
    required this.secretRef,
    required this.isDefault,
    this.disabled = false,
    this.lastUsedAt,
    required this.createdAt,
  });

  final String id;
  final String providerId;
  final String label;

  /// 通道备注，如 "OpenAI 生图 Key"。
  final String channelNote;

  /// secure storage 引用（不含明文）。
  final String secretRef;

  @JsonKey(fromJson: boolFromInt, toJson: boolToInt)
  final bool isDefault;

  /// 已停用（§5.2 删除策略）：被任务引用的 Key 不可物理删除，删除时转为
  /// 停用——不出现在创作页可选列表/默认 Key 候选，但密文保留，
  /// 历史任务的恢复轮询（同令牌）不受影响；可随时重新启用。
  @JsonKey(fromJson: boolFromInt, toJson: boolToInt)
  final bool disabled;

  final int? lastUsedAt;
  final int createdAt;

  ApiKey copyWith({bool? disabled}) => ApiKey(
    id: id,
    providerId: providerId,
    label: label,
    channelNote: channelNote,
    secretRef: secretRef,
    isDefault: isDefault,
    disabled: disabled ?? this.disabled,
    lastUsedAt: lastUsedAt,
    createdAt: createdAt,
  );

  factory ApiKey.fromJson(Map<String, dynamic> json) => _$ApiKeyFromJson(json);

  Map<String, dynamic> toJson() => _$ApiKeyToJson(this);
}
