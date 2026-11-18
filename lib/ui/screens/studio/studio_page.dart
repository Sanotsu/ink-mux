import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../app/providers/app_services.dart';
import '../../../app/providers/guard.dart';
import '../../../app/providers/orchestrator.dart';
import '../../../app/providers/repos.dart';
import '../../../app/providers/settings_controller.dart'
    show modelsTickProvider, dataImportTickProvider, imagesChangedTickProvider;
import '../../../app/providers/studio_import.dart';
import '../../../core/theme/density.dart';
import '../../../data/adapters/adapter.dart';
import '../../../data/adapters/openai_compatible/presets.dart';
import '../../../domain/entities/api_key.dart';
import '../../../domain/entities/image_asset.dart';
import '../../../domain/entities/model_info.dart';
import '../../../domain/entities/param_snapshot.dart';
import '../../../domain/entities/prompt_template.dart';
import '../../../domain/entities/provider_config.dart';
import '../../../domain/values/enums.dart';
import '../../../ui/widgets/thumb_image.dart';
import '../preview/preview_page.dart';

/// 创作页（§10.2/10.3）：文生图 / 参考图编辑 + 参数面板（按 caps 渲染）+ 提交。
class StudioPage extends ConsumerStatefulWidget {
  const StudioPage({super.key});

  @override
  ConsumerState<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends ConsumerState<StudioPage> {
  List<ProviderConfig> _providers = [];
  Map<String, List<ApiKey>> _keysByProvider = {};
  String? _providerId;
  String? _keyId;
  String? _model;
  TaskKind _mode = TaskKind.generate;
  final _promptCtrl = TextEditingController();
  final _extraJsonCtrl = TextEditingController();
  final List<String> _refImages = [];
  // String _size = '1024x1024';
  String _size = 'auto';
  String _quality = 'auto';
  int _n = 1;
  String _outputFormat = 'auto';
  bool _transparentBg = false;
  String? _loadError;
  bool _loading = true;
  bool _refreshing = false;
  bool _dragHover = false;
  List<ImageAsset> _recent = const [];

  /// 是否存在可用平台（启用的平台中至少一个配了可用 Key，U-41）——
  /// 全部为空时创作页配置卡显示引导提示（去设置页配置）。
  bool _hasUsablePlatform = false;

  // 宽屏左面板宽度（可拖动调节，§10.2）：null = 默认窗口宽 60%（创作:画布 ≈ 3:2）。
  double? _panelWidth;
  bool _dividerHot = false;

  ProviderConfig? get _provider =>
      _providers.where((p) => p.id == _providerId).firstOrNull;

  /// 当前平台的 adapter caps（openai_custom 按实例定制）。
  ProviderCapabilities? get _caps {
    final p = _provider;
    if (p == null) return null;
    return ref.read(appServicesProvider).registry.ofProvider(p).caps;
  }

  ApiKey? get _selectedKey => _keyId == null
      ? null
      : (_keysByProvider[_providerId] ?? const [])
            .where((k) => k.id == _keyId)
            .firstOrNull;

  static Map<String, dynamic> _decodeJson(String text) =>
      Map<String, dynamic>.from(const JsonDecoder().convert(text) as Map);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      // 最近作品启动即加载（2026-11-15 用户反馈：原先只靠 doneTick 监听
      // 刷新，每次启动画布必空，直到本会话首次出图）。
      _loadRecent();
    });
    // 模型目录变更（设置页连通测试 / 手动刷新 / Base URL 修改）→ 联动重载（保留选择）。
    ref.listenManual(modelsTickProvider, (_, _) => _loadPreserve());
    // 落盘成功后刷新"最近结果"。
    ref.listenManual(orchestratorDoneTickProvider, (_, _) => _loadRecent());
    // 画廊删除图片（记录/文件）→ 最近作品/结果面板立即重载（2026-11-17：
    // 刚删的图仍显示在创作页条里，点击预览只剩转圈）。
    ref.listenManual(imagesChangedTickProvider, (_, _) => _loadRecent());
    // 备份恢复完成：平台/Key 配置与图片都可能被批量改写 → 全量重载 + 最近作品。
    ref.listenManual(dataImportTickProvider, (_, _) {
      _loadPreserve();
      _loadRecent();
    });
    // 「用此图继续编辑」导入（预览/画廊 → 创作页）。
    ref.listenManual(studioImportProvider, (_, import) {
      if (import == null) return;
      _consumeImport(import);
    });
  }

  /// 消费导入请求（§10.7-4）：
  /// · 历史再次生成 → 文生图回填提示词/参数（保持文生图）；编辑任务带回
  ///   原参考图（本地文件已缺失的自动剔除，全缺则降级为文生图回填）；
  /// · 预览/画廊继续编辑 → 编辑模式 + 装图 + 参数回填。
  void _consumeImport(StudioImport import) {
    // 参考图文件可能已被删除（画廊删除策略/清理缓存），入列前过滤。
    final images = import.refImagePaths
        .where((p) => p.isNotEmpty && File(p).existsSync())
        .toList();
    // 模式判定：显式 kind 优先；无 kind 时有图=编辑、无图=保持当前模式。
    var mode = import.kind ?? (images.isNotEmpty ? TaskKind.edit : null);
    var imagesDropped = false;
    if (mode == TaskKind.edit && images.isEmpty) {
      // 编辑任务但原参考图全部不可用 → 降级文生图回填。
      mode = TaskKind.generate;
      imagesDropped = true;
    }
    setState(() {
      if (mode != null) _mode = mode;
      for (final p in images) {
        if (!_refImages.contains(p) &&
            _refImages.length < (_caps?.maxRefImages ?? 10)) {
          _refImages.add(p);
        }
      }
      if (import.prompt != null && import.prompt!.trim().isNotEmpty) {
        _promptCtrl.text = import.prompt!.trim();
      }
      final params = import.params;
      if (params != null) {
        if (params.size != null) _size = params.size!;
        if (params.quality != null) _quality = params.quality!;
        _n = params.n.clamp(1, 5);
        if (params.outputFormat != null) _outputFormat = params.outputFormat!;
        if (params.background != null) _transparentBg = true;
        _extraJsonCtrl.text = params.extraJson ?? _extraJsonCtrl.text;
      }
    });
    ref.read(studioImportProvider.notifier).consume(import.token);
    _toast(switch ((_mode, images)) {
      (TaskKind.edit, final list) when list.isNotEmpty =>
        '已带入 ${list.length} 张参考图，可继续调整后提交编辑',
      (TaskKind.generate, _) when imagesDropped => '原参考图已不可用，已按文生图回填提示词与参数',
      (TaskKind.generate, _) => '已回填提示词与参数，可直接生成',
      _ => '已回填创作参数',
    });
  }

  /// Ctrl+V：剪贴板图片 → 参考图（桌面，M2）。
  /// 先确认剪贴板有图再切模式——纯文本剪贴板时 Windows 引擎对 image/*
  /// 请求抛 PlatformException（Unknown clipboard format），必须捕获按
  /// "无图"处理（实测 bug：复制提示词后 Ctrl+V 被误切到参考图编辑模式）。
  Future<void> _pasteImageFromClipboard() async {
    final caps = _caps;
    if (caps == null) return;
    if (_refImages.length >= caps.maxRefImages) {
      _toast('参考图已达上限 ${caps.maxRefImages} 张');
      return;
    }
    for (final type in ['image/png', 'image/jpeg', 'image/webp']) {
      String? bytesStr;
      try {
        final data = await Clipboard.getData(type);
        bytesStr = data?.text;
      } on PlatformException {
        continue; // 剪贴板无该格式（Windows：剪贴板只有文本时即此错）
      }
      if (bytesStr == null || bytesStr.isEmpty) continue;
      Uint8List bytes;
      try {
        bytes = base64Decode(bytesStr);
      } on FormatException {
        continue;
      }
      final dir = await getApplicationSupportDirectory();
      final pasteDir = Directory(
        '${dir.path}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}pastes',
      );
      if (!await pasteDir.exists()) await pasteDir.create(recursive: true);
      final ext = type.split('/').last == 'jpeg' ? 'jpg' : type.split('/').last;
      final file = File(
        '${pasteDir.path}${Platform.pathSeparator}paste_${DateTime.now().microsecondsSinceEpoch}.$ext',
      );
      await file.writeAsBytes(bytes, flush: true);
      // 图片真正入手后才切编辑模式（原实现入口即切，无图也切，误导用户）。
      setState(() {
        if (_mode != TaskKind.edit) _mode = TaskKind.edit;
        _refImages.add(file.path);
      });
      _toast('已从剪贴板添加参考图');
      return;
    }
    _toast('剪贴板中没有图片');
  }

  Future<void> _loadRecent() async {
    final imgs = await ref.read(appServicesProvider).images.page(limit: 24);
    if (mounted) setState(() => _recent = imgs);
  }

  /// 重载平台/Key/模型，但尽量保留用户当前选择。
  Future<void> _loadPreserve() async {
    final prevProvider = _providerId;
    final prevKey = _keyId;
    final prevModel = _model;
    await _load();
    if (!mounted) return;
    if (prevProvider != null && _providers.any((p) => p.id == prevProvider)) {
      _providerId = prevProvider;
    }
    final keys = _keysByProvider[_providerId] ?? const <ApiKey>[];
    if (prevKey != null && keys.any((k) => k.id == prevKey)) {
      _keyId = prevKey;
    } else {
      _keyId =
          keys.where((k) => k.isDefault).firstOrNull?.id ??
          keys.firstOrNull?.id;
    }
    final models = _safeModels();
    if (prevModel != null && models.contains(prevModel)) {
      _model = prevModel;
    } else {
      _model = models.firstOrNull;
    }
    setState(() {});
  }

  /// 手动刷新模型目录：走连通测试通道（GET /models → modelsCacheJson）。
  Future<void> _refreshModels() async {
    final provider = _provider;
    final key = _selectedKey;
    if (provider == null || key == null) {
      _toast('请先选择平台与 Key');
      return;
    }
    setState(() => _refreshing = true);
    try {
      final result = await ref
          .read(settingsRepoProvider)
          .testConnectivity(provider: provider, key: key);
      if (!mounted) return;
      _toast(
        result.ok ? '已刷新：${result.modelCount} 个模型可用' : '刷新失败：${result.message}',
      );
      ref.read(modelsTickProvider.notifier).bump();
      await _loadPreserve();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _extraJsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(settingsRepoProvider);
      await repo.seedPresets();
      await repo.ensurePresetOrder();
      final providers = (await repo.listProviders())
          .where((p) => p.enabled)
          .toList();
      final keysMap = <String, List<ApiKey>>{};
      for (final p in providers) {
        // 停用 Key（被任务引用转停用，§5.2）不参与提交选择；
        // 设置页仍可见可重新启用。
        keysMap[p.id] = (await repo.listKeys(p.id))
            .where((k) => !k.disabled)
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _keysByProvider = keysMap;
        _loading = false;
        _hasUsablePlatform = providers.any(
          (p) => (keysMap[p.id] ?? const <ApiKey>[]).isNotEmpty,
        );
        _providerId ??= providers.firstOrNull?.id;
        final keys = _keysByProvider[_providerId] ?? const [];
        _keyId ??=
            keys.where((k) => k.isDefault).firstOrNull?.id ??
            keys.firstOrNull?.id;
        _model ??= _safeModels().firstOrNull;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '加载失败：$e';
        });
      }
    }
  }

  // _providerId 变化后从缓存取模型（容错空 json）；
  // 缓存缺失（未测通/清库后）回退预设内置清单（§6.2，shenwenai 内置 4 个
  // gpt-image 模型；gpt-image-2 已下架不内置）。
  List<String> _safeModels() {
    final p = _provider;
    if (p != null) {
      final cache = p.modelsCacheJson;
      if (cache != null && cache.isNotEmpty) {
        try {
          return ModelCache.fromJson(_decodeJson(cache)).models
              .map((m) => m.id)
              .toList();
        } catch (_) {}
      }
      return InkMuxPresets.byKey(p.presetKey).fallbackModels;
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    // 加载 / 错误 / 空状态优先。
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('创作')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('创作')),
        body: Center(child: Text(_loadError!)),
      );
    }
    if (_providers.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('创作')),
        body: const Center(child: Text('请先到设置页启用平台')),
      );
    }

    // M3 多任务排队：在途>0 不再禁用，可直接继续入队（引擎并发闸门自动排队）。
    final orchestrator = ref.watch(orchestratorProvider);
    final activeCount = orchestrator.activeCount;

    // 窄屏生成按钮（固定底栏）。
    Widget mobileGenerateButton = Padding(
      padding: EdgeInsets.fromLTRB(d.screenH, 8, d.screenH, 8),
      // SizedBox 撑满宽度（minimumSize 只约束高度，杜绝 infinity 宽度约束）。
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            minimumSize: Size(0, d.controlH),
            shape: const StadiumBorder(),
            textStyle: TextStyle(
              fontSize: d.body + 1,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.bolt, size: 20),
          label: Text(
            activeCount > 0
                ? '加入队列（已有 $activeCount 个在途）'
                : (_mode == TaskKind.edit ? '提交编辑' : '生 成'),
          ),
        ),
      ),
    );

    Widget body;
    if (wide) {
      // ≥900 宽屏：Leonardo/即梦式工作台（§10.2 重构）——
      // 左创作面板（完整输入流：配置 → 提示词 → 模式 → 参考图 → 参数，
      // 底部固定渐变生成按钮）+ 可拖分隔条 + 中央画布区（最近作品网格
      // 主角化 + 在途横幅 + 空态引导）。
      // 面板宽度可拖（320~最大）；默认比例 = 创作面板 : 最近作品画布 ≈ 3:2
      // （2026-11-15 用户指定：创作输入区默认比最近作品略宽）——未拖过分隔条
      // 时按窗口宽 60% 取面板宽（随窗口缩放联动），拖动后记忆值优先；画布
      // 保底 minCanvas 不可被挤穿（窄窗口 60% 超 maxPanel 时自动被截）。
      const minPanel = 320.0;
      const minCanvas = 420.0;
      body = LayoutBuilder(
        builder: (context, cons) {
          final maxPanel = (cons.maxWidth - minCanvas).clamp(
            minPanel,
            double.infinity,
          );
          final pw = (_panelWidth ?? cons.maxWidth * 0.6).clamp(
            minPanel,
            maxPanel,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: pw, child: _wideLeftPanel(d)),
              _resizeDivider(pw, minPanel, maxPanel),
              Expanded(child: _wideCanvas(d)),
            ],
          );
        },
      );
    } else {
      // 窄屏单列（<600，§10.3）：设置卡 → 提示词主角卡 → 模式双卡 →（参考图）
      // → 参数 chips 卡 → 最近结果；生成按钮固定底栏。
      body = SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(d.screenH, 4, d.screenH, d.screenH),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _configCard(d),
            SizedBox(height: d.cardGap),
            _promptCard(d),
            SizedBox(height: d.cardGap),
            _modeCards(d),
            if (_mode == TaskKind.edit) ...[
              SizedBox(height: d.cardGap),
              _refStrip(d),
            ],
            SizedBox(height: d.cardGap),
            _mobileParamCard(d),
            if (_recent.isNotEmpty) ...[
              SizedBox(height: d.cardGap),
              _recentStrip(d),
            ],
            SizedBox(height: 8),
          ],
        ),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // 桌面 Ctrl/Cmd+V：剪贴板图片 → 参考图。
        // ⚠️ 焦点在文本输入框内必须放行（ignored）——页面级 Focus 先于 app 级 DefaultTextEditingShortcuts 看到冒泡事件，
        // 无条件 handled 会吞掉 TextField 的文本粘贴（用户反馈：提示词框 Ctrl+V 不粘贴反切模式）。
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyV &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          final focus = FocusManager.instance.primaryFocus;
          final inEditable =
              focus?.context?.findAncestorStateOfType<EditableTextState>() !=
              null;
          if (inEditable) return KeyEventResult.ignored;
          unawaited(_pasteImageFromClipboard());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        // 宽屏沉浸式（无 AppBar，左面板自带标题区，画布直达窗口顶，§10.2）；
        // 窄屏恢复 AppBar 标题（2026-11-14，移动端信息层级回归）。
        appBar: wide ? null : AppBar(title: const Text('创作')),
        body: body,
        // 窄屏：生成按钮固定底部（键盘弹出上移，§10.9）。
        bottomNavigationBar: wide
            ? null
            : SafeArea(top: false, child: mobileGenerateButton),
      ),
    );
  }

  // ---- 宽屏工作台（≥900，§10.2 重构：Leonardo/即梦式左面板 + 画布） ----

  /// 左创作面板：配置卡（平台/Key/模型）→ 提示词主角卡（内嵌渐变生成按钮，
  /// 即梦式短动线）→ 模式切换 →（参考图条）→ 参数区（chips + 高级折叠）。
  /// 无页面大标题（成熟工作台惯例：面板直接从功能内容开始）。
  Widget _wideLeftPanel(AppDensity d) {
    final caps = _caps;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        _configCard(d),
        const SizedBox(height: 12),
        _promptCard(d, minLines: 5, maxLines: 10, showGenerate: true),
        const SizedBox(height: 12),
        _modeCards(d),
        if (_mode == TaskKind.edit) ...[
          const SizedBox(height: 10),
          _refStrip(d),
        ],
        const SizedBox(height: 16),
        if (caps != null) _paramSection(d, caps),
      ],
    );
  }

  /// 通用配置卡（平台 / Key / 模型 行式，宽窄屏共用）。
  /// 没有任何可用平台（启用的平台全部未配 Key）→ 显示引导提示卡（U-41）。
  Widget _configCard(AppDensity d) {
    if (!_hasUsablePlatform) return _emptyPlatformHint(d);
    final keys = _keysByProvider[_providerId] ?? const <ApiKey>[];
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const SizedBox(height: 6),
          _configRow(
            d,
            icon: Icons.dns_outlined,
            label: '平台',
            child: _denseDropdown<ProviderConfig>(
              d: d,
              value: _provider,
              items: _providers,
              hint: '选择平台',
              // 未配 Key 的平台照常列出并标注（不隐藏——用户需看到它存在，
              // U-41），配置 Key 后即可用。
              label: (p) => (_keysByProvider[p.id] ?? const <ApiKey>[]).isEmpty
                  ? '${p.displayName}（无 Key）'
                  : p.displayName,
              onChanged: (p) => setState(() {
                _providerId = p?.id;
                final ks = _keysByProvider[p?.id] ?? const <ApiKey>[];
                _keyId =
                    ks.where((k) => k.isDefault).firstOrNull?.id ??
                    ks.firstOrNull?.id;
                _model = _safeModels().firstOrNull;
                final caps = _caps;
                if (caps != null && !caps.sizePresets.contains(_size)) {
                  _size = caps.sizePresets.first;
                }
              }),
            ),
          ),
          Divider(height: 1, indent: 40, color: cs.outlineVariant),
          _configRow(
            d,
            icon: Icons.vpn_key_outlined,
            label: 'AK',
            child: _denseDropdown<ApiKey>(
              d: d,
              value: _selectedKey,
              items: keys,
              hint: _providerId == null ? '先选平台' : '选择 AK',
              label: (k) => k.label,
              onChanged: (k) => setState(() => _keyId = k?.id),
            ),
          ),
          Divider(height: 1, indent: 40, color: cs.outlineVariant),
          _configRow(
            d,
            icon: Icons.model_training_outlined,
            label: '模型',
            child: _denseDropdown<String>(
              d: d,
              value: _safeModels().contains(_model) ? _model : null,
              items: _safeModels(),
              hint: _safeModels().isEmpty ? '先到设置页测试连通拉取' : '选择模型',
              label: (m) => m,
              onChanged: (m) => setState(() => _model = m),
            ),
            trailing: _refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _refreshModels,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.refresh,
                        size: 16,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 无可用平台的引导提示卡（U-41）：替代配置卡三行，指引去平台管理页
  /// 启用/添加平台并配置 API Key。
  Widget _emptyPlatformHint(AppDensity d) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                '还没有可用的平台',
                style: TextStyle(
                  fontSize: d.body + 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '到「平台管理」启用内置平台或添加 OpenAI 兼容站，'
            '并为平台配置配套的 AK 密钥，即可开始创作。',
            style: TextStyle(
              fontSize: d.sub + 1,
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/settings/providers'),
            icon: const Icon(Icons.settings_outlined, size: 16),
            label: const Text('去配置平台'),
          ),
        ],
      ),
    );
  }

  /// 配置行（icon + label + 控件 + 可选尾部按钮）。
  Widget _configRow(
    AppDensity d, {
    required IconData icon,
    required String label,
    required Widget child,
    Widget? trailing,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: TextStyle(fontSize: d.body, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(child: child),
          ?trailing,
        ],
      ),
    );
  }

  /// 无边框紧凑下拉（配置行内嵌用，宽窄屏共用）。
  Widget _denseDropdown<T>({
    required AppDensity d,
    required T? value,
    required List<T> items,
    required String hint,
    required String Function(T) label,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        items: [
          for (final it in items)
            DropdownMenuItem(
              value: it,
              child: Text(
                label(it),
                style: TextStyle(fontSize: d.body),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        hint: Text(hint, style: TextStyle(fontSize: d.body)),
        onChanged: onChanged,
        isDense: true,
        iconSize: 18,
        isExpanded: true,
        padding: EdgeInsets.zero,
      ),
    );
  }

  /// 提示词主角卡（宽窄屏共用）：填充圆角容器 + 工具行头部 + 内嵌字数；
  /// 桌面（showGenerate=true）卡底部内嵌渐变生成按钮（即梦式短动线，
  /// 提示词 → 生成一步完成，无需滚动到面板底）。
  Widget _promptCard(
    AppDensity d, {
    int minLines = 3,
    int maxLines = 6,
    bool showGenerate = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note, size: 16, color: cs.primary),
              const SizedBox(width: 4),
              Text(
                '提示词',
                style: TextStyle(fontSize: d.body, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              // 模板入口（tonal pill，内联工具行）。
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _showTemplateDialog,
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: cs.onSecondaryContainer,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '模板',
                        style: TextStyle(
                          fontSize: d.sub,
                          color: cs.onSecondaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          TextField(
            controller: _promptCtrl,
            minLines: minLines,
            maxLines: maxLines,
            textInputAction: TextInputAction.newline,
            style: TextStyle(fontSize: d.body, height: 1.4),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              hintText: '描述想要的画面，如：\n雨夜霓虹街道，少女撑伞回望，电影感光影…',
              hintStyle: TextStyle(
                fontSize: d.body,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
            maxLength: 4000,
          ),
          Row(
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _promptCtrl,
                builder: (context, value, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${value.text.length} 字',
                      style: TextStyle(
                        fontSize: d.sub,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    // 清空（M1 规格补齐）：仅有内容时出现，一键清空提示词。
                    if (value.text.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _promptCtrl.clear,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.backspace_outlined,
                                size: 12,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '清空',
                                style: TextStyle(
                                  fontSize: d.sub,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Spacer(),
              if (showGenerate) _generateChip(d),
            ],
          ),
        ],
      ),
    );
  }

  /// 内嵌生成按钮（提示词卡右下角）：primary→lerp(tertiary) 渐变胶囊。
  Widget _generateChip(AppDensity d) {
    final cs = Theme.of(context).colorScheme;
    final activeCount = ref.watch(orchestratorProvider).activeCount;
    final label = activeCount > 0
        ? '加入队列 · $activeCount 在途'
        : (_mode == TaskKind.edit ? '提交编辑' : '立即生成');
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.6)!],
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _submit,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 17, color: cs.onPrimary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: d.body,
                    fontWeight: FontWeight.w700,
                    color: cs.onPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 模式双卡（宽窄屏共用）：文生图 / 参考图编辑，选中态 tonal + 描边。
  Widget _modeCards(AppDensity d) {
    final caps = _caps;
    final cs = Theme.of(context).colorScheme;
    Widget card(TaskKind kind, IconData icon, String title, String subtitle) {
      final selected = _mode == kind;
      return Expanded(
        child: Material(
          color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: selected
                ? BorderSide(color: cs.primary, width: 1.4)
                : BorderSide(color: cs.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _mode = kind),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: d.body,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? cs.onSecondaryContainer
                              : cs.onSurface,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: d.sub - 1,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            card(TaskKind.generate, Icons.auto_awesome, '文生图', '从文字开始'),
            const SizedBox(width: 8),
            card(TaskKind.edit, Icons.image_search, '参考图编辑', '上传图片重绘'),
          ],
        ),
        if (_mode == TaskKind.edit && caps != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              '≤${caps.maxRefImages} 张 · 单张 ≤10MB · 总量 ≤${caps.maxRefTotalMb}MB',
              style: TextStyle(fontSize: d.sub, color: cs.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  // ---- 提示词模板（M2） ----

  Future<void> _showTemplateDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _TemplateDialog(
        onApply: (template) {
          _promptCtrl.text = template.content;
          ref.read(appServicesProvider).templates.bumpUse(template.id);
          Navigator.pop(ctx);
          _toast('已套用模板「${template.title}」');
        },
      ),
    );
  }

  /// 宽屏参数区（面板流式，无卡片框）：尺寸 chips → 质量 chips → 数量/格式 →
  /// 透明背景 → 高级折叠（扩展 JSON / 流式 / 同步说明）。
  Widget _paramSection(AppDensity d, ProviderCapabilities caps) {
    final cs = Theme.of(context).colorScheme;
    final isSync = caps.taskMode == TaskMode.syncHold;

    Widget sectionLabel(String text) => Text(
      text,
      style: TextStyle(
        fontSize: d.body,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
    );

    Widget fieldLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: d.sub, color: cs.onSurfaceVariant),
      ),
    );

    Widget pill(
      String text, {
      required bool selected,
      required VoidCallback onTap,
      IconData? icon,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: d.chipH,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? cs.primaryContainer
                : cs.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(color: cs.primary, width: 1.2)
                : Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(
                  icon,
                  size: 14,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              if (icon != null) const SizedBox(width: 4),
              Text(
                text,
                style: TextStyle(
                  fontSize: d.sub + 1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionLabel('参数'),
        const SizedBox(height: 12),
        fieldLabel('尺寸'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in caps.sizePresets)
              pill(
                s,
                selected: _size == s,
                onTap: () => setState(() => _size = s),
              ),
            if (!caps.sizePresets.contains(_size))
              pill(_size, selected: true, onTap: () {}),
            pill(
              '自定义',
              selected: false,
              icon: Icons.tune,
              onTap: () => _showCustomSizeDialog(caps),
            ),
          ],
        ),
        const SizedBox(height: 14),
        fieldLabel('质量'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in caps.qualities)
              pill(
                q,
                selected: _quality == q,
                onTap: () => setState(() => _quality = q),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // 数量 / 格式 / 背景一行（2026-11-16 用户指定，桌面端紧凑排布）；
        // Wrap 兜底：面板拖到极窄时段落换行而非溢出。
        Wrap(
          spacing: 16,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '数量',
                    style: TextStyle(
                      fontSize: d.sub,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Container(
                  height: d.chipH,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.remove, size: 16),
                        onPressed: _n > 1 ? () => setState(() => _n--) : null,
                      ),
                      SizedBox(
                        width: 22,
                        child: Text(
                          '$_n',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: d.sub + 1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.add, size: 16),
                        onPressed: _n < caps.maxN
                            ? () => setState(() => _n++)
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '格式',
                    style: TextStyle(
                      fontSize: d.sub,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Container(
                  width: 100,
                  height: d.chipH,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _outputFormat,
                      items: [
                        for (final f in caps.outputFormats)
                          DropdownMenuItem(
                            value: f,
                            child: Text(
                              f,
                              style: TextStyle(fontSize: d.sub + 1),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _outputFormat = v);
                      },
                      iconSize: 16,
                      isDense: true,
                      isExpanded: true,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '背景',
                    style: TextStyle(
                      fontSize: d.sub,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  height: 32,
                  child: Switch(
                    value: _transparentBg,
                    onChanged: (v) => setState(() => _transparentBg = v),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _transparentBg ? '透明' : '不透明',
                  style: TextStyle(fontSize: d.sub + 1, color: cs.onSurface),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            maintainState: true,
            tilePadding: EdgeInsets.zero,
            dense: true,
            childrenPadding: EdgeInsets.zero,
            title: Text('高级参数', style: TextStyle(fontSize: d.body)),
            children: [
              TextField(
                controller: _extraJsonCtrl,
                maxLines: 2,
                minLines: 2,
                style: TextStyle(fontSize: d.sub, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: '扩展参数 JSON（可选）',
                  hintText: '{"seed": 123, "moderation": "low"}',
                  helperText: '透传平台；同名键覆盖上方标准参数',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  labelStyle: TextStyle(fontSize: d.sub),
                ),
              ),
              if (isSync)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'ⓘ 同步平台：服务端最长等待 15 分钟；quality 可能被 Key 档位覆盖',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 面板/画布可拖分隔条：命中区 8 宽，视觉 1px 线（hover/拖动时 3px 主色）；
  /// 拖动更新 _panelWidth（clamp 由调用方保证）。[currentWidth] 为当前实际
  /// 渲染宽度（未拖动过时是 60% 比例值而非固定兜底，防首拖跳变）。
  Widget _resizeDivider(double currentWidth, double minPanel, double maxPanel) {
    final cs = Theme.of(context).colorScheme;
    final hot = _dividerHot;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _dividerHot = true),
      onExit: (_) => setState(() => _dividerHot = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dividerHot = true),
        onHorizontalDragUpdate: (details) {
          setState(() {
            _panelWidth = (currentWidth + details.delta.dx).clamp(
              minPanel,
              maxPanel,
            );
          });
        },
        onHorizontalDragEnd: (_) => setState(() => _dividerHot = false),
        onHorizontalDragCancel: () => setState(() => _dividerHot = false),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: hot ? 3 : 1,
              color: hot ? cs.primary : cs.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 中央画布区：顶栏（最近作品 + 打开画廊）→ 在途横幅 → 自适应网格 / 空态。
  Widget _wideCanvas(AppDensity d) {
    final cs = Theme.of(context).colorScheme;
    final activeCount = ref.watch(orchestratorProvider).activeCount;
    return Container(
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
            child: Row(
              children: [
                Text(
                  '最近作品',
                  style: TextStyle(
                    fontSize: d.body + 3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                if (_recent.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_recent.length}',
                      style: TextStyle(
                        fontSize: d.sub,
                        fontWeight: FontWeight.w700,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => context.go('/gallery'),
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: const Text('打开画廊'),
                ),
              ],
            ),
          ),
          if (activeCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$activeCount 个任务进行中 · 完成后自动出现在下方',
                        style: TextStyle(
                          fontSize: d.sub + 1,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go('/tasks'),
                      child: const Text('查看任务'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _recent.isEmpty
                ? _canvasEmptyState(d)
                : LayoutBuilder(
                    builder: (context, cons) {
                      // 自适应列数：目标卡宽 ~240（2~5 列）。
                      final cols = ((cons.maxWidth - 40 - 12 * 4) / 240)
                          .floor()
                          .clamp(2, 5);
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1,
                        ),
                        itemCount: _recent.length,
                        itemBuilder: (context, i) {
                          final img = _recent[i];
                          return _CanvasTile(
                            asset: img,
                            onOpen: () {
                              final ids = _recent.map((e) => e.id).toList();
                              context.push(
                                '/preview',
                                extra: PreviewArgs(
                                  ids: ids,
                                  startIndex: ids
                                      .indexOf(img.id)
                                      .clamp(0, ids.length - 1),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 画布空态引导。
  Widget _canvasEmptyState(AppDensity d) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.palette_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 12),
          Text(
            '开始你的第一幅创作',
            style: TextStyle(
              fontSize: d.body + 2,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '在左侧输入提示词，点击生成',
            style: TextStyle(
              fontSize: d.sub + 1,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 移动端（<600，§10.3）：紧凑视觉重构 ----
  // 设计参考：Shape of AI「Initial CTA / Preset styles / Parameters」模式 +
  // 主流生图 App 惯例（提示词主角卡 / 参数 chip 化 / 双卡模式切换）。

  /// 参数卡：尺寸 / 质量 / 数量 三列（列上 label、列下控件），格式与低频参数收进高级折叠。
  /// 尺寸下拉内置「自定义尺寸…」入口触发弹窗。
  Widget _mobileParamCard(AppDensity d) {
    final caps = _caps;
    if (caps == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final isSync = caps.taskMode == TaskMode.syncHold;
    const customSizeEntry = '__custom__';

    // 紧凑下拉（列内）：填充式圆角小框。
    Widget compactDropdown({
      required String? value,
      required List<MapEntry<String, String>> items,
      required String hint,
      required ValueChanged<String?> onChanged,
    }) => Container(
      height: d.controlH,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          items: [
            for (final it in items)
              DropdownMenuItem(
                value: it.key,
                child: Text(
                  it.value,
                  style: TextStyle(fontSize: d.body),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          hint: Text(hint, style: TextStyle(fontSize: d.body)),
          onChanged: onChanged,
          iconSize: 16,
          isDense: true,
          isExpanded: true,
          padding: EdgeInsets.zero,
        ),
      ),
    );

    Widget column(String label, Widget child) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 2),
            child: Text(
              label,
              style: TextStyle(fontSize: d.sub, color: cs.onSurfaceVariant),
            ),
          ),
          child,
        ],
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '参数',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontSize: d.body + 1),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                column(
                  '尺寸',
                  compactDropdown(
                    value: _size,
                    items: [
                      ...caps.sizePresets.map((s) => MapEntry(s, s)),
                      if (!caps.sizePresets.contains(_size))
                        MapEntry(_size, _size),
                      const MapEntry(customSizeEntry, '自定义尺寸…'),
                    ],
                    hint: '尺寸',
                    onChanged: (v) {
                      if (v == customSizeEntry) {
                        _showCustomSizeDialog(caps);
                        return;
                      }
                      if (v != null) setState(() => _size = v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                column(
                  '质量',
                  compactDropdown(
                    value: _quality,
                    items: [for (final q in caps.qualities) MapEntry(q, q)],
                    hint: '质量',
                    onChanged: (v) {
                      if (v != null) setState(() => _quality = v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                column(
                  '数量',
                  Container(
                    height: d.controlH,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 18,
                          ),
                          onPressed: _n > 1 ? () => setState(() => _n--) : null,
                        ),
                        SizedBox(
                          width: 20,
                          child: Text(
                            '$_n',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: d.body,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.add_circle_outline, size: 18),
                          onPressed: _n < caps.maxN
                              ? () => setState(() => _n++)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                maintainState: true,
                tilePadding: EdgeInsets.zero,
                dense: true,
                childrenPadding: EdgeInsets.zero,
                title: Text('高级参数', style: TextStyle(fontSize: d.body)),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(
                            '格式',
                            style: TextStyle(
                              fontSize: d.body,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            height: d.controlH,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _outputFormat,
                                items: [
                                  for (final f in caps.outputFormats)
                                    DropdownMenuItem(
                                      value: f,
                                      child: Text(
                                        f,
                                        style: TextStyle(fontSize: d.body),
                                      ),
                                    ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    setState(() => _outputFormat = v);
                                  }
                                },
                                iconSize: 18,
                                isDense: true,
                                isExpanded: true,
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('透明背景', style: TextStyle(fontSize: d.body)),
                    value: _transparentBg,
                    onChanged: (v) => setState(() => _transparentBg = v),
                  ),
                  TextField(
                    controller: _extraJsonCtrl,
                    maxLines: 2,
                    minLines: 2,
                    style: TextStyle(fontSize: d.sub, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      labelText: '扩展参数 JSON（可选）',
                      hintText: '{"seed": 123}',
                      helperText: '透传平台；同名键覆盖标准参数',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelStyle: TextStyle(fontSize: d.sub),
                    ),
                  ),
                  if (isSync)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'ⓘ 同步平台：quality 可能被 Key 档位覆盖；生成期间请保持应用运行',
                        style: TextStyle(
                          fontSize: d.sub,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 参考图 ----

  Widget _refStrip(AppDensity d) {
    final dropEnabled =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return SizedBox(
      height: 104,
      child: DropTarget(
        // desktop_drop 0.8.x：仅桌面启用拖拽（Android preview 不稳）。
        enable: dropEnabled,
        onDragEntered: (_) => setState(() => _dragHover = true),
        onDragExited: (_) => setState(() => _dragHover = false),
        onDragDone: (details) async {
          setState(() => _dragHover = false);
          await _addRefImagePaths(details.files.map((f) => f.path).toList());
        },
        child: Container(
          decoration: _dragHover
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          padding: _dragHover ? const EdgeInsets.all(2) : EdgeInsets.zero,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _refImages.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (i == _refImages.length) {
                return _addRefButton();
              }
              final path = _refImages[i];
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    // 参考图可能是相机原图（十几 MB）——降采样解码（U-38 B）。
                    child: Image.file(
                      File(path),
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      cacheWidth: 256,
                      gaplessPlayback: true,
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => setState(() => _refImages.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _addRefButton() {
    return SizedBox(
      width: 96,
      height: 96,
      child: OutlinedButton(
        onPressed: _pickRefImages,
        // 简单圆角方形，与参考图瓦片（8dp 圆角）视觉一致（原默认 Stadium 呈圆形）。
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined, size: 28),
            Text('添加', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickRefImages() async {
    List<String> paths;
    if (Platform.isAndroid) {
      final picked = await ImagePicker().pickMultiImage(imageQuality: 100);
      paths = picked.map((x) => x.path).toList();
    } else {
      // file_picker 13.x：静态多选 API。
      final files = await FilePicker.pickFiles(type: FileType.image);
      paths = files.map((f) => f.path).whereType<String>().toList();
    }
    await _addRefImagePaths(paths);
  }

  /// 参考图入列统一校验（拖拽 / 选择器共用）：上限 / 单张 10MB / 总量。
  Future<void> _addRefImagePaths(List<String> paths) async {
    final caps = _caps;
    if (caps == null) return;
    if (paths.isEmpty) return;
    if (_mode != TaskKind.edit) {
      setState(() => _mode = TaskKind.edit);
    }
    if (_refImages.length >= caps.maxRefImages) {
      _toast('参考图已达上限 ${caps.maxRefImages} 张');
      return;
    }
    var total = 0;
    for (final p in _refImages) {
      total += await File(p).length();
    }
    final added = <String>[];
    for (final p in paths) {
      if (_refImages.length + added.length >= caps.maxRefImages) break;
      final size = await File(p).length();
      if (size > 10 * 1024 * 1024) {
        _toast('${p.split(Platform.pathSeparator).last} 超过 10MB，已跳过');
        continue;
      }
      if (total + size > caps.maxRefTotalMb * 1024 * 1024) {
        _toast('参考图总量将超过 ${caps.maxRefTotalMb}MB，已停止添加');
        break;
      }
      total += size;
      added.add(p);
    }
    if (added.isEmpty) return;
    setState(() => _refImages.addAll(added));
    _toast('已添加 ${added.length} 张参考图');
  }

  // ---- 最近结果（本机最新 10 张） ----

  Widget _recentStrip(AppDensity d) {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('最近结果', style: Theme.of(context).textTheme.titleSmall),
        ),
        SizedBox(
          height: 110,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _recent.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final img = _recent[i];
              return GestureDetector(
                onTap: () {
                  final ids = _recent.map((e) => e.id).toList();
                  context.push(
                    '/preview',
                    extra: PreviewArgs(
                      ids: ids,
                      startIndex: ids.indexOf(img.id).clamp(0, ids.length - 1),
                    ),
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  // 最近结果条（U-38 B）：ThumbImage 降采样 + thumb 回退原图。
                  child: ThumbImage(
                    filePath: img.filePath,
                    thumbPath: img.thumbPath,
                    cacheWidth: 256,
                    fit: BoxFit.cover,
                    errorPlaceholder: const SizedBox(
                      width: 110,
                      height: 110,
                      child: ColoredBox(
                        color: Colors.black12,
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---- 提交 ----

  Future<void> _submit() async {
    // 移动端：提交即收起虚拟键盘（生成按钮在固定底栏，键盘会遮挡结果区）。
    FocusManager.instance.primaryFocus?.unfocus();
    final provider = _provider;
    final key = _selectedKey;
    final prompt = _promptCtrl.text.trim();
    if (provider == null || key == null) {
      _toast('请先选择平台与 Key（设置页添加）');
      return;
    }
    if (_model == null) {
      _toast('请先选择模型；若列表为空，到设置页"测试连通"拉取');
      return;
    }
    if (prompt.isEmpty) {
      _toast('提示词不能为空');
      return;
    }
    if (_mode == TaskKind.edit && _refImages.isEmpty) {
      _toast('参考图编辑至少添加 1 张图');
      return;
    }
    // 自定义尺寸本地校验（§6.1/§11.2）：神稳 16 倍数/≤3840/像素窗/≤3:1。
    final caps = _caps;
    final sizeRule = caps?.customSizeRule;
    if (sizeRule != null && _size != 'auto') {
      final sizeError = sizeRule(_size);
      if (sizeError != null) {
        _toast(sizeError);
        return;
      }
    }
    String? extraJson;
    final extraText = _extraJsonCtrl.text.trim();
    if (extraText.isNotEmpty) {
      Object? decoded;
      try {
        decoded = const JsonDecoder().convert(extraText);
      } on FormatException {
        _toast('扩展参数不是合法 JSON');
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        _toast('扩展参数必须是 JSON 对象（{...}）');
        return;
      }
      extraJson = extraText;
    }
    final params = ParamSnapshot(
      model: _model!,
      prompt: prompt,
      n: _n,
      size: _size == 'auto' ? null : _size,
      quality: _quality == 'auto' ? null : _quality,
      background: _transparentBg ? 'transparent' : null,
      outputFormat: _outputFormat == 'auto' ? null : _outputFormat,
      extraJson: extraJson,
    );
    await ref
        .read(orchestratorProvider.notifier)
        .enqueue(
          providerId: provider.id,
          keyId: key.id,
          kind: _mode,
          params: params,
          refImagePaths: _mode == TaskKind.edit
              ? _refImages.toList()
              : const [],
        );
    ref.read(guardOpenProvider.notifier).show();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 自定义尺寸弹窗（§10.2「自定义 WxH」）：输入即时校验（caps.customSizeRule），
  /// 合法才允许应用；无校验器平台仅要求 WxH 格式。
  /// U-28：控制器生命周期随 _CustomSizeDialog State（退场动画期安全）。
  Future<void> _showCustomSizeDialog(ProviderCapabilities caps) async {
    final v = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _CustomSizeDialog(
        initial: RegExp(r'^\d+x\d+$').hasMatch(_size) ? _size : '',
        rule: caps.customSizeRule,
      ),
    );
    if (v != null && v.isNotEmpty) {
      setState(() => _size = v);
    }
  }
}

/// 画布网格卡片：hover 显示提示词摘要浮层（底部渐变遮罩），点击进预览。
class _CanvasTile extends StatefulWidget {
  const _CanvasTile({required this.asset, required this.onOpen});

  final ImageAsset asset;
  final VoidCallback onOpen;

  @override
  State<_CanvasTile> createState() => _CanvasTileState();
}

class _CanvasTileState extends State<_CanvasTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    final img = widget.asset;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 画布瓦片（U-38 B）：ThumbImage 降采样，4K 原图不再全尺寸解码。
              ThumbImage(filePath: img.filePath, thumbPath: img.thumbPath),
              // hover 浮层：底部渐变 + 提示词摘要。
              // Positioned 必须是 Stack 直接子级（ParentData 契约）；
              // AnimatedOpacity 作为 Positioned 的 child 而非父级。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                    child: Text(
                      img.promptSnapshot ?? '图像',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: d.sub,
                        height: 1.3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 提示词模板管理弹窗（M2）：列表/套用（计数）/新增/编辑/删除。
class _TemplateDialog extends ConsumerStatefulWidget {
  const _TemplateDialog({required this.onApply});

  final void Function(PromptTemplate) onApply;

  @override
  ConsumerState<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends ConsumerState<_TemplateDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('提示词模板'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: FutureBuilder<List<PromptTemplate>>(
          future: ref.read(appServicesProvider).templates.list(),
          builder: (context, snap) {
            final list = snap.data ?? const <PromptTemplate>[];
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (list.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('还没有模板'),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () => _edit(null),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('新建模板'),
                    ),
                  ],
                ),
              );
            }
            return StatefulBuilder(
              builder: (context, setStateDialog) => ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final t = list[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      t.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '用过 ${t.useCount} 次',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: '编辑',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () =>
                              _edit(t).then((_) => setStateDialog(() {})),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await ref
                                .read(appServicesProvider)
                                .templates
                                .delete(t.id);
                            setStateDialog(() => list.removeAt(i));
                          },
                        ),
                      ],
                    ),
                    onTap: () => widget.onApply(t),
                  );
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _edit(null).then((_) => setState(() {})),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('新建'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _edit(PromptTemplate? existing) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _TemplateEditDialog(existing: existing),
    );
    // 保存/删除后刷新列表（弹窗内部完成 dao 写入；U-28 生命周期修）。
    if (mounted) setState(() {});
  }
}

/// 自定义尺寸弹窗（U-28：控制器生命周期随 State.dispose，退场动画期安全）。
/// 应用时 pop 合法尺寸字符串；取消 pop null。
class _CustomSizeDialog extends StatefulWidget {
  const _CustomSizeDialog({required this.initial, required this.rule});

  final String initial;
  final String? Function(String)? rule;

  @override
  State<_CustomSizeDialog> createState() => _CustomSizeDialogState();
}

class _CustomSizeDialogState extends State<_CustomSizeDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rule = widget.rule;
    return AlertDialog(
      title: const Text('自定义尺寸'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '宽x高',
                hintText: '如 2048x1152',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 8),
            Text(
              rule == null
                  ? '格式：半角 x，如 1024x1024'
                  : '规则：16 倍数 · 最长边 ≤3840 · 总像素 65万~830万 · 长宽比 ≤3:1',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final v = _ctrl.text.trim().toLowerCase();
            if (!RegExp(r'^\d+x\d+$').hasMatch(v)) {
              setState(() => _error = '格式应为 WxH（半角 x，如 1024x1024）');
              return;
            }
            final ruleError = rule?.call(v);
            if (ruleError != null) {
              setState(() => _error = ruleError);
              return;
            }
            Navigator.of(context).pop(v);
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}

/// 模板新建/编辑弹窗（U-28：控制器生命周期随 State.dispose）。
/// 保存由弹窗内部完成（dao 写入），pop 通知调用方刷新。
class _TemplateEditDialog extends ConsumerStatefulWidget {
  const _TemplateEditDialog({required this.existing});

  final PromptTemplate? existing;

  @override
  ConsumerState<_TemplateEditDialog> createState() =>
      _TemplateEditDialogState();
}

class _TemplateEditDialogState extends ConsumerState<_TemplateEditDialog> {
  late final _titleCtrl = TextEditingController(text: widget.existing?.title);
  late final _contentCtrl = TextEditingController(
    text: widget.existing?.content,
  );

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? '新建模板' : '编辑模板'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contentCtrl,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '提示词内容'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            final title = _titleCtrl.text.trim();
            final content = _contentCtrl.text.trim();
            if (title.isEmpty || content.isEmpty) return;
            final dao = ref.read(appServicesProvider).templates;
            final now = DateTime.now().millisecondsSinceEpoch;
            if (existing == null) {
              await dao.insert(
                PromptTemplate(
                  id: const Uuid().v4(),
                  title: title,
                  content: content,
                  createdAt: now,
                ),
              );
            } else {
              await dao.update(
                PromptTemplate(
                  id: existing.id,
                  title: title,
                  content: content,
                  useCount: existing.useCount,
                  lastUsedAt: existing.lastUsedAt,
                  createdAt: existing.createdAt,
                ),
              );
            }
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
