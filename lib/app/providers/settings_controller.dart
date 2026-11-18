import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/repos/settings_repo.dart';
import '../../domain/entities/api_key.dart';
import '../../domain/entities/provider_config.dart';
import '../../domain/values/enums.dart';
import 'app_services.dart';
import 'repos.dart';

/// 设置页视图状态。
class SettingsState {
  const SettingsState({
    this.loading = true,
    this.error,
    this.sections = const [],
    this.debugEnabled = DebugDefaults.enabled,
    this.debugPageEntry = false,
    this.ringLimit = DebugDefaults.ringLimit,
    this.concurrencyPerProvider = EngineDefaults.perProvider,
    this.concurrencyGlobal = EngineDefaults.global,
  });

  final bool loading;
  final String? error;
  final List<ProviderSection> sections;
  final bool debugEnabled;

  /// 桌面侧栏「调试」入口显隐（默认关；开启后侧栏才出现调试项）。
  final bool debugPageEntry;
  final int ringLimit;
  final int concurrencyPerProvider;
  final int concurrencyGlobal;

  SettingsState copyWith({
    bool? loading,
    String? error,
    List<ProviderSection>? sections,
    bool? debugEnabled,
    bool? debugPageEntry,
    int? ringLimit,
    int? concurrencyPerProvider,
    int? concurrencyGlobal,
  }) => SettingsState(
    loading: loading ?? this.loading,
    error: error,
    sections: sections ?? this.sections,
    debugEnabled: debugEnabled ?? this.debugEnabled,
    debugPageEntry: debugPageEntry ?? this.debugPageEntry,
    ringLimit: ringLimit ?? this.ringLimit,
    concurrencyPerProvider:
        concurrencyPerProvider ?? this.concurrencyPerProvider,
    concurrencyGlobal: concurrencyGlobal ?? this.concurrencyGlobal,
  );
}

/// 平台区块：配置 + Key 列表（含掩码）+ 测试状态。
class ProviderSection {
  const ProviderSection({
    required this.config,
    required this.keys,
    this.testingKeyId,
    this.test,
  });

  final ProviderConfig config;
  final List<KeyRow> keys;

  /// 正在测试的 Key（null = 无测试进行）。
  final String? testingKeyId;
  final ModelTestResult? test;

  ProviderSection copyWith({
    List<KeyRow>? keys,
    String? testingKeyId,
    bool clearTesting = false,
    ModelTestResult? test,
  }) => ProviderSection(
    config: config,
    keys: keys ?? this.keys,
    testingKeyId: clearTesting ? null : (testingKeyId ?? this.testingKeyId),
    test: test ?? this.test,
  );
}

class KeyRow {
  const KeyRow({required this.key, this.masked});

  final ApiKey key;
  final String? masked;
}

final settingsProvider = NotifierProvider<SettingsController, SettingsState>(
  SettingsController.new,
);

/// 模型目录/平台配置变更信号：连通测试刷新缓存、Base URL 修改、平台开关/
/// 增删后 bump，创作页据此联动重载（providers/keys/models 全量重读并保留选择）。
final modelsTickProvider = NotifierProvider<_ModelsTick, int>(_ModelsTick.new);

class _ModelsTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// 备份恢复完成信号（2026-11-16 修复）：恢复会批量改写本地 DB（平台/Key/
/// 任务/图片），但 StatefulShellRoute 下画廊/创作页等 State 常驻存活，
/// 不重启就不会重查库——恢复完成后 bump，常驻页面据此立即重载。
final dataImportTickProvider = NotifierProvider<_DataImportTick, int>(
  _DataImportTick.new,
);

class _DataImportTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// 图片库变更信号（2026-11-17 用户反馈）：画廊删除图片（记录/文件）后
/// bump——创作页「最近作品」条与结果面板据此立即重载。此前只靠落盘
/// doneTick / 恢复 dataImportTick 刷新，画廊删掉的图仍留在创作页条里，
/// 点击进预览只剩转圈（文件已删）。
final imagesChangedTickProvider = NotifierProvider<_ImagesChangedTick, int>(
  _ImagesChangedTick.new,
);

class _ImagesChangedTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

class SettingsController extends Notifier<SettingsState> {
  SettingsRepo get _repo => ref.read(settingsRepoProvider);

  @override
  SettingsState build() => const SettingsState();

  /// 全量加载。 [silent] = true 时不切换整页 loading（保留现有内容原地刷新），
  /// 用于保存后即时回读（与重启后 load() 同一条重读路径，确保 UI = DB 事实）。
  Future<void> load({bool silent = false}) async {
    if (!silent) state = state.copyWith(loading: true, error: null);
    try {
      await _repo.seedPresets();
      await _repo.ensurePresetOrder();
      final configs = await _repo.listProviders();
      final sections = <ProviderSection>[];
      for (final c in configs) {
        final keys = await _repo.listKeys(c.id);
        final rows = <KeyRow>[];
        for (final k in keys) {
          rows.add(KeyRow(key: k, masked: await _repo.maskSecret(k.id)));
        }
        // 保留短暂的连通测试 UI 态（进行中标记 + 结果）：load 是数据刷新，
        // 不应清掉刚显示的「✓ N 个模型可用」（历史回归：silent 重载后
        // 测试结果一闪而过）。全新加载（首帧）时 _sectionOf 为 null，无影响。
        final prev = _sectionOf(c.id);
        sections.add(
          ProviderSection(
            config: c,
            keys: rows,
            testingKeyId: prev?.testingKeyId,
            test: prev?.test,
          ),
        );
      }
      final prefs = ref.read(appServicesProvider).prefs;
      state = state.copyWith(
        loading: false,
        sections: sections,
        debugEnabled:
            prefs.getBool(PrefKeys.debugEnabled) ?? DebugDefaults.enabled,
        debugPageEntry: prefs.getBool(PrefKeys.debugPageEntry) ?? false,
        ringLimit:
            prefs.getInt(PrefKeys.debugRingLimit) ?? DebugDefaults.ringLimit,
        concurrencyPerProvider:
            prefs.getInt(PrefKeys.concurrencyPerProvider) ??
            EngineDefaults.perProvider,
        concurrencyGlobal:
            prefs.getInt(PrefKeys.concurrencyGlobal) ?? EngineDefaults.global,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '加载失败：$e');
    }
  }

  Future<void> toggleProvider(String providerId, bool enabled) async {
    await _repo.setProviderEnabled(providerId, enabled);
    await _refreshConfigs();
    ref.read(modelsTickProvider.notifier).bump();
  }

  Future<void> addKey({
    required String providerId,
    required String label,
    required String channelNote,
    required String secret,
  }) async {
    await _repo.addKey(
      providerId: providerId,
      label: label,
      channelNote: channelNote,
      secret: secret,
    );
    await load(silent: true);
    // 新 Key 可用 → 同步创作页（无 Key 引导卡/「无 Key」标注即时消失）。
    ref.read(modelsTickProvider.notifier).bump();
  }

  /// 删除 Key：无引用物理删除；被任务引用时转为停用（返回提示文案，
  /// null = 静默成功）。失败时写入 state.error 并返回 null。
  /// Key 可用性变化影响创作页可选列表 → bump modelsTick 同步（U-42：
  /// 停用后创作页仍持旧缓存可继续用它提交）。
  Future<String?> deleteKey(String providerId, String keyId) async {
    try {
      final r = await _repo.deleteKey(keyId);
      await load(silent: true);
      ref.read(modelsTickProvider.notifier).bump();
      return r.deleted
          ? null
          : '已被 ${r.refs} 个任务引用，已转为停用'
                '（不出现在创作页选择列表，可随时在 AK 菜单重新启用）';
    } catch (e) {
      state = state.copyWith(
        error: e.toString().replaceFirst('Bad state: ', ''),
      );
      return null;
    }
  }

  /// 重新启用已停用的 Key（可用性变化 → 同步创作页）。
  Future<void> enableKey(String providerId, String keyId) async {
    await _repo.enableKey(keyId);
    await load(silent: true);
    ref.read(modelsTickProvider.notifier).bump();
  }

  Future<void> setDefaultKey(String providerId, String keyId) async {
    try {
      await _repo.setDefaultKey(providerId, keyId);
    } catch (e) {
      state = state.copyWith(
        error: e.toString().replaceFirst('Bad state: ', ''),
      );
      return;
    }
    await load(silent: true);
  }

  /// 连通测试：优先测试指定 Key，否则该平台默认 Key。
  Future<void> testProvider(String providerId, {String? keyId}) async {
    final section = _sectionOf(providerId);
    if (section == null) return;
    final key = keyId == null
        ? (section.keys.where((r) => r.key.isDefault).firstOrNull ??
                  section.keys.firstOrNull)
              ?.key
        : section.keys.where((r) => r.key.id == keyId).firstOrNull?.key;
    if (key == null) {
      _updateSection(
        section.copyWith(
          test: const ModelTestResult(ok: false, message: '请先添加 API Key'),
        ),
      );
      return;
    }
    _updateSection(section.copyWith(testingKeyId: key.id, test: section.test));
    final result = await _repo.testConnectivity(
      provider: section.config,
      key: key,
    );
    final fresh = _sectionOf(providerId);
    if (fresh == null) return;
    _updateSection(fresh.copyWith(clearTesting: true, test: result));
    if (result.ok) {
      // 模型目录已更新：联动信号 + 全量重读（modelsCacheJson 等以 DB 为准）。
      ref.read(modelsTickProvider.notifier).bump();
      await load(silent: true);
    }
  }

  /// 修改平台 Base URL（设置页编辑入口）。保存成功后走 load(silent) 全量
  /// 重读 DB——与重启后同一条路径（历史 bug：局部 _reloadSection 曾复用
  /// 旧 config 对象，设置页/创作页都显示旧地址直到重启）；并 bump
  /// modelsTick 让创作页立即同步新地址。
  Future<void> updateBaseUrl(String providerId, String url) async {
    try {
      await _repo.updateBaseUrl(providerId, url);
    } catch (e) {
      state = state.copyWith(
        error: e.toString().replaceFirst('Bad state: ', ''),
      );
      return;
    }
    await load(silent: true);
    ref.read(modelsTickProvider.notifier).bump();
  }

  Future<void> setDebugEnabled(bool enabled) async {
    final s = ref.read(appServicesProvider);
    await s.prefs.setBool(PrefKeys.debugEnabled, enabled);
    await s.logSink.flush();
    s.logSink.enabled = enabled;
    state = state.copyWith(debugEnabled: enabled);
  }

  /// 桌面侧栏「调试」入口开关（默认关）。只影响侧栏显隐，调试日志记录
  /// 与任务行「查看调试日志」跳转不受影响。
  Future<void> setDebugPageEntry(bool enabled) async {
    final s = ref.read(appServicesProvider);
    await s.prefs.setBool(PrefKeys.debugPageEntry, enabled);
    state = state.copyWith(debugPageEntry: enabled);
  }

  Future<void> setRingLimit(int limit) async {
    final s = ref.read(appServicesProvider);
    await s.prefs.setInt(PrefKeys.debugRingLimit, limit);
    s.logSink.ringLimit = limit;
    state = state.copyWith(ringLimit: limit);
  }

  /// 并发闸门设置（§7.2）：引擎每次调度实时读取，改后即刻生效。
  Future<void> setConcurrencyPerProvider(int limit) async {
    final s = ref.read(appServicesProvider);
    await s.prefs.setInt(PrefKeys.concurrencyPerProvider, limit);
    state = state.copyWith(concurrencyPerProvider: limit);
  }

  Future<void> setConcurrencyGlobal(int limit) async {
    final s = ref.read(appServicesProvider);
    await s.prefs.setInt(PrefKeys.concurrencyGlobal, limit);
    state = state.copyWith(concurrencyGlobal: limit);
  }

  // ---- 自定义站 / 配置导入导出（M3） ----

  /// 添加自定义 OpenAI 兼容站（openai_custom 完整化）。
  Future<bool> addCustomProvider({
    required String displayName,
    required String baseUrl,
    required TaskMode taskMode,
    required String editImageField,
  }) async {
    try {
      await _repo.addCustomProvider(
        displayName: displayName,
        baseUrl: baseUrl,
        taskMode: taskMode,
        editImageField: editImageField,
      );
      await load();
      ref.read(modelsTickProvider.notifier).bump();
      return true;
    } catch (e) {
      state = state.copyWith(
        error: e.toString().replaceFirst('Bad state: ', ''),
      );
      return false;
    }
  }

  /// 删除自定义平台（被任务引用时拦截）。
  Future<bool> deleteProvider(String providerId) async {
    try {
      await _repo.deleteProvider(providerId);
      await load();
      ref.read(modelsTickProvider.notifier).bump();
      return true;
    } catch (e) {
      state = state.copyWith(
        error: e.toString().replaceFirst('Bad state: ', ''),
      );
      return false;
    }
  }

  /// 导出配置 JSON（不含任何 Key 数据）。
  Future<Map<String, dynamic>> exportConfig() => _repo.exportConfig();

  /// 备份恢复完成后调用：刷新设置页各区块（恢复可能带来新平台/Key）
  /// + 广播 dataImportTick（画廊/创作页等常驻页面立即重载，无需重启）。
  Future<void> notifyDataImported() async {
    await load();
    ref.read(dataImportTickProvider.notifier).bump();
  }

  /// 导入配置：返回结果文案（成功含统计，失败含原因）。
  Future<String> importConfig(Map<String, dynamic> data) async {
    try {
      final r = await _repo.importConfig(data);
      await load();
      return '导入完成：更新 ${r.providersUpdated} 个平台，'
          '新增 ${r.providersAdded} 个平台，合并 ${r.templatesMerged} 个模板';
    } catch (e) {
      return '导入失败：${e.toString().replaceFirst('Bad state: ', '')}';
    }
  }

  // ---- 内部 ----

  ProviderSection? _sectionOf(String providerId) {
    for (final s in state.sections) {
      if (s.config.id == providerId) return s;
    }
    return null;
  }

  void _updateSection(ProviderSection section) {
    state = state.copyWith(
      sections: [
        for (final s in state.sections)
          if (s.config.id == section.config.id) section else s,
      ],
    );
  }

  Future<void> _refreshConfigs() async {
    final configs = await _repo.listProviders();
    state = state.copyWith(
      sections: [
        for (final c in configs)
          ProviderSection(
            config: c,
            keys: _sectionOf(c.id)?.keys ?? const [],
            test: _sectionOf(c.id)?.test,
          ),
      ],
    );
  }
}
