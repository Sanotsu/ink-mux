/// SQLite schema 单一来源（§5.1/§5.2）：6 表 + 7 索引，列名统一 snake_case
/// （与实体 fieldRename: FieldRename.snake 对齐）。
///
/// 版本策略（用户约定）：**开发期固定 v1，不做增量迁移**——破坏性 schema
/// 改动直接改 statements，测试用卸载 App（移动端）或删除数据目录
/// `Documents/InkMux/ink_mux.db`（桌面端）从头重建；无需 onUpgrade。
/// 最近一次破坏性改动：① api_keys 增加 disabled 列（2026-11-16，被任务引用
/// 的 Key 删除时转为停用而非拒绝，§5.2 删除策略）；② images.task_id 改可空
/// + ON DELETE SET NULL（2026-11-16 U-42：删除任务记录时图片解除关联保留
/// 为「无任务图」，画廊不受影响）——旧库需删库重建。
library;

class Schema {
  Schema._();

  static const int version = 1;

  static const List<String> statements = [
    // ---- 表 ----
    '''
    CREATE TABLE provider_configs (
      id TEXT PRIMARY KEY,
      preset_key TEXT NOT NULL,
      display_name TEXT NOT NULL,
      base_url TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      extra_json TEXT,
      models_cache_json TEXT,
      sort INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE api_keys (
      id TEXT PRIMARY KEY,
      provider_id TEXT NOT NULL REFERENCES provider_configs(id),
      label TEXT NOT NULL,
      channel_note TEXT NOT NULL DEFAULT '',
      secret_ref TEXT NOT NULL,
      is_default INTEGER NOT NULL DEFAULT 0,
      disabled INTEGER NOT NULL DEFAULT 0,
      last_used_at INTEGER,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      provider_id TEXT NOT NULL REFERENCES provider_configs(id),
      key_id TEXT NOT NULL REFERENCES api_keys(id),
      kind TEXT NOT NULL,
      prompt TEXT NOT NULL,
      params_json TEXT NOT NULL,
      ref_images_json TEXT NOT NULL DEFAULT '[]',
      mask_path TEXT,
      status TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      remote_task_id TEXT,
      remote_expires_at INTEGER,
      poll_state_json TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      download_attempts INTEGER NOT NULL DEFAULT 0,
      error_json TEXT,
      usage_json TEXT,
      result_hint_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      queued_at INTEGER,
      started_at INTEGER,
      finished_at INTEGER
    )
    ''',
    '''
    CREATE TABLE images (
      id TEXT PRIMARY KEY,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      seq INTEGER NOT NULL,
      file_path TEXT NOT NULL,
      thumb_path TEXT,
      width INTEGER,
      height INTEGER,
      bytes INTEGER,
      format TEXT,
      channel TEXT NOT NULL,
      prompt_snapshot TEXT,
      params_snapshot_json TEXT,
      favorite INTEGER NOT NULL DEFAULT 0,
      tags_json TEXT,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE debug_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      task_id TEXT,
      seq INTEGER NOT NULL,
      ts INTEGER NOT NULL,
      kind TEXT NOT NULL,
      direction TEXT NOT NULL,
      method TEXT,
      url TEXT,
      status_code INTEGER,
      duration_ms INTEGER,
      headers_json TEXT,
      body_text TEXT
    )
    ''',
    '''
    CREATE TABLE prompt_templates (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      use_count INTEGER NOT NULL DEFAULT 0,
      last_used_at INTEGER,
      created_at INTEGER NOT NULL
    )
    ''',
    // ---- 索引 ----
    'CREATE UNIQUE INDEX idx_tasks_idem ON tasks(idempotency_key)',
    'CREATE INDEX idx_tasks_status ON tasks(status)',
    'CREATE INDEX idx_tasks_session ON tasks(session_id)',
    'CREATE INDEX idx_images_task ON images(task_id)',
    'CREATE INDEX idx_images_created ON images(created_at DESC)',
    'CREATE INDEX idx_logs_session ON debug_logs(session_id, seq)',
    'CREATE INDEX idx_logs_task ON debug_logs(task_id)',
  ];
}
