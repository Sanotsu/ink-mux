import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 任务栏进度（M3）。
///
/// nativeapi 0.5.10/0.6.0 均无 ITaskbarList3 绑定（评估结论，任务清单 M3），
/// 由自写 runner method channel `inkmux/taskbar` 提供（flutter_window.cpp）。
/// 非 Windows 平台全部 no-op。
///
/// 当前 Dart 侧仅使用 none/indeterminate/normal 三态（App 语义够用）；
/// runner C++ 侧已实现 error/paused 全五态映射，属预留通道，暂无调用方。
class TaskbarProgress {
  TaskbarProgress._();

  static const MethodChannel _channel = MethodChannel('inkmux/taskbar');

  static bool get _supported => Platform.isWindows;

  /// 清除进度（无活跃任务）。
  static void clear() => _set('none', 0, 0);

  /// 不确定进度（绿色循环动画；活跃但无可量化比例）。
  static void indeterminate() => _set('indeterminate', 0, 0);

  /// 数值进度（done/total，clamp 由 C++ 侧处理）。
  static void value(int done, int total) => _set('normal', done, total);

  static void _set(String state, int value, int total) {
    if (!_supported) return;
    // fire-and-forget：进度是纯视觉反馈，失败静默（runner 降级路径返回成功）。
    unawaited(
      _channel.invokeMethod<void>('setProgress', {
        'state': state,
        'value': value,
        'total': total,
      }),
    );
  }
}
