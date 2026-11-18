import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

import '../../core/util/convert.dart';
import '../values/enums.dart';

part 'image_asset.g.dart';

/// 图片资产（images 表，画廊主表）。
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class ImageAsset {
  const ImageAsset({
    required this.id,
    this.taskId,
    required this.seq,
    required this.filePath,
    this.thumbPath,
    this.width,
    this.height,
    this.bytes,
    this.format,
    required this.channel,
    this.promptSnapshot,
    this.paramsSnapshotJson,
    this.favorite = false,
    this.tagsJson,
    required this.createdAt,
  });

  final String id;

  /// 所属任务（§5.2「无任务图」语义）：删除任务记录时置 NULL（ON DELETE
  /// SET NULL），图片保留在画廊；本实体仅在落盘时写入，读取可为 null。
  final String? taskId;

  /// 任务内第几张（n>1 时 1..n）。
  final int seq;
  final String filePath;
  final String? thumbPath;
  final int? width;
  final int? height;
  final int? bytes;
  final String? format;
  final ResultChannel channel;
  final String? promptSnapshot;
  final String? paramsSnapshotJson;

  @JsonKey(fromJson: boolFromInt, toJson: boolToInt)
  final bool favorite;
  final String? tagsJson;
  final int createdAt;

  List<String> get tags {
    if (tagsJson == null || tagsJson!.isEmpty) return const [];
    return List<String>.from(jsonDecode(tagsJson!) as List);
  }

  /// 局部更新（U-38）：收藏切换 / 缩略图补建后原地替换列表项，
  /// 免整页重查重建。
  ImageAsset copyWith({String? thumbPath, bool? favorite}) => ImageAsset(
    id: id,
    taskId: taskId,
    seq: seq,
    filePath: filePath,
    thumbPath: thumbPath ?? this.thumbPath,
    width: width,
    height: height,
    bytes: bytes,
    format: format,
    channel: channel,
    promptSnapshot: promptSnapshot,
    paramsSnapshotJson: paramsSnapshotJson,
    favorite: favorite ?? this.favorite,
    tagsJson: tagsJson,
    createdAt: createdAt,
  );

  factory ImageAsset.fromJson(Map<String, dynamic> json) =>
      _$ImageAssetFromJson(json);

  Map<String, dynamic> toJson() => _$ImageAssetToJson(this);
}
