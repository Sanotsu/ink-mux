import 'package:sqflite/sqflite.dart';

import '../../../domain/entities/image_asset.dart';

class ImageDao {
  ImageDao(this.db);

  final Database db;

  static const String _t = 'images';

  Future<void> insert(ImageAsset image) async {
    await db.insert(
      _t,
      image.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ImageAsset>> byTask(String taskId) async {
    final rows = await db.query(
      _t,
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'seq ASC',
    );
    return rows.map(ImageAsset.fromJson).toList();
  }

  /// 任务实际落库张数（COUNT(*)，不取本体行——详情「出图 X/N」用，
  /// 上游未按 n 出全时与提交 n 对账）。
  Future<int> countByTask(String taskId) async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $_t WHERE task_id = ?', [
          taskId,
        ]),
      ) ??
      0;

  Future<ImageAsset?> byId(String id) async {
    final rows = await db.query(_t, where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ImageAsset.fromJson(rows.first);
  }

  /// 画廊分页（默认最新在前；offset 支持滚动加载更多，U-38 E）。
  Future<List<ImageAsset>> page({
    int limit = 60,
    int offset = 0,
    bool favoriteOnly = false,
  }) async {
    final rows = await db.query(
      _t,
      where: favoriteOnly ? 'favorite = 1' : null,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(ImageAsset.fromJson).toList();
  }

  /// 总数与收藏数（画廊页首统计行，U-39）。
  Future<(int total, int favorites)> counts() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total, COALESCE(SUM(favorite), 0) AS favs FROM $_t',
    );
    final r = rows.first;
    return ((r['total'] as int?) ?? 0, (r['favs'] as int?) ?? 0);
  }

  /// 搜索匹配数（当前搜索词 + 收藏过滤口径，U-39 统计行用）。
  Future<int> countSearch(String query, {bool favoriteOnly = false}) async {
    final escaped = query
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final where = [
      "prompt_snapshot LIKE ? ESCAPE '\\'",
      if (favoriteOnly) 'favorite = 1',
    ].join(' AND ');
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_t WHERE $where',
      ['%$escaped%'],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// 缺缩略图的存量记录（历史图/恢复备份，U-38 A+ 补建扫描用）。
  Future<List<ImageAsset>> missingThumbs({int limit = 500}) async {
    final rows = await db.query(
      _t,
      where: 'thumb_path IS NULL',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(ImageAsset.fromJson).toList();
  }

  /// 回填缩略图路径（补建完成后写回，U-38 A+）。
  Future<void> setThumbPath(String id, String thumbPath) async {
    await db.update(
      _t,
      {'thumb_path': thumbPath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// prompt 全文搜索（M2 画廊搜索；LIKE 转义 %/_；offset 分页 U-38 E）。
  Future<List<ImageAsset>> search(
    String query, {
    bool favoriteOnly = false,
    int limit = 200,
    int offset = 0,
  }) async {
    final escaped = query
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final where = [
      "prompt_snapshot LIKE ? ESCAPE '\\'",
      if (favoriteOnly) 'favorite = 1',
    ].join(' AND ');
    final rows = await db.query(
      _t,
      where: where,
      whereArgs: ['%$escaped%'],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(ImageAsset.fromJson).toList();
  }

  /// 删除记录（文件由调用方处理，§8.3 删除策略）。
  Future<void> delete(String id) async {
    await db.delete(_t, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await db.update(
      _t,
      {'favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteByTask(String taskId) async {
    await db.delete(_t, where: 'task_id = ?', whereArgs: [taskId]);
  }

  /// 全表（数据备份导出用）。
  Future<List<ImageAsset>> listAll() async {
    final rows = await db.query(_t, orderBy: 'created_at ASC');
    return rows.map(ImageAsset.fromJson).toList();
  }

  /// 备份恢复 upsert（id 相同跳过由调用方判断；replace 兜底）。
  Future<void> upsert(ImageAsset image) async {
    await db.insert(
      _t,
      image.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
