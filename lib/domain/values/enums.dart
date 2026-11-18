/// 领域枚举（DB 存 name 字符串，json_serializable 原生支持）。
library;

enum TaskStatus {
  queued,
  submitting,
  waiting,
  persisting,
  succeeded,
  failed,
  cancelled,
  expired,
  unknown;

  bool get isTerminal => switch (this) {
    succeeded || failed || cancelled || expired || unknown => true,
    _ => false,
  };

  bool get isActive => !isTerminal;
}

/// 任务类型。
enum TaskKind { generate, edit }

/// 平台任务模式（§6.1）：同步长连接 / 异步任务。
enum TaskMode { syncHold, asyncTask }

/// 图片结果来源通道（§8.1）。
enum ResultChannel { url, b64 }

/// 调试日志条目类型。
enum LogKind { http, event, error }

/// 调试日志方向。
enum LogDirection { req, resp, info }
