import 'dart:convert';

import '../core/models.dart';

String shortenPath(String path, {int keep = 2}) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length <= keep) return path;
  return '…/${parts.sublist(parts.length - keep).join('/')}';
}

String relativeTime(int timestampMs) {
  if (timestampMs <= 0) return '';
  final diff = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(timestampMs));
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${diff.inDays ~/ 7} 周前';
}

String statusLabel(SessionInfo session) {
  if (session.status == 'waiting_permission') return '待确认';
  if (session.status == 'running') return '运行中';
  if (!session.live && session.sdkSessionId != null) return '冷会话';
  return '空闲';
}

String toolSummary(ChatMessage item) {
  final input = item.toolInput ?? const <String, dynamic>{};
  switch (item.toolName) {
    case 'Bash':
      return asString(input['command'], 'Bash');
    case 'Read':
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
      return asString(input['file_path'], item.toolName ?? 'Tool');
    case 'Grep':
    case 'Glob':
      return asString(input['pattern'], item.toolName ?? 'Tool');
    default:
      return prettyJson(input);
  }
}

String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String truncate(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}\n…';
