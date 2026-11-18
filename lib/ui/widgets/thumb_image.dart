import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// 缩略图瓦片（性能版，U-38）：优先加载 thumbPath；缺失或加载失败时回退
/// **原图 + cacheWidth 降采样**——绝不全尺寸解码（4K 原图 ≈33MB 位图/张，
/// 默认 ImageCache 100MB 下 3 张即触顶，滚动持续驱逐重解码 = 画廊卡顿主因）。
///
/// cacheWidth 默认 512：格子实际显示 ~110~240px，2 倍像素密度下 512 足够。
class ThumbImage extends StatefulWidget {
  const ThumbImage({
    super.key,
    required this.filePath,
    this.thumbPath,
    this.cacheWidth = 512,
    this.fit = BoxFit.cover,
    this.errorPlaceholder = const ColoredBox(
      color: Colors.black12,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    ),
  });

  final String filePath;
  final String? thumbPath;
  final int cacheWidth;
  final BoxFit fit;
  final Widget errorPlaceholder;

  @override
  State<ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<ThumbImage> {
  bool _thumbFailed = false;

  @override
  void didUpdateWidget(covariant ThumbImage old) {
    super.didUpdateWidget(old);
    // 路径变化（如补建缩略图完成后 thumbPath 更新）→ 重置回退标记。
    if (old.thumbPath != widget.thumbPath || old.filePath != widget.filePath) {
      _thumbFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final useThumb =
        widget.thumbPath != null &&
        widget.thumbPath!.isNotEmpty &&
        !_thumbFailed;
    return Image.file(
      File(useThumb ? widget.thumbPath! : widget.filePath),
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) {
        if (useThumb) {
          // thumb 文件损坏/缺失（如跨设备恢复）：下一帧起改走原图降采样。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _thumbFailed = true);
          });
          return const ColoredBox(color: Colors.black12);
        }
        return widget.errorPlaceholder;
      },
    );
  }
}
