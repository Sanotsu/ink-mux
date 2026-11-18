import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repos/backup_repo.dart';
import '../../data/repos/debug_log_repo.dart';
import '../../data/repos/settings_repo.dart';
import 'app_services.dart';

final settingsRepoProvider = Provider<SettingsRepo>((ref) {
  final s = ref.watch(appServicesProvider);
  return SettingsRepo(
    db: s.db,
    vault: s.vault,
    dioHub: s.dioHub,
    registry: s.registry,
  );
});

final debugRepoProvider = Provider<DebugLogRepo>((ref) {
  final s = ref.watch(appServicesProvider);
  return DebugLogRepo(s.debugLogs, s.logSink);
});

final backupRepoProvider = Provider<BackupRepo>(
  (ref) => BackupRepo(ref.watch(appServicesProvider)),
);
