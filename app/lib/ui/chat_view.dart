import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/app_controller.dart';
import 'composer.dart';
import 'format.dart';
import 'permission_sheet.dart';
import 'widgets.dart';

class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.session});

  final SessionInfo session;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _scroll = ScrollController();
  int _signature = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _send(String text, List<PendingAttachment> attachments) async {
    if (text.isEmpty && attachments.isEmpty) return false;
    final state = ref.read(appControllerProvider);
    if (state.connection != ConnectionStatus.connected) {
      _snack('尚未连接电脑');
      return false;
    }
    final controller = ref.read(appControllerProvider.notifier);
    if (attachments.isEmpty) {
      controller.sendPrompt(text);
      return true;
    }
    return controller.sendPromptWithAttachments(text, attachments);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatTokens(int value) =>
      value >= 1000 ? '${(value / 1000).toStringAsFixed(1)}k' : '$value';

  String? _usageLabel(SessionUsage? usage) {
    if (usage == null) return null;
    final cost = usage.totalCostUsd > 0
        ? '\$${usage.totalCostUsd.toStringAsFixed(2)}'
        : '费用未定价';
    return '累计 $cost · ${_formatTokens(usage.totalTokens)} tok · ${usage.numTurns} 轮';
  }

  void _scrollIfNeeded(List<ChatMessage> messages) {
    final signature = messages.length * 1000000 +
        (messages.isNotEmpty ? messages.last.text.length : 0);
    if (signature == _signature) return;
    _signature = signature;
    final nearBottom = !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 180;
    if (!nearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final session = state.currentSession ?? widget.session;
    final messages = state.currentMessages;
    final visible = messages
        .where((item) =>
            item.kind != ChatKind.assistant ||
            item.streaming ||
            item.displayText.trim().isNotEmpty)
        .toList();
    final pending = state.currentPermissions;
    _scrollIfNeeded(visible);

    final running =
        session.status == 'running' || visible.any((item) => item.streaming);
    final isNew = session.sdkSessionId == null;
    final isCold = session.isCold && !isNew;
    final usage = state.usageFor(session.id);

    return Column(
      children: [
        Expanded(
          child: visible.isEmpty
              ? EmptyChat(
                  title: isCold ? '冷会话' : '开始对话',
                  subtitle: isCold
                      ? '进程已回收以节省内存。发送一条消息，daemon 会用 resume 恢复这段对话。'
                      : '发送第一条消息，daemon 会在当前工作目录启动 Claude Code。',
                )
              : ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 16),
                  itemBuilder: (context, index) =>
                      ChatMessageView(item: visible[index]),
                ),
        ),
        if (pending.isNotEmpty)
          PendingPermissionBanner(
            count: pending.length,
            onTap: () => showPermissionSheet(context, pending.first),
          ),
        if (session.permissionMode == 'bypassPermissions')
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 15, color: scheme.onErrorContainer),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Bypass 模式：Claude 会不经手机确认执行所有工具',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Column(
              children: [
                Composer(
                  hintText: '发消息…',
                  allowAttachments: true,
                  uploading: state.uploading,
                  running: running,
                  onStop: () =>
                      ref.read(appControllerProvider.notifier).interrupt(),
                  onSend: _send,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          running ? '运行中 · Claude' : '空闲 · 等待输入',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: scheme.onSurface.withValues(alpha: 0.42),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _usageLabel(usage) ??
                              (session.isCold ? '冷会话' : statusLabel(session)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: scheme.onSurface.withValues(alpha: 0.42),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
