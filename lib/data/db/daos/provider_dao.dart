import 'package:sqflite/sqflite.dart';

import '../../../domain/entities/provider_config.dart';

class ProviderDao {
  ProviderDao(this.db);

  final Database db;

  static const String _t = 'provider_configs';

  Future<int> count() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_t')) ?? 0;

  Future<List<ProviderConfig>> list() async {
    final rows = await db.query(_t, orderBy: 'sort ASC, created_at ASC');
    return rows.map(ProviderConfig.fromJson).toList();
  }

  Future<ProviderConfig?> byId(String id) async {
    final rows = await db.query(_t, where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ProviderConfig.fromJson(rows.first);
  }

  Future<void> insert(ProviderConfig config) async {
    await db.insert(
      _t,
      config.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await db.update(
      _t,
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 调整排序（内置预设顺序校正用）。
  Future<void> setSort(String id, int sort) async {
    await db.update(_t, {'sort': sort}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateBaseUrl(String id, String baseUrl) async {
    await db.update(
      _t,
      {'base_url': baseUrl},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 改显示名（配置导入联动）。
  Future<void> rename(String id, String displayName) async {
    await db.update(
      _t,
      {'display_name': displayName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除平台（调用方负责引用检查）。
  Future<void> delete(String id) async {
    await db.delete(_t, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateModelsCache(String id, String cacheJson) async {
    await db.update(
      _t,
      {'models_cache_json': cacheJson},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
