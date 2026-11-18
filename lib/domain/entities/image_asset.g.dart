// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_asset.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ImageAsset _$ImageAssetFromJson(Map<String, dynamic> json) => ImageAsset(
  id: json['id'] as String,
  taskId: json['task_id'] as String?,
  seq: (json['seq'] as num).toInt(),
  filePath: json['file_path'] as String,
  thumbPath: json['thumb_path'] as String?,
  width: (json['width'] as num?)?.toInt(),
  height: (json['height'] as num?)?.toInt(),
  bytes: (json['bytes'] as num?)?.toInt(),
  format: json['format'] as String?,
  channel: $enumDecode(_$ResultChannelEnumMap, json['channel']),
  promptSnapshot: json['prompt_snapshot'] as String?,
  paramsSnapshotJson: json['params_snapshot_json'] as String?,
  favorite: json['favorite'] == null ? false : boolFromInt(json['favorite']),
  tagsJson: json['tags_json'] as String?,
  createdAt: (json['created_at'] as num).toInt(),
);

Map<String, dynamic> _$ImageAssetToJson(ImageAsset instance) =>
    <String, dynamic>{
      'id': instance.id,
      'task_id': instance.taskId,
      'seq': instance.seq,
      'file_path': instance.filePath,
      'thumb_path': instance.thumbPath,
      'width': instance.width,
      'height': instance.height,
      'bytes': instance.bytes,
      'format': instance.format,
      'channel': _$ResultChannelEnumMap[instance.channel]!,
      'prompt_snapshot': instance.promptSnapshot,
      'params_snapshot_json': instance.paramsSnapshotJson,
      'favorite': boolToInt(instance.favorite),
      'tags_json': instance.tagsJson,
      'created_at': instance.createdAt,
    };

const _$ResultChannelEnumMap = {
  ResultChannel.url: 'url',
  ResultChannel.b64: 'b64',
};
