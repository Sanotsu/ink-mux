import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:go_router/go_router.dart';
import 'package:nativeapi/nativeapi.dart' as na;
import 'package:path_provider/path_provider.dart';

import '../../app/router.dart' show rootNavigatorKey;

/// Windows 托盘（M3）：图标 + 右键菜单 + 左键唤起主窗口。
///
/// 依赖现状（任务清单 M3 评估结论）：
/// - nativeapi 0.5.10 自带 TrayIcon/Menu 原生绑定，零新增依赖；
/// - tray_manager 0.9.0 需 Flutter 3.50/Dart 3.14，等 SDK 升级后再迁移。
class TrayService {
  TrayService._();

  static TrayService? _instance;

  /// 惰性单例（main 初始化；未 init 前调用 update 为 no-op）。
  static TrayService get instance => _instance ??= TrayService._();

  na.TrayIcon? _icon;
  int _activeCount = 0;
  bool _initialized = false;

  bool get _supported => Platform.isWindows;

  Future<void> init() async {
    if (_initialized || !_supported) return;
    _initialized = true;
    try {
      final iconPath = await _ensureIconFile();
      final icon = na.TrayIcon.create();
      if (icon == null) return;
      _icon = icon;
      // GC 警示：TrayIcon 由 finalizer 管理原生句柄，必须长期持有引用
      //（本类字段持有），否则托盘图标会随回收消失。
      icon.icon = na.Image.fromFile(iconPath);
      icon.setTooltip('InkMux');
      icon.setContextMenuTrigger(na.ContextMenuTrigger.rightClicked);
      icon.addListener((event) {
        // 左键/双击唤起主窗口；右键由系统按 trigger 弹出菜单。
        if (event is na.TrayIconClickedEvent ||
            event is na.TrayIconDoubleClickedEvent) {
          _showMainWindow();
        }
      });
      await _rebuildMenu();
      icon.setVisible(true);
    } catch (_) {
      // 托盘初始化失败不影响主流程（功能降级为无托盘）。
    }
  }

  /// 活跃任务数变化 → tooltip 与菜单文案同步（app_shell 调用）。
  void updateActiveCount(int count) {
    if (!_initialized || _icon == null || count == _activeCount) return;
    _activeCount = count;
    _icon!.setTooltip(count > 0 ? 'InkMux（$count 个任务进行中）' : 'InkMux');
    unawaited(_rebuildMenu());
  }

  Future<void> _rebuildMenu() async {
    final icon = _icon;
    if (icon == null) return;
    final menu = na.Menu.create();
    if (menu == null) return;

    final showItem = na.MenuItem.createWithLabelAndType(
      '显示主窗口',
      na.MenuItemType.normal,
    );
    if (showItem != null) {
      showItem.addListener((event) {
        if (event is na.MenuItemClickedEvent) _showMainWindow();
      });
      menu.addItem(showItem);
    }

    final tasksItem = na.MenuItem.createWithLabelAndType(
      _activeCount > 0 ? '任务（$_activeCount 个进行中）' : '任务管理',
      na.MenuItemType.normal,
    );
    if (tasksItem != null) {
      tasksItem.addListener((event) {
        if (event is na.MenuItemClickedEvent) {
          _showMainWindow();
          _navigate('/tasks');
        }
      });
      menu.addItem(tasksItem);
    }

    menu.addSeparator();

    final exitItem = na.MenuItem.createWithLabelAndType(
      '退出 InkMux',
      na.MenuItemType.normal,
    );
    if (exitItem != null) {
      exitItem.addListener((event) {
        if (event is na.MenuItemClickedEvent) {
          // 走主窗口 close 事件 → 由 app_shell 关闭拦截统一处理（有在途
          // 任务时弹确认）；取不到窗口/平台不支持关窗时进程级退出兜底。
          final win = na.WindowManager.instance.getCurrent();
          if (win != null && na.Window.isCloseSupported()) {
            win.close();
          } else {
            na.Application.instance.quit(0);
          }
        }
      });
      menu.addItem(exitItem);
    }

    icon.setContextMenu(menu);
  }

  void _showMainWindow() {
    unawaited(() async {
      final win = na.WindowManager.instance.getCurrent();
      win?.show();
      win?.focus();
    }());
  }

  /// 托盘菜单无 Widget 上下文，借根导航器 context 做 go_router 跳转。
  void _navigate(String location) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      GoRouter.of(ctx).go(location);
    }
  }

  /// assets 图标落盘为临时文件（nativeapi Image.fromFile 需要真实路径）。
  Future<String> _ensureIconFile() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}tray_icon.png',
    );
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/tray/tray_icon.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return file.path;
  }
}
