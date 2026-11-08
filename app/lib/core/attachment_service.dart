import 'dart:convert';
import 'dart:io';

import 'package:http/io_client.dart';

import 'models.dart';
import 'security.dart';

class AttachmentService {
  AttachmentService({required this.pairing});

  final SavedPairing pairing;

  Future<Map<String, dynamic>> upload(PendingAttachment attachment) async {
    final client = IOClient(pinnedHttpClient(pairing.fingerprint));
    try {
      final ws = Uri.parse(pairing.wsUrl);
      final uri = Uri(
        scheme: 'https',
        host: ws.host,
        port: ws.hasPort ? ws.port : 443,
        path: '/attachments',
      );
      final bytes = await File(attachment.path).readAsBytes();
      final response = await client.post(
        uri,
        headers: {
          'authorization': 'Bearer ${pairing.token}',
          'x-file-name': attachment.name,
          'content-type': attachment.mime,
        },
        body: bytes,
      );

      if (response.statusCode != 200) {
        var message = '上传失败（HTTP ${response.statusCode}）';
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['error'] is String) {
            message = body['error'] as String;
          }
        } catch (_) {
          /* keep default */
        }
        throw Exception(message);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw Exception('附件响应格式错误');
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } finally {
      client.close();
    }
  }
}

String mimeFromFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.md')) return 'text/markdown';
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.log')) return 'text/plain';
  return 'application/octet-stream';
}
