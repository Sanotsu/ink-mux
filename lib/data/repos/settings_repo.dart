import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/util/convert.dart';
import '../../domain/entities/api_key.dart';
import '../../domain/entities/model_info.dart';
import '../../domain/entities/provider_config.dart';
import '../../domain/values/enums.dart';
import '../adapters/adapter.dart';
import '../adapters/openai_compatible/presets.dart';
import '../adapters/registry.dart';
import '../db/app_db.dart';
import '../db/daos/key_dao.dart';
import '../db/daos/provider_dao.dart';
import '../db/daos/task_dao.dart';
import '../db/daos/template_dao.dart';
import '../network/dio_hub.dart';
import '../secure/key_vault.dart';
import '../../domain/entities/prompt_template.dart';

/// 连通测试结果（listModels 探活）。
class ModelTestResult {
  const ModelTestResult({
    required this.ok,
    this.modelCount,
    this.sampleIds = const [],
    this.message,
    this.sessionId,
  });

  final bool ok;
  final int? modelCount;
  final List<String> sampleIds;
  final String? message;
  final String? sessionId;

  factory ModelTestResult.fail(String message, {String? sessionId}) =>
      ModelTestResult(ok: false, message: message, sessionId: sessionId);
}

/// 设置域仓储：平台/Key 管理 + 连通测试 + 模型缓存（§10.6）。
class SettingsRepo {
  SettingsRepo({
    required AppDb db,
    required this.vault,
    required this.dioHub,
    required this.registry,
  }) : providers = ProviderDao(db.database),
       keys = KeyDao(db.database),
       tasks = TaskDao(db.database),
       templates = TemplateDao(db.database);

  final ProviderDao providers;
  final KeyDao keys;
  final TaskDao tasks;
  final TemplateDao templates;
  final KeyVault vault;
  final DioHub dioHub;

  /// 适配器注册表（容器级单例，与引擎/创作页共享实例缓存）。
  final AdapterRegistry registry;

  static const Uuid _uuid = Uuid();

  /// 首次启动播种内置预设（shenwenai / a6api，均启用）。
  ///
  /// ⚠️ 暂时下线内置平台（2026-11-17）：只允许自定义添加 OpenAI 兼容站。
  /// 恢复内置平台时：删掉下方 early return 与 ignore 注释即可 （两段 insert 原样保留）。
  ///
  /// 我个人在使用的两个中转站测试（**非生产环境**），使用我的邀请码我有 3% 的返利。若有必要可支持一下，谢谢。
  /// 注意：仅仅是因为其生图价格较低方便测试，**对其中转站模型质量完全未评估**，请注意识别。
  /// - [A6API](https://a6api.ai/?auth=register&aff=QsTE)
  /// - [神稳AI](https://shenwenai.com/zh-cn/login?ref=Z4EWRT7Z)
  ///
  Future<void> seedPresets() async {
    // 暂时不播种内置平台；已建库中已有的内置记录在「平台管理」关闭开关即可。
    return;
    // ignore: dead_code
    if (await providers.count() > 0) return;
    final now = nowMs();
    // 2026-11-14 调整默认顺序：A6API 在前（sort 0），神稳AI 在后（sort 1）；
    // 创作页默认选中第一项（providers.firstOrNull）。
    await providers.insert(
      ProviderConfig(
        id: _uuid.v4(),
        presetKey: Presets.a6api,
        displayName: Presets.builtin[Presets.a6api]!.displayName,
        baseUrl: Presets.builtin[Presets.a6api]!.baseUrl,
        enabled: true,
        sort: 0,
        createdAt: now,
      ),
    );
    await providers.insert(
      ProviderConfig(
        id: _uuid.v4(),
        presetKey: Presets.shenwenai,
        displayName: Presets.builtin[Presets.shenwenai]!.displayName,
        baseUrl: Presets.builtin[Presets.shenwenai]!.baseUrl,
        enabled: true,
        sort: 1,
        createdAt: now,
      ),
    );
  }

  /// 内置预设排序校正（2026-11-14：A6API 调到神稳AI 之前）。
  /// 幂等：旧库（神稳 sort 在前）加载时自动对调；自定义站 sort 不受影响。
  Future<void> ensurePresetOrder() async {
    final list = await providers.list();
    final a6 = list.where((p) => p.presetKey == Presets.a6api).firstOrNull;
    final sw = list.where((p) => p.presetKey == Presets.shenwenai).firstOrNull;
    if (a6 == null || sw == null || a6.sort < sw.sort) return;
    await providers.setSort(a6.id, sw.sort);
    await providers.setSort(sw.id, a6.sort);
  }

  Future<List<ProviderConfig>> listProviders() => providers.list();

  Future<void> setProviderEnabled(String id, bool enabled) =>
      providers.setEnabled(id, enabled);

  /// 修改平台 Base URL（预设默认值仍可一键恢复，§10.6）。
  Future<void> updateBaseUrl(String providerId, String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('http')) {
      throw StateError('Base URL 必须以 http(s):// 开头');
    }
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    await providers.updateBaseUrl(providerId, normalized);
  }

  /// 平台预设默认 Base URL（"恢复默认"用）。
  String defaultBaseUrl(String presetKey) =>
      InkMuxPresets.byKey(presetKey).defaultBaseUrl;

  Future<List<ApiKey>> listKeys(String providerId) =>
      keys.listByProvider(providerId);

  /// 新增 Key：明文入 secure storage，DB 只存引用；
  /// 平台还没有可用（未停用）Key 时自动设为默认。
  Future<ApiKey> addKey({
    required String providerId,
    required String label,
    required String channelNote,
    required String secret,
  }) async {
    final id = _uuid.v4();
    await vault.write(id, secret);
    final existing = await keys.listByProvider(providerId);
    final hasUsable = existing.any((k) => !k.disabled);
    final key = ApiKey(
      id: id,
      providerId: providerId,
      label: label,
      channelNote: channelNote,
      secretRef: vault.refFor(id),
      isDefault: !hasUsable,
      createdAt: nowMs(),
    );
    await keys.insert(key);
    return key;
  }

  /// 删除 Key 结果：物理删除 / 转为停用（被任务引用，§5.2）。
  Future<({bool deleted, int refs})> deleteKey(String keyId) async {
    final refs = await keys.taskReferenceCount(keyId);
    if (refs > 0) {
      // 不物理删：置停用（密文保留，历史任务恢复轮询不受影响），
      // 可随时在 Key 菜单「重新启用」。
      await keys.setDisabled(keyId, disabled: true);
      return (deleted: false, refs: refs);
    }
    await vault.delete(keyId);
    await keys.delete(keyId);
    return (deleted: true, refs: 0);
  }

  /// 重新启用已停用的 Key。
  Future<void> enableKey(String keyId) async {
    await keys.setDisabled(keyId, disabled: false);
  }

  Future<void> setDefaultKey(String providerId, String keyId) async {
    final key = await keys.byId(keyId);
    if (key != null && key.disabled) {
      throw StateError('已停用的 Key 不能设为默认（请先重新启用）');
    }
    await keys.setDefault(providerId, keyId);
  }

  Future<String?> loadSecret(String keyId) async {
    final key = await keys.byId(keyId);
    if (key == null) return null;
    return vault.read(key.id);
  }

  /// 掩码显示：sk-or-v1-xxxx…abcd。
  Future<String?> maskSecret(String keyId) async {
    final secret = await loadSecret(keyId);
    if (secret == null || secret.isEmpty) return null;
    if (secret.length <= 8) return '••••';
    return '${secret.substring(0, 4)}••••${secret.substring(secret.length - 4)}';
  }

  /// 连通测试（adapter.listModels）：成功则缓存模型目录并更新 lastUsedAt。
  Future<ModelTestResult> testConnectivity({
    required ProviderConfig provider,
    required ApiKey key,
  }) async {
    final session = _uuid.v4();
    final secret = await vault.read(key.id);
    if (secret == null || secret.isEmpty) {
      return ModelTestResult.fail('密钥读取失败，请删除后重新添加', sessionId: session);
    }
    try {
      final adapter = registry.ofProvider(provider);
      final models = await adapter.listModels(
        provider.baseUrl,
        ApiCredential(keyId: key.id, secret: secret),
        session: session,
      );
      final cache = ModelCache(fetchedAt: nowMs(), models: models);
      await providers.updateModelsCache(
        provider.id,
        jsonEncode(cache.toJson()),
      );
      await keys.touchLastUsed(key.id, nowMs());
      return ModelTestResult(
        ok: true,
        modelCount: models.length,
        sampleIds: models.take(3).map((m) => m.id).toList(),
        sessionId: session,
      );
    } on AppException catch (e) {
      return ModelTestResult.fail(e.message, sessionId: session);
    }
  }

  // ===================== 自定义平台（M3：openai_custom 完整化） =====================

  /// 添加自定义 OpenAI 兼容站：差异参数存 extraJson，adapter 按此定制 caps。
  Future<ProviderConfig> addCustomProvider({
    required String displayName,
    required String baseUrl,
    required TaskMode taskMode,
    required String editImageField,
  }) async {
    final normalized = baseUrl.trim();
    if (!normalized.startsWith('http')) {
      throw StateError('Base URL 必须以 http(s):// 开头');
    }
    final maxSort = (await providers.list()).fold<int>(
      -1,
      (acc, p) => acc > p.sort ? acc : p.sort,
    );
    final config = ProviderConfig(
      id: _uuid.v4(),
      presetKey: Presets.openaiCustom,
      displayName: displayName.trim(),
      baseUrl: normalized.endsWith('/')
          ? normalized.substring(0, normalized.length - 1)
          : normalized,
      enabled: true,
      sort: maxSort + 1,
      createdAt: nowMs(),
      extraJson: jsonEncode({
        'task_mode': taskMode.name,
        'edit_image_field': editImageField,
      }),
    );
    await providers.insert(config);
    return config;
  }

  /// 删除平台：被任务引用时拒绝（与 Key 删除同一策略）。
  Future<void> deleteProvider(String providerId) async {
    final refs = await tasks.countByProvider(providerId);
    if (refs > 0) {
      throw StateError('该平台已被 $refs 个任务引用，不能删除（可关闭开关）');
    }
    await providers.delete(providerId);
  }

  // ===================== 配置导入导出（M3） =====================

  /// 导出配置：平台（不含 Key/密文引用）+ 提示词模板。
  /// 刻意不含：api_keys、tasks、images、debug_logs（§5.2 安全边界）。
  Future<Map<String, dynamic>> exportConfig() async {
    final configs = await providers.list();
    final tpls = await templates.list();
    return {
      'app': 'inkmux',
      'format_version': 1,
      'exported_at': nowMs(),
      'providers': [
        for (final p in configs)
          {
            'preset_key': p.presetKey,
            'display_name': p.displayName,
            'base_url': p.baseUrl,
            'enabled': p.enabled,
            'sort': p.sort,
            if (p.extraJson != null) 'extra_json': p.extraJson,
          },
      ],
      'templates': [for (final t in tpls) t.toJson()],
    };
  }

  /// 导入配置：内置 preset 按 preset_key 更新；自定义站按 base_url 匹配，
  /// 无匹配则新增；模板按 id 原样并入（replace，覆盖同名 id）。
  /// 返回 (providersUpdated, providersAdded, templatesMerged)。
  Future<({int providersUpdated, int providersAdded, int templatesMerged})>
  importConfig(Map<String, dynamic> data) async {
    if (data['app'] != 'inkmux') {
      throw StateError('不是 InkMux 配置文件（app 字段不符）');
    }
    final providerList = data['providers'];
    final templateList = data['templates'];
    var updated = 0;
    var added = 0;
    var merged = 0;
    if (providerList is List) {
      final existing = await providers.list();
      for (final raw in providerList) {
        if (raw is! Map<String, dynamic>) continue;
        final presetKey = raw['preset_key']?.toString() ?? '';
        final baseUrl = raw['base_url']?.toString() ?? '';
        final displayName = raw['display_name']?.toString() ?? '';
        if (displayName.isEmpty) continue;
        final isCustom = presetKey == Presets.openaiCustom;
        final match = existing.where(
          (e) => isCustom
              ? e.presetKey == presetKey && e.baseUrl == baseUrl
              : e.presetKey == presetKey,
        );
        final found = match.isEmpty ? null : match.first;
        if (found != null) {
          // 更新展示信息（不动 id/modelsCache，避免破坏任务引用与缓存）。
          if (baseUrl.isNotEmpty) {
            await providers.updateBaseUrl(found.id, baseUrl);
          }
          await providers.rename(found.id, displayName);
          await providers.setEnabled(found.id, raw['enabled'] == true);
          updated++;
        } else if (baseUrl.isNotEmpty) {
          final maxSort = existing.fold<int>(
            -1,
            (acc, p) => acc > p.sort ? acc : p.sort,
          );
          await providers.insert(
            ProviderConfig(
              id: _uuid.v4(),
              presetKey: presetKey,
              displayName: displayName,
              baseUrl: baseUrl,
              enabled: raw['enabled'] == true,
              sort: maxSort + 1,
              createdAt: nowMs(),
              extraJson: raw['extra_json']?.toString(),
            ),
          );
          added++;
        }
      }
    }
    if (templateList is List) {
      for (final raw in templateList) {
        if (raw is! Map<String, dynamic>) continue;
        try {
          final tpl = PromptTemplate.fromJson(raw);
          if (tpl.title.isEmpty || tpl.content.isEmpty) continue;
          await templates.insert(tpl); // replace：同 id 覆盖
          merged++;
        } catch (_) {
          // 脏数据跳过，不中断整批导入。
        }
      }
    }
    return (
      providersUpdated: updated,
      providersAdded: added,
      templatesMerged: merged,
    );
  }
}
