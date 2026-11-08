import 'dart:convert';

import 'package:http/io_client.dart';

import 'models.dart';
import 'security.dart';

Uri normalizeWsUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const FormatException('请输入服务器地址');
  }
  if (!text.contains('://')) text = 'wss://$text';

  var uri = Uri.parse(text);
  if (uri.scheme == 'https') uri = uri.replace(scheme: 'wss');
  if (uri.scheme != 'wss') {
    throw const FormatException('地址必须以 wss:// 开头');
  }
  if (uri.path.isEmpty || uri.path == '/') {
    uri = uri.replace(path: '/ws');
  }
  return uri;
}

Uri pairingUri(Uri wsUrl) => Uri(
      scheme: 'https',
      host: wsUrl.host,
      port: wsUrl.hasPort ? wsUrl.port : 443,
      path: '/pair',
    );

Future<PairingResult> pairDevice({
  required Uri wsUrl,
  required String fingerprint,
  required String code,
  required String deviceName,
}) async {
  final client = IOClient(pinnedHttpClient(fingerprint));
  try {
    final response = await client.post(
      pairingUri(wsUrl),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'code': code.trim().toUpperCase(),
        'deviceName': deviceName,
      }),
    );

    if (response.statusCode != 200) {
      var message = '配对失败（HTTP ${response.statusCode}）';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } catch (_) {
        /* keep the default message */
      }
      throw Exception(message);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('配对响应格式错误');
    final deviceId = decoded['deviceId'];
    final token = decoded['token'];
    if (deviceId is! String || token is! String) {
      throw Exception('配对响应缺少 token');
    }
    return PairingResult(
      deviceId: deviceId,
      token: token,
      serverName: decoded['serverName'] is String
          ? decoded['serverName'] as String
          : '',
    );
  } finally {
    client.close();
  }
}
