import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/constants.dart';
import '../data/db/app_db.dart';
import '../data/db/daos/debug_log_dao.dart';
import '../data/db/daos/task_dao.dart';
import '../data/network/dio_hub.dart';
import '../data/network/debug_log_sink.dart';
import '../data/notifications/notify_service.dart';
import '../data/secure/key_vault.dart';
import 'providers/app_services.dart';

/// 异步初始化链（§4.2）：DB 平台工厂 → prefs → DioHub(+日志 sink) → 服务容器。
/// 播种内置预设在设置页首次 load 时执行（幂等）。
class Bootstrap {
  Bootstrap._();

  static Future<AppServices> init() async {
    // Windows/Linux：切换到 FFI 工厂（sqlite3 v3 起自带原生库打包，无需 sqlite3_flutter_libs）。
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final prefs = await SharedPreferences.getInstance();

    // 用户数据统一根目录（§5.2）：Documents/InkMux/（移动端为 app 私有目录）
    //   ink_mux.db / images/ / backups/ / logs/。
    final docs = await getApplicationDocumentsDirectory();
    final dataRoot = Directory(path.join(docs.path, 'InkMux'));
    if (!await dataRoot.exists()) {
      await dataRoot.create(recursive: true);
    }
    final dbPath = path.join(dataRoot.path, 'ink_mux.db');

    final db = await AppDb.open(factory: databaseFactory, path: dbPath);

    // 旧库清洗（幂等，U-29 防御）：超限大列置空，防 CursorWindow 崩溃。
    // 引擎恢复扫描之前执行（恢复/详情/备份都要 SELECT *）。
    final sanitized = await TaskDao(db.database).sanitizeOversizedRows();
    if (sanitized > 0) {
      debugPrint('[Bootstrap] tasks 超限行清洗：$sanitized 处大列已置空');
    }

    final sink = DebugLogSink(
      DebugLogDao(db.database),
      enabled: prefs.getBool(PrefKeys.debugEnabled) ?? DebugDefaults.enabled,
      ringLimit:
          prefs.getInt(PrefKeys.debugRingLimit) ?? DebugDefaults.ringLimit,
    );
    final dioHub = DioHub.create(sink);

    // 本地通知（任务完成/失败，后台提醒；Android/Windows）。
    await NotifyService.init();

    return AppServices(
      db: db,
      prefs: prefs,
      vault: KeyVault(),
      dioHub: dioHub,
      logSink: sink,
    );
  }
}
