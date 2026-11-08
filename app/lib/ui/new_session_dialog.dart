import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/permission_modes.dart';
import '../state/app_controller.dart';
import 'format.dart';

class NewSessionRequest {
  const NewSessionRequest({required this.cwd, required this.permissionMode});

  final String cwd;
  final String permissionMode;
}

Future<void> showNewSessionDialog(BuildContext context, WidgetRef ref) async {
  final state = ref.read(appControllerProvider);
  final roots = state.server?.allowedRoots ?? const <String>[];
  final initial = state.lastCwd ?? (roots.isNotEmpty ? roots.first : '');

  final result = await showDialog<NewSessionRequest>(
    context: context,
    builder: (_) => _NewSessionDialog(roots: roots, initial: initial),
  );

  if (result != null) {
    ref.read(appControllerProvider.notifier).createSession(
          result.cwd,
          permissionMode: result.permissionMode,
        );
  }
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({required this.roots, required this.initial});

  final List<String> roots;
  final String initial;

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String _mode = 'default';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('新建会话'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.roots.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final root in widget.roots)
                    ActionChip(
                      label: Text(
                        shortenPath(root),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                        ),
                      ),
                      onPressed: () {
                        _controller.text = root;
                        setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _controller,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                labelText: '工作目录',
                hintText: '/home/you/code/my-project',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: '权限模式'),
              items: [
                for (final info in permissionModeInfos)
                  DropdownMenuItem(
                    value: info.value,
                    child: Text(
                      info.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: info.dangerous ? scheme.error : null,
                      ),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _mode = value);
              },
            ),
            const SizedBox(height: 6),
            Text(
              permissionModeInfo(_mode).description,
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'daemon 只允许配置里的工作目录。',
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final cwd = _controller.text.trim();
            if (cwd.isNotEmpty) {
              Navigator.of(context).pop(
                NewSessionRequest(cwd: cwd, permissionMode: _mode),
              );
            }
          },
          child: const Text('创建'),
        ),
      ],
    );
  }
}
