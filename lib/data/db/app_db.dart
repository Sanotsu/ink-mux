import 'package:sqflite/sqflite.dart';

import 'schema.dart';

/// 数据库单例封装（§5.2）：平台工厂注入（Android 平台插件 / Windows FFI），
/// 打开即启用 foreign_keys；文件库启用 WAL。
class AppDb {
  AppDb._(this.database);

  final Database database;

  /// [path] 为数据库文件完整路径；null 时打开内存库（测试用，singleInstance 关闭）。
  static Future<AppDb> open({
    required DatabaseFactory factory,
    String? path,
  }) async {
    final inMemory = path == null;
    final target = path ?? ':memory:';
    final db = await factory.openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: Schema.version,
        singleInstance: !inMemory,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          for (final stmt in Schema.statements) {
            await db.execute(stmt);
          }
        },
        // 开发期不做增量迁移（schema 恒 v1，onUpgrade 不触发）；
        // 破坏性改动 → 卸载 App / 删除 db 文件重建。
      ),
    );
    if (!inMemory) {
      try {
        await db.rawQuery('PRAGMA journal_mode = WAL');
      } catch (_) {
        // WAL 不可用时回退默认日志模式，不影响功能。
      }
    }
    return AppDb._(db);
  }

  Future<void> close() => database.close();
}
