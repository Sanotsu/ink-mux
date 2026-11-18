import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:nativeapi/nativeapi.dart' as na show Size, WindowManager;

import 'app/bootstrap.dart';
import 'app/providers/app_services.dart';
import 'app/router.dart';
import 'core/theme/app_theme.dart';
import 'data/platform/tray_service.dart';

/// 桌面最小窗口 720×540（用户反馈）：防止缩得过小无法操作。
/// 主窗口在 runner 中已创建，getCurrent 直接取；极早期取不到则首帧后再试。
void _applyDesktopMinSize() {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  void apply() {
    final window = na.WindowManager.instance.getCurrent();
    if (window != null) {
      window.minimumSize = na.Size(width: 720, height: 540);
    }
  }

  apply();
  WidgetsBinding.instance.addPostFrameCallback((_) => apply());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 正式发行版关闭日志输出（U-53）：debugPrint 的默认节流实现不区分构建模式，
  // release 下仍会写 stdout / Android logcat（且携带文件路径、任务参数等调试信息）。
  // 这里在入口统一置空——仅在需要在 release 保留输出时才移除。
  // 注意：覆盖只消除打印 I/O；调用点的字符串拼接仍会发生，热路径日志请另行用 `if (kDebugMode)` 包裹。
  // 全库已无裸 `print()`（会绕过本覆盖）。
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // intl locale 数据初始化（2026-11-16 修复）：intl 仅内置 en_US 数据，
  // DateFormat 显式传 'zh'（用量统计页周几格式）时未初始化会抛 LocaleDataException。
  // 失败不阻塞启动（页面有错误分支兜底）。
  try {
    await initializeDateFormatting('zh');
    Intl.defaultLocale = 'zh';
  } catch (_) {
    // ignore：维持 en_US 默认行为。
  }
  _applyDesktopMinSize();
  final services = await Bootstrap.init();
  // Windows 托盘（M3）：失败降级不阻塞；app_shell 活跃任务变化时同步文案。
  await TrayService.instance.init();
  runApp(
    ProviderScope(
      overrides: [appServicesProvider.overrideWith((ref) => services)],
      child: const InkMuxApp(),
    ),
  );
}

class InkMuxApp extends ConsumerWidget {
  const InkMuxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'InkMux',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
