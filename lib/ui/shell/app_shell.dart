import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nativeapi/nativeapi.dart' as na;

import '../../app/providers/app_services.dart';
import '../../app/providers/guard.dart';
import '../../app/providers/orchestrator.dart';
import '../../app/providers/settings_controller.dart';
import '../../app/router.dart' show rootNavigatorKey;
import '../../core/constants.dart';
import '../../data/notifications/notify_service.dart';
import '../../data/platform/taskbar_progress.dart';
import '../../data/platform/tray_service.dart';
import '../widgets/center_toast.dart';
import '../widgets/guard_overlay.dart';

/// 断点壳（§10.1）：
/// - <600（移动）：Scaffold + BottomNavigationBar ×4，调试日志从"设置"进入；
/// - >=600（桌面）：NavigationRail（>=900 展开文字），5 项含调试；
/// - 全局：任务角标 + 守卫弹窗 Overlay + 生命周期联动轮询 +
///   桌面关闭拦截（在途任务确认，M2）。
///
/// 桌面关闭拦截走 nativeapi 窗口事件模型：WindowCloseRequestedEvent
/// 到达时以 EventRequest.cancel 取消关闭并弹确认。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  /// 主窗口（nativeapi）。
  na.Window? _win;

  /// 主窗口事件监听句柄（关闭拦截用）。
  na.ListenerId? _winListenerId;

  /// 关闭确认弹窗是否已展开（防重复弹出）。
  bool _closeDialogOpen = false;

  /// 侧栏宽度（可拖调节，U-27）：null = 默认 208；范围 64~280。
  /// 收起钮 = 宽度预设切换（72 ↔ 208）；<150 视为收起形态。
  double? _navWidth;
  bool _navDividerHot = false;

  /// Android 上次返回键时刻（双击 2s 内退出，否则提示不退出）。
  DateTime? _lastAndroidBackAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      _attachCloseInterceptor();
      _syncCloseIntercept();
    }
    // 侧栏「调试」入口显隐读 settingsProvider（U-47）：设置页此前从未
    // 打开过时 state 是默认值——启动即加载一次（幂等），否则用户开启
    // 过的入口在冷启动后会消失，直到进设置页才恢复。
    // ⚠️ 必须延后到首帧后（U-48）：load() 读库很快，
    // 首帧构建期内就回写 provider 会触发 riverpod "widget tree was building" 断言（启动报 Unhandled Exception）。
    // post-frame 回调在构建期结束后执行，合法。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(settingsProvider.notifier).load();
    });
    // 首次启动：通知权限先解释用途再申请（U-49），只问一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeAskNotifyPermission();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) _detachCloseInterceptor();
    super.dispose();
  }

  /// 首次启动的通知权限引导（U-49，仅 Android，只问一次）：
  /// 已授权 → 静默跳过；未授权 → 先弹应用内解释（说清通知用途，裸系统
  /// 弹窗没有上下文用户容易直接拒绝），同意才拉系统授权弹窗。
  Future<void> _maybeAskNotifyPermission() async {
    if (!Platform.isAndroid) return;
    final s = ref.read(appServicesProvider);
    if (s.prefs.getBool(PrefKeys.notifyRationaleAsked) ?? false) return;
    await s.prefs.setBool(PrefKeys.notifyRationaleAsked, true);
    if (await NotifyService.androidPermissionGranted()) return;
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开启通知提醒？'),
        content: const SizedBox(
          width: 340,
          child: Text(
            '图片生成 / 编辑完成或失败时提醒你（App 在后台也能收到）。'
            '通知仅用于任务状态，没有任何营销推送；'
            '不开启也不影响正常使用，只是需要自己回到任务页查看结果。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暂不'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去开启'),
          ),
        ],
      ),
    );
    if (go == true) await NotifyService.requestAndroidPermission();
  }

  /// 挂主窗口关闭拦截（M2；nativeapi 事件模型）：窗口关闭是
  /// WindowCloseRequestedEvent + EventRequest，cancel 即拦截。
  void _attachCloseInterceptor() {
    final win = na.WindowManager.instance.getCurrent();
    if (win == null) {
      // 极早期可能取不到主窗口 → 首帧后再试一次（同 main.dart 最小尺寸）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _win == null) _attachCloseInterceptor();
      });
      return;
    }
    _win = win;
    _winListenerId = win.addListener((event) {
      if (event is na.WindowCloseRequestedEvent) _onWindowCloseRequested(event);
    });
  }

  void _detachCloseInterceptor() {
    final id = _winListenerId;
    if (id != null) _win?.removeListener(id);
    _winListenerId = null;
  }

  /// 关闭请求：无在途任务 → 放行（不 cancel，原生默认关闭）；有在途
  /// 任务 → 取消本次关闭 + 弹确认（同步任务结果绑定进程，必须确认）。
  Future<void> _onWindowCloseRequested(
    na.WindowCloseRequestedEvent event,
  ) async {
    final active = ref.read(orchestratorBadgeProvider);
    if (active <= 0) {
      _detachCloseInterceptor();
      return;
    }
    event.request.cancel();
    if (_closeDialogOpen) return;
    _closeDialogOpen = true;
    try {
      _win?.focus();
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        // 无 UI 上下文（极端）：放行退出。
        await _forceCloseWindow();
        return;
      }
      final choice = await showDialog<String>(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          title: const Text('有任务生成中'),
          content: const SizedBox(
            width: 360,
            child: Text('退出后同步任务结果不可恢复（异步任务重新打开 App 会自动续取）。确定退出吗？'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, 'stay'),
              child: const Text('继续运行'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, 'exit'),
              child: const Text('仍然退出'),
            ),
          ],
        ),
      );
      if (choice == 'exit') await _forceCloseWindow();
    } finally {
      _closeDialogOpen = false;
    }
  }

  /// 强制关闭主窗口（绕过关闭拦截）：先摘监听防重入；平台无关窗能力时
  /// 退回进程级退出。
  Future<void> _forceCloseWindow() async {
    _detachCloseInterceptor();
    final win = _win;
    if (win != null && na.Window.isCloseSupported()) {
      win.close();
      return;
    }
    na.Application.instance.quit(0);
  }

  /// 在途任务数变化 → 托盘/任务栏同步（M3）。关闭拦截由窗口事件实时
  /// 判定（见 _onWindowCloseRequested），无需在此开关。
  void _syncCloseIntercept() {
    final active = ref.read(orchestratorBadgeProvider);
    // 托盘 tooltip / 菜单文案。
    TrayService.instance.updateActiveCount(active);
    // 任务栏进度：有活跃任务显示已完成图数比例；无则清除。
    if (active <= 0) {
      TaskbarProgress.clear();
    } else {
      final state = ref.read(orchestratorProvider);
      final actives = state.tasks.values.where((t) => t.isActive).toList();
      var done = 0;
      var total = 0;
      for (final t in actives) {
        done += t.doneImages;
        total += t.n;
      }
      if (total > 0) {
        TaskbarProgress.value(done, total);
      } else {
        TaskbarProgress.indeterminate();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台：立即补一轮 poll（§7.6）。
    if (state == AppLifecycleState.resumed) {
      ref.read(orchestratorProvider.notifier).onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final guardOpen = ref.watch(guardOpenProvider);

    // 活跃任务数变化 → 同步关闭拦截与任务栏进度。
    ref.listenManual(
      orchestratorBadgeProvider,
      (_, _) => _syncCloseIntercept(),
    );
    // 落盘完成 tick：doneImages 累计后任务栏比例随之刷新。
    ref.listenManual(
      orchestratorProvider.select(
        (s) => s.tasks.values.fold<int>(0, (acc, t) => acc + t.doneImages),
      ),
      (_, _) => _syncCloseIntercept(),
    );

    Widget body = width < AppBreakpoints.compact
        ? _mobileScaffold(context)
        : _desktopScaffold(context);

    return Stack(children: [body, if (guardOpen) const GuardOverlay()]);
  }

  Widget _mobileScaffold(BuildContext context) {
    final activeCount = ref.watch(orchestratorBadgeProvider);
    Widget scaffold = Scaffold(
      body: widget.navigationShell,
      // 紧凑高度 64（默认 80）：为内容让出纵向空间（§10.3 移动端优化）。
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: _mobileIndex(widget.navigationShell.currentIndex),
        onDestinationSelected: (i) => _goMobile(i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.palette_outlined, size: 22),
            selectedIcon: Icon(Icons.palette, size: 22),
            label: '创作',
          ),
          const NavigationDestination(
            icon: Icon(Icons.photo_library_outlined, size: 22),
            selectedIcon: Icon(Icons.photo_library, size: 22),
            label: '画廊',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.playlist_add_check_outlined, size: 22),
            ),
            selectedIcon: const Icon(Icons.playlist_add_check, size: 22),
            label: '任务',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline, size: 22),
            selectedIcon: Icon(Icons.person, size: 22),
            label: '设置',
          ),
        ],
      ),
    );
    // Android 系统返回键：主页不直接退出，2s 内双击才退出（常规 App 语义）。
    if (Platform.isAndroid) {
      scaffold = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          final now = DateTime.now();
          if (_lastAndroidBackAt != null &&
              now.difference(_lastAndroidBackAt!) <
                  const Duration(seconds: 2)) {
            SystemNavigator.pop();
          } else {
            _lastAndroidBackAt = now;
            showCenterToast(context, '再按一次返回键退出');
          }
        },
        child: scaffold,
      );
    }
    return scaffold;
  }

  Widget _desktopScaffold(BuildContext context) {
    final activeCount = ref.watch(orchestratorBadgeProvider);
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= AppBreakpoints.wide;
    // 侧栏宽度可拖（U-27）：64~280；收起钮为预设切换（72 ↔ 208）。
    // <900 窗口强制 72 窄形态。布局形态按宽度阈值切换（无动画——历史
    // bug：AnimatedContainer 宽度动画时展开态品牌行在窄宽度下 overflow）。
    const minNav = 64.0;
    const maxNav = 280.0;
    final navW = isWide ? (_navWidth ?? 208).clamp(minNav, maxNav) : 72.0;
    final collapsed = !isWide || navW < 150;
    final cs = Theme.of(context).colorScheme;
    final current = widget.navigationShell.currentIndex;
    // 「调试」入口默认隐藏，设置 → 调试「显示调试页入口」开启后才出现。
    final debugEntry = ref.watch(
      settingsProvider.select((s) => s.debugPageEntry),
    );
    final navItems = [
      for (final item in _navItems)
        if (item.branch != 3 || debugEntry) item,
    ];

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: navW,
            color: cs.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brandHeader(context, collapsed: collapsed, isWide: isWide),
                ...List.generate(navItems.length, (i) {
                  final item = navItems[i];
                  return _navTile(
                    context,
                    item: item,
                    selected: current == item.branch,
                    collapsed: collapsed,
                    badge: item.branch == 2 && activeCount > 0
                        ? activeCount
                        : null,
                    onTap: () => _goBranch(item.branch),
                  );
                }),
                const Spacer(),
                if (!collapsed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'InkMux',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isWide) _navResizeDivider(minNav, maxNav),
          Container(width: 1, color: cs.outlineVariant),
          Expanded(child: widget.navigationShell),
        ],
      ),
    );
  }

  /// 侧栏右缘拖动分隔条（与创作面板分隔条同款交互）：
  /// 命中区 8 宽，视觉 1px 线，hover/拖动时 3px 主色 + 微高亮底。
  Widget _navResizeDivider(double minNav, double maxNav) {
    final cs = Theme.of(context).colorScheme;
    final hot = _navDividerHot;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _navDividerHot = true),
      onExit: (_) => setState(() => _navDividerHot = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _navDividerHot = true),
        onHorizontalDragUpdate: (details) {
          setState(() {
            _navWidth = ((_navWidth ?? 208) + details.delta.dx).clamp(
              minNav,
              maxNav,
            );
          });
        },
        onHorizontalDragEnd: (_) => setState(() => _navDividerHot = false),
        onHorizontalDragCancel: () => setState(() => _navDividerHot = false),
        child: Container(
          width: 8,
          color: hot ? cs.primary.withValues(alpha: 0.15) : null,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Center(
            child: Container(
              width: hot ? 2 : 1,
              color: hot ? cs.primary : cs.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }

  // 侧栏导航数据（分支索引与 §10.1 一致：0 创作画布壳）。
  static const List<_NavItem> _navItems = [
    _NavItem(Icons.palette_outlined, Icons.palette, '创作', 0),
    _NavItem(Icons.photo_library_outlined, Icons.photo_library, '画廊', 1),
    _NavItem(
      Icons.playlist_add_check_outlined,
      Icons.playlist_add_check,
      '任务',
      2,
    ),
    _NavItem(Icons.bug_report_outlined, Icons.bug_report, '调试', 3),
    _NavItem(Icons.settings_outlined, Icons.settings, '设置', 4),
  ];

  /// 品牌行：展开态 = logo + 标题；收起态 = 仅 logo。宽度由拖动分隔条
  /// 调节（64~280，<150 为收起形态），无独立收起按钮（避免与拖动重复）。
  Widget _brandHeader(
    BuildContext context, {
    required bool collapsed,
    required bool isWide,
  }) {
    // 品牌图标 = 应用真图标（assets/icon/app_icon.png，与 exe/Android 同源
    // 2026-11-15 用户指出占位画笔图标不对）；圆角裁切与原占位观感一致。
    Widget logoBox({double size = 30}) => ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Center(child: logoBox(size: 28)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Row(
        children: [
          logoBox(),
          const SizedBox(width: 10),
          const Text(
            'InkMux',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  /// 导航项：展开态 = 行式（icon+label+badge）；收起态 = 居中图标 + tooltip。
  Widget _navTile(
    BuildContext context, {
    required _NavItem item,
    required bool selected,
    required bool collapsed,
    int? badge,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    Widget iconWidget({double size = 20}) => badge != null
        ? Badge(
            isLabelVisible: true,
            label: Text(
              '$badge',
              style: const TextStyle(
                fontSize: 9,
                height: 1,
                color: Colors.white,
              ),
            ),
            backgroundColor: cs.error,
            child: Icon(
              selected ? item.selectedIcon : item.icon,
              size: size,
              color: iconColor,
            ),
          )
        : Icon(
            selected ? item.selectedIcon : item.icon,
            size: size,
            color: iconColor,
          );

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: Tooltip(
            message: item.label,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Container(
                width: 48,
                height: 40,
                decoration: BoxDecoration(
                  color: selected ? cs.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(child: iconWidget()),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? cs.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              iconWidget(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? cs.onSecondaryContainer : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 桌面 5 分支直接映射。
  void _goBranch(int index) => widget.navigationShell.goBranch(
    index,
    initialLocation: index == widget.navigationShell.currentIndex,
  );

  // 移动 4 Tab → 分支索引（0,1,2,4）。
  static const List<int> _mobileBranches = [0, 1, 2, 4];

  int _mobileIndex(int branchIndex) {
    // /debug（分支3）从"设置"进入，保持"设置"高亮。
    if (branchIndex == 3) return 3;
    final i = _mobileBranches.indexOf(branchIndex);
    return i < 0 ? 0 : i;
  }

  void _goMobile(int mobileIndex) {
    final target = _mobileBranches[mobileIndex];
    widget.navigationShell.goBranch(
      target,
      initialLocation: target == widget.navigationShell.currentIndex,
    );
  }
}

/// 侧栏导航项数据。
class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label, this.branch);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int branch;
}
