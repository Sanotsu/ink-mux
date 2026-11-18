import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/screens/debug/debug_page.dart';
import '../ui/screens/gallery/gallery_page.dart';
import '../ui/screens/history/history_page.dart';
import '../ui/screens/preview/preview_page.dart';
import '../ui/screens/settings/providers_page.dart';
import '../ui/screens/settings/settings_page.dart';
import '../ui/screens/studio/studio_page.dart';
import '../ui/screens/tasks/tasks_page.dart';
import '../ui/shell/app_shell.dart';

/// 根导航 key（窗口关闭拦截等非 UI 场景取上下文用）。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 路由（§10.1）：StatefulShellRoute 五分支 + 全屏 /preview（Shell 外，无导航栏）。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/studio',
    routes: [
      // 全屏图片查看器（桌面/移动一致，黑底沉浸式）。
      GoRoute(
        path: '/preview',
        builder: (context, state) {
          final extra = state.extra;
          final args = extra is PreviewArgs
              ? extra
              : const PreviewArgs(ids: <String>[]);
          return PreviewPage(args: args);
        },
      ),
      // 创作历史（跨会话任务存档；任务页 AppBar 入口，Shell 外全屏）。
      GoRoute(path: '/history', builder: (_, _) => const HistoryPage()),
      // 平台管理（设置页入口行拆出，U-36：平台/Key/模型/自定义站统一管理，
      // Shell 外全屏，与 /history 同模式）。
      GoRoute(
        path: '/settings/providers',
        builder: (_, _) => const ProvidersPage(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/studio', builder: (_, _) => const StudioPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/gallery',
                builder: (_, state) => GalleryPage(
                  filterTaskId: state.uri.queryParameters['task'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/tasks', builder: (_, _) => const TasksPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/debug',
                builder: (_, state) =>
                    DebugPage(session: state.uri.queryParameters['session']),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
