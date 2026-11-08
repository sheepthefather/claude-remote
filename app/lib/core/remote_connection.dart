import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'security.dart';

class RemoteConnection {
  RemoteConnection({
    required this.wsUrl,
    required this.fingerprint,
    required this.deviceId,
    required this.token,
  });

  final Uri wsUrl;
  final String fingerprint;
  final String deviceId;
  final String token;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _uuid = const Uuid();

  IOWebSocketChannel? _channel;
  String? _bootId;
  Timer? _heartbeat;
  bool _closed = false;
  bool _notifiedClosed = false;

  void Function(int? code, String? reason)? onClosed;

  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> connect() async {
    final client = pinnedHttpClient(fingerprint);
    final channel = IOWebSocketChannel.connect(
      wsUrl,
      customClient: client,
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;
    await channel.ready;

    channel.stream.listen(
      (data) {
        try {
          final text = data is String ? data : utf8.decode(data as List<int>);
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            _events.add(decoded.map(
              (key, value) => MapEntry(key.toString(), value),
            ));
          }
        } catch (_) {
          /* ignore malformed frames */
        }
      },
      onError: (Object _) => _handleClosed(),
      onDone: _handleClosed,
      cancelOnError: false,
    );

    send('client.hello', {
      'protocolVersion': 1,
      'deviceId': deviceId,
      'token': token,
      'capabilities': ['interrupt', 'questions', 'attachments'],
    });
  }

  void setBootId(String? bootId) {
    _bootId = bootId;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closed) return;
      try {
        send('ping', {'nonce': _uuid.v4()});
      } catch (_) {
        /* reconnect handles it */
      }
    });
  }

  void send(
    String type,
    Map<String, dynamic> payload, {
    String? sessionId,
  }) {
    final channel = _channel;
    if (channel == null || _closed) return;
    final envelope = <String, dynamic>{
      'v': 1,
      'type': type,
      'id': _uuid.v4(),
      'ts': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    };
    if (_bootId != null) envelope['bootId'] = _bootId;
    if (sessionId != null) envelope['sessionId'] = sessionId;
    try {
      channel.sink.add(jsonEncode(envelope));
    } catch (_) {
      /* the close handler schedules a reconnect */
    }
  }

  void close() {
    _closed = true;
    _heartbeat?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {
      /* ignore */
    }
    if (!_events.isClosed) _events.close();
  }

  void _handleClosed() {
    if (_closed || _notifiedClosed) return;
    _notifiedClosed = true;
    _heartbeat?.cancel();
    onClosed?.call(_channel?.closeCode, _channel?.closeReason);
  }
}
