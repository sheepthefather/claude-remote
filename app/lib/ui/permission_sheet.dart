import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/app_controller.dart';
import 'format.dart';
import 'theme.dart';

Future<void> showPermissionSheet(
  BuildContext context,
  PermissionRequestInfo request,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => PermissionSheet(request: request),
  );
}

class PermissionSheet extends ConsumerStatefulWidget {
  const PermissionSheet({super.key, required this.request});

  final PermissionRequestInfo request;

  @override
  ConsumerState<PermissionSheet> createState() => _PermissionSheetState();
}

class _PermissionSheetState extends ConsumerState<PermissionSheet> {
  Timer? _timer;
  int _remaining = 300;
  bool _responded = false;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    final seconds =
        ((widget.request.expiresAt - DateTime.now().millisecondsSinceEpoch) /
                1000)
            .ceil();
    _remaining = seconds.clamp(0, 3600);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining = (_remaining - 1).clamp(0, 3600);
      });
      if (_remaining <= 0) {
        _timer?.cancel();
        _respond('deny', message: '等待超时，已自动拒绝');
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _respond(String decision, {String? message}) {
    if (_responded) return;
    _responded = true;
    _timer?.cancel();
    ref.read(appControllerProvider.notifier).respondPermission(
          widget.request,
          decision,
          message: message,
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final request = widget.request;
    final input = request.input;
    final command = asString(input['command']);
    final filePath = asString(input['file_path']);
    final oldString = asString(input['old_string']);
    final newString = asString(input['new_string']);
    final content = asString(input['content']);
    final minutes = (_remaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remaining % 60).toString().padLeft(2, '0');

    ref.listen(
      appControllerProvider.select(
        (value) => value.permissionFor(widget.request.permissionId),
      ),
      (previous, next) {
        if (previous != null && next == null && !_responded && mounted) {
          Navigator.of(context).pop();
        }
      },
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 14 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: scheme.secondary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      size: 19,
                      color: scheme.secondary,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          request.title ?? '需要你确认',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          request.description ?? 'Claude 想执行一个工具调用',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHigh,
                      minimumSize: const Size(32, 32),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Pill(
                    text: request.displayName ?? request.toolName,
                    background: scheme.primaryContainer,
                    foreground: scheme.onPrimaryContainer,
                  ),
                  if (filePath.isNotEmpty)
                    Text(
                      shortenPath(filePath, keep: 3),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        color: scheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  if (request.blockedPath != null)
                    _Pill(
                      text: '受限路径',
                      background: scheme.errorContainer,
                      foreground: scheme.onErrorContainer,
                    ),
                  if (request.defaultToNo)
                    _Pill(
                      text: '高风险 · 默认拒绝',
                      background: scheme.errorContainer,
                      foreground: scheme.onErrorContainer,
                    ),
                  if (request.suppressAlwaysAllowRule)
                    _Pill(
                      text: '不可持久允许',
                      background: scheme.surfaceContainerHighest,
                      foreground: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (command.isNotEmpty) _CodeBox(text: command),
              if (oldString.isNotEmpty || newString.isNotEmpty) ...[
                if (oldString.isNotEmpty)
                  _TintedBlock(
                    label: '删除',
                    text: oldString,
                    background: scheme.errorContainer,
                    foreground: scheme.onErrorContainer,
                  ),
                if (newString.isNotEmpty)
                  _TintedBlock(
                    label: '新增',
                    text: newString,
                    background: scheme.primaryContainer,
                    foreground: scheme.onPrimaryContainer,
                  ),
              ],
              if (content.isNotEmpty && command.isEmpty)
                _TintedBlock(
                  label: '写入内容',
                  text: content,
                  background: scheme.primaryContainer,
                  foreground: scheme.onPrimaryContainer,
                ),
              if (command.isEmpty && oldString.isEmpty && newString.isEmpty && content.isEmpty)
                _CodeBox(text: prettyJson(input)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showRaw = !_showRaw),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(_showRaw ? '收起完整参数' : '查看完整参数与权限来源'),
                ),
              ),
              if (_showRaw) ...[
                const SizedBox(height: 6),
                _CodeBox(text: prettyJson(request.input)),
                if (request.decisionReason != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '原因：${request.decisionReason}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '来源：${request.sessionId.length > 8 ? '${request.sessionId.substring(0, 8)}…' : request.sessionId}',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  Text(
                    '$minutes:$seconds 后自动拒绝',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: _remaining < 60
                          ? scheme.error
                          : scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: (_remaining / 300).clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: _remaining < 60 ? scheme.error : scheme.secondary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '“本会话总是允许”只对当前会话生效，不写入项目配置。高风险操作不会提供这个选项。',
                style: TextStyle(
                  fontSize: 10,
                  height: 1.5,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _respond('deny'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(
                          color: scheme.error.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => _respond('allow_once'),
                      child: const Text('允许一次'),
                    ),
                  ),
                ],
              ),
              if (!request.suppressAlwaysAllowRule) ...[
                const SizedBox(height: 9),
                FilledButton(
                  onPressed: () => _respond('allow_session'),
                  child: const Text('本会话总是允许'),
                ),
              ],
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => _respond('deny_stop', message: '用户拒绝并停止了当前任务'),
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('拒绝并停止'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 230),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppTheme.codeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.codeLine),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 10.5,
            height: 1.6,
            color: AppTheme.codeFg,
          ),
        ),
      ),
    );
  }
}

class _TintedBlock extends StatelessWidget {
  const _TintedBlock({
    required this.label,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String label;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: foreground,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            truncate(text, 4000),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              height: 1.55,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
