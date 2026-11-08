import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/notifications.dart';
import '../state/app_controller.dart';
import '../state/app_state.dart';
import 'chat_view.dart';
import 'format.dart';
import 'home_view.dart';
import 'new_session_dialog.dart';
import 'permission_sheet.dart';
import 'question_sheet.dart';
import 'settings_page.dart';
import 'widgets.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _shownPermissions = <String>{};
  final _shownQuestions = <String>{};
  bool _sheetVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowSheet();
      unawaited(
        NotificationService.instance.sync(ref.read(appControllerProvider)),
      );
    });
  }

  Future<void> _maybeShowSheet() async {
    if (!mounted || _sheetVisible) return;
    final state = ref.read(appControllerProvider);

    PermissionRequestInfo? permission;
    for (final item in state.permissions) {
      if (!_shownPermissions.contains(item.permissionId)) {
        permission = item;
        break;
      }
    }
    if (permission != null) {
      _shownPermissions.add(permission.permissionId);
      _sheetVisible = true;
      await showPermissionSheet(context, permission);
      _sheetVisible = false;
      if (mounted) _maybeShowSheet();
      return;
    }

    QuestionRequestInfo? question;
    for (final item in state.questions) {
      if (!_shownQuestions.contains(item.permissionId)) {
        question = item;
        break;
      }
    }
    if (question != null) {
      _shownQuestions.add(question.permissionId);
      _sheetVisible = true;
      await showQuestionSheet(context, question);
      _sheetVisible = false;
      if (mounted) _maybeShowSheet();
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  String _connectionLabel(AppState state) => switch (state.connection) {
        ConnectionStatus.connected => '已连接',
        ConnectionStatus.connecting => '连接中…',
        ConnectionStatus.syncing => '同步中…',
        ConnectionStatus.error => '连接失败',
        ConnectionStatus.disconnected => '未连接',
      };

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);

    ref.listen(
      appControllerProvider.select(
        (value) => [
          ...value.permissions.map((item) => item.permissionId),
          ...value.questions.map((item) => item.permissionId),
        ].join('|'),
      ),
      (previous, next) {
        if (previous != next) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowSheet());
        }
      },
    );

    ref.listen(appControllerProvider, (previous, next) {
      if (previous?.connection != next.connection ||
          previous?.permissions.length != next.permissions.length ||
          previous?.questions.length != next.questions.length ||
          previous?.runningCount != next.runningCount ||
          previous?.sessions.length != next.sessions.length) {
        unawaited(NotificationService.instance.sync(next));
      }
      if (next.notice != null && next.notice != previous?.notice) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(next.notice!)),
          );
          ref.read(appControllerProvider.notifier).clearNotice();
        });
      }
    });

    final session = state.currentSession;
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: session == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && session != null) {
          ref.read(appControllerProvider.notifier).goHome();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _SessionDrawer(
          onSettings: _openSettings,
          connectionLabel: _connectionLabel(state),
        ),
        appBar: session == null
            ? AppBar(
              toolbarHeight: 64,
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Claude Remote'),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: state.connection == ConnectionStatus.connected
                              ? scheme.primary
                              : scheme.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          '${_connectionLabel(state)} · ${state.server?.serverName ?? state.pairing?.serverName ?? '本机'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9.5,
                            fontWeight: FontWeight.w400,
                            color: scheme.onSurface.withValues(alpha: 0.48),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                IconButton(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            )
          : AppBar(
              toolbarHeight: 64,
              leading: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              title: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            Icons.expand_more,
                            size: 15,
                            color: scheme.onSurface.withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 6),
                          StatusChip(session: session, compact: true),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        shortenPath(session.cwd),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9.5,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (value) {
                    switch (value) {
                      case 'drawer':
                        _scaffoldKey.currentState?.openDrawer();
                      case 'interrupt':
                        ref.read(appControllerProvider.notifier).interrupt();
                      case 'home':
                        ref.read(appControllerProvider.notifier).goHome();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'drawer', child: Text('会话列表')),
                    PopupMenuItem(value: 'interrupt', child: Text('中断任务')),
                    PopupMenuItem(value: 'home', child: Text('返回主页')),
                  ],
                ),
              ],
            ),
        body: Column(
          children: [
            ConnectionBanner(
              state: state,
              onRetry: () =>
                  ref.read(appControllerProvider.notifier).reconnect(),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: session == null
                    ? const HomeView(key: ValueKey('home'))
                    : ChatView(
                        key: ValueKey('chat-${session.id}'),
                        session: session,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionDrawer extends ConsumerStatefulWidget {
  const _SessionDrawer({
    required this.onSettings,
    required this.connectionLabel,
  });

  final VoidCallback onSettings;
  final String connectionLabel;

  @override
  ConsumerState<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends ConsumerState<_SessionDrawer> {
  String _query = '';
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final sessions = state.sessions.where((session) {
      if (_filter == 'running' && session.status != 'running') return false;
      if (_filter == 'waiting' && session.status != 'waiting_permission') {
        return false;
      }
      if (_query.isNotEmpty) {
        final needle = _query.toLowerCase();
        final haystack = '${session.title} ${session.cwd}'.toLowerCase();
        if (!haystack.contains(needle)) return false;
      }
      return true;
    }).toList();

    return Drawer(
      width: MediaQuery.sizeOf(context).width.clamp(280, 344).toDouble(),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'CR',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      'Claude Remote',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHigh,
                      minimumSize: const Size(34, 34),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Material(
                color: state.currentSession == null
                    ? scheme.primary.withValues(alpha: 0.1)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    ref.read(appControllerProvider.notifier).goHome();
                    Navigator.of(context).pop();
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    child: Row(
                      children: [
                        Icon(
                          Icons.home_outlined,
                          size: 18,
                          color: state.currentSession == null
                              ? scheme.primary
                              : scheme.onSurface.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 9),
                        Text(
                          '主页',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: state.currentSession == null
                                ? scheme.primary
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await showNewSessionDialog(context, ref);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('新对话'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: const InputDecoration(
                  hintText: '搜索会话',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
              child: Row(
                children: [
                  const Text(
                    '全部对话',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    '${sessions.length}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: scheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  _FilterChip(
                    label: '全部',
                    active: _filter == 'all',
                    onTap: () => setState(() => _filter = 'all'),
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: '运行中',
                    active: _filter == 'running',
                    onTap: () => setState(() => _filter = 'running'),
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: '待确认',
                    active: _filter == 'waiting',
                    onTap: () => setState(() => _filter = 'waiting'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Text(
                        '没有符合条件的会话',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                      itemCount: sessions.length,
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        return _DrawerSessionTile(
                          session: session,
                          onTap: () {
                            Navigator.of(context).pop();
                            ref
                                .read(appControllerProvider.notifier)
                                .openSession(session.id);
                          },
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.smartphone,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.server?.serverName ??
                              state.pairing?.serverName ??
                              '本机',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${widget.connectionLabel} · ${state.sessions.length} 个会话',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: scheme.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onSettings();
                    },
                    icon: const Icon(Icons.settings_outlined, size: 19),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: active ? scheme.onSurface : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(99),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active
                ? scheme.surface
                : scheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

class _DrawerSessionTile extends StatelessWidget {
  const _DrawerSessionTile({required this.session, required this.onTap});

  final SessionInfo session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = session.status == 'waiting_permission'
        ? scheme.secondary
        : session.status == 'running'
            ? scheme.primary
            : scheme.outline;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (session.status == 'waiting_permission')
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '待确认',
                            style: TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.secondary,
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        relativeTime(session.lastActiveAt),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 8.5,
                          color: scheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    shortenPath(session.cwd),
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
          ],
        ),
      ),
    );
  }
}
