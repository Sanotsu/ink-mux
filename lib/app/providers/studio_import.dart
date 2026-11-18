import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/param_snapshot.dart';
import '../../domain/values/enums.dart';

/// 导入请求（预览/画廊「继续编辑」、任务历史「再次生成」→ 创作页）。
/// [kind] 显式指定目标模式：null 时按参考图推导（有图=编辑，无图=保持当前模式）。
class StudioImport {
  const StudioImport({
    required this.refImagePaths,
    this.kind,
    this.prompt,
    this.params,
    required this.token,
  });

  final List<String> refImagePaths;

  /// 目标模式（任务历史再次生成 = 原任务类型；继续编辑 = edit）。
  final TaskKind? kind;
  final String? prompt;
  final ParamSnapshot? params;

  /// 消费令牌：studio 只消费与自身持有的 token 相等的请求，避免重复导入。
  final int token;
}

final studioImportProvider =
    NotifierProvider<StudioImportController, StudioImport?>(
      StudioImportController.new,
    );

class StudioImportController extends Notifier<StudioImport?> {
  @override
  StudioImport? build() => null;

  void request(StudioImport import) {
    state = StudioImport(
      refImagePaths: import.refImagePaths,
      kind: import.kind,
      prompt: import.prompt,
      params: import.params,
      token: (state?.token ?? 0) + 1,
    );
  }

  void consume(int token) {
    if (state?.token == token) state = null;
  }
}
