// 一次性 DB 检查脚本：dart run tool/inspect_db.dart [dbPath]
// 忽略 lint（仅开发诊断用）。
// ignore_for_file: avoid_print
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final path = args.isNotEmpty
      ? args.first
      : r'D:\davidsu\Documents\InkMux\ink_mux.db';
  print('打开：$path');
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: 1),
  );
  for (final t in ['tasks', 'images', 'provider_configs']) {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $t');
    print('$t: ${rows.first['n']} 行');
  }
  final imgs = await db.rawQuery(
    'SELECT id, task_id, file_path, created_at FROM images ORDER BY created_at DESC LIMIT 5',
  );
  for (final r in imgs) {
    print(
      'image: ${r['id'].toString().substring(0, 8)} task=${r['task_id'].toString().substring(0, 8)} file=${r['file_path']}',
    );
  }
  final tasks = await db.rawQuery(
    'SELECT id, status, provider_id FROM tasks ORDER BY created_at DESC LIMIT 5',
  );
  for (final r in tasks) {
    print(
      'task: ${r['id'].toString().substring(0, 8)} status=${r['status']} provider=${r['provider_id'].toString().substring(0, 8)}',
    );
  }
  await db.close();
}
