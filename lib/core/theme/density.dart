import 'package:material_ui/material_ui.dart';

import '../constants.dart';

/// 双端密度常量（§10.9-A）：移动端紧凑（8dp 边距/40dp 控件/13sp），
/// 桌面端正常密度；一处调整全局生效。
class AppDensity {
  const AppDensity._({
    required this.screenH,
    required this.cardGap,
    required this.cardPadding,
    required this.controlH,
    required this.chipH,
    required this.body,
    required this.title,
    required this.sub,
  });

  /// 屏幕水平边距。
  final double screenH;

  /// 区块 / 卡片间距。
  final double cardGap;

  /// 卡片内边距。
  final double cardPadding;

  /// 按钮 / 输入框高度。
  final double controlH;

  /// chips / 次级按钮高度。
  final double chipH;

  /// 正文字号。
  final double body;

  /// 页面标题字号。
  final double title;

  /// 辅助说明字号。
  final double sub;

  static const AppDensity compact = AppDensity._(
    screenH: 8,
    cardGap: 8,
    cardPadding: 10,
    controlH: 40,
    chipH: 32,
    body: 13,
    title: 15,
    sub: 11,
  );

  static const AppDensity desktop = AppDensity._(
    screenH: 16,
    cardGap: 12,
    cardPadding: 14,
    controlH: 48,
    chipH: 36,
    body: 14,
    title: 17,
    sub: 12,
  );

  /// 按窗口宽度选择密度：<600 紧凑，否则桌面。
  static AppDensity of(BuildContext context) =>
      MediaQuery.sizeOf(context).width < AppBreakpoints.compact
      ? compact
      : desktop;
}
