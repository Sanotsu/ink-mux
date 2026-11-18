import 'package:sqflite/sqflite.dart';

import '../../../core/util/convert.dart';
import '../../../domain/entities/prompt_template.dart';

class TemplateDao {
  TemplateDao(this.db);

  final Database db;

  static const String _t = 'prompt_templates';

  Future<List<PromptTemplate>> list() async {
    final rows = await db.query(
      _t,
      orderBy: 'last_used_at IS NULL, last_used_at DESC, use_count DESC',
    );
    return rows.map(PromptTemplate.fromJson).toList();
  }

  Future<void> insert(PromptTemplate template) async {
    await db.insert(
      _t,
      template.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> update(PromptTemplate template) async {
    await db.update(
      _t,
      template.toJson(),
      where: 'id = ?',
      whereArgs: [template.id],
    );
  }

  Future<void> delete(String id) async {
    await db.delete(_t, where: 'id = ?', whereArgs: [id]);
  }

  /// 应用模板：使用计数 +1 并刷新最近使用时间。
  Future<void> bumpUse(String id) async {
    await db.rawUpdate(
      'UPDATE $_t SET use_count = use_count + 1, last_used_at = ? WHERE id = ?',
      [nowMs(), id],
    );
  }
}
