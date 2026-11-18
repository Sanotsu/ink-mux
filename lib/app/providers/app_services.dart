import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db/app_db.dart';
import '../../data/db/daos/debug_log_dao.dart';
import '../../data/db/daos/image_dao.dart';
import '../../data/db/daos/key_dao.dart';
import '../../data/db/daos/provider_dao.dart';
import '../../data/db/daos/task_dao.dart';
import '../../data/db/daos/template_dao.dart';
import '../../data/adapters/registry.dart';
import '../../data/network/dio_hub.dart';
import '../../data/network/debug_log_sink.dart';
import '../../data/secure/key_vault.dart';

/// 应用服务容器：bootstrap 一次性构建，main 中 override 进 Riverpod。
class AppServices {
  AppServices({
    required this.db,
    required this.prefs,
    required this.vault,
    required this.dioHub,
    required this.logSink,
  }) : providers = ProviderDao(db.database),
       keys = KeyDao(db.database),
       tasks = TaskDao(db.database),
       images = ImageDao(db.database),
       debugLogs = DebugLogDao(db.database),
       templates = TemplateDao(db.database),
       registry = AdapterRegistry(dioHub);

  final AppDb db;
  final SharedPreferences prefs;
  final KeyVault vault;
  final DioHub dioHub;
  final DebugLogSink logSink;

  final ProviderDao providers;
  final KeyDao keys;
  final TaskDao tasks;
  final ImageDao images;
  final DebugLogDao debugLogs;
  final TemplateDao templates;

  /// 适配器注册表（§6.2）：进程级唯一，preset/custom 实例缓存全局生效。
  final AdapterRegistry registry;
}

/// 根服务 Provider：由 main() 中 overrideWith 注入（bootstrap 先于 UI）。
final appServicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError('appServicesProvider 必须在 main 中 override'),
);
