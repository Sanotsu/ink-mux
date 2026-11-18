import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// 居中轻提示：Overlay 层浮出（不依赖三方 toast 库），淡入 → 停留
/// 1.4s → 淡出后自动移除。Android「再按一次退出」等全局提示用。
void showCenterToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) =>
        _CenterToastView(message: message, onDismiss: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _CenterToastView extends StatefulWidget {
  const _CenterToastView({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  State<_CenterToastView> createState() => _CenterToastViewState();
}

class _CenterToastViewState extends State<_CenterToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _hold = Timer(const Duration(milliseconds: 1500), () async {
      await _c.reverse();
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        // 全屏命中穿透：toast 不挡交互。
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
              child: Align(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 96),
                  child: Material(
                    color: cs.inverseSurface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: cs.onInverseSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
