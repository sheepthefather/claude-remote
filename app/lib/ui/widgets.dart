import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'format.dart';
import 'theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.session, this.compact = false});

  final SessionInfo session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final Color background;
    final Color foreground;

    if (session.status == 'waiting_permission') {
      label = '待确认';
      background = scheme.secondary.withValues(alpha: 0.15);
      foreground = scheme.secondary;
    } else if (session.status == 'running') {
      label = '运行中';
      background = scheme.primary.withValues(alpha: 0.12);
      foreground = scheme.primary;
    } else if (!session.live && session.sdkSessionId != null) {
      label = '冷会话';
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurface.withValues(alpha: 0.5);
    } else {
      label = '空闲';
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurface.withValues(alpha: 0.5);
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2.5 : 3.5,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.state,
    required this.onRetry,
  });

  final AppState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.connection == ConnectionStatus.connected) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final busy = state.connection == ConnectionStatus.connecting ||
        state.connection == ConnectionStatus.syncing;
    final message = state.connectionError ??
        switch (state.connection) {
          ConnectionStatus.connecting => '正在连接电脑…',
          ConnectionStatus.syncing => '正在同步会话…',
          ConnectionStatus.disconnected => '连接已断开',
          ConnectionStatus.error => '连接失败',
          _ => '未连接',
        };

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          if (busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            )
          else
            Icon(
              Icons.cloud_off_outlined,
              size: 15,
              color: scheme.error,
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurface.withValues(alpha: 0.68),
              ),
            ),
          ),
          if (!busy)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class QuickCard extends StatelessWidget {
  const QuickCard({
    super.key,
    required this.icon,
    required this.tint,
    required this.tintInk,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final Color tint;
  final Color tintInk;
  final String title;
  final String subtitle;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 18, color: tintInk),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (count != null && count! > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      height: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: scheme.onSurface,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.surface,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9.5,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.item});

  final ChatMessage item;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  late bool _expanded = widget.item.expanded;

  String get _icon {
    switch (widget.item.toolName) {
      case 'Bash':
        return r'$';
      case 'Read':
        return '▤';
      case 'Edit':
      case 'MultiEdit':
        return '✎';
      case 'Write':
        return '✚';
      case 'Grep':
      case 'Glob':
        return '⌕';
      default:
        return '⚙';
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasResult = item.toolResult != null;
    final statusLabel =
        hasResult ? (item.toolIsError ? '失败' : '完成') : '运行中';
    final statusColor = !hasResult
        ? AppTheme.codeMuted
        : (item.toolIsError ? const Color(0xFFD99A8C) : const Color(0xFF8FC39C));

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: AppTheme.codeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.codeLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.codeLine,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      _icon,
                      style: const TextStyle(
                        color: AppTheme.codeFg,
                        fontSize: 9,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.toolName ?? 'Tool',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.codeFg,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      toolSummary(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: AppTheme.codeMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 9,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: AppTheme.codeMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              padding: const EdgeInsets.fromLTRB(11, 9, 11, 11),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.codeLine)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _CodeLabel('INPUT'),
                  const SizedBox(height: 5),
                  SelectableText(
                    truncate(prettyJson(item.toolInput ?? const {}), 4000),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      height: 1.55,
                      color: AppTheme.codeFg,
                    ),
                  ),
                  if (hasResult) ...[
                    const SizedBox(height: 12),
                    _CodeLabel(item.toolIsError ? 'ERROR' : 'OUTPUT'),
                    const SizedBox(height: 5),
                    SelectableText(
                      truncate(item.toolResult!, 4000),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        height: 1.55,
                        color: item.toolIsError
                            ? const Color(0xFFD99A8C)
                            : AppTheme.codeFg,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CodeLabel extends StatelessWidget {
  const _CodeLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 8.5,
        letterSpacing: 0.8,
        color: AppTheme.codeMuted,
      ),
    );
  }
}

class ChatMessageView extends StatelessWidget {
  const ChatMessageView({super.key, required this.item});

  final ChatMessage item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    switch (item.kind) {
      case ChatKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.84,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.text.isNotEmpty)
                  Text(
                    item.text,
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 14,
                      height: 1.55,
                    ),
                  ),
                if (item.attachments.isNotEmpty) ...[
                  if (item.text.isNotEmpty) const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: [
                      for (final attachment in item.attachments)
                        Container(
                          constraints: const BoxConstraints(maxWidth: 220),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.onPrimary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.attach_file,
                                size: 12,
                                color: scheme.onPrimary,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  asString(attachment['name'], '附件'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );

      case ChatKind.assistant:
        final text = item.displayText;
        if (text.trim().isEmpty && !item.streaming) {
          return const SizedBox.shrink();
        }
        final display = item.streaming ? '$text▍' : text;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                'C',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: display.trim().isEmpty
                  ? Text(
                      '正在输入…',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurface.withValues(alpha: 0.45),
                      ),
                    )
                  : MarkdownBody(
                      data: display,
                      selectable: true,
                      styleSheet: _markdownStyle(theme),
                    ),
            ),
          ],
        );

      case ChatKind.system:
        return Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              item.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        );

      case ChatKind.tool:
        return ToolCard(item: item);
    }
  }
}

MarkdownStyleSheet _markdownStyle(ThemeData theme) {
  final scheme = theme.colorScheme;
  final base = MarkdownStyleSheet.fromTheme(theme);
  return base.copyWith(
    p: TextStyle(
      fontSize: 14,
      height: 1.58,
      color: scheme.onSurface,
    ),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: scheme.onSurface,
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    codeblockDecoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: scheme.outlineVariant),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockSpacing: 8,
    h1: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    ),
    h2: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    ),
    h3: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    blockquoteDecoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      border: Border(left: BorderSide(color: scheme.primary, width: 3)),
    ),
  );
}

class PendingPermissionBanner extends StatelessWidget {
  const PendingPermissionBanner({
    super.key,
    required this.count,
    required this.onTap,
  });

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondary.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 17, color: scheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count 个操作等待确认',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: scheme.secondary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('查看'),
          ),
        ],
      ),
    );
  }
}

class EmptyChat extends StatelessWidget {
  const EmptyChat({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: scheme.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Text(
                '◌',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 19,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
