import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/settings_controller.dart';
import '../../../core/constants.dart';
import '../../../core/theme/density.dart';
import '../../../domain/entities/api_key.dart';
import '../../../domain/entities/provider_config.dart';
import '../../../domain/values/enums.dart';
import '../../../data/repos/settings_repo.dart' show ModelTestResult;

/// 平台管理页（2026-11-16 由设置页首页拆出）：平台开关 / API Key / 连通测试 /
/// Base URL / 自定义站——设置页首页只留入口行，平台增多后不再无限拉长。
class ProvidersPage extends ConsumerStatefulWidget {
  const ProvidersPage({super.key});

  @override
  ConsumerState<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends ConsumerState<ProvidersPage> {
  @override
  void initState() {
    super.initState();
    // 直接导航进入时（深链/路由直达）sections 可能未加载；从设置页进入时
    // 已有数据，load() 幂等重读无害。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(settingsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final d = AppDensity.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('平台管理')),
      body: state.loading && state.sections.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: EdgeInsets.all(d.screenH),
                  children: [
                    if (state.error != null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: EdgeInsets.all(d.cardPadding),
                          child: Text(
                            state.error!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    for (final section in state.sections) ...[
                      _ProviderCard(section: section),
                      SizedBox(height: d.cardGap),
                    ],
                    OutlinedButton.icon(
                      onPressed: () => _showAddCustomDialog(context, ref),
                      icon: const Icon(Icons.add_business_outlined, size: 18),
                      label: const Text('添加自定义站（OpenAI 兼容）'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'ⓘ 同步=请求挂起直接返回结果；异步=提交任务后轮询（少数站支持）。\n'
                      '模型目录由「测试连通」拉取并缓存，创作页模型行尾按钮可手动刷新',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({required this.section});

  final ProviderSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = AppDensity.of(context);
    final ctrl = ref.read(settingsProvider.notifier);
    final config = section.config;
    final hint = Presets.builtin[config.presetKey]?.channelHint;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(d.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hub_outlined,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            config.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            config.presetKey,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              config.baseUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () =>
                                _showEditBaseUrlDialog(context, ref, config),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 13,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '改',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: config.enabled,
                  onChanged: (v) => ctrl.toggleProvider(config.id, v),
                ),
                // 自定义站可整体删除（内置预设不可）。
                if (config.presetKey == Presets.openaiCustom)
                  IconButton(
                    tooltip: '删除此平台',
                    onPressed: () =>
                        _confirmDeleteProvider(context, ref, config),
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                'ⓘ $hint',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.tertiary),
              ),
            ],
            const Divider(height: 20),
            for (final row in section.keys)
              _KeyTile(section: section, row: row),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showAddKeyDialog(context, ref, config),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加 AK'),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: section.keys.isEmpty
                      ? null
                      : () => ctrl.testProvider(config.id),
                  icon: section.testingKeyId != null
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('测试连通'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/debug'),
                  child: const Text('调试日志'),
                ),
              ],
            ),
            if (section.test != null) ...[
              const SizedBox(height: 6),
              _TestResultView(result: section.test!),
            ],
          ],
        ),
      ),
    );
  }

  /// 删除自定义平台确认（被任务引用时由 repo 拦截）。
  void _confirmDeleteProvider(
    BuildContext context,
    WidgetRef ref,
    ProviderConfig config,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Text('删除平台？'),
        content: SizedBox(
          width: 360,
          child: Text(
            '「${config.displayName}」将被删除（仅删除平台配置，密钥与任务记录保留）。'
            '被任务引用的平台无法删除。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(settingsProvider.notifier).deleteProvider(config.id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 编辑 Base URL：预设默认值不可随意变更，但提供入口（§10.6 用户反馈）。
  /// 控制器生命周期随 _EditBaseUrlDialog State（U-28：弹窗退场动画期间
  /// TextField 仍活着，.then dispose 会在动画期挂已销毁 listener → 崩）。
  Future<void> _showEditBaseUrlDialog(
    BuildContext context,
    WidgetRef ref,
    ProviderConfig config,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _EditBaseUrlDialog(config: config),
    );
  }

  Future<void> _showAddKeyDialog(
    BuildContext context,
    WidgetRef ref,
    ProviderConfig config,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _AddKeyDialog(config: config),
    );
  }
}

class _KeyTile extends ConsumerWidget {
  const _KeyTile({required this.section, required this.row});

  final ProviderSection section;
  final KeyRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(settingsProvider.notifier);
    final key = row.key;
    final disabled = key.disabled;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        disabled
            ? Icons.key_off
            : (key.isDefault ? Icons.key : Icons.key_off_outlined),
        size: 20,
        color: disabled
            ? Theme.of(context).colorScheme.outline
            : (key.isDefault
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              key.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (key.isDefault && !disabled) ...[
            const SizedBox(width: 6),
            const _DefaultBadge(),
          ],
          if (disabled) ...[const SizedBox(width: 6), const _DisabledBadge()],
        ],
      ),
      subtitle: Text(
        [
          row.masked ?? '(密钥未读取到)',
          if (key.channelNote.isNotEmpty) key.channelNote,
          if (disabled) '已停用（被任务引用，密文保留）',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        itemBuilder: (_) => [
          // 停用 AK：被任务引用不可物理删除，只提供测试与重新启用。
          if (!disabled && !key.isDefault)
            const PopupMenuItem(value: 'default', child: Text('设为默认')),
          const PopupMenuItem(value: 'test', child: Text('用此 AK 测试')),
          if (disabled)
            const PopupMenuItem(value: 'enable', child: Text('重新启用'))
          else
            const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
        onSelected: (v) => switch (v) {
          'default' => ctrl.setDefaultKey(section.config.id, key.id),
          'test' => ctrl.testProvider(section.config.id, keyId: key.id),
          'enable' => ctrl.enableKey(section.config.id, key.id),
          'delete' => _confirmDelete(context, ref, section.config.id, key),
          _ => null,
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String providerId,
    ApiKey key,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Text('删除 AK？'),
        content: SizedBox(
          width: 340,
          child: Text(
            '「${key.label}」将被删除（密文一并清除）。'
            '被任务引用的 AK 无法物理删除，会转为停用'
            '（不出现在创作页选择列表，可随时重新启用；'
            '历史任务恢复轮询不受影响）。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final message = await ref
        .read(settingsProvider.notifier)
        .deleteKey(providerId, key.id);
    if (message != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('该 Key $message')));
    }
  }
}

class _DefaultBadge extends StatelessWidget {
  const _DefaultBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '默认',
        style: TextStyle(fontSize: 10, color: scheme.onPrimaryContainer),
      ),
    );
  }
}

class _DisabledBadge extends StatelessWidget {
  const _DisabledBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '已停用',
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _TestResultView extends StatelessWidget {
  const _TestResultView({required this.result});

  final ModelTestResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!result.ok) {
      return Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '✗ ${result.message ?? '测试失败'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(Icons.check_circle_outline, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '✓ ${result.modelCount} 个模型可用'
            '${result.sampleIds.isEmpty ? '' : ' · ${result.sampleIds.join(', ')}'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.primary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// 添加自定义站：显示名 / Base URL / 任务模式 / 编辑参考图字段。
Future<void> _showAddCustomDialog(BuildContext context, WidgetRef ref) async {
  final input = await showDialog<(String, String, TaskMode, String)>(
    context: context,
    builder: (ctx) => const _AddCustomDialog(),
  );
  if (input == null) return;
  final (name, url, taskMode, editField) = input;
  final success = await ref
      .read(settingsProvider.notifier)
      .addCustomProvider(
        displayName: name,
        baseUrl: url,
        taskMode: taskMode,
        editImageField: editField,
      );
  if (success && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已添加，请先「测试连通」拉取模型')));
  }
}

/// 修改 Base URL 弹窗（U-28：控制器生命周期随 State.dispose——对话框完全
/// 退场后才销毁，规避退场动画期间使用已 disposed controller 的崩溃）。
class _EditBaseUrlDialog extends ConsumerStatefulWidget {
  const _EditBaseUrlDialog({required this.config});

  final ProviderConfig config;

  @override
  ConsumerState<_EditBaseUrlDialog> createState() => _EditBaseUrlDialogState();
}

class _EditBaseUrlDialogState extends ConsumerState<_EditBaseUrlDialog> {
  late final _urlCtrl = TextEditingController(text: widget.config.baseUrl);

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presetDefault =
        Presets.builtin[widget.config.presetKey]?.baseUrl ??
        widget.config.baseUrl;
    return AlertDialog(
      title: Text('修改 Base URL · ${widget.config.displayName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _urlCtrl,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'Base URL（含 /v1）',
                helperText: '预设默认：$presetDefault',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _urlCtrl.text = presetDefault,
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('恢复预设默认', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            ref
                .read(settingsProvider.notifier)
                .updateBaseUrl(widget.config.id, _urlCtrl.text);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 添加 API Key 弹窗（U-28：控制器生命周期随 State.dispose）。
class _AddKeyDialog extends ConsumerStatefulWidget {
  const _AddKeyDialog({required this.config});

  final ProviderConfig config;

  @override
  ConsumerState<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends ConsumerState<_AddKeyDialog> {
  final _labelCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();

  @override
  void dispose() {
    _labelCtrl.dispose();
    _noteCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('添加 AK · ${widget.config.displayName}'),
      // 桌面定宽（§10.9 补充）：密钥弹窗不随窗口拉伸。
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _labelCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '如：我的生图Key',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _noteCtrl,
                decoration: const InputDecoration(
                  labelText: '通道备注（可选）',
                  hintText: '如：OpenAI 生图 Key',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _secretCtrl,
                obscureText: true,
                maxLines: 1,
                decoration: const InputDecoration(
                  labelText: '密钥 sk-…',
                  hintText: '仅粘贴，保存后不再回显',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final label = _labelCtrl.text.trim();
            final secret = _secretCtrl.text.trim();
            if (label.isEmpty || secret.isEmpty) return;
            Navigator.pop(context);
            ref
                .read(settingsProvider.notifier)
                .addKey(
                  providerId: widget.config.id,
                  label: label,
                  channelNote: _noteCtrl.text.trim(),
                  secret: secret,
                );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 添加自定义站弹窗（U-28：控制器生命周期随 State.dispose）。
/// 提交返回 (显示名, BaseURL, 任务模式, 编辑图字段) record；取消返回 null。
class _AddCustomDialog extends StatefulWidget {
  const _AddCustomDialog();

  @override
  State<_AddCustomDialog> createState() => _AddCustomDialogState();
}

class _AddCustomDialogState extends State<_AddCustomDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  var _taskMode = TaskMode.syncHold;
  var _editField = 'image';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自定义 OpenAI 兼容站'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '显示名',
                hintText: '如：我的中转站',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Base URL（含 /v1）',
                hintText: 'https://example.com/v1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 2),
                const Text('任务模式', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<TaskMode>(
                    segments: const [
                      ButtonSegment(
                        value: TaskMode.syncHold,
                        label: Text('同步', style: TextStyle(fontSize: 12)),
                      ),
                      ButtonSegment(
                        value: TaskMode.asyncTask,
                        label: Text('异步', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    selected: {_taskMode},
                    onSelectionChanged: (s) =>
                        setState(() => _taskMode = s.first),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 2),
                const Text('编辑图字段', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _editField,
                  items: const [
                    DropdownMenuItem(value: 'image', child: Text('image')),
                    DropdownMenuItem(value: 'image[]', child: Text('image[]')),
                  ],
                  onChanged: (v) =>
                      v == null ? null : setState(() => _editField = v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'ⓘ 同步=请求挂起直接返回结果；异步=提交任务后轮询（少数站支持）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (
              name,
              _urlCtrl.text.trim(),
              _taskMode,
              _editField,
            ));
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}
