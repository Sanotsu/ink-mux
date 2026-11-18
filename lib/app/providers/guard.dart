import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'orchestrator.dart';

/// 守卫弹窗显隐（§10.8）：enqueue 后打开；用户"最小化"关闭；无活跃任务自动关。
final guardOpenProvider = NotifierProvider<GuardController, bool>(
  GuardController.new,
);

class GuardController extends Notifier<bool> {
  @override
  bool build() {
    // 无活跃任务时自动收起（异常路径兜底）。
    ref.listen(orchestratorProvider.select((s) => s.activeCount), (_, active) {
      if (active == 0 && state) state = false;
    });
    return false;
  }

  void show() => state = true;

  void minimize() => state = false;
}

/// 活跃任务数（角标 + 守卫联动）。
final orchestratorBadgeProvider = Provider<int>(
  (ref) => ref.watch(orchestratorProvider.select((s) => s.activeCount)),
);
