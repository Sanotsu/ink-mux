import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/util/convert.dart';
import '../../domain/entities/app_task.dart';
import '../../domain/entities/image_asset.dart';
import '../../domain/entities/provider_config.dart';
import '../../domain/entities/prompt_template.dart';
import '../../app/providers/app_services.dart';

/// 备份进度（phase 文案 + 计数；total=0 表示不定进度）。
class BackupProgress {
  const BackupProgress(this.phase, {this.done = 0, this.total = 0});

  final String phase;
  final int done;
  final int total;

  double? get value => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// 恢复结果摘要（跳过语义：已存在同 id/同标识的数据一律跳过不覆盖）。
class BackupResult {
  const BackupResult({
    required this.providersAdded,
    required this.providersSkipped,
    required this.templatesAdded,
    required this.templatesSkipped,
    required this.tasksImported,
    required this.tasksSkipped,
    required this.imagesImported,
    required this.imagesSkipped,
    required this.missingFiles,
  });

  final int providersAdded;
  final int providersSkipped;
  final int templatesAdded;
  final int templatesSkipped;
  final int tasksImported;
  final int tasksSkipped;
  final int imagesImported;
  final int imagesSkipped;
  final int missingFiles;

  String get summary =>
      '平台：新增 $providersAdded / 跳过 $providersSkipped\n'
      '模板：新增 $templatesAdded / 跳过 $templatesSkipped\n'
      '任务：导入 $tasksImported / 跳过 $tasksSkipped\n'
      '图片：导入 $imagesImported / 跳过 $imagesSkipped\n'
      '源文件缺失：$missingFiles 条（已跳过，避免死记录）';
}

/// 数据备份/恢复（zip 资源包）：元数据 JSON + 原图文件。
///
/// 包结构（zip 条目路径按规范永远 '/' 分隔）：
/// ```
/// manifest.json / prefs.json / providers.json / templates.json
/// tasks.json / images.json / files/images/<yyyy-MM>/<文件名>
/// ```
/// 明确不含：api_keys（secure storage 系统级密文不可导出）、debug_logs（环形临时日志）、
/// 缩略图（cache 性质，可从原图重建，恢复后按需重生成）。
///
/// 路径策略：导出时 file_path 记**相对路径**（InkMux/images/ 之后段，'/' 分隔），
/// 恢复时按目标设备文档目录用 `path` 包重写绝对路径——跨设备/跨平台迁移可用。
class BackupRepo {
  BackupRepo(this._s);

  final AppServices _s;
  static const Uuid _uuid = Uuid();
  static const int formatVersion = 1;

  // ===================== 导出 =====================

  /// 导出到 [targetPath]（zip）。onProgress 每张图片回调一次。
  /// 返回因超限（>CursorWindow 安全阈值）跳过的任务条数（明细见调试日志）。
  Future<int> exportBackup(
    String targetPath, {
    void Function(BackupProgress p)? onProgress,
  }) async {
    debugPrint('[Backup] 导出开始 → $targetPath');
    var skippedTooLarge = 0;
    final workDir = await _newTempDir('backup_export');
    try {
      // ---- 收集元数据 ----
      onProgress?.call(const BackupProgress('收集数据库数据…'));
      final providers = await _s.providers.list();
      final templates = await _s.templates.list();

      // tasks 行体检（U-29）：单行超 Android CursorWindow 2MB 会让 SELECT *
      // 整表抛异常——先只读列长度定位（永远安全），超限行跳过并打印明细。
      const taskRowLimit = 1500 * 1024; // 1.5MB（2MB 留余量）
      final measures = await _s.tasks.measureRows();
      final skippedTasks = <String>[];
      for (final entry in measures.entries) {
        debugPrint(
          '[Backup] 体检 tasks/${entry.key}：'
          '${entry.value} 字符'
          '${entry.value > 200 * 1024 ? ' ⚠️ 偏大' : ''}',
        );
        if (entry.value > taskRowLimit) skippedTasks.add(entry.key);
      }
      for (final id in skippedTasks) {
        final detail = await _s.tasks.measureRow(id);
        debugPrint(
          '[Backup] ⚠️ 跳过超限任务 $id（${detail.entries.where((e) => (e.value) > 100 * 1024).map((e) => '${e.key.substring(2)}=${e.value}').join(', ')}）',
        );
      }
      final tasks = await _s.tasks.listByIds(
        measures.keys.where((id) => !skippedTasks.contains(id)).toList(),
      );
      final images = await _s.images.listAll();
      skippedTooLarge = skippedTasks.length;
      debugPrint(
        '[Backup] 元数据收集完成：providers=${providers.length} '
        'templates=${templates.length} tasks=${tasks.length}'
        '${skippedTooLarge > 0 ? '（跳过超限 $skippedTooLarge）' : ''} '
        'images=${images.length}',
      );
      final prefsData = {
        for (final k in const [
          PrefKeys.themeMode,
          PrefKeys.concurrencyPerProvider,
          PrefKeys.concurrencyGlobal,
          PrefKeys.debugEnabled,
          PrefKeys.debugRingLimit,
        ])
          k: _s.prefs.get(k),
      };

      Future<File> writeJson(String name, Object data) async {
        final f = File(path.join(workDir.path, name));
        await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(data),
          flush: true,
        );
        return f;
      }

      final manifestFile = await writeJson('manifest.json', {
        'app': 'inkmux-backup',
        'format_version': formatVersion,
        'exported_at': nowMs(),
        'counts': {
          'providers': providers.length,
          'templates': templates.length,
          'tasks': tasks.length,
          'images': images.length,
        },
      });
      final prefsFile = await writeJson('prefs.json', prefsData);
      final providersFile = await writeJson('providers.json', {
        'providers': [for (final p in providers) _providerJson(p)],
      });
      final templatesFile = await writeJson('templates.json', {
        'templates': [for (final t in templates) t.toJson()],
      });
      final tasksFile = await writeJson('tasks.json', {
        'tasks': [for (final t in tasks) t.toJson()],
      });

      // images 元数据：file_path 相对化；缺失文件照常导出元数据。
      final imageRows = <Map<String, dynamic>>[];
      for (final img in images) {
        final rel = _relativeImagePath(img.filePath);
        imageRows.add({
          ...img.toJson(),
          'file_path': rel ?? img.filePath,
          if (img.thumbPath != null) 'thumb_path': null,
        });
      }
      final imagesFile = await writeJson('images.json', {'images': imageRows});

      // ---- 打包 zip（流式写目标路径，逐张回调进度）----
      // archive 4.x：createWithStream 用 ZipEncoder(streamed: true)——压缩
      // 数据直接写盘，内存占用恒定（源码注释：非流式 920MB 文件需 1GB 内存，
      // 流式仅 ~19MB）。level=store（不压缩）：图片本身已是压缩格式，deflate
      // 是纯 Dart 同步 CPU 活，单张大图可卡 UI 数秒~数十秒（历史 bug：桌面
      // 端导出卡死在"打包图片"）；store 直拷（CompressionType.none）即磁盘
      // 拷贝速度、零内存峰值。
      onProgress?.call(BackupProgress('打包图片…', total: images.length));
      final encoder = ZipFileEncoder();
      debugPrint('[Backup] ZipEncoder.create（store 模式）…');
      encoder.create(targetPath, level: ZipFileEncoder.store);
      debugPrint('[Backup] create 完成，开始逐张 addFile');
      Future<void> add(File f, String arcName) => encoder.addFile(f, arcName);
      await add(manifestFile, 'manifest.json');
      await add(prefsFile, 'prefs.json');
      await add(providersFile, 'providers.json');
      await add(templatesFile, 'templates.json');
      await add(tasksFile, 'tasks.json');
      await add(imagesFile, 'images.json');
      debugPrint('[Backup] JSON 条目打包完成');
      var done = 0;
      for (final img in images) {
        final rel = _relativeImagePath(img.filePath);
        if (rel != null) {
          final f = File(img.filePath);
          final exists = await f.exists();
          final size = exists ? await f.length() : -1;
          debugPrint(
            '[Backup] 图片 $done/${images.length}：$rel '
            '(${size < 0 ? '缺失' : '$size bytes'})',
          );
          if (exists) {
            await add(f, 'files/images/$rel');
            debugPrint('[Backup] 图片 $done 打包完成');
          }
        }
        done++;
        onProgress?.call(
          BackupProgress('打包图片…', done: done, total: images.length),
        );
      }
      debugPrint('[Backup] 全部图片打包完成，关闭 zip…');
      await encoder.close();
      debugPrint(
        '[Backup] 导出成功 → $targetPath'
        '${skippedTooLarge > 0 ? '（跳过超限任务 $skippedTooLarge 条）' : ''}',
      );
      return skippedTooLarge;
    } finally {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    }
  }

  // ===================== 恢复 =====================

  /// 从 [zipPath] 恢复（跳过已存在数据）。onProgress 逐条回调。
  Future<BackupResult> importBackup(
    String zipPath, {
    void Function(BackupProgress p)? onProgress,
  }) async {
    final workDir = await _newTempDir('backup_restore');
    var providersAdded = 0,
        providersSkipped = 0,
        templatesAdded = 0,
        templatesSkipped = 0,
        tasksImported = 0,
        tasksSkipped = 0,
        imagesImported = 0,
        imagesSkipped = 0,
        missingFiles = 0;
    try {
      // ---- 解压（流式写盘；逐条目回调显示已处理计数，总数未知用不定进度）----
      onProgress?.call(const BackupProgress('解压备份包…'));
      var extracted = 0;
      await extractFileToDisk(
        zipPath,
        workDir.path,
        callback: (entry) {
          extracted++;
          onProgress?.call(BackupProgress('解压备份包…（已处理 $extracted 个文件）'));
        },
      );

      // ---- 校验 ----
      final manifest = _readJsonMap(path.join(workDir.path, 'manifest.json'));
      if (manifest == null ||
          manifest['app'] != 'inkmux-backup' ||
          manifest['format_version'] != formatVersion) {
        throw const FormatException('不是有效的 InkMux 备份包（manifest 校验失败）');
      }

      // ---- 平台与模板（跳过已存在；建立备份 id → 本地 id 映射）----
      onProgress?.call(const BackupProgress('恢复平台与模板…'));
      final providersData = _readJsonMap(
        path.join(workDir.path, 'providers.json'),
      );
      // 外键策略：tasks.provider_id/key_id 指向导出设备的 uuid——provider
      // 可映射（下方），api_keys 不在备份内（key_id 必然悬挂，历史记录
      // 只读展示不受影响；重试时由换 Key 逻辑兜底）。因此恢复期间临时
      // 关闭外键，结束（finally）恢复开启。
      await _s.db.database.execute('PRAGMA foreign_keys = OFF');
      final providerIdMap = <String, String>{};
      var existingProviders = await _s.providers.list();
      final providerList = providersData?['providers'];
      if (providerList is List) {
        for (final raw in providerList) {
          if (raw is! Map<String, dynamic>) continue;
          final backupId = raw['id']?.toString() ?? '';
          final presetKey = raw['preset_key']?.toString() ?? '';
          final baseUrl = raw['base_url']?.toString() ?? '';
          final displayName = raw['display_name']?.toString() ?? '';
          if (displayName.isEmpty) continue;
          final isCustom = presetKey == Presets.openaiCustom;
          // 已存在（内置按 preset_key、自定义按 preset_key+baseUrl）→ 映射到本地。
          final match = existingProviders.where(
            (e) => isCustom
                ? (e.presetKey == presetKey && e.baseUrl == baseUrl)
                : e.presetKey == presetKey,
          );
          if (match.isNotEmpty) {
            if (backupId.isNotEmpty) providerIdMap[backupId] = match.first.id;
            providersSkipped++;
            continue;
          }
          // 不存在 → 插入（有备份 id 用原 id，保证 tasks 引用精确对应）。
          final maxSort = existingProviders.fold<int>(
            -1,
            (acc, p) => acc > p.sort ? acc : p.sort,
          );
          final newId = backupId.isNotEmpty ? backupId : _uuid.v4();
          await _s.providers.insert(
            ProviderConfig(
              id: newId,
              presetKey: presetKey,
              displayName: displayName,
              baseUrl: baseUrl,
              enabled: raw['enabled'] == true,
              sort: maxSort + 1,
              createdAt: nowMs(),
              extraJson: raw['extra_json']?.toString(),
            ),
          );
          if (backupId.isNotEmpty) providerIdMap[backupId] = newId;
          existingProviders = await _s.providers.list();
          providersAdded++;
        }
      }
      final templatesData = _readJsonMap(
        path.join(workDir.path, 'templates.json'),
      );
      final templateList = templatesData?['templates'];
      if (templateList is List) {
        final existingTemplates = await _s.templates.list();
        for (final raw in templateList) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            final tpl = PromptTemplate.fromJson(raw);
            if (existingTemplates.any((e) => e.id == tpl.id)) {
              templatesSkipped++;
              continue;
            }
            await _s.templates.insert(tpl);
            templatesAdded++;
          } on Exception {
            // 单条脏数据跳过，不中断整体恢复。
          }
        }
      }

      // ---- 任务记录（id / 幂等键任一已存在即跳过）----
      final tasksData = _readJsonMap(path.join(workDir.path, 'tasks.json'));
      final taskList = tasksData?['tasks'];
      final tasks = <AppTask>[];
      if (taskList is List) {
        for (final raw in taskList) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            tasks.add(AppTask.fromJson(raw));
          } on Exception {
            // ignore：脏数据跳过。
          }
        }
      }
      onProgress?.call(BackupProgress('恢复任务记录…', total: tasks.length));
      for (final t in tasks) {
        // 跳过判据：同 id 已存在，或同幂等键已存在（idx_tasks_idem 唯一
        // 索引会让 INSERT OR REPLACE 顶掉本地行，违背"跳过不覆盖"语义）。
        if (await _s.tasks.byId(t.id) != null ||
            await _s.tasks.byIdempotencyKey(t.idempotencyKey) != null) {
          tasksSkipped++;
        } else {
          // provider_id 映射到本地对应平台（跨设备 uuid 不同）；
          // key_id 无法映射（api_keys 不在备份），悬挂由关外键窗口容忍。
          final mapped = AppTask(
            id: t.id,
            sessionId: t.sessionId,
            providerId: providerIdMap[t.providerId] ?? t.providerId,
            keyId: t.keyId,
            kind: t.kind,
            prompt: t.prompt,
            paramsJson: t.paramsJson,
            refImagesJson: t.refImagesJson,
            maskPath: t.maskPath,
            status: t.status,
            idempotencyKey: t.idempotencyKey,
            remoteTaskId: t.remoteTaskId,
            remoteExpiresAt: t.remoteExpiresAt,
            pollStateJson: t.pollStateJson,
            attempts: t.attempts,
            downloadAttempts: t.downloadAttempts,
            errorJson: t.errorJson,
            usageJson: t.usageJson,
            resultHintJson: t.resultHintJson,
            createdAt: t.createdAt,
            updatedAt: t.updatedAt,
            queuedAt: t.queuedAt,
            startedAt: t.startedAt,
            finishedAt: t.finishedAt,
          );
          await _s.tasks.upsert(mapped);
          tasksImported++;
        }
        onProgress?.call(
          BackupProgress(
            '恢复任务记录…',
            done: tasksImported + tasksSkipped,
            total: tasks.length,
          ),
        );
      }

      // ---- 图片（id 已存在跳过；文件复制 + 绝对路径重写）----
      final imagesData = _readJsonMap(path.join(workDir.path, 'images.json'));
      final imageList = imagesData?['images'];
      final images = <ImageAsset>[];
      if (imageList is List) {
        for (final raw in imageList) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            images.add(ImageAsset.fromJson(raw));
          } on Exception {
            // ignore
          }
        }
      }
      onProgress?.call(BackupProgress('恢复图片文件…', total: images.length));
      final docDir = await getApplicationDocumentsDirectory();
      var done = 0;
      for (final img in images) {
        done++;
        onProgress?.call(
          BackupProgress('恢复图片文件…', done: done, total: images.length),
        );
        if (await _s.images.byId(img.id) != null) {
          imagesSkipped++;
          continue;
        }
        // images.json 里 file_path 已是相对路径（导出时转换）——直接用；
        // _relativeImagePath 仅兜底异常数据（误存绝对路径时再提取一次）。
        // 历史 bug：对相对路径二次提取失败返回 null → 全部按"源文件缺失"跳过。
        final rel = _relativeImagePath(img.filePath) ?? img.filePath;
        // 本地文件系统路径用 path 包按平台拼（Windows '\'，POSIX '/'）；
        // rel 内为 '/' 分隔，join 前归一化为平台分隔符。
        final src = path.join(
          workDir.path,
          'files',
          'images',
          rel.replaceAll('/', path.separator),
        );
        final destDir = Directory(
          path.join(docDir.path, 'InkMux', 'images', path.dirname(rel)),
        );
        debugPrint(
          '[Backup] 图片恢复：json filePath=${img.filePath} '
          'rel=$rel destDir=${destDir.path}',
        );
        if (!await File(src).exists()) {
          missingFiles++;
          continue;
        }
        if (!await destDir.exists()) {
          await destDir.create(recursive: true);
        }
        final destPath = path.join(destDir.path, path.basename(rel));
        debugPrint('[Backup] copy：$src → $destPath');
        try {
          await File(src).copy(destPath);
        } on FileSystemException catch (e) {
          debugPrint(
            '[Backup] copy 失败：${e.message}\n'
            '  img.filePath=${img.filePath}\n'
            '  rel=$rel\n'
            '  destDir=${destDir.path} 存在=${await destDir.exists()}\n'
            '  destPath=$destPath',
          );
          rethrow;
        }
        await _s.images.upsert(_assetWithPaths(img, destPath));
        imagesImported++;
      }

      // ---- 偏好（键已存在则跳过，保留当前设置）----
      final prefsData = _readJsonMap(path.join(workDir.path, 'prefs.json'));
      if (prefsData != null) {
        for (final entry in prefsData.entries) {
          if (_s.prefs.containsKey(entry.key)) continue;
          final v = entry.value;
          if (v is bool) {
            await _s.prefs.setBool(entry.key, v);
          } else if (v is int) {
            await _s.prefs.setInt(entry.key, v);
          } else if (v is double) {
            await _s.prefs.setDouble(entry.key, v);
          } else if (v is String) {
            await _s.prefs.setString(entry.key, v);
          }
        }
      }

      return BackupResult(
        providersAdded: providersAdded,
        providersSkipped: providersSkipped,
        templatesAdded: templatesAdded,
        templatesSkipped: templatesSkipped,
        tasksImported: tasksImported,
        tasksSkipped: tasksSkipped,
        imagesImported: imagesImported,
        imagesSkipped: imagesSkipped,
        missingFiles: missingFiles,
      );
    } finally {
      // 无论成败，恢复外键开启（与 AppDb.onConfigure 的初始状态一致）。
      try {
        await _s.db.database.execute('PRAGMA foreign_keys = ON');
      } catch (_) {
        // ignore：连接已断开等场景。
      }
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    }
  }

  // ===================== helpers =====================

  Map<String, dynamic> _providerJson(dynamic p) => {
    'id': p.id,
    'preset_key': p.presetKey,
    'display_name': p.displayName,
    'base_url': p.baseUrl,
    'enabled': p.enabled,
    'sort': p.sort,
    if (p.extraJson != null) 'extra_json': p.extraJson,
  };

  /// 绝对路径 → 相对路径（InkMux/images/ 之后段，'/' 分隔）；非标准路径返回 null。
  String? _relativeImagePath(String absPath) {
    final norm = absPath.replaceAll('\\', '/');
    const marker = 'InkMux/images/';
    final i = norm.indexOf(marker);
    if (i < 0) return null;
    return norm.substring(i + marker.length);
  }

  ImageAsset _assetWithPaths(ImageAsset img, String newFilePath) => ImageAsset(
    id: img.id,
    taskId: img.taskId,
    seq: img.seq,
    filePath: newFilePath,
    thumbPath: null, // 缩略图 cache 不迁移；画廊自动回退原图。
    width: img.width,
    height: img.height,
    bytes: img.bytes,
    format: img.format,
    channel: img.channel,
    promptSnapshot: img.promptSnapshot,
    paramsSnapshotJson: img.paramsSnapshotJson,
    favorite: img.favorite,
    tagsJson: img.tagsJson,
    createdAt: img.createdAt,
  );

  Map<String, dynamic>? _readJsonMap(String path_) {
    final f = File(path_);
    if (!f.existsSync()) return null;
    try {
      final decoded = const JsonDecoder().convert(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<Directory> _newTempDir(String prefix) async {
    final base = await getApplicationSupportDirectory();
    final stamp = nowMs();
    final dir = Directory(path.join(base.path, 'cache', '$prefix$stamp'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
