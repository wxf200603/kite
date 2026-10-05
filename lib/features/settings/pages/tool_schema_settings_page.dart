import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/tool_schema_override.dart';
import '../../../core/database/business_preferences.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/environment_provider.dart';
import '../../../core/services/mcp_call_stats_service.dart';
import '../../../core/services/tools/built_in_tool_catalog.dart';
import '../../../core/services/toolpkg/toolpkg_channel.dart';
import '../../../core/services/toolpkg/toolpkg_permission_service.dart';
import '../../../features/home/services/local_tools_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../widgets/tool_schema_ui.dart';
import 'tool_schema_editor_page.dart';

class ToolSchemaSettingsPage extends StatefulWidget {
  const ToolSchemaSettingsPage({super.key});

  @override
  State<ToolSchemaSettingsPage> createState() => _ToolSchemaSettingsPageState();
}

class _ToolSchemaSettingsPageState extends State<ToolSchemaSettingsPage> {
  @override
  void initState() {
    super.initState();
    DeviceLocalTools.prefetchIosCapabilities().then((_) {
      if (mounted) setState(() {});
    });
    // If the PRoot backend is selected, push the current rootfs dir to the
    // native ToolPkg plugin on page open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = context.read<SettingsProvider>();
      if (settings.toolpkgHostBackend == 'proot') {
        final rootfs = context.read<EnvironmentProvider>().state.rootfsDir;
        ToolPkgChannel().setRootfsDir(rootfs);
      }
    });
  }

  Future<void> _confirmResetAll() async {
    final confirmed = await confirmResetAllToolSchemas(context);
    if (!confirmed || !mounted) return;
    await context.read<SettingsProvider>().resetAllToolSchemaOverrides();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final catalog = BuiltInToolCatalog.entries(
      lang: settings.resolvedMemoryPromptLang,
      legacyMemoryMode: settings.legacyMemoryMode,
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.toolSchemaSettingsPageTitle),
        actions: [
          Tooltip(
            message: l10n.toolSchemaSettingsResetAll,
            child: IosIconButton(
              icon: Lucide.RotateCcw,
              color: cs.onSurface,
              size: 20,
              minSize: 44,
              semanticLabel: l10n.toolSchemaSettingsResetAll,
              onTap: _confirmResetAll,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SectionCard(
              children: [
                SwitchListTile(
                  title: const Text('启用本地 llama.cpp 推理'),
                  subtitle: const Text(
                    '使用移植的 llama.cpp JNI 在设备端本地推理。模型路径来自 Kite 现有模型选择器。关闭时完全不初始化原生层。',
                  ),
                  value: settings.localLlmEnabled,
                  onChanged: (v) => settings.setLocalLlmEnabled(v),
                ),
                SwitchListTile(
                  title: const Text('启用本地 JS 沙箱（QuickJS+ToolPkg）'),
                  subtitle: const Text(
                    '使用移植的 QuickJS 引擎执行临时 JS 或加载 .toolpkg 包。文件/网络权限按调用单独控制。关闭时完全不初始化。',
                  ),
                  value: settings.quickJsSandboxEnabled,
                  onChanged: (v) => settings.setQuickJsSandboxEnabled(v),
                ),
                ListTile(
                  enabled: settings.quickJsSandboxEnabled,
                  title: const Text('ToolPkg 宿主后端'),
                  subtitle: Text(
                    settings.quickJsSandboxEnabled
                        ? _backendLabel(settings.toolpkgHostBackend)
                        : '需先启用本地 JS 沙箱',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: settings.quickJsSandboxEnabled
                      ? () => _showBackendPicker(context)
                      : null,
                ),
                SwitchListTile(
                  enabled: settings.quickJsSandboxEnabled,
                  title: const Text('ToolPkg 允许网络访问'),
                  subtitle: const Text(
                    '允许声明了 network 能力的工具包通过 Dart HTTP 客户端发起请求。关闭时所有工具包网络调用直接返回权限错误。不做代理/VPN。',
                  ),
                  value: settings.quickJsSandboxEnabled &&
                      settings.toolpkgNetworkEnabled,
                  onChanged: settings.quickJsSandboxEnabled
                      ? (v) => settings.setToolpkgNetworkEnabled(v)
                      : null,
                ),
                ListTile(
                  enabled: settings.quickJsSandboxEnabled &&
                      settings.toolpkgNetworkEnabled,
                  title: const Text('网络域名白名单'),
                  subtitle: Text(
                    settings.toolpkgNetworkWhitelist.isEmpty
                        ? '未设置：允许所有域名'
                        : settings.toolpkgNetworkWhitelist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: (settings.quickJsSandboxEnabled &&
                          settings.toolpkgNetworkEnabled)
                      ? () => _showNetworkWhitelistDialog(context)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('启用实验性轻量工作流'),
                  subtitle: const Text(
                    '基于现有 MCP 工具链的简单状态机编排（步骤列表、重试、失败策略）。关闭时该模块完全不初始化，零开销。',
                  ),
                  value: settings.workflowPluginEnabled,
                  onChanged: (v) => settings.setWorkflowPluginEnabled(v),
                ),
                SwitchListTile(
                  title: const Text('实验性会话增强记忆'),
                  subtitle: const Text(
                    '在现有会话数据库上做自动摘要与关键词向量召回，不新建任何表。关闭时完全不跑摘要与召回。',
                  ),
                  value: settings.memoryEnhancementEnabled,
                  onChanged: (v) => settings.setMemoryEnhancementEnabled(v),
                ),
                SwitchListTile(
                  title: const Text('后台自动释放模型'),
                  subtitle: const Text(
                    'App 退到后台时自动卸载已加载的 llama.cpp 模型以释放内存。需先开启本地 llama.cpp 推理。',
                  ),
                  value: settings.llmBgReleaseModel,
                  onChanged: settings.localLlmEnabled
                      ? (v) => settings.setLlmBgReleaseModel(v)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('充电时可选预热'),
                  subtitle: const Text(
                    '设备充电时对最近使用的模型做 mmap 预热以加快首次推理。默认关闭。需先开启本地 llama.cpp 推理。',
                  ),
                  value: settings.llmWarmupOnCharge,
                  onChanged: settings.localLlmEnabled
                      ? (v) => settings.setLlmWarmupOnCharge(v)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Token 流平滑'),
                  subtitle: const Text(
                    '对本地 llama.cpp 流式输出做轻量时间缓冲，减少逐 token 抖动。仅 UI 体验优化，不修改推理输出。默认关闭，关闭时零开销。',
                  ),
                  value: settings.tokenStreamSmoothing,
                  onChanged: settings.localLlmEnabled
                      ? (v) => settings.setTokenStreamSmoothing(v)
                      : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SectionCard(
              children: [
                ListTile(
                  title: const Text('ToolPkg 权限日志'),
                  subtitle: const Text('查看工具包能力授权/拒绝记录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPermissionLog(context),
                ),
                ListTile(
                  title: const Text('ToolPkg 调试日志'),
                  subtitle: const Text('查看 JS console.log/warn/error 输出'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: settings.quickJsSandboxEnabled,
                  onTap: settings.quickJsSandboxEnabled
                      ? () => _showConsoleLog(context)
                      : null,
                ),
                ListTile(
                  title: const Text('工具调用统计'),
                  subtitle: const Text(
                    '本地统计 mcp_native_llama / mcp_native_js / ToolPkg 的调用次数、平均耗时与失败数。数据仅存本机，不上传。',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showCallStats(context),
                ),
              ],
            ),
          ),
          // ---- 高级指引：Root 与无障碍（纯文字，无自动执行按钮）----
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SectionCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '⚠️ Root 提示',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '如果不想每次 Root 都弹窗，请前往 KernelSU / Magisk 超级用户列表，把 Kite 设为【永久允许、关闭通知】。\n\n风险：永久允许后 ToolPkg 脚本可直接调用 Root，仅加载信任的 .toolpkg 包。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '💡 无障碍指引',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '不想手动开启无障碍，可以电脑 ADB 一次性授权（无需 Root）：',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          'adb shell settings put secure enabled_accessibility_services com.psyche.kelivo/com.psyche.kelivo.services.KiteAccessibilityService\n'
                          'adb shell settings put secure accessibility_enabled 1',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '备注：部分 ROM 重启后会失效；仍可通过下方按钮正常跳转系统无障碍设置页。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.settings, size: 18),
                        label: const Text('跳转系统无障碍设置'),
                        onPressed: () =>
                            DeviceLocalTools.openAccessibilitySettings(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final group in BuiltInToolGroup.values)
            ..._groupSection(
              context,
              group: group,
              entries: catalog.where((e) => e.group == group).toList(),
              overrides: settings.toolSchemaOverrides,
            ),
        ],
      ),
    );
  }

  void _showPermissionLog(BuildContext context) {
    final prefs = context.read<BusinessPreferences>();
    final service = ToolPkgPermissionService(prefs);
    final entries = service.getAuditLog();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ToolPkg 权限日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? const Text('暂无权限记录。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final decision = e['decision']?.toString() ?? '';
                    final cap = e['capability']?.toString() ?? '';
                    final pkg = e['packageId']?.toString() ?? '';
                    final ts = e['ts']?.toString() ?? '';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        decision == 'denied'
                            ? Icons.block
                            : decision == 'temporary'
                                ? Icons.timer_outlined
                                : Icons.check_circle_outline,
                        size: 18,
                      ),
                      title: Text('$pkg · $cap'),
                      subtitle: Text(ts),
                      trailing: Text(
                        decision == 'denied'
                            ? '拒绝'
                            : decision == 'temporary'
                                ? '临时'
                                : '允许',
                      ),
                    );
                  },
                ),
        ),
        actions: [
          if (entries.isNotEmpty)
            TextButton(
              onPressed: () async {
                await service.clearAuditLog();
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: const Text('清空'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showConsoleLog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ConsoleLogDialog(),
    );
  }

  static const _backendOptions = <String, String>{
    'normal': '普通 Shell',
    'root': 'Root Shell (su)',
    'proot': 'PRoot（复用 Kite rootfs）',
  };

  String _backendLabel(String id) =>
      _backendOptions[id] ?? '普通 Shell';

  void _showBackendPicker(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('选择 ToolPkg 宿主后端'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _backendOptions.entries.map((e) {
              return RadioListTile<String>(
                title: Text(e.value),
                value: e.key,
                groupValue: settings.toolpkgHostBackend,
                onChanged: (v) async {
                  if (v != null) {
                    await settings.setToolpkgHostBackend(v);
                    if (v == 'proot') {
                      final rootfs = context
                          .read<EnvironmentProvider>()
                          .state
                          .rootfsDir;
                      await ToolPkgChannel().setRootfsDir(rootfs);
                    }
                  }
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _showNetworkWhitelistDialog(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final controller = TextEditingController(
      text: settings.toolpkgNetworkWhitelist,
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ToolPkg 网络域名白名单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '用英文逗号分隔域名，支持 * 通配符，例如：\n'
              '*.example.com, github.com, api.openai.com\n\n'
              '留空表示不限制域名（仍受全局开关控制）。',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '*.example.com, github.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await settings.setToolpkgNetworkWhitelist(
                controller.text.trim(),
              );
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showCallStats(BuildContext context) {
    final prefs = context.read<BusinessPreferences>();
    final service = McpCallStatsService(prefs);
    final aggregates = service.getAggregated();
    final maxCount = aggregates.isEmpty
        ? 1
        : aggregates
            .map((a) => a.count)
            .reduce((a, b) => a > b ? a : b);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('工具调用统计'),
          content: SizedBox(
            width: double.maxFinite,
            child: aggregates.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('暂无调用记录')),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...aggregates.map((a) {
                        final ratio = maxCount == 0 ? 0.0 : a.count / maxCount;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    a.toolType,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${a.count} 次',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: ratio.clamp(0.0, 1.0),
                                  minHeight: 8,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '平均耗时 ${a.avgDurationMs} ms　'
                                '失败 ${a.failureCount} 次　'
                                '成功率 ${(a.successRate * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: aggregates.isEmpty
                  ? null
                  : () async {
                      await service.clear();
                      if (ctx.mounted) setSt(() {});
                    },
              child: const Text('清空统计'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _groupSection(
    BuildContext context, {
    required BuiltInToolGroup group,
    required List<BuiltInToolCatalogEntry> entries,
    required Map<String, ToolSchemaOverride> overrides,
  }) {
    if (entries.isEmpty) return const [];
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final title = switch (group) {
      BuiltInToolGroup.search => l10n.toolSchemaSettingsGroupSearch,
      BuiltInToolGroup.memory => l10n.toolSchemaSettingsGroupMemory,
      BuiltInToolGroup.local => l10n.toolSchemaSettingsGroupLocal,
      BuiltInToolGroup.workspace => l10n.workspacesTitle,
    };
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ),
      if (group == BuiltInToolGroup.memory)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            l10n.toolSchemaSettingsMemoryLangNote,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      SectionCard(
        padding: EdgeInsets.zero,
        children: [
          for (final entry in entries)
            ToolSchemaToolRow(
              entry: entry,
              schemaOverride: overrides[entry.name],
              onTap: () => _openEditor(context, entry, overrides[entry.name]),
            ),
        ],
      ),
      const SizedBox(height: 18),
    ];
  }

  Future<void> _openEditor(
    BuildContext context,
    BuiltInToolCatalogEntry entry,
    ToolSchemaOverride? schemaOverride,
  ) async {
    final result = await Navigator.of(context).push<ToolSchemaOverride?>(
      MaterialPageRoute(
        builder: (_) => ToolSchemaEditorPage(
          toolName: entry.name,
          defaultDefinition: entry.defaultDefinition,
          initialOverride: schemaOverride,
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<SettingsProvider>().setToolSchemaOverride(
      entry.name,
      result,
    );
  }
}

/// Scrollable, live-updating dialog that shows QuickJS console output.
class _ConsoleLogDialog extends StatefulWidget {
  @override
  State<_ConsoleLogDialog> createState() => _ConsoleLogDialogState();
}

class _ConsoleLogDialogState extends State<_ConsoleLogDialog> {
  final ScrollController _scroll = ScrollController();
  final List<ToolPkgConsoleEntry> _entries = <ToolPkgConsoleEntry>[];
  StreamSubscription<ToolPkgConsoleEntry>? _sub;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final atBottom = _scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 40;
      if (atBottom != _autoScroll) setState(() => _autoScroll = atBottom);
    });
    _loadInitial();
    _sub = ToolPkgChannel().consoleLogStream.listen((entry) {
      if (!mounted) return;
      setState(() {
        _entries.add(entry);
        if (_entries.length > 500) _entries.removeAt(0);
      });
      if (_autoScroll) _jumpToBottom();
    });
  }

  Future<void> _loadInitial() async {
    final past = await ToolPkgChannel().getConsoleLogs();
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(past);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  Future<void> _clear() async {
    await ToolPkgChannel().clearConsoleLogs();
    if (!mounted) return;
    setState(() => _entries.clear());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'error':
        return Colors.red;
      case 'warn':
        return Colors.orange;
      case 'debug':
        return Colors.grey;
      default:
        return Theme.of(context).colorScheme.onSurface;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('ToolPkg 调试日志'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _entries.isEmpty
            ? const Center(child: Text('暂无日志，运行 ToolPkg 后会在此显示 console 输出。'))
            : ListView.builder(
                controller: _scroll,
                itemCount: _entries.length,
                itemBuilder: (_, i) {
                  final e = _entries[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                        children: [
                          TextSpan(
                            text: '[${e.formattedTime}] ',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          TextSpan(
                            text: '${e.level.toUpperCase()}: ',
                            style: TextStyle(
                              color: _levelColor(e.level),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(
                            text: e.message,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: _entries.isEmpty ? null : _clear,
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
