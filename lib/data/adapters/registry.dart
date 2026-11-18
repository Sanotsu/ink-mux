import 'dart:convert';

import '../../domain/entities/provider_config.dart';
import '../../domain/values/enums.dart';
import '../network/dio_hub.dart';
import 'adapter.dart';
import 'openai_compatible/openai_adapter.dart';
import 'openai_compatible/presets.dart';

/// presetKey → Adapter 实例（§6.2）。未来非 OpenAI 平台在此注册新实现。
class AdapterRegistry {
  AdapterRegistry(this.dioHub);

  final DioHub dioHub;

  final Map<String, ImageProviderAdapter> _cache = {};

  /// 自定义站按 provider.id 单独缓存（extraJson 定制 caps）。
  final Map<String, ImageProviderAdapter> _customCache = {};

  ImageProviderAdapter of(String presetKey) => _cache.putIfAbsent(
    presetKey,
    () => OpenAiCompatibleAdapter(InkMuxPresets.byKey(presetKey), dioHub.dio),
  );

  /// 按平台实例取 adapter：openai_custom 读 extraJson 覆盖
  /// {task_mode, edit_image_field}（M3 自定义站完整化）；其余同 of()。
  ImageProviderAdapter ofProvider(ProviderConfig provider) {
    final customKey = InkMuxPresets.openaiCustom.presetKey;
    if (provider.presetKey != customKey) {
      return of(provider.presetKey);
    }
    return _customCache.putIfAbsent(provider.id, () {
      final base = InkMuxPresets.byKey(customKey);
      var taskMode = base.caps.taskMode;
      var editImageField = base.editImageField;
      final extra = provider.extraJson;
      if (extra != null && extra.isNotEmpty) {
        try {
          final map = Map<String, dynamic>.from(jsonDecode(extra) as Map);
          final modeName = map['task_mode']?.toString() ?? '';
          if (modeName == TaskMode.asyncTask.name ||
              modeName == TaskMode.syncHold.name) {
            taskMode = TaskMode.values.byName(modeName);
          }
          final field = map['edit_image_field']?.toString();
          if (field != null && field.isNotEmpty) editImageField = field;
        } catch (_) {
          // extraJson 脏数据 → 回退预设默认。
        }
      }
      final preset = OpenAiPreset(
        presetKey: base.presetKey,
        displayName: provider.displayName,
        defaultBaseUrl: base.defaultBaseUrl,
        caps: ProviderCapabilities(
          taskMode: taskMode,
          hasAsyncEndpoint: taskMode == TaskMode.asyncTask,
        ),
        editImageField: editImageField,
      );
      return OpenAiCompatibleAdapter(preset, dioHub.dio);
    });
  }

  /// 预设元信息（能力/显示名/默认 baseUrl），UI 与仓储共用。
  OpenAiPreset presetOf(String presetKey) => InkMuxPresets.byKey(presetKey);
}
