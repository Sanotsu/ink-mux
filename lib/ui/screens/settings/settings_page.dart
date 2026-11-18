import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers/debug_controller.dart';
import '../../../app/providers/repos.dart';
import '../../../app/providers/settings_controller.dart';
import '../../../core/constants.dart';
import '../../../core/theme/density.dart';
import '../../../data/platform/storage_permission.dart';
import '../../../data/repos/backup_repo.dart';

/// 设置页（§10.6，2026-11-16 重构）：首页只留分区入口——平台/Key/模型管理
/// 拆入 [ProvidersPage]（/settings/providers，平台增多后首页不再无限拉长），
/// 本页保留 数据备份 / 任务引擎 / 调试 / 关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    // 首帧后加载，避免 build 期间改状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(settingsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final d = AppDensity.of(context);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: MediaQuery.sizeOf(context).width < 600 ? 48 : 56,
        title: const Text('设置'),
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          // 内容区最大宽度约束（2026-11-15 重构）：超宽屏不再整行拉满，
          // 行密度与桌面成熟设置页（VS Code/Linear 式 720~900px 内容宽）一致；
          // 移动端窗口 <840 时不受影响。
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
                    // 平台与模型管理入口（2026-11-16 拆分）：平台卡整体迁入
                    // /settings/providers，首页不再随平台数量线性拉长。
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader(
                            '平台与模型',
                            icon: Icons.hub_outlined,
                          ),
                          InkWell(
                            onTap: () => context.push('/settings/providers'),
                            child: _SettingsRow(
                              icon: Icons.dns_outlined,
                              title: '平台管理',
                              subtitle:
                                  '${state.sections.length} 个平台 · 开关 / API Key / 模型 / Base URL / 自定义站',
                              trailing: Icon(
                                Icons.chevron_right,
                                size: 22,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    SizedBox(height: d.cardGap),
                    _DataCard(),
                    SizedBox(height: d.cardGap),
                    _EnginePrefsCard(),
                    SizedBox(height: d.cardGap),
                    _DebugPrefsCard(),
                    SizedBox(height: d.cardGap),
                    _AboutCard(),
                  ],
                ),
              ),
            ),
    );
  }
}

// ===================== 设置页行模板（2026-11-15 重构） =====================
// 参考 Material 设置模式（分组 + 具体节标题 + 统一行模板）与桌面成熟实践
// （内容最大宽度）。全页行样式统一：leading 图标 + 标题/副标题 + 右侧控件。

/// 卡头：图标 + 左对齐标题（替代原先部分卡居中标题的不一致写法）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        d.cardPadding,
        d.cardPadding,
        d.cardPadding,
        d.cardPadding * 0.5,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// 统一设置行：icon + 标题（+副标题）+ 右侧控件，行内垂直居中。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = AppDensity.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: d.cardPadding,
        vertical: d.cardPadding * 0.4,
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyLarge),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          ?trailing,
        ],
      ),
    );
  }
}

/// 行间分隔线：缩进对齐行文字起点（22 图标 + 14 间距）。
class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    final d = AppDensity.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: d.cardPadding),
      child: const Divider(height: 1, indent: 36),
    );
  }
}

/// 数据与备份（M3/U-36）：配置导入导出（不含 Key）+ 备份恢复；平台管理已拆入 providers_page。
class _DataCard extends ConsumerWidget {
  const _DataCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = AppDensity.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('数据与备份', icon: Icons.dns_outlined),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: d.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _exportConfig(context, ref),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('导出配置'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _importConfig(context, ref),
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: const Text('导入配置'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'ⓘ 导出内容：平台配置与提示词模板；不含 API Key、任务与图片数据',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(
                      Icons.backup_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '备份与恢复（含图片）',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _exportBackup(context, ref),
                      icon: const Icon(Icons.backup_outlined, size: 18),
                      label: const Text('备份数据'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _importBackup(context, ref),
                      icon: const Icon(Icons.restore_outlined, size: 18),
                      label: const Text('恢复备份'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'ⓘ 备份内容：平台配置、模板、任务记录、画廊图片与偏好；'
                  '不含 API Key（secure storage 不可导出，恢复后需重新粘贴）。'
                  '恢复时已存在的同 id 数据一律跳过不覆盖',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ===================== 备份与恢复 =====================

  /// 进度对话框：ValueNotifier 驱动阶段文案 + 进度条。
  static Future<void> _showProgressDialog(
    BuildContext context,
    ValueNotifier<BackupProgress> progress,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('请稍候…'),
          content: ValueListenableBuilder<BackupProgress>(
            valueListenable: progress,
            builder: (context, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.phase, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: p.value),
                const SizedBox(height: 8),
                Text(
                  p.total > 0 ? '${p.done} / ${p.total}' : '',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 备份数据（流式压缩直接写目标位置，zip 内存占用恒定，几 GB 图片库也可用）：
  /// · Windows：选目录后 archive ZipFileEncoder 流式直写所选位置
  /// · Android（U-32，参考 free-fitness）：请求「所有文件访问」授权 →
  ///   选目录 → 同样流式直写用户目录（授权后 dart:io 可直写公共目录）；
  ///   拒绝授权则回退私有目录 + 完成后分享面板兜底。
  ///   （file_picker 的 saveFile 强制全量 bytes 入内存，与流式冲突，不采用。）
  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final progress = ValueNotifier<BackupProgress>(const BackupProgress('准备…'));
    String? chosenDir;
    if (Platform.isWindows) {
      chosenDir = await FilePicker.getDirectoryPath(dialogTitle: '选择备份保存位置');
      if (chosenDir == null || chosenDir.isEmpty) return;
    } else if (Platform.isAndroid) {
      final granted = await requestStoragePermission();
      if (!context.mounted) return;
      if (granted) {
        chosenDir = await FilePicker.getDirectoryPath(dialogTitle: '选择备份保存位置');
        if (chosenDir == null || chosenDir.isEmpty) return;
      }
      // 未授权：chosenDir 保持 null → 走私有目录 + 完成后分享面板兜底。
    }
    try {
      Directory targetParent;
      if (chosenDir != null) {
        targetParent = Directory(chosenDir);
      } else {
        final dir = await getApplicationDocumentsDirectory();
        targetParent = Directory(
          '${dir.path}${Platform.pathSeparator}InkMux'
          '${Platform.pathSeparator}backups',
        );
      }
      if (!await targetParent.exists()) {
        await targetParent.create(recursive: true);
      }
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final targetPath =
          '${targetParent.path}${Platform.pathSeparator}inkmux_backup_$stamp.zip';
      debugPrint('[Backup] 目标路径：$targetPath（用户选择目录：$chosenDir）');
      if (!context.mounted) return;
      // 进度对话框 barrierDismissible 且无自动关闭逻辑，完成后必须主动
      // pop（历史 bug：await dialog 死等一个永不完成的 Future，进度框卡住）。
      // showDialog 默认弹在根 Navigator（useRootNavigator: true），pop 必须
      // 同层级 rootNavigator: true——否则弹掉的是 go_router 分支嵌套
      // Navigator 的当前 route（设置页自身），导致导航树销毁黑屏。
      final dialogFuture = _showProgressDialog(context, progress);
      // Android 授权后 dart:io 可直写用户目录（MANAGE_EXTERNAL_STORAGE），
      // archive ZipFileEncoder 流式直写 targetPath，无临时副本。
      final skippedTooLarge = await ref
          .read(backupRepoProvider)
          .exportBackup(targetPath, onProgress: (p) => progress.value = p);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await dialogFuture;
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('备份完成'),
          content: Text(
            '已导出到：\n$targetPath'
            '${skippedTooLarge > 0 ? '\n\n⚠️ 跳过 $skippedTooLarge 条超限任务记录（图片不受影响）；明细见调试日志' : ''}',
          ),
          actions: [
            if (Platform.isAndroid && chosenDir == null)
              TextButton.icon(
                // 私有目录兜底路径（未授权存储）：经系统分享面板「保存到文件」
                // 转移到任意位置（FileProvider 路径引用，不复制字节到内存）。
                onPressed: () async {
                  Navigator.pop(ctx);
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(targetPath, mimeType: 'application/zip')],
                      title: 'InkMux 备份',
                    ),
                  );
                },
                icon: const Icon(Icons.share_outlined, size: 16),
                label: const Text('保存到其他位置'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('备份失败：$e')));
      }
    } finally {
      progress.dispose();
    }
  }

  /// 恢复备份：选 zip → 确认（跳过语义 + Key 不恢复）→ 进度 → 结果摘要。
  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (picked == null) return;
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复备份？'),
          content: const Text(
            '将按备份包恢复平台配置、模板、任务记录、画廊图片与偏好。\n\n'
            '· 已存在的同 id 数据一律跳过，不覆盖当前数据\n'
            '· API Key 不在备份内，恢复后需到设置页重新粘贴\n'
            '· 图片文件按相对路径写回本机文档目录',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始恢复'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final progress = ValueNotifier<BackupProgress>(
        const BackupProgress('准备…'),
      );
      if (!context.mounted) return;
      // 同导出：完成后（或异常时）必须主动 pop 根 Navigator 的进度对话框。
      final dialogFuture = _showProgressDialog(context, progress);
      try {
        final result = await ref
            .read(backupRepoProvider)
            .importBackup(picked.path!, onProgress: (p) => progress.value = p);
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        await dialogFuture;
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('恢复完成'),
            content: Text(result.summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('好的'),
              ),
            ],
          ),
        );
        // 恢复批量改写了 DB：刷新设置页 + 广播画廊/创作页立即重载
        // （历史 bug：常驻页面 State 存活，不重启永不重查库）。
        await ref.read(settingsProvider.notifier).notifyDataImported();
      } on Exception {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          await dialogFuture;
        }
        rethrow;
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
      }
    }
  }

  /// 导出配置：file_picker 13.x saveFile（bytes 必传，返回目标 Uri）。
  Future<void> _exportConfig(BuildContext context, WidgetRef ref) async {
    try {
      final data = await ref.read(settingsProvider.notifier).exportConfig();
      final jsonText = const JsonEncoder.withIndent('  ').convert(data);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final uri = await FilePicker.saveFile(
        fileName: 'inkmux_config_$stamp.json',
        bytes: Uint8List.fromList(utf8.encode(jsonText)),
        mimeType: 'application/json',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(uri == null ? '已取消' : '已导出到：$uri')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 导入配置：选择 JSON → repo 合并（平台更新/新增，模板并入）。
  Future<void> _importConfig(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      Object? decoded;
      try {
        decoded = const JsonDecoder().convert(utf8.decode(bytes));
      } on FormatException {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('文件不是合法 JSON')));
        }
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('配置文件必须是 JSON 对象')));
        }
        return;
      }
      final msg = await ref
          .read(settingsProvider.notifier)
          .importConfig(decoded);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }
}

class _EnginePrefsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('任务引擎', icon: Icons.tune),
          _SettingsRow(
            icon: Icons.layers_outlined,
            title: '并发上限 · 单平台',
            subtitle: '同一平台同时提交的生成任务数；修改即刻生效',
            trailing: DropdownButton<int>(
              value: state.concurrencyPerProvider,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 个任务')),
                DropdownMenuItem(value: 2, child: Text('2 个任务')),
                DropdownMenuItem(value: 3, child: Text('3 个任务')),
              ],
              onChanged: (v) =>
                  v == null ? null : ctrl.setConcurrencyPerProvider(v),
            ),
          ),
          const _SettingsDivider(),
          _SettingsRow(
            icon: Icons.public,
            title: '并发上限 · 全局',
            subtitle: '所有平台合计的同时提交数',
            trailing: DropdownButton<int>(
              value: state.concurrencyGlobal,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 2, child: Text('2 个任务')),
                DropdownMenuItem(value: 4, child: Text('4 个任务')),
                DropdownMenuItem(value: 6, child: Text('6 个任务')),
                DropdownMenuItem(value: 8, child: Text('8 个任务')),
              ],
              onChanged: (v) => v == null ? null : ctrl.setConcurrencyGlobal(v),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _DebugPrefsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('调试', icon: Icons.bug_report_outlined),
          _SettingsRow(
            icon: Icons.terminal_outlined,
            title: '显示调试页入口',
            subtitle: '开启后桌面端侧栏显示「调试」页（默认关闭）',
            trailing: Switch(
              value: state.debugPageEntry,
              onChanged: ctrl.setDebugPageEntry,
            ),
          ),
          const _SettingsDivider(),
          _SettingsRow(
            icon: Icons.description_outlined,
            title: '记录请求/响应日志',
            subtitle: '关闭后拦截器直通不落库（终端镜像仍可用）',
            trailing: Switch(
              value: state.debugEnabled,
              onChanged: ctrl.setDebugEnabled,
            ),
          ),
          const _SettingsDivider(),
          _SettingsRow(
            icon: Icons.inventory_2_outlined,
            title: '环形上限',
            subtitle: '调试日志最大保留条数，超出后滚动丢弃',
            trailing: DropdownButton<int>(
              value: state.ringLimit,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 1000, child: Text('1,000 条')),
                DropdownMenuItem(value: 5000, child: Text('5,000 条')),
                DropdownMenuItem(value: 10000, child: Text('1 万条')),
                DropdownMenuItem(value: 20000, child: Text('2 万条')),
              ],
              onChanged: (v) => v == null ? null : ctrl.setRingLimit(v),
            ),
          ),
          const _SettingsDivider(),
          // 动作行：与调试页共用同一控制器能力（clearAll / exportToFile）。
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppDensity.of(context).cardPadding,
              vertical: 6,
            ),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => _exportLogs(context, ref),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出全部日志'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => _confirmClearLogs(context, ref),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清空调试日志'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 导出全部日志（U-46）：与备份导出同款位置策略——私有目录
  /// （/data/user/0/...）用户不可见，改为：
  /// · Windows：选目录直写；
  /// · Android：请求「所有文件访问」授权 → 选目录直写；拒绝授权回退
  ///   私有目录 + 完成后分享面板兜底转存。
  Future<void> _exportLogs(BuildContext context, WidgetRef ref) async {
    final debugCtrl = ref.read(debugLogProvider.notifier);
    String? chosenDir;
    if (Platform.isWindows) {
      chosenDir = await FilePicker.getDirectoryPath(dialogTitle: '选择日志导出位置');
      if (chosenDir == null || chosenDir.isEmpty) return;
    } else if (Platform.isAndroid) {
      final granted = await requestStoragePermission();
      if (!context.mounted) return;
      if (granted) {
        chosenDir = await FilePicker.getDirectoryPath(dialogTitle: '选择日志导出位置');
        if (chosenDir == null || chosenDir.isEmpty) return;
      }
      // 未授权：chosenDir 保持 null → 走私有目录 + 分享面板兜底。
    }
    try {
      final path = await debugCtrl.exportToFile(
        targetPath: chosenDir == null
            ? null
            : '$chosenDir${Platform.pathSeparator}'
                  'inkmux-debug-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}.txt',
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('日志已导出'),
          content: Text('已导出到：\n$path'),
          actions: [
            if (Platform.isAndroid && chosenDir == null)
              TextButton.icon(
                // 私有目录兜底路径（未授权存储）：经系统分享面板转存。
                onPressed: () async {
                  Navigator.pop(ctx);
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(path, mimeType: 'text/plain')],
                      title: 'InkMux 调试日志',
                    ),
                  );
                },
                icon: const Icon(Icons.share_outlined, size: 16),
                label: const Text('保存到其他位置'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  void _confirmClearLogs(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Text('清空调试日志？'),
        content: const SizedBox(
          width: 340,
          child: Text('将删除全部调试日志记录（环形存储清零），不影响任务与图片。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(debugLogProvider.notifier).clearAll();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('关于', icon: Icons.info_outline),
          _SettingsRow(
            icon: Icons.workspace_premium_outlined,
            title: '${AppMeta.name} ${AppMeta.version}',
            subtitle: '本地优先 · 无遥测 · Key 仅存系统安全存储',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
