import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/app_controller.dart';

Future<void> showQuestionSheet(
  BuildContext context,
  QuestionRequestInfo request,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => QuestionSheet(request: request),
  );
}

class QuestionSheet extends ConsumerStatefulWidget {
  const QuestionSheet({super.key, required this.request});

  final QuestionRequestInfo request;

  @override
  ConsumerState<QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends ConsumerState<QuestionSheet> {
  final _selected = <int, Set<String>>{};
  final _others = <int, TextEditingController>{};
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.request.questions.length; i++) {
      _selected[i] = <String>{};
      _others[i] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _others.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _answerFor(int index, Map<String, dynamic> question) {
    final other = _others[index]?.text.trim() ?? '';
    if (other.isNotEmpty) return other;
    final chosen = _selected[index] ?? const <String>{};
    return chosen.join(', ');
  }

  bool get _canSubmit {
    if (widget.request.questions.isEmpty) return true;
    for (var i = 0; i < widget.request.questions.length; i++) {
      if (_answerFor(i, widget.request.questions[i]).isEmpty) return false;
    }
    return true;
  }

  void _toggle(int index, String label, bool multi) {
    setState(() {
      final set = _selected[index] ?? <String>{};
      if (multi) {
        if (set.contains(label)) {
          set.remove(label);
        } else {
          set.add(label);
        }
      } else {
        set
          ..clear()
          ..add(label);
      }
      _selected[index] = set;
    });
  }

  void _submit() {
    if (_submitted || !_canSubmit) return;
    _submitted = true;
    final answers = <String, String>{};
    for (var i = 0; i < widget.request.questions.length; i++) {
      final question = widget.request.questions[i];
      final key = asString(question['question'], 'question_$i');
      answers[key] = _answerFor(i, question);
    }
    ref.read(appControllerProvider.notifier).respondQuestion(
          widget.request,
          answers,
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final questions = widget.request.questions;

    ref.listen(
      appControllerProvider.select(
        (value) => value.questionFor(widget.request.permissionId),
      ),
      (previous, next) {
        if (previous != null && next == null && !_submitted && mounted) {
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
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '?',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Claude 想确认一下',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '不回答会暂停当前步骤',
                          style: TextStyle(
                            fontSize: 11.5,
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
              const SizedBox(height: 18),
              if (questions.isEmpty)
                _OtherField(controller: _others.putIfAbsent(0, TextEditingController.new))
              else
                for (var i = 0; i < questions.length; i++)
                  _QuestionBlock(
                    question: questions[i],
                    index: i,
                    selected: _selected[i] ?? const <String>{},
                    otherController: _others[i]!,
                    onToggle: _toggle,
                    onOtherChanged: () => setState(() {}),
                  ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _canSubmit ? _submit : null,
                child: const Text('提交回答'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    required this.question,
    required this.index,
    required this.selected,
    required this.otherController,
    required this.onToggle,
    required this.onOtherChanged,
  });

  final Map<String, dynamic> question;
  final int index;
  final Set<String> selected;
  final TextEditingController otherController;
  final void Function(int index, String label, bool multi) onToggle;
  final VoidCallback onOtherChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = asString(question['header']);
    final text = asString(question['question'], '请选择');
    final multi = asBool(question['multiSelect']);
    final options = asMapList(question['options']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header.isNotEmpty) ...[
            Text(
              header.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          if (multi) ...[
            const SizedBox(height: 4),
            Text(
              '可多选',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
          const SizedBox(height: 10),
          for (final option in options)
            _OptionTile(
              label: asString(option['label'], '选项'),
              description: asString(option['description']),
              selected: selected.contains(asString(option['label'])),
              multi: multi,
              onTap: () => onToggle(
                index,
                asString(option['label']),
                multi,
              ),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: otherController,
            onChanged: (_) => onOtherChanged(),
            decoration: const InputDecoration(
              hintText: '其他答案（可选）',
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.description,
    required this.selected,
    required this.multi,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  multi
                      ? (selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank)
                      : (selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                  size: 17,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.35),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.45,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OtherField extends StatelessWidget {
  const _OtherField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: const InputDecoration(hintText: '输入你的回答'),
      maxLines: 3,
    );
  }
}
