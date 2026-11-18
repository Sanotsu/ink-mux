import 'package:sqflite/sqflite.dart';

import '../../../domain/entities/api_key.dart';

class KeyDao {
  KeyDao(this.db);

  final Database db;

  static const String _t = 'api_keys';

  Future<List<ApiKey>> listByProvider(String providerId) async {
    final rows = await db.query(
      _t,
      where: 'provider_id = ?',
      whereArgs: [providerId],
      orderBy: 'created_at ASC',
    );
    return rows.map(ApiKey.fromJson).toList();
  }

  Future<ApiKey?> byId(String id) async {
    final rows = await db.query(_t, where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ApiKey.fromJson(rows.first);
  }

  Future<void> insert(ApiKey key) async {
    await db.insert(
      _t,
      key.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 被 tasks 引用过的 Key 数（>0 即不可物理删除，走置停用，§5.2）。
  Future<int> taskReferenceCount(String keyId) async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM tasks WHERE key_id = ?', [
          keyId,
        ]),
      ) ??
      0;

  Future<void> delete(String id) async {
    await db.delete(_t, where: 'id = ?', whereArgs: [id]);
  }

  /// 停用/重新启用（不删行、不动密文——恢复轮询同令牌依赖完整 Key 行）。
  Future<void> setDisabled(String id, {required bool disabled}) async {
    await db.update(
      _t,
      {'disabled': disabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 同平台唯一默认 Key（事务内先清后设）。
  Future<void> setDefault(String providerId, String keyId) async {
    await db.transaction((txn) async {
      await txn.update(
        _t,
        {'is_default': 0},
        where: 'provider_id = ? AND id != ? AND is_default = 1',
        whereArgs: [providerId, keyId],
      );
      await txn.update(
        _t,
        {'is_default': 1},
        where: 'id = ?',
        whereArgs: [keyId],
      );
    });
  }

  Future<void> touchLastUsed(String id, int ts) async {
    await db.update(_t, {'last_used_at': ts}, where: 'id = ?', whereArgs: [id]);
  }
}
