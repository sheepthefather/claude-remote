import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/attachment_service.dart';
import '../core/models.dart';

/// The single message composer used by both the home surface and a session.
/// It owns the draft text and pending attachments so switching between the
/// two states never duplicates input handling.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.hintText,
    required this.onSend,
    this.leading,
    this.allowAttachments = false,
    this.uploading = false,
    this.running = false,
    this.onStop,
    this.maxLines = 5,
  });

  final String hintText;

  /// Returns true when the draft should be cleared (accepted/sent).
  final Future<bool> Function(
    String text,
    List<PendingAttachment> attachments,
  ) onSend;

  final Widget? leading;
  final bool allowAttachments;
  final bool uploading;
  final bool running;
  final VoidCallback? onStop;
  final int maxLines;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _input = TextEditingController();
  final _pending = <PendingAttachment>[];
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    if (_sending || widget.uploading) return;
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    setState(() => _sending = true);
    try {
      final ok = await widget.onSend(text, List.of(_pending));
      if (ok && mounted) {
        _input.clear();
        setState(() => _pending.clear());
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
      );
      if (picked == null) return;
      final length = await picked.length();
      if (!mounted) return;
      setState(() {
        _pending.add(PendingAttachment(
          path: picked.path,
          name: picked.name,
          mime: picked.mimeType ?? mimeFromFileName(picked.name),
          size: length,
        ));
      });
    } catch (error) {
      _snack('选择图片失败：$error');
    }
  }

  Future<void> _pickFile() async {
    try {
      final files = await FilePicker.pickFiles();
      if (files.isEmpty || !mounted) return;
      final added = <PendingAttachment>[];
      for (final file in files) {
        final path = file.path;
        if (path == null) continue;
        final length = file.lengthSync() ?? await file.length() ?? 0;
        added.add(PendingAttachment(
          path: path,
          name: file.name,
          mime: mimeFromFileName(file.name),
          size: length,
        ));
      }
      if (!mounted || added.isEmpty) return;
      setState(() => _pending.addAll(added));
    } catch (error) {
      _snack('选择文件失败：$error');
    }
  }

  Future<void> _showAttachMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('选择文件'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _sending || widget.uploading;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final file in _pending)
                    InputChip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 170),
                        child: Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onDeleted: busy
                          ? null
                          : () => setState(() => _pending.remove(file)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.leading != null)
                widget.leading!
              else if (widget.allowAttachments)
                IconButton(
                  onPressed: busy ? null : _showAttachMenu,
                  icon: const Icon(Icons.attach_file, size: 19),
                ),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: widget.maxLines,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (widget.running && widget.onStop != null)
                IconButton.filled(
                  onPressed: widget.onStop,
                  icon: const Icon(Icons.stop, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    minimumSize: const Size(40, 40),
                  ),
                )
              else
                IconButton.filled(
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
