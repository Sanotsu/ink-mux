import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers/app_services.dart';
import '../../../app/providers/orchestrator.dart';
import '../../../app/providers/settings_controller.dart';
import '../../../app/providers/studio_import.dart';
import '../../../core/theme/density.dart';
import '../../../data/storage/image_store.dart';
import '../../../domain/entities/image_asset.dart';
import '../../../domain/entities/param_snapshot.dart';
import '../../../ui/widgets/thumb_image.dart';
import '../preview/preview_page.dart';

/// 画廊（M2 全功能）：prompt 搜索 · 收藏过滤 · 按月分组 · 多选批量（收藏/删除）
/// · 长按/右键菜单（预览/继续编辑/收藏/删除）；删除策略 §8.3。
/// [filterTaskId]：任务行/详情「在画廊中查看」定位到该任务组图（/gallery?task=xxx）。
class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key, this.filterTaskId});

  final String? filterTaskId;

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends ConsumerState<GalleryPage> {
  List<ImageAsset> _images = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  bool _favoriteOnly = false;
  String? _query;

  /// 任务过滤（进入时路由参数，可手动清除恢复全部）。
  String? _filterTaskId;

  /// 多选集合（空 = 非选择模式）。
  final Set<String> _selected = {};

  /// 已处理的刷新 tick（build 内兜底刷新用）。
  int _lastRefreshTick = -1;

  // ---- 分页（U-38 E）----
  static const int _pageSize = 60;
  int _offset = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  final ScrollController _scrollCtrl = ScrollController();

  /// 统计（U-39）：全部总数 / 收藏数 / 搜索匹配数（页首统计行）。
  int _totalCount = 0;
  int _favCount = 0;
  int _matchCount = 0;

  /// 缩略图补建进行中标记（进程级，防重复跑，U-38 A+）。
  static bool _thumbBackfillRunning = false;

  @override
  void initState() {
    super.initState();
    _filterTaskId = widget.filterTaskId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    ref.listenManual(_galleryRefreshProvider, (_, _) => _load());
    // 滚动近底部 → 加载更早一页（U-38 E）。
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || !_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.extentAfter < 600) _loadMore();
  }

  @override
  void didUpdateWidget(covariant GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // StatefulShellRoute.indexedStack 下画廊 State 常驻存活：再次跳转
    // /gallery?task=xxx（任务详情/历史「在画廊中查看」）不会重建 State，
    // 只会在 widget 上换参数——仅 initState 读一次会导致第二次起定位
    // 失效（「查看全部」后再次跳转同样失效）。参数变化即重载。
    if (widget.filterTaskId != _filterTaskId) {
      _filterTaskId = widget.filterTaskId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load({bool reset = true}) async {
    try {
      final dao = ref.read(appServicesProvider).images;
      final query = _query?.trim();
      List<ImageAsset> images;
      final paginate = _filterTaskId == null; // 任务过滤态不分页
      final offset = reset ? 0 : _offset;
      if (_filterTaskId != null) {
        images = await dao.byTask(_filterTaskId!);
      } else if (query != null && query.isNotEmpty) {
        images = await dao.search(
          query,
          favoriteOnly: _favoriteOnly,
          limit: _pageSize,
          offset: offset,
        );
      } else {
        images = await dao.page(
          limit: _pageSize,
          offset: offset,
          favoriteOnly: _favoriteOnly,
        );
      }
      debugPrint(
        '[Gallery] _load：${images.length} 张 '
        '(filter=$_filterTaskId q=$_query fav=$_favoriteOnly reset=$reset)',
      );
      if (!mounted) return;
      // 统计行数据（U-39）：总数/收藏数一次轻查询；搜索态另取匹配数。
      final (total, favs) = await dao.counts();
      final searching =
          _filterTaskId == null && query != null && query.isNotEmpty;
      final match = searching
          ? await dao.countSearch(query, favoriteOnly: _favoriteOnly)
          : 0;
      if (!mounted) return;
      setState(() {
        _totalCount = total;
        _favCount = favs;
        _matchCount = match;
        if (reset) {
          _images = images;
          _offset = images.length;
          _selected.clear();
        } else {
          final ids = _images.map((e) => e.id).toSet();
          _images = [..._images, ...images.where((e) => !ids.contains(e.id))];
          _offset = _images.length;
        }
        _hasMore = paginate && images.length >= _pageSize;
        _loading = false;
      });
      // 库里有缺缩略图的存量（历史图/恢复备份）→ 后台逐张补建。
      unawaited(_backfillThumbs());
    } catch (e, s) {
      debugPrint('[Gallery] _load 失败：$e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    await _load(reset: false);
    if (mounted) setState(() => _loadingMore = false);
  }

  /// 缩略图补建（U-38 A+）：Windows 历史上从未生成过缩略图、恢复备份的
  /// 记录 thumb_path 为空——后台顺序重建并回填 DB，完成后刷新画廊。
  Future<void> _backfillThumbs() async {
    if (_thumbBackfillRunning) return;
    final s = ref.read(appServicesProvider);
    final missing = await s.images.missingThumbs();
    if (missing.isEmpty) return;
    _thumbBackfillRunning = true;
    try {
      final ok = await ImageStore(s.dioHub, s.images).backfillThumbs(missing);
      debugPrint('[Gallery] 缩略图补建完成：$ok/${missing.length}');
      if (ok > 0 && mounted) _load();
    } finally {
      _thumbBackfillRunning = false;
    }
  }

  /// 收藏切换（U-38 D + U-39）：默认局部更新单条并同步统计计数；
  /// 收藏过滤视图取消收藏时该图应从视图消失——回退整页重载
  /// （分页 offset 语义下局部删除不可靠）。
  void _toggleFavorite(ImageAsset img, bool fav) {
    if (_favoriteOnly && !fav) {
      ref
          .read(appServicesProvider)
          .images
          .setFavorite(img.id, fav)
          .then((_) => _load());
      return;
    }
    ref.read(appServicesProvider).images.setFavorite(img.id, fav).then((_) {
      if (!mounted) return;
      setState(() {
        if (img.favorite != fav) _favCount += fav ? 1 : -1;
        _images = [
          for (final i in _images)
            if (i.id == img.id) i.copyWith(favorite: fav) else i,
        ];
      });
    });
  }

  /// 统计行文案（U-39）：按当前视图口径（全部 / 收藏 / 搜索）。
  String get _summaryLabel {
    final query = _query?.trim();
    if (query != null && query.isNotEmpty) {
      return '搜索到 $_matchCount 张 · 全部 $_totalCount 张（收藏 $_favCount 张）';
    }
    if (_favoriteOnly) {
      return '收藏 $_favCount 张 · 全部 $_totalCount 张';
    }
    return '共 $_totalCount 张 · 收藏 $_favCount 张';
  }

  @override
  Widget build(BuildContext context) {
    // 兜底刷新：成功计数 tick 的任何变化都强制重载。历史 bug：仅靠
    // listenManual 监听边沿，页面实例注册晚于 0→1 跳变时（懒构建/切换
    // 时序），画廊永不刷新显示空——即便 images 表已有数据。
    final tick = ref.watch(_galleryRefreshProvider);
    if (tick != _lastRefreshTick) {
      _lastRefreshTick = tick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _load();
      });
    }
    final width = MediaQuery.sizeOf(context).width;
    final crossCount = width < 600 ? 2 : ((width ~/ 220).clamp(3, 6));
    final d = AppDensity.of(context);
    final groups = _groupByMonth(_images);
    final selecting = _selected.isNotEmpty;

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(() => _selected.clear());
      },
      child: Scaffold(
        // 双端统一 AppBar（移动端恢复，2026-11-14）：搜索行入 AppBar bottom，
        // 与桌面共用 _normalAppBar；多选态切换为选择计数 AppBar。
        appBar: selecting ? _selectionAppBar() : _normalAppBar(d),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _images.isEmpty
            // 空态也要给任务过滤态留「查看全部」逃生口（U-45）：否则失败任务/删光的任务过滤进来只剩空文案，无法回到全库视图。
            // ⚠️ 必须用 Center 包裹（2026-11-17）：Scaffold body 宽度是松约束，裸 Column 会收缩到最宽子项宽度停靠左侧——看起来"靠左"；
            // Center 会撑满整行使子项真正水平居中。
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      // 任务过滤态空态单独文案：图片删光后到此显示，
                      // "还没有作品"会误导（库存明明有别的图）。
                      _filterTaskId != null
                          ? '该任务暂无图片\n（可能已被删除，或任务尚未产出）'
                          : _query?.isNotEmpty == true || _favoriteOnly
                          ? '没有匹配的作品'
                          : '还没有作品\n去创作页生成第一张图吧',
                      textAlign: TextAlign.center,
                    ),
                    if (_filterTaskId != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () {
                          setState(() => _filterTaskId = null);
                          _load();
                        },
                        child: const Text('查看全部'),
                      ),
                    ],
                  ],
                ),
              )
            : Column(
                children: [
                  if (_filterTaskId != null)
                    Material(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.filter_alt_outlined,
                          size: 18,
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer,
                        ),
                        title: Text(
                          '仅显示任务 ${_filterTaskId!.substring(0, 8)} 的 ${_images.length} 张图',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                        ),
                        trailing: TextButton(
                          onPressed: () {
                            setState(() => _filterTaskId = null);
                            _load();
                          },
                          child: const Text('查看全部'),
                        ),
                      ),
                    ),
                  Expanded(
                    child: CustomScrollView(
                      // Sliver 化（U-38 C）：瓦片按可视区惰性构建，
                      // 消灭 shrinkWrap 网格"整月全量构建"的解码风暴。
                      controller: _scrollCtrl,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.all(8),
                          sliver: SliverMainAxisGroup(
                            slivers: [
                              // 页首统计行（U-39）：总数按 DB 口径（跨分页），
                              // 按当前视图区分全部/收藏/搜索。
                              if (_filterTaskId == null)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      4,
                                      2,
                                      4,
                                      2,
                                    ),
                                    child: Text(
                                      _summaryLabel,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outline,
                                          ),
                                    ),
                                  ),
                                ),
                              for (final group in groups) ...[
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      4,
                                      10,
                                      4,
                                      6,
                                    ),
                                    child: Text(
                                      group.month,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outline,
                                          ),
                                    ),
                                  ),
                                ),
                                SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossCount,
                                        mainAxisSpacing: 8,
                                        crossAxisSpacing: 8,
                                      ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, i) => _tile(
                                      context,
                                      group.items[i],
                                      selecting,
                                    ),
                                    childCount: group.items.length,
                                  ),
                                ),
                              ],
                              // 分页加载更多（U-38 E）：滚动近底部自动触发，
                              // 页脚提供手动入口兜底。
                              if (_hasMore)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: Center(
                                      child: _loadingMore
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : TextButton(
                                              onPressed: _loadMore,
                                              child: const Text('加载更早的作品'),
                                            ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: selecting ? _selectionBar(d) : null,
      ),
    );
  }

  // ---- 顶栏 ----

  /// 搜索行（移动端内容区顶部 / 桌面 AppBar bottom 共用）。
  Widget _searchRow(AppDensity d) {
    final scheme = Theme.of(context).colorScheme;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(d.screenH, mobile ? 8 : 0, d.screenH, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索提示词…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = null);
                          _load();
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) {
                setState(() => _query = v.trim().isEmpty ? null : v.trim());
                _load();
              },
            ),
          ),
          IconButton(
            tooltip: _favoriteOnly ? '仅看收藏（开）' : '仅看收藏',
            onPressed: () {
              setState(() => _favoriteOnly = !_favoriteOnly);
              _load();
            },
            icon: Icon(
              _favoriteOnly ? Icons.favorite : Icons.favorite_border,
              color: _favoriteOnly ? scheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _normalAppBar(AppDensity d) {
    return AppBar(
      title: const Text('画廊'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(52),
        child: _searchRow(d),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(() => _selected.clear()),
      ),
      title: Text('已选 ${_selected.length} 项'),
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  // ---- 瓦片 ----

  Widget _tile(BuildContext context, ImageAsset img, bool selecting) {
    final selected = _selected.contains(img.id);
    // 点击/长按手势只绑在图片区域；爱心按钮作为 Stack 兄弟节点独立存在，
    // 与瓦片手势零竞争（用户反馈：嵌套时单击爱心会被外层吞掉）。
    return Stack(
      // expand：未定位子级撑满格子（竖图/横图一致），角标不漂移（用户反馈）。
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: () {
            if (selecting) {
              setState(() {
                selected ? _selected.remove(img.id) : _selected.add(img.id);
              });
            } else {
              _open(img);
            }
          },
          onLongPressStart: (details) =>
              // 用 LongPressStartDetails 全局坐标：菜单弹在手指按压处（用户反馈）。
              _imageMenuAt(
                context,
                img,
                details.globalPosition,
                enteringSelect: true,
              ),
          onSecondaryTapUp: (details) =>
              _imageMenuAt(context, img, details.globalPosition),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            // 缩略图优先 + 原图降采样回退（U-38 B）：不再全尺寸解码 4K。
            child: ThumbImage(filePath: img.filePath, thumbPath: img.thumbPath),
          ),
        ),
        // 多选模式：勾选框；普通模式：心形收藏按钮（独立兄弟节点，直接可点）。
        Positioned(
          top: 2,
          right: 2,
          child: selecting
              ? Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 22,
                  color: selected ? Colors.white : Colors.white70,
                )
              : _FavoriteButton(
                  img: img,
                  // 回调链必须完整执行 setFavorite（历史 bug：回调只 _load()
                  // 未写库，导致点击"无效"——实为数据未变，手势一直通畅）。
                  // U-38 D：局部更新单条，不再整页重查重建。
                  onChanged: (fav) => _toggleFavorite(img, fav),
                ),
        ),
      ],
    );
  }

  // ---- 菜单（长按 / 右键） ----
  void _imageMenuAt(
    BuildContext context,
    ImageAsset img,
    Offset? position, {
    bool enteringSelect = false,
  }) {
    // showMenu 坐标相对其弹出 Navigator 的 Overlay；分支壳 Overlay 不含
    // Rail/顶栏，直接用全局坐标会偏移（用户反馈）→ 用根 Overlay 换算。
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox;
    final menuPosition = position == null
        ? RelativeRect.fill
        : RelativeRect.fromRect(
            overlay.globalToLocal(position) & const Size(8, 8),
            Offset.zero & overlay.size,
          );
    showMenu<String>(
      context: context,
      useRootNavigator: true,
      position: menuPosition,
      items: [
        const PopupMenuItem(value: 'preview', child: Text('预览')),
        const PopupMenuItem(value: 'edit', child: Text('用此图继续编辑')),
        PopupMenuItem(value: 'fav', child: Text(img.favorite ? '取消收藏' : '收藏')),
        const PopupMenuItem(value: 'select', child: Text('进入多选')),
        const PopupMenuItem(value: 'delete', child: Text('删除…')),
      ],
    ).then((v) {
      if (v == null || !mounted) return;
      switch (v) {
        case 'preview':
          _open(img);
        case 'edit':
          _continueEdit(img);
        case 'fav':
          _toggleFavorite(img, !img.favorite);
        case 'select':
          setState(() => _selected.add(img.id));
        case 'delete':
          _confirmDelete([img.id]);
      }
    });
  }

  void _continueEdit(ImageAsset img) {
    ref
        .read(studioImportProvider.notifier)
        .request(
          StudioImport(
            refImagePaths: [img.filePath],
            prompt: img.promptSnapshot,
            params: _safeParams(img),
            token: 0,
          ),
        );
    context.go('/studio');
  }

  ParamSnapshot? _safeParams(ImageAsset img) {
    if (img.paramsSnapshotJson == null) return null;
    try {
      return ParamSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(img.paramsSnapshotJson!) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  // ---- 多选操作栏 ----

  Widget _selectionBar(AppDensity d) {
    return SafeArea(
      child: Container(
        height: 60,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: _selected.isEmpty
                  ? null
                  : () {
                      final dao = ref.read(appServicesProvider).images;
                      for (final id in _selected) {
                        dao.setFavorite(id, true);
                      }
                      _load();
                    },
              icon: const Icon(Icons.star, size: 16),
              label: const Text('收藏'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
              onPressed: _selected.isEmpty
                  ? null
                  : () => _confirmDelete(_selected.toList()),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除…'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _selected.clear()),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(List<String> ids) async {
    final isAndroid = Platform.isAndroid;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: Text('删除 ${ids.length} 张图片？'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('仅删记录：保留文件；记录+文件：同时删除本地文件。'),
              if (isAndroid)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '注意：已保存到系统相册的副本不受影响，需在相册中手动删除。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'record'),
            child: const Text('仅删记录'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'file'),
            child: const Text('记录+文件'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final dao = ref.read(appServicesProvider).images;
    for (final id in ids) {
      final asset = await dao.byId(id);
      if (choice == 'file' && asset != null) {
        for (final p in [
          asset.filePath,
          if (asset.thumbPath != null) asset.thumbPath!,
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      await dao.delete(id);
    }
    // 图片库变更信号（2026-11-17）：创作页「最近作品」/预览面板立即重载，
    // 否则刚删的图仍显示在创作页（点击只剩转圈，文件已不存在）。
    ref.read(imagesChangedTickProvider.notifier).bump();
    await _load();
  }

  // ---- 工具 ----

  void _open(ImageAsset img) {
    final ids = _images.map((e) => e.id).toList();
    context.push(
      '/preview',
      extra: PreviewArgs(
        ids: ids,
        startIndex: ids.indexOf(img.id).clamp(0, ids.length - 1),
      ),
    );
  }

  List<_MonthGroup> _groupByMonth(List<ImageAsset> images) {
    final fmt = DateFormat('yyyy 年 MM 月');
    final groups = <String, _MonthGroup>{};
    for (final img in images) {
      final key = DateFormat('yyyy-MM')
          .format(DateTime.fromMillisecondsSinceEpoch(img.createdAt));
      groups
          .putIfAbsent(
            key,
            () => _MonthGroup(
              fmt.format(DateTime.fromMillisecondsSinceEpoch(img.createdAt)),
            ),
          )
          .items
          .add(img);
    }
    return groups.values.toList();
  }
}

class _MonthGroup {
  _MonthGroup(this.month);
  final String month;
  final List<ImageAsset> items = [];
}

/// 缩略图右上角心形收藏按钮（用户三轮反馈后最简实现）：
/// 裸 GestureDetector(opaque) + Container，无 IconButton/Tooltip/InkWell
/// 任何中间层——作为瓦片 Stack 的兄弟节点，tap 命中即触发，行为零不确定性。
class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.img, required this.onChanged});

  final ImageAsset img;
  final void Function(bool favorite) onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!img.favorite),
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Colors.black38,
          shape: BoxShape.circle,
        ),
        child: Icon(
          img.favorite ? Icons.favorite : Icons.favorite_border,
          size: 17,
          color: img.favorite ? Colors.pinkAccent : Colors.white,
        ),
      ),
    );
  }
}

/// 落盘后触发画廊刷新（桥接：orchestrator 终态变化 → gallery 重载）；
/// 备份恢复完成（dataImportTick）同样触发——恢复批量改库后常驻的画廊
/// State 必须重查库，否则恢复内容要重启才可见。
final _galleryRefreshProvider = Provider<int>((ref) {
  final done = ref.watch(orchestratorDoneTickProvider);
  final imported = ref.watch(dataImportTickProvider);
  return Object.hash(done, imported);
});
