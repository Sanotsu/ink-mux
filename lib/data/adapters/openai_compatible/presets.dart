import 'dart:math' as math;

import '../../../domain/entities/model_info.dart';
import '../../../domain/values/enums.dart';
import '../adapter.dart';

/// 两站内置预设（§6.2）+ openai_custom。
class OpenAiPreset {
  const OpenAiPreset({
    required this.presetKey,
    required this.displayName,
    required this.defaultBaseUrl,
    required this.caps,
    required this.editImageField,
    this.filterModels,
    this.fallbackModels = const [],
  });

  final String presetKey;
  final String displayName;
  final String defaultBaseUrl;
  final ProviderCapabilities caps;

  /// multipart 编辑参考图字段名：shenwenai 用 image[]，a6api 用 image。
  final String editImageField;

  /// 模型目录过滤（a6api：supported_endpoint_types ∋ image-generation）。
  final List<ModelInfo> Function(List<ModelInfo>)? filterModels;

  /// 内置模型清单兜底（§6.2：shenwenai 内置 5 个 gpt-image 模型）：
  /// /models 缓存缺失时创作页下拉直接可用，测通后仍以平台实返回为准。
  final List<String> fallbackModels;
}

class InkMuxPresets {
  InkMuxPresets._();

  static const a6api = OpenAiPreset(
    presetKey: 'a6api',
    displayName: 'A6API',
    defaultBaseUrl: 'https://media.a6api.net/v1',
    editImageField: 'image',
    caps: ProviderCapabilities(
      taskMode: TaskMode.asyncTask,
      hasAsyncEndpoint: true,
      maxN: 5,
      maxRefImages: 10,
      maxRefTotalMb: 64,
    ),
    filterModels: _filterImageGeneration,
  );

  static const shenwenai = OpenAiPreset(
    presetKey: 'shenwenai',
    displayName: '神稳AI',
    defaultBaseUrl: 'https://api.shenwenai.com/v1',
    editImageField: 'image[]',
    caps: ProviderCapabilities(
      taskMode: TaskMode.syncHold,
      supportsIdempotencyKey: true,
      maxN: 5,
      maxRefImages: 10,
      maxRefTotalMb: 64,
      supportsMask: true,
      syncHoldCeiling: Duration(minutes: 15),
      customSizeRule: shenwenaiSizeRule,
    ),
    // §2.1 实测清单：必须完整 ID（没有裸的 2.5/2.6）。
    fallbackModels: [
      // 'gpt-image-2',
      'gpt-image-2.5-flare',
      'gpt-image-2.5-sunburst',
      'gpt-image-2.6-flare',
      'gpt-image-2.6-sunburst',
    ],
  );

  static const openaiCustom = OpenAiPreset(
    presetKey: 'openai_custom',
    displayName: '自定义 OpenAI 兼容站',
    defaultBaseUrl: '',
    editImageField: 'image',
    caps: ProviderCapabilities(taskMode: TaskMode.syncHold),
  );

  /// a6api：仅保留支持 image-generation 的模型（实测/文档 §2.2）。
  static List<ModelInfo> _filterImageGeneration(List<ModelInfo> models) {
    return models.where((m) {
      final eps = m.raw['supported_endpoint_types'];
      return eps is List && eps.any((e) => e == 'image-generation');
    }).toList();
  }

  /// 神稳尺寸规则（§2.1）：`auto` 或 `WxH`——两边均为 16 的倍数、
  /// 最长边 ≤3840、总像素 655,360~8,294,400、长宽比 ≤3:1。
  static String? shenwenaiSizeRule(String size) {
    if (size == 'auto') return null;
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
    if (m == null) return '尺寸格式应为 WxH（半角 x，如 1024x1024）';
    final w = int.parse(m.group(1)!);
    final h = int.parse(m.group(2)!);
    if (w % 16 != 0 || h % 16 != 0) return '宽高必须都是 16 的倍数';
    if (math.max(w, h) > 3840) return '最长边不能超过 3840';
    final px = w * h;
    if (px < 655360) return '总像素不足（最小 655,360，如 1024x640）';
    if (px > 8294400) return '总像素超限（最大 8,294,400，如 3840x2160）';
    if (math.max(w, h) / math.min(w, h) > 3) return '长宽比不能超过 3:1';
    return null;
  }

  static OpenAiPreset byKey(String presetKey) => switch (presetKey) {
    'shenwenai' => shenwenai,
    'a6api' => a6api,
    _ => openaiCustom,
  };
}
