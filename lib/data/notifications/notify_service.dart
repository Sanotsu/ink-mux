import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 任务完成/失败本地通知（M2）：App 不在前台时提醒；Android/Windows 支持。
class NotifyService {
  NotifyService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _ready = false;
  static int _seq = 0;

  static Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      if (Platform.isAndroid) {
        const androidInit = AndroidInitializationSettings(
          '@mipmap/ic_launcher',
        );
        await _plugin.initialize(
          settings: const InitializationSettings(android: androidInit),
        );
        // Android 13+ 通知权限：不在 init 直接申请（U-49）——裸系统弹窗
        // 无用途说明，用户容易直接拒绝。改为首次启动先弹应用内解释
        // （app_shell._maybeAskNotifyPermission），同意后才调
        // [requestAndroidPermission]。
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            'inkmux_tasks',
            '生成任务',
            description: '图片生成 / 编辑任务完成与失败提醒',
            importance: Importance.defaultImportance,
          ),
        );
      } else if (Platform.isWindows) {
        const windowsInit = WindowsInitializationSettings(
          appName: 'InkMux',
          appUserModelId: 'com.inkmux.app',
          guid: '7f6e5d4c-3b2a-4918-a876-5c4b3a2d1e0f',
        );
        await _plugin.initialize(
          settings: const InitializationSettings(windows: windowsInit),
        );
      }
      _ready = true;
    } catch (e) {
      debugPrint('[Notify] init failed: $e');
    }
  }

  /// Android 通知权限当前是否已授权（其他平台恒 true）。
  /// 查询失败按已授权处理（避免误弹解释弹窗打扰）。
  static Future<bool> androidPermissionGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Android 通知权限申请（U-49：调用前应先展示应用内用途解释）。
  static Future<void> requestAndroidPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[Notify] requestPermission failed: $e');
    }
  }

  /// 任务终态通知（调用方保证前台判断）。
  static Future<void> showTaskDone({
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    final id = _seq++ % 0x7fffffff;
    try {
      if (Platform.isAndroid) {
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'inkmux_tasks',
              '生成任务',
              channelDescription: '图片生成 / 编辑任务完成与失败提醒',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
            ),
          ),
        );
      } else if (Platform.isWindows) {
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            windows: WindowsNotificationDetails(),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Notify] show failed: $e');
    }
  }
}
