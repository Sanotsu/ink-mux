import 'package:flutter_test/flutter_test.dart';
import 'package:ink_mux/core/util/convert.dart';
import 'package:ink_mux/data/db/app_db.dart';
import 'package:ink_mux/data/db/daos/debug_log_dao.dart';
import 'package:ink_mux/data/db/daos/key_dao.dart';
import 'package:ink_mux/data/db/daos/provider_dao.dart';
import 'package:ink_mux/data/db/daos/task_dao.dart';
import 'package:ink_mux/data/db/daos/template_dao.dart';
import 'package:ink_mux/domain/entities/api_key.dart';
import 'package:ink_mux/domain/entities/app_task.dart';
import 'package:ink_mux/domain/entities/debug_log_entry.dart';
import 'package:ink_mux/domain/entities/prompt_template.dart';
import 'package:ink_mux/domain/entities/provider_config.dart';
import 'package:ink_mux/domain/values/enums.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late AppDb db;
  late ProviderDao providers;
  late KeyDao keys;
  late TaskDao tasks;
  late DebugLogDao logs;

  setUp(() async {
    db = await AppDb.open(factory: databaseFactoryFfi);
    providers = ProviderDao(db.database);
    keys = KeyDao(db.database);
    tasks = TaskDao(db.database);
    logs = DebugLogDao(db.database);
  });

  tearDown(() async {
    await db.close();
  });

  test('schema 建库 + 预设播种 + 行映射往返', () async {
    final now = nowMs();
    await providers.insert(
      ProviderConfig(
        id: 'p1',
        presetKey: 'shenwenai',
        displayName: '神稳AI',
        baseUrl: 'https://api.shenwenai.com/v1',
        enabled: true,
        sort: 0,
        createdAt: now,
      ),
    );
    final loaded = await providers.list();
    expect(loaded, hasLength(1));
    expect(loaded.first.presetKey, 'shenwenai');
    expect(loaded.first.enabled, isTrue); // int → bool
    expect(loaded.first.baseUrl, 'https://api.shenwenai.com/v1');

    await providers.updateModelsCache('p1', '{"fetchedAt":1,"models":[]}');
    expect(
      (await providers.byId('p1'))!.modelsCacheJson,
      contains('fetchedAt'),
    );
  });

  test('api_keys 默认 Key 唯一化 + 任务引用转停用', () async {
    final now = nowMs();
    await providers.insert(
      ProviderConfig(
        id: 'p1',
        presetKey: 'a6api',
        displayName: 'A6API',
        baseUrl: 'https://media.a6api.net/v1',
        enabled: true,
        createdAt: now,
      ),
    );
    for (final (i, id) in ['k1', 'k2'].indexed) {
      await keys.insert(
        ApiKey(
          id: id,
          providerId: 'p1',
          label: 'key$i',
          channelNote: '',
          secretRef: 'apikey.$id',
          isDefault: i == 0,
          createdAt: now,
        ),
      );
    }
    await keys.setDefault('p1', 'k2');
    final rows = await keys.listByProvider('p1');
    expect(rows.firstWhere((k) => k.id == 'k2').isDefault, isTrue);
    expect(rows.firstWhere((k) => k.id == 'k1').isDefault, isFalse);

    // 无引用可物理删；有引用转停用（行保留、密文保留、可重新启用）。
    expect(await keys.taskReferenceCount('k1'), 0);
    await tasks.insert(
      AppTask(
        id: 't1',
        sessionId: 's1',
        providerId: 'p1',
        keyId: 'k1',
        kind: TaskKind.generate,
        prompt: '一只橘猫',
        paramsJson: '{"model":"gpt-image-2"}',
        status: TaskStatus.queued,
        idempotencyKey: 'idem-1',
        createdAt: now,
        updatedAt: now,
      ),
    );
    expect(await keys.taskReferenceCount('k1'), 1);
    await keys.setDisabled('k1', disabled: true);
    final after = await keys.listByProvider('p1');
    expect(after.firstWhere((k) => k.id == 'k1').disabled, isTrue);
    // 恢复轮询依赖：byId 不受停用影响（同令牌读取密文引用）。
    expect((await keys.byId('k1'))!.secretRef, 'apikey.k1');
    await keys.setDisabled('k1', disabled: false);
    expect(
      (await keys.listByProvider('p1'))
          .firstWhere((k) => k.id == 'k1')
          .disabled,
      isFalse,
    );
  });

  test('tasks 状态迁移 + 非终态扫描（恢复入口）', () async {
    final now = nowMs();
    await providers.insert(
      ProviderConfig(
        id: 'p1',
        presetKey: 'shenwenai',
        displayName: '神稳AI',
        baseUrl: 'u',
        enabled: true,
        createdAt: now,
      ),
    );
    await keys.insert(
      ApiKey(
        id: 'k1',
        providerId: 'p1',
        label: 'a',
        channelNote: '',
        secretRef: 'r',
        isDefault: true,
        createdAt: now,
      ),
    );
    await tasks.insert(
      AppTask(
        id: 't1',
        sessionId: 's1',
        providerId: 'p1',
        keyId: 'k1',
        kind: TaskKind.generate,
        prompt: 'p',
        paramsJson: '{}',
        status: TaskStatus.queued,
        idempotencyKey: 'i1',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await tasks.insert(
      AppTask(
        id: 't2',
        sessionId: 's2',
        providerId: 'p1',
        keyId: 'k1',
        kind: TaskKind.edit,
        prompt: 'p',
        paramsJson: '{}',
        status: TaskStatus.succeeded,
        idempotencyKey: 'i2',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tasks.patch(
      't1',
      TaskStatus.waiting,
      extra: {
        'remote_task_id': 'a6-task-9',
        'remote_expires_at': now + 86400000,
      },
    );
    final t1 = await tasks.byId('t1');
    expect(t1!.status, TaskStatus.waiting);
    expect(t1.remoteTaskId, 'a6-task-9');

    final nonTerminal = await tasks.nonTerminal();
    expect(nonTerminal.map((t) => t.id), ['t1']);
  });

  test('debug_logs 批量插入 + 分页 + 仅看错误 + 环形裁剪', () async {
    DebugLogEntry mk(int i, {int? status, LogKind kind = LogKind.http}) =>
        DebugLogEntry(
          sessionId: 's-$i',
          seq: 1,
          ts: 1000 + i,
          kind: kind,
          direction: LogDirection.resp,
          method: 'GET',
          url: 'https://x/v1/models',
          statusCode: status ?? 200,
          bodyText: 'body-$i',
        );
    await logs.insertBatch([for (var i = 0; i < 30; i++) mk(i)]);
    await logs.insertBatch([mk(30, status: 429), mk(31, kind: LogKind.error)]);

    final latest = await logs.latest(limit: 10);
    expect(latest, hasLength(10));
    expect(latest.first.id, greaterThan(latest.last.id!)); // 新的在前

    final older = await logs.latest(limit: 10, beforeId: latest.last.id);
    expect(older, hasLength(10));

    final errors = await logs.latest(limit: 100, errorsOnly: true);
    expect(errors, hasLength(2));
    expect(errors.every((e) => e.hasError), isTrue);

    expect(await logs.countAll(), 32);
    await logs.prune(10);
    expect(await logs.countAll(), 10);

    final exported = await logs.exportAll();
    expect(exported, hasLength(10));
    expect(exported.first.id, lessThan(exported.last.id!)); // 时间线正序
  });

  test('prompt_templates 建库可用（M2；开发期 schema 恒 v1 无迁移）', () async {
    // 当前 statements 直接包含 prompt_templates；破坏性 schema 改动的
    // 策略是卸载 App / 删除 db 文件重建（用户约定），不再写 upgrade。
    final dao = TemplateDao(db.database);
    await dao.insert(
      PromptTemplate(
        id: 'tpl1',
        title: '产品图',
        content: '极简风格产品摄影，白色背景，柔和布光',
        createdAt: nowMs(),
      ),
    );
    await dao.bumpUse('tpl1');
    final list = await dao.list();
    expect(list, hasLength(1));
    expect(list.first.useCount, 1);
    expect(list.first.lastUsedAt, isNotNull);
  });
}
