import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:uuid/uuid.dart';

import '../../core/error/app_exception.dart';
import '../../domain/entities/image_asset.dart';
import '../../domain/values/enums.dart';
import '../adapters/adapter.dart';
import '../db/daos/image_dao.dart';
import '../network/dio_hub.dart';

/// 结果落盘（§8）：双通道解析（P6）→ 写文件 → 缩略图 → 入库 →（Android 入相册）。
class ImageStore {
  ImageStore(this.dioHub, this.imageDao);

  final DioHub dioHub;
  final ImageDao imageDao;

  static const Uuid _uuid = Uuid();
  static const int thumbSize = 256;

  /// 逐张落盘；全部成功才返回（引擎再标 succeeded）。
  ///
  /// 双通道以**实际响应**为准（P6）：平台可能无视 response_format——
  /// b64_json 为纯 base64 或整个 data URI；url 字段也可能直接是 data URI。
  Future<List<ImageAsset>> persist({
    required String taskId,
    required String sessionId,
    required ImagePayload payload,
    required String prompt,
    required String paramsJson,
    void Function(int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final assets = <ImageAsset>[];
    final items = payload.items;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final seq = i + 1;
      final resolved = await _resolveBytes(item, sessionId, taskId, cancel);
      final ext = _pickExt(item, resolved.mimeType);
      final fileName = _fileName(taskId, seq, ext);
      final filePath = await _writeMaster(resolved.bytes, fileName);
      final thumbPath = await _writeThumb(taskId, seq, resolved.bytes);
      final (w, h) = await _measure(resolved.bytes);
      final asset = ImageAsset(
        id: _uuid.v4(),
        taskId: taskId,
        seq: seq,
        filePath: filePath,
        thumbPath: thumbPath,
        width: w,
        height: h,
        bytes: resolved.bytes.length,
        format: ext,
        channel: resolved.channel,
        promptSnapshot: item.revisedPrompt ?? prompt,
        paramsSnapshotJson: paramsJson,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await imageDao.insert(asset);
      assets.add(asset);
      if (Platform.isAndroid) {
        await _saveToGallery(resolved.bytes, fileName);
      }
      onProgress?.call(i + 1, items.length);
    }
    return assets;
  }

  // ---- 三态解析（§8.1） ----

  /// data URI 剥离：`data:image/png;base64,xxxx` → (bytes, mime)。
  /// 无法解析返回 null。
  static (Uint8List, String?)? decodeDataUri(String uri) {
    final match = RegExp(
      r'^data:([^;,]+);base64,(.*)$',
      dotAll: true,
    ).firstMatch(uri);
    if (match == null) return null;
    try {
      return (base64Decode(match.group(2)!), match.group(1));
    } on FormatException {
      return null;
    }
  }

  Future<_Resolved> _resolveBytes(
    ImageItem item,
    String sessionId,
    String taskId,
    CancelToken? cancel,
  ) async {
    final url = item.url;
    final b64 = item.b64Json;

    // ① data URI（url 或 b64_json 字段都可能出现）→ 直接解码。
    if (url != null && url.startsWith('data:')) {
      final decoded = decodeDataUri(url);
      if (decoded != null) {
        return _Resolved(
          decoded.$1,
          ResultChannel.b64,
          decoded.$2 ?? item.mimeType,
        );
      }
    }
    if (b64 != null && b64.startsWith('data:')) {
      final decoded = decodeDataUri(b64);
      if (decoded != null) {
        return _Resolved(
          decoded.$1,
          ResultChannel.b64,
          decoded.$2 ?? item.mimeType,
        );
      }
    }
    // ② b64_json 纯 base64 → 解码。
    if (b64 != null && b64.isNotEmpty) {
      try {
        return _Resolved(base64Decode(b64), ResultChannel.b64, item.mimeType);
      } on FormatException {
        // 非法 base64 且存在 url → 回退下载；否则报错。
        final isHttpUrl =
            url != null &&
            (url.startsWith('http://') || url.startsWith('https://'));
        if (!isHttpUrl) {
          throw LocalIoException('b64_json 不是有效 base64（长度 ${b64.length}）');
        }
      }
    }
    // ③ http(s) url → 下载。
    if (url != null &&
        (url.startsWith('http://') || url.startsWith('https://'))) {
      final bytes = await _download(url, sessionId, taskId, cancel);
      return _Resolved(bytes, ResultChannel.url, item.mimeType);
    }
    throw EmptyResultException('响应图片字段无法解析（既非 base64/data URI 也非 http url）');
  }

  /// 下载走 DioHub（session 注入 → 调试日志全链路记录），失败重试 ≤3。
  Future<Uint8List> _download(
    String url,
    String sessionId,
    String taskId,
    CancelToken? cancel,
  ) async {
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final resp = await dioHub.dio.get<List<int>>(
          url,
          options: DioHub.options(
            session: sessionId,
            taskId: taskId,
            receiveTimeout: DioHub.downloadReceive,
            responseType: ResponseType.bytes,
            contentType: null,
          ),
          cancelToken: cancel,
        );
        return Uint8List.fromList(resp.data!);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        lastErr = e;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    throw UpstreamException(
      '结果图下载失败（预签名链接可能过期，可"重试保存"重新取链）：$lastErr',
      retryable: true,
    );
  }

  // ---- 文件 ----

  String _pickExt(ImageItem item, [String? resolvedMime]) {
    final mime = (resolvedMime ?? item.mimeType)?.toLowerCase();
    if (mime != null) {
      if (mime.contains('png')) return 'png';
      if (mime.contains('webp')) return 'webp';
      if (mime.contains('jpeg') || mime.contains('jpg')) return 'jpeg';
    }
    final url = item.url;
    if (url != null) {
      final path = Uri.tryParse(url)?.path ?? '';
      final dot = path.lastIndexOf('.');
      if (dot >= 0 && path.length - dot <= 5) {
        final ext = path.substring(dot + 1).toLowerCase();
        if ({'png', 'jpeg', 'jpg', 'webp'}.contains(ext)) {
          return ext == 'jpg' ? 'jpeg' : ext;
        }
      }
    }
    return 'png';
  }

  /// INK_{yyyyMMdd}_{HHmmss}_{taskId前8位}_{seq}.{ext}（§8.3）。
  String _fileName(String taskId, int seq, String ext) {
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    return 'INK_${stamp}_${taskId.substring(0, 8)}_$seq.$ext';
  }

  Future<String> _writeMaster(List<int> bytes, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final month = DateFormat('yyyy-MM').format(DateTime.now());
    final target = Directory(path.join(dir.path, 'InkMux', 'images', month));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final file = File(path.join(target.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<String?> _writeThumb(String taskId, int seq, List<int> bytes) async {
    File? out;
    try {
      final dir = await getApplicationSupportDirectory();
      final thumbDir = Directory(path.join(dir.path, 'cache', 'thumbs'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      out = File(path.join(thumbDir.path, '${taskId}_$seq.jpg'));
      Uint8List result;
      if (Platform.isWindows || Platform.isLinux) {
        // flutter_image_compress 联邦插件族无 Windows/Linux 实现（压缩会抛
        // MissingPluginException，历史上被静默吞掉 → Windows 缩略图从未
        // 生成过，画廊全量解码原图卡顿，U-38）——dart:ui 降采样兜底：
        // 引擎线程异步解码缩尺寸，PNG 256px 仅几十 KB，不卡 UI。
        result = await _thumbViaUiCodec(bytes);
      } else {
        result = await FlutterImageCompress.compressWithList(
          Uint8List.fromList(bytes),
          minHeight: thumbSize,
          minWidth: thumbSize,
          quality: 80,
          format: CompressFormat.jpeg,
        );
      }
      await out.writeAsBytes(result, flush: true);
      return out.path;
    } catch (e) {
      // 缩略图失败不阻断主流程，画廊回退原图降采样；但不再静默（可诊断）。
      debugPrint('[Thumb] 生成失败 ${out?.path ?? taskId}: $e');
      return null;
    }
  }

  /// dart:ui 降采样缩略图（Windows/Linux 兜底）：targetWidth 单边指定时
  /// 保持宽高比；解码与编码均在引擎线程异步执行。
  Future<Uint8List> _thumbViaUiCodec(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(bytes),
      targetWidth: thumbSize,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (data == null) {
      throw StateError('缩略图编码返回空数据');
    }
    return data.buffer.asUint8List();
  }

  /// 存量缩略图补建（U-38 A+）：为 thumbPath 为空的历史图/恢复备份图
  /// 逐张重建。调用方控制节奏（顺序执行 + 让出 UI），完成后刷新画廊。
  /// 返回成功补建的条数。
  Future<int> backfillThumbs(List<ImageAsset> assets) async {
    var ok = 0;
    for (final a in assets) {
      try {
        final f = File(a.filePath);
        if (!await f.exists()) continue;
        // 缩略图文件名优先 taskId，「无任务图」（task_id NULL）回退资产 id。
        final thumb = await _writeThumb(
          a.taskId ?? a.id,
          a.seq,
          await f.readAsBytes(),
        );
        if (thumb == null) continue;
        await imageDao.setThumbPath(a.id, thumb);
        ok++;
        // 逐张让出一帧，避免长任务占住 UI 管线。
        await Future<void>.delayed(const Duration(milliseconds: 4));
      } catch (_) {
        // 单张失败跳过，不中断整批。
      }
    }
    return ok;
  }

  Future<(int?, int?)> _measure(List<int> bytes) async {
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(Uint8List.fromList(bytes), completer.complete);
      final image = await completer.future;
      final w = image.width;
      final h = image.height;
      image.dispose();
      return (w, h);
    } catch (_) {
      return (null, null);
    }
  }

  Future<void> _saveToGallery(List<int> bytes, String fileName) async {
    try {
      // saver_gallery 5.x：albumPath 为相册层级名（Android 解析为 Pictures/InkMux）。
      await SaverGallery.saveImage(
        Uint8List.fromList(bytes),
        fileName: fileName,
        albumPath: 'InkMux',
        skipIfExists: false,
      );
    } catch (_) {
      // 相册保存失败不阻断（文件与画廊记录已成功）。
    }
  }
}

/// 单张解析结果。
class _Resolved {
  const _Resolved(this.bytes, this.channel, [this.mimeType]);
  final Uint8List bytes;
  final ResultChannel channel;
  final String? mimeType;
}
