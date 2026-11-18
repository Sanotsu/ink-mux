/// 全局常量：断点、偏好键、预设标识、通道提示。
library;

/// 布局断点（§10.1）：<600 移动布局；600~900 窄桌面；>=900 宽桌面。
class AppBreakpoints {
  static const double compact = 600;
  static const double wide = 900;
}

/// shared_preferences 键。
class PrefKeys {
  static const String debugEnabled = 'debug.enabled';
  static const String debugPageEntry = 'debug.pageEntry';
  static const String debugRingLimit = 'debug.ringLimit';
  static const String themeMode = 'theme.mode';
  static const String concurrencyPerProvider = 'engine.concurrencyPerProvider';
  static const String concurrencyGlobal = 'engine.concurrencyGlobal';
  static const String notifyRationaleAsked = 'notify.rationaleAsked';
}

/// 内置平台预设标识（provider_configs.presetKey 取值）。
class Presets {
  static const String shenwenai = 'shenwenai';
  static const String a6api = 'a6api';
  static const String openaiCustom = 'openai_custom';

  static const Map<
    String,
    ({String displayName, String baseUrl, String channelHint})
  >
  builtin = {
    a6api: (
      displayName: 'A6API',
      baseUrl: 'https://media.a6api.net/v1',
      channelHint:
          '模型列表过滤 supported_endpoint_types 含 image-generation；默认走异步任务端点',
    ),
    shenwenai: (
      displayName: '神稳AI',
      baseUrl: 'https://api.shenwenai.com/v1',
      channelHint:
          '生图 Key 与文字 Key 分开，混用会 403；模型 ID 必须完整（如 gpt-image-2.5-flare）',
    ),
    openaiCustom: (
      displayName: '自定义 OpenAI 兼容站',
      baseUrl: '',
      channelHint: '任意 OpenAI Images 兼容中转站，填 Base URL（含 /v1）',
    ),
  };
}

/// 应用元信息。
class AppMeta {
  static const String name = 'InkMux';
  static const String version = '0.1.0';
  static const String stage = 'M3';
}

/// 任务引擎默认值（§7.2 并发闸门，设置页可调）。
class EngineDefaults {
  static const int perProvider = 2;
  static const int global = 4;

  /// 轮询看门狗：waiting 超过此时长无终态 → 自动失败释放并发名额（§7.3）。
  /// 10 分钟：一张图 10 分钟无结果即视为悬挂，无人愿意继续等待。
  static const Duration watchdog = Duration(minutes: 10);
}

/// 调试日志默认值。
class DebugDefaults {
  static const bool enabled = true;
  static const int ringLimit = 5000;
  static const int pageSize = 100;
}
