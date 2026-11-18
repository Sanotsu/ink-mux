import 'dart:convert';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers/app_services.dart';
import '../../../app/providers/studio_import.dart';
import '../../../core/theme/density.dart';
import '../../../domain/entities/image_asset.dart';
import '../../../domain/entities/param_snapshot.dart';
import '../../../domain/values/enums.dart';
import '../../../ui/widgets/thumb_image.dart';

/// 路由 extra：查看器上下文（当前画廊过滤结果 + 起始下标）。
class PreviewArgs {
  const PreviewArgs({required this.ids, this.startIndex = 0});
  final List<String> ids;
  final int startIndex;
}

/// 全屏沉浸式图片查看器（§10.1/10.5，对标 Midjourney Web / Google Photos）：
/// 黑底大图 fit 填满 · 左右箭头/键盘切换 · 底部胶片条 · 右侧可开合元信息面板。
class PreviewPage extends ConsumerStatefulWidget {
  const PreviewPage({super.key, required this.args});

  final PreviewArgs args;

  @override
  ConsumerState<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends ConsumerState<PreviewPage> {
  late final FocusNode _focusNode;
  late List<String> _ids;
  late int _index;
  ImageAsset? _asset;
  bool _showInfo = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ids = widget.args.ids;
    _index = _ids.isEmpty
        ? 0
        : widget.args.startIndex.clamp(0, _ids.length - 1);
    _focusNode = FocusNode();
    _loadCurrent();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    if (_ids.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final asset = await ref.read(appServicesProvider).images.byId(_ids[_index]);
    if (!mounted) return;
    setState(() {
      _asset = asset;
      _loading = false;
    });
  }

  void _go(int delta) {
    if (_ids.isEmpty) return;
    final next = (_index + delta).clamp(0, _ids.length - 1);
    if (next == _index) return;
    setState(() {
      _index = next;
      _loading = true;
    });
    _loadCurrent();
  }

  Future<void> _toggleFavorite() async {
    final asset = _asset;
    if (asset == null) return;
    await ref
        .read(appServicesProvider)
        .images
        .setFavorite(asset.id, !asset.favorite);
    await _loadCurrent();
  }

  Future<void> _openFolder() async {
    final path = _asset?.filePath;
    if (path == null || !Platform.isWindows) return;
    await Process.run('explorer.exe', ['/select,', path]);
  }

  Future<void> _share() async {
    final path = _asset?.filePath;
    if (path == null || !Platform.isAndroid) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: 'InkMux 作品'),
    );
  }

  /// 移动端：复制到剪贴板 + 轻提示。
  void _copySnack(BuildContext context, String label, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  /// 移动端：单击图片 → 全屏缩放查看器（黑底沉浸 + 手势 + 左右切换/胶片条）。
  /// 切换通过 [onIndexChanged] 回流，详情页与查看器保持同一 index。
  void _openFullscreen() {
    if (_asset == null || _ids.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewerPage(
          ids: _ids,
          initialIndex: _index,
          onIndexChanged: (i) {
            if (i == _index || !mounted) return;
            setState(() {
              _index = i;
              _loading = true;
            });
            _loadCurrent();
          },
        ),
      ),
    );
  }

  /// 移动端：用此图继续编辑（与画廊/信息面板同语义，§10.5）。
  void _continueEdit() {
    final a = _asset;
    if (a == null) return;
    ParamSnapshot? params;
    if (a.paramsSnapshotJson != null) {
      try {
        params = ParamSnapshot.fromJson(
          Map<String, dynamic>.from(jsonDecode(a.paramsSnapshotJson!) as Map),
        );
      } catch (_) {
        params = null;
      }
    }
    ref
        .read(studioImportProvider.notifier)
        .request(
          StudioImport(
            refImagePaths: [a.filePath],
            prompt: a.promptSnapshot,
            params: params,
            token: 0,
          ),
        );
    context.go('/studio');
  }

  /// 移动端参数卡内容（主题色版，解析失败静默隐藏）。
  Widget _mobileParams(BuildContext context, ImageAsset a, AppDensity d) {
    try {
      final p = ParamSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(a.paramsSnapshotJson!) as Map),
      );
      final cs = Theme.of(context).colorScheme;
      final rows = <String, String>{
        '模型': p.model,
        '数量': '${p.n}',
        if (p.size != null) '尺寸': p.size!,
        if (p.quality != null) '质量': p.quality!,
        if (p.background != null) '背景': p.background!,
        if (p.outputFormat != null) '格式': p.outputFormat!,
        if (p.extraJson != null && p.extraJson!.trim().isNotEmpty)
          '扩展': p.extraJson!,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in rows.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${e.key}  ',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: d.sub,
                      ),
                    ),
                    TextSpan(
                      text: e.value,
                      style: TextStyle(color: cs.onSurface, fontSize: d.body),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  /// 移动端元信息卡内容。
  Widget _mobileMeta(BuildContext context, ImageAsset a, AppDensity d) {
    final cs = Theme.of(context).colorScheme;
    final meta = [
      if (a.width != null && a.height != null) '${a.width}×${a.height} 像素',
      if (a.format != null) a.format!.toUpperCase(),
      if (a.bytes != null) '${(a.bytes! / 1024).round()} KB',
      a.channel == ResultChannel.url ? '来源 url' : '来源 b64',
      DateFormat('yyyy-MM-dd HH:mm:ss')
          .format(DateTime.fromMillisecondsSinceEpoch(a.createdAt)),
    ].join(' · ');
    return Text(
      meta,
      style: TextStyle(
        fontSize: d.sub,
        color: cs.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      context.pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 600;
    final cacheWidth = asset == null
        ? null
        : (viewport.width * dpr).round().clamp(1600, 4096);

    final imageView = _loading || asset == null
        ? const Center(child: CircularProgressIndicator())
        : ExtendedImage.file(
            File(asset.filePath),
            fit: BoxFit.contain,
            mode: ExtendedImageMode.gesture,
            cacheWidth: cacheWidth,
            clearMemoryCacheWhenDispose: true,
            initGestureConfigHandler: (state) =>
                GestureConfig(minScale: 0.5, maxScale: 12.0),
            loadStateChanged: (state) {
              if (state.extendedImageLoadState == LoadState.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (state.extendedImageLoadState == LoadState.failed) {
                return const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 48,
                    color: Colors.white38,
                  ),
                );
              }
              return null;
            },
          );

    // ---- 移动端（<600，对标小红书帖子详情）：主题色详情页 —— AppBar（关闭 /
    // ---- index / 收藏 / 分享）→ 可滚动内容（图片卡 + 提示词 + 参数 + 元信息）
    // ---- → 底部固定 [复制提示词 | 用此图继续编辑]；点击图片进全屏缩放查看器。
    if (compact) {
      final d = AppDensity.of(context);
      final cs = Theme.of(context).colorScheme;
      final a = asset;
      return Scaffold(
        // 跟随主题而非固定暗色（用户反馈）。
        backgroundColor: cs.surfaceContainerLowest,
        appBar: AppBar(
          toolbarHeight: 48,
          leading: IconButton(
            tooltip: '关闭',
            onPressed: () => context.pop(),
            icon: const Icon(Icons.close),
          ),
          centerTitle: true,
          title: Text(
            _ids.isEmpty ? '' : '${_index + 1} / ${_ids.length}',
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            if (a != null)
              IconButton(
                tooltip: a.favorite ? '取消收藏' : '收藏',
                onPressed: _toggleFavorite,
                icon: Icon(
                  a.favorite ? Icons.favorite : Icons.favorite_border,
                  size: 20,
                  color: a.favorite ? Colors.pinkAccent : null,
                ),
              ),
            if (a != null && Platform.isAndroid)
              IconButton(
                tooltip: '分享',
                onPressed: _share,
                icon: const Icon(Icons.share, size: 20),
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: _loading || a == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  // 图片卡：单击进入全屏缩放查看器（AspectRatio 按实际像素约束，
                  // 竖图不撑爆滚动区；测量缺失时回退 1:1）。
                  GestureDetector(
                    onTap: _openFullscreen,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio:
                            (a.width != null &&
                                a.height != null &&
                                a.width! > 0 &&
                                a.height! > 0)
                            ? a.width! / a.height!
                            : 1.0,
                        child: Image.file(
                          File(a.filePath),
                          fit: BoxFit.cover,
                          cacheWidth: cacheWidth,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: Colors.black12,
                            child: Center(
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 图片宽高比约束的完整呈现（避免竖图撑爆滚动区）。
                  _MobileInfoCard(
                    label: '提示词',
                    child: SelectionArea(
                      child: Text(
                        a.promptSnapshot ?? '（无）',
                        style: TextStyle(fontSize: d.body, height: 1.4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (a.paramsSnapshotJson != null) ...[
                    _MobileInfoCard(
                      label: '参数',
                      child: _mobileParams(context, a, d),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _MobileInfoCard(
                    label: '信息',
                    child: _mobileMeta(context, a, d),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
        // 底部固定双按钮（与创作页生成按钮同层级的持久操作区）。
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        _copySnack(context, '提示词', a?.promptSnapshot ?? ''),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制提示词'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _continueEdit,
                    icon: const Icon(
                      Icons.photo_size_select_large_outlined,
                      size: 16,
                    ),
                    label: const Text('继续编辑'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ---- 桌面端（≥600）：黑底 Stack + 右侧可开合信息面板（原布局）。 ----
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            // ---- 大图 ----
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                  right: _showInfo ? 340 : 0,
                  bottom: _ids.length > 1 ? 84 : 0,
                ),
                child: imageView,
              ),
            ),

            // ---- 顶栏（悬浮） ----
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _TopBar(
                asset: asset,
                position: _ids.isEmpty ? '' : '${_index + 1} / ${_ids.length}',
                showInfo: _showInfo,
                onToggleInfo: () => setState(() => _showInfo = !_showInfo),
                onClose: () => context.pop(),
                onFavorite: _toggleFavorite,
                onOpenFolder: _openFolder,
                onShare: _share,
              ),
            ),

            // ---- 左右箭头 ----
            if (_ids.length > 1) ...[
              if (_index > 0)
                _ArrowButton(
                  icon: Icons.chevron_left,
                  alignment: Alignment.centerLeft,
                  showInfo: _showInfo,
                  onTap: () => _go(-1),
                ),
              if (_index < _ids.length - 1)
                _ArrowButton(
                  icon: Icons.chevron_right,
                  alignment: Alignment.centerRight,
                  showInfo: _showInfo,
                  onTap: () => _go(1),
                ),
            ],

            // ---- 底部胶片条 ----
            if (_ids.length > 1)
              Positioned(
                left: 0,
                right: _showInfo ? 340 : 0,
                bottom: 0,
                child: _Filmstrip(
                  ids: _ids,
                  currentId: asset?.id,
                  onPick: (id) {
                    final i = _ids.indexOf(id);
                    if (i >= 0) _go(i - _index);
                  },
                ),
              ),

            // ---- 右侧信息面板 ----
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              top: 0,
              right: _showInfo ? 0 : -340,
              bottom: 0,
              child: _InfoPanel(asset: asset),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== 移动端：信息卡 =====================

/// 移动端详情页信息卡（主题色，替代桌面深色固定面板）。
class _MobileInfoCard extends StatelessWidget {
  const _MobileInfoCard({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = AppDensity.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: d.sub,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            child,
          ],
        ),
      ),
    );
  }
}

// ===================== 移动端：全屏缩放查看器 =====================

/// 点击详情页图片后进入：黑底沉浸 + 手势缩放 + 左右切换 + 胶片条。
/// index 变化经 [onIndexChanged] 回流详情页保持同步。
class _FullscreenViewerPage extends ConsumerStatefulWidget {
  const _FullscreenViewerPage({
    required this.ids,
    required this.initialIndex,
    required this.onIndexChanged,
  });

  final List<String> ids;
  final int initialIndex;
  final void Function(int index) onIndexChanged;

  @override
  ConsumerState<_FullscreenViewerPage> createState() =>
      _FullscreenViewerPageState();
}

class _FullscreenViewerPageState extends ConsumerState<_FullscreenViewerPage> {
  late int _index = widget.initialIndex;
  late final ExtendedPageController _pageController = ExtendedPageController(
    initialPage: _index,
  );

  /// 全量资产缓存（查看器打开时一次性加载，PageView 每页直接取用）。
  final Map<String, ImageAsset> _assets = {};
  bool _loading = true;

  /// 工具栏显隐（顶栏/箭头/胶片条）：单击图片切换（相册惯例，默认显示）。
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final dao = ref.read(appServicesProvider).images;
    for (final id in widget.ids) {
      final a = await dao.byId(id);
      if (a != null) _assets[id] = a;
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _go(int delta) {
    if (widget.ids.isEmpty) return;
    final next = (_index + delta).clamp(0, widget.ids.length - 1);
    if (next == _index || !_pageController.hasClients) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    widget.onIndexChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final viewport = MediaQuery.sizeOf(context);
    final multi = widget.ids.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 手势切图：ExtendedImageGesturePageView + inPageView=true
          // （Android 相册惯例委托规则）——scale≤1 时水平滑动切页；
          // 放大后拖动=看细节，拖到边界再同向拖才交给 PageView 切页。
          Positioned.fill(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ExtendedImageGesturePageView.builder(
                    controller: _pageController,
                    itemCount: widget.ids.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, i) {
                      final asset = _assets[widget.ids[i]];
                      final cacheWidth = asset == null
                          ? null
                          : (viewport.width * dpr).round().clamp(1600, 4096);
                      // 图片始终全屏居中；工具栏为纯覆盖层（显隐不挤压图片）。
                      return GestureDetector(
                        onTap: () =>
                            setState(() => _chromeVisible = !_chromeVisible),
                        child: asset == null
                            ? const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 48,
                                  color: Colors.white38,
                                ),
                              )
                            : ExtendedImage.file(
                                File(asset.filePath),
                                fit: BoxFit.contain,
                                mode: ExtendedImageMode.gesture,
                                cacheWidth: cacheWidth,
                                clearMemoryCacheWhenDispose: true,
                                initGestureConfigHandler: (state) =>
                                    GestureConfig(
                                      minScale: 0.5,
                                      maxScale: 12.0,
                                      inPageView: true,
                                    ),
                                loadStateChanged: (state) {
                                  if (state.extendedImageLoadState ==
                                      LoadState.loading) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }
                                  if (state.extendedImageLoadState ==
                                      LoadState.failed) {
                                    return const Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        size: 48,
                                        color: Colors.white38,
                                      ),
                                    );
                                  }
                                  return null;
                                },
                              ),
                      );
                    },
                  ),
          ),
          // 顶栏（沉浸悬浮）：关闭 + index；随单击显隐。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: AnimatedOpacity(
                opacity: _chromeVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_chromeVisible,
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(
                            Icons.close,
                            size: 20,
                            color: Colors.white70,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_index + 1} / ${widget.ids.length}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 左右箭头（随单击显隐）。
          if (multi && _chromeVisible) ...[
            if (_index > 0)
              _ArrowButton(
                icon: Icons.chevron_left,
                alignment: Alignment.centerLeft,
                showInfo: false,
                onTap: () => _go(-1),
              ),
            if (_index < widget.ids.length - 1)
              _ArrowButton(
                icon: Icons.chevron_right,
                alignment: Alignment.centerRight,
                showInfo: false,
                onTap: () => _go(1),
              ),
          ],
          // 底部胶片条（随单击显隐）。
          if (multi)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _chromeVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_chromeVisible,
                  child: _Filmstrip(
                    ids: widget.ids,
                    currentId: widget.ids.isEmpty ? null : widget.ids[_index],
                    onPick: (id) {
                      final i = widget.ids.indexOf(id);
                      if (i >= 0) _go(i - _index);
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===================== 顶栏 =====================

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.asset,
    required this.position,
    required this.showInfo,
    required this.onToggleInfo,
    required this.onClose,
    required this.onFavorite,
    required this.onOpenFolder,
    required this.onShare,
  });

  final ImageAsset? asset;
  final String position;
  final bool showInfo;
  final VoidCallback onToggleInfo;
  final VoidCallback onClose;
  final VoidCallback onFavorite;
  final VoidCallback onOpenFolder;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final surface = Colors.black.withValues(alpha: 0.45);
    Widget action(
      IconData icon,
      String tip,
      VoidCallback? onTap, {
      bool active = false,
    }) {
      return IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(
          icon,
          size: 20,
          color: active ? Colors.amberAccent : Colors.white70,
        ),
      );
    }

    return SafeArea(
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: surface),
        child: Row(
          children: [
            action(Icons.close, '关闭 (Esc)', onClose),
            const SizedBox(width: 8),
            Text(
              position,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const Spacer(),
            if (a != null)
              IconButton(
                tooltip: a.favorite ? '取消收藏' : '收藏',
                onPressed: onFavorite,
                icon: Icon(
                  a.favorite ? Icons.favorite : Icons.favorite_border,
                  size: 20,
                  color: a.favorite ? Colors.pinkAccent : Colors.white70,
                ),
              ),
            if (a != null && Platform.isWindows)
              action(Icons.folder_open, '打开所在文件夹', onOpenFolder),
            if (a != null && Platform.isAndroid)
              action(Icons.share, '分享', onShare),
            action(
              showInfo ? Icons.info : Icons.info_outline,
              showInfo ? '隐藏信息' : '显示信息',
              onToggleInfo,
              active: showInfo,
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== 左右箭头 =====================

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.alignment,
    required this.showInfo,
    required this.onTap,
  });

  final IconData icon;
  final Alignment alignment;
  final bool showInfo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: EdgeInsets.only(
          left: alignment == Alignment.centerLeft ? 12 : 0,
          right: alignment == Alignment.centerRight ? (showInfo ? 352 : 12) : 0,
        ),
        child: Material(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, size: 28, color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}

// ===================== 底部胶片条 =====================

class _Filmstrip extends ConsumerWidget {
  const _Filmstrip({
    required this.ids,
    required this.currentId,
    required this.onPick,
  });

  final List<String> ids;
  final String? currentId;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 84,
      color: Colors.black.withValues(alpha: 0.45),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: FutureBuilder<List<ImageAsset>>(
        future: ref.read(appServicesProvider).images.page(limit: 200),
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const SizedBox.shrink();
          final byId = {for (final a in all) a.id: a};
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: ids.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final id = ids[i];
              final asset = byId[id];
              final selected = id == currentId;
              return GestureDetector(
                onTap: () => onPick(id),
                child: Opacity(
                  opacity: selected ? 1 : 0.45,
                  child: Container(
                    width: 64,
                    height: 64,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: selected ? Colors.white : Colors.white24,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: asset == null
                        ? const ColoredBox(color: Colors.white10)
                        : ThumbImage(
                            filePath: asset.filePath,
                            thumbPath: asset.thumbPath,
                            cacheWidth: 256,
                            fit: BoxFit.cover,
                            errorPlaceholder: const ColoredBox(
                              color: Colors.white10,
                            ),
                          ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ===================== 信息面板 =====================

class _InfoPanel extends ConsumerWidget {
  const _InfoPanel({required this.asset});

  final ImageAsset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = asset;
    return Container(
      width: 340,
      color: const Color(0xFF141416),
      child: a == null
          ? const SizedBox.shrink()
          : SafeArea(
              left: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 64, 16, 16),
                children: [
                  _label('提示词'),
                  _selectable(a.promptSnapshot ?? '（无）'),
                  const SizedBox(height: 12),
                  if (a.paramsSnapshotJson != null) ...[
                    _label('参数'),
                    SelectionArea(child: _params(a)),
                    const SizedBox(height: 12),
                  ],
                  _label('信息'),
                  SelectionArea(child: _metaCard(context, a)),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        _copySnack(context, '提示词', a.promptSnapshot ?? ''),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制提示词'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _continueEdit(context, ref),
                    icon: const Icon(
                      Icons.photo_size_select_large_outlined,
                      size: 16,
                    ),
                    label: const Text('用此图继续编辑'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: Colors.white38,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _selectable(String text) => SelectionArea(
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, color: Color(0xFFDEDEDE)),
    ),
  );

  Widget _params(ImageAsset a) {
    try {
      final p = ParamSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(a.paramsSnapshotJson!) as Map),
      );
      final rows = <String, String>{
        '模型': p.model,
        '数量': '${p.n}',
        if (p.size != null) '尺寸': p.size!,
        if (p.quality != null) '质量': p.quality!,
        if (p.background != null) '背景': p.background!,
        if (p.outputFormat != null) '格式': p.outputFormat!,
        if (p.extraJson != null && p.extraJson!.trim().isNotEmpty)
          '扩展': p.extraJson!,
      };
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in rows.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${e.key}  ',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      TextSpan(
                        text: e.value,
                        style: const TextStyle(
                          color: Color(0xFFDEDEDE),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _metaCard(BuildContext context, ImageAsset a) {
    final meta = [
      if (a.width != null && a.height != null) '${a.width}×${a.height} 像素',
      if (a.format != null) a.format!.toUpperCase(),
      if (a.bytes != null) '${(a.bytes! / 1024).round()} KB',
      a.channel == ResultChannel.url ? '来源 url' : '来源 b64',
      DateFormat('yyyy-MM-dd HH:mm:ss')
          .format(DateTime.fromMillisecondsSinceEpoch(a.createdAt)),
    ].join(' · ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        meta,
        style: const TextStyle(fontSize: 11, color: Colors.white60),
      ),
    );
  }

  void _copySnack(BuildContext context, String label, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  /// 「用此图继续编辑」：携带参考图（与可用的原参数）回创作页。
  void _continueEdit(BuildContext context, WidgetRef ref) {
    final a = asset;
    if (a == null) return;
    ParamSnapshot? params;
    if (a.paramsSnapshotJson != null) {
      try {
        params = ParamSnapshot.fromJson(
          Map<String, dynamic>.from(jsonDecode(a.paramsSnapshotJson!) as Map),
        );
      } catch (_) {
        params = null;
      }
    }
    ref
        .read(studioImportProvider.notifier)
        .request(
          StudioImport(
            refImagePaths: [a.filePath],
            prompt: a.promptSnapshot,
            params: params,
            token: 0,
          ),
        );
    context.go('/studio');
  }
}
