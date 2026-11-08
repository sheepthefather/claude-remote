import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/permission_modes.dart';
import '../state/app_controller.dart';
import '../state/app_state.dart';
import 'composer.dart';
import 'format.dart';
import 'new_session_dialog.dart';
import 'permission_sheet.dart';
import 'widgets.dart';

class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView> {
  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _send(String text, List<PendingAttachment> attachments) async {
    if (text.isEmpty) return false;
    final state = ref.read(appControllerProvider);
    if (state.connection != ConnectionStatus.connected) {
      _snack('尚未连接电脑，请稍后再试');
      return false;
    }
    final hasCwd = state.lastCwd != null ||
        (state.server?.allowedRoots.isNotEmpty ?? false);
    if (!hasCwd) {
      showNewSessionDialog(context, ref);
      return false;
    }
    ref.read(appControllerProvider.notifier).createSessionAndSend(text);
    return true;
  }

  void _openPending(AppState state) {
    if (state.permissions.isEmpty) {
      _snack('没有待确认的操作');
      return;
    }
    final permission = state.permissions.first;
    ref.read(appControllerProvider.notifier).openSession(permission.sessionId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showPermissionSheet(context, permission);
    });
  }

  void _openRunning(AppState state) {
    SessionInfo? running;
    for (final session in state.sessions) {
      if (session.status == 'running') {
        running = session;
        break;
      }
    }
    final target = running ?? state.mostRecent;
    if (target == null) {
      _snack('还没有会话，先新建一个吧');
      return;
    }
    ref.read(appControllerProvider.notifier).openSession(target.id);
  }

  String _permissionSubtitle(AppState state) {
    if (state.permissions.isEmpty) return '都处理完了';
    final request = state.permissions.first;
    final input = request.input;
    final detail = asString(input['file_path']).isNotEmpty
        ? asString(input['file_path'])
        : asString(input['command'], request.toolName);
    return '${request.toolName} · $detail';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final recent = state.sessions.take(5).toList();
    final mode = state.mostRecent?.permissionMode ?? 'default';

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
            children: [
              const SizedBox(height: 16),
              Text(
                _greeting,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.1,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '今天想做点什么？',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 7,
                runSpacing: 7,
                children: [
                  _ScopePill(
                    icon: Icons.shield_outlined,
                    label: '${permissionModeLabel(mode)} 模式',
                    danger: mode == 'bypassPermissions',
                  ),
                  const _ScopePill(
                    icon: Icons.folder_outlined,
                    label: '工作区内修改',
                  ),
                ],
              ),
              const SizedBox(height: 22),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.18,
                children: [
                  QuickCard(
                    icon: Icons.shield_outlined,
                    tint: scheme.secondary.withValues(alpha: 0.14),
                    tintInk: scheme.secondary,
                    title: '待确认',
                    count: state.pendingCount,
                    subtitle: _permissionSubtitle(state),
                    onTap: () => _openPending(state),
                  ),
                  QuickCard(
                    icon: Icons.play_arrow_rounded,
                    tint: scheme.primary.withValues(alpha: 0.12),
                    tintInk: scheme.primary,
                    title: '运行中',
                    count: state.runningCount,
                    subtitle: state.sessions
                            .where((item) => item.status == 'running')
                            .isEmpty
                        ? '没有运行中的任务'
                        : state.sessions
                            .firstWhere((item) => item.status == 'running')
                            .title,
                    onTap: () => _openRunning(state),
                  ),
                  QuickCard(
                    icon: Icons.history,
                    tint: scheme.tertiary.withValues(alpha: 0.13),
                    tintInk: scheme.tertiary,
                    title: '继续上次',
                    subtitle: state.mostRecent?.title ?? '暂无会话',
                    onTap: () {
                      final session = state.mostRecent;
                      if (session == null) {
                        _snack('还没有会话');
                        return;
                      }
                      ref
                          .read(appControllerProvider.notifier)
                          .openSession(session.id);
                    },
                  ),
                  QuickCard(
                    icon: Icons.add,
                    tint: scheme.onSurface.withValues(alpha: 0.07),
                    tintInk: scheme.onSurface.withValues(alpha: 0.65),
                    title: '新建会话',
                    subtitle: '选择工作目录',
                    onTap: () => showNewSessionDialog(context, ref),
                  ),
                ],
              ),
              if (recent.isNotEmpty) ...[
                const SectionLabel('最近'),
                for (final session in recent) _RecentRow(session: session),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 17,
                      color: scheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '点左上角汉堡打开会话抽屉；长按可以置顶、改名或归档。',
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.5,
                          color: scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
            child: Column(
              children: [
                Composer(
                  hintText: '给 Claude 发消息…',
                  maxLines: 4,
                  leading: IconButton(
                    onPressed: () => showNewSessionDialog(context, ref),
                    icon: const Icon(Icons.add, size: 21),
                  ),
                  onSend: _send,
                ),
                const SizedBox(height: 7),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: state.connection == ConnectionStatus.connected
                            ? scheme.primary
                            : scheme.outline,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '本机 · ${state.sessions.length} 个会话',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: scheme.onSurface.withValues(alpha: 0.42),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScopePill extends StatelessWidget {
  const _ScopePill({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = danger ? scheme.error : scheme.onSurface.withValues(alpha: 0.65);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: danger
            ? scheme.error.withValues(alpha: 0.08)
            : scheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: danger ? scheme.error.withValues(alpha: 0.4) : scheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: danger ? scheme.error : ink),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: ink),
          ),
        ],
      ),
    );
  }
}

class _RecentRow extends ConsumerWidget {
  const _RecentRow({required this.session});

  final SessionInfo session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () =>
          ref.read(appControllerProvider.notifier).openSession(session.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${shortenPath(session.cwd)} · ${statusLabel(session)}',
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
            const SizedBox(width: 12),
            Text(
              relativeTime(session.lastActiveAt),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9.5,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
