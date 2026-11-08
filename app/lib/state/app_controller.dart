import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/attachment_service.dart';
import '../core/database.dart';
import '../core/models.dart';
import '../core/pairing_service.dart';
import '../core/remote_connection.dart';
import '../core/security.dart';
import '../core/storage.dart';
import 'app_state.dart';

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);

class AppController extends Notifier<AppState> {
  final _uuid = const Uuid();
  final _storage = AppStorage();

  AppDatabase? _db;
  RemoteConnection? _connection;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  int _connectionGeneration = 0;
  bool _pendingOpenNew = false;
  String? _pendingPrompt;

  @override
  AppState build() {
    state = AppState.initial();
    unawaited(_init());
    return state;
  }

  Future<void> _init() async {
    try {
      await _initInner();
    } catch (error, stack) {
      debugPrint('init failed: $error\n$stack');
      state = state.copyWith(
        initialized: true,
        paired: false,
        connectionError: '初始化失败：$error',
      );
    }
  }

  Future<void> _initInner() async {
    final db = AppDatabase();
    await db.open();
    _db = db;

    final theme = await _storage.loadThemeMode();
    final pairing = await _storage.loadPairing();
    final sessions = await db.loadSessions();
    final lastEventId = await db.lastEventId();
    final cachedEvents = await db.loadRecentEvents();

    state = state.copyWith(
      initialized: false,
      themeMode: theme,
      sessions: sessions,
      lastEventId: lastEventId,
    );

    for (final event in cachedEvents) {
      _applyEvent(event.type, event.sessionId, event.payload);
    }

    if (pairing == null) {
      final devUrl = const String.fromEnvironment('CR_SERVER_URL');
      final devFingerprint = const String.fromEnvironment('CR_CERT_FP');
      final devCode = const String.fromEnvironment('CR_PAIRING_CODE');
      if (devUrl.isNotEmpty && devFingerprint.isNotEmpty && devCode.isNotEmpty) {
        try {
          await pair(
            url: devUrl,
            fingerprint: devFingerprint,
            code: devCode,
            deviceName: 'Emulator',
          );
          return;
        } catch (_) {
          /* fall through to the manual pairing page */
        }
      }
      state = state.copyWith(initialized: true, paired: false);
      return;
    }

    state = state.copyWith(initialized: true, paired: true, pairing: pairing);
    await _connect();
  }

  Future<void> pair({
    required String url,
    required String fingerprint,
    required String code,
    String deviceName = 'Android',
  }) async {
    final wsUrl = normalizeWsUrl(url);
    if (!isValidFingerprint(fingerprint)) {
      throw const FormatException('证书指纹应为 64 位十六进制字符');
    }

    state = state.copyWith(busy: true, clearConnectionError: true);
    try {
      final result = await pairDevice(
        wsUrl: wsUrl,
        fingerprint: fingerprint,
        code: code,
        deviceName: deviceName,
      );
      final saved = SavedPairing(
        wsUrl: wsUrl.toString(),
        fingerprint: normalizeFingerprint(fingerprint),
        deviceId: result.deviceId,
        token: result.token,
        serverName: result.serverName,
      );
      await _storage.savePairing(saved);
      state = state.copyWith(
        initialized: true,
        paired: true,
        pairing: saved,
        busy: false,
        connection: ConnectionStatus.connecting,
        clearConnectionError: true,
      );
      await _connect();
    } catch (error) {
      state = state.copyWith(
        busy: false,
        connection: ConnectionStatus.error,
        connectionError: error.toString().replaceFirst('Exception: ', ''),
      );
      rethrow;
    }
  }

  Future<void> _connect() async {
    final pairing = state.pairing;
    if (pairing == null) return;

    _retryTimer?.cancel();
    _connection?.close();
    _connection = null;

    final generation = ++_connectionGeneration;
    state = state.copyWith(
      connection: ConnectionStatus.connecting,
      clearConnectionError: true,
    );

    final connection = RemoteConnection(
      wsUrl: Uri.parse(pairing.wsUrl),
      fingerprint: pairing.fingerprint,
      deviceId: pairing.deviceId,
      token: pairing.token,
    );
    _connection = connection;
    connection.onClosed = (code, reason) {
      if (generation != _connectionGeneration) return;
      if (code == 4401) {
        unawaited(_handleAuthRevoked(reason ?? '认证失效'));
        return;
      }
      _scheduleReconnect();
    };
    connection.events.listen((event) => unawaited(_handleEvent(event)));

    try {
      await connection.connect();
    } catch (error) {
      if (generation != _connectionGeneration) return;
      state = state.copyWith(
        connection: ConnectionStatus.error,
        connectionError: '连接失败：$error',
      );
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!state.paired || state.pairing == null) return;
    _retryTimer?.cancel();
    final exponent = math.min(_retryAttempt, 4);
    final seconds = math.min(30, 1 << exponent);
    _retryAttempt += 1;
    state = state.copyWith(
      connection: ConnectionStatus.disconnected,
      connectionError: '连接断开，${seconds}s 后重试',
    );
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (state.paired) unawaited(_connect());
    });
  }

  Future<void> _handleAuthRevoked(String reason) async {
    if (!state.paired) return;
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _connectionGeneration += 1;
    _connection?.close();
    _connection = null;
    await _storage.clearPairing();
    await _db?.clearAll();
    state = AppState.initial().copyWith(
      initialized: true,
      themeMode: state.themeMode,
      notice: '设备认证失效，请重新配对（$reason）',
    );
  }

  void refreshSync() {
    _connection?.send('sync.request', {'lastEventId': state.lastEventId});
  }

  /* ---------------- events ---------------- */

  Future<void> _handleEvent(Map<String, dynamic> message) async {
    final type = asString(message['type']);
    final payload = asMap(message['payload']);
    final eventId = asInt(message['eventId'], -1);
    final sessionId =
        message['sessionId'] is String ? message['sessionId'] as String : null;
    final bootId =
        message['bootId'] is String ? message['bootId'] as String : null;

    if (eventId > 0) {
      final stored = StoredEvent(
        eventId: eventId,
        type: type,
        sessionId: sessionId,
        payload: payload,
        createdAt: asInt(message['ts']),
      );
      final db = _db;
      if (db != null) {
        unawaited(db.saveEvent(stored));
        unawaited(db.setLastEventId(eventId));
      }
      if (eventId > state.lastEventId) {
        state = state.copyWith(lastEventId: eventId);
      }
    }

    switch (type) {
      case 'server.hello':
        _connection?.setBootId(bootId);
        state = state.copyWith(
          connection: ConnectionStatus.syncing,
          server: ServerInfo.fromJson({...payload, 'bootId': bootId}),
        );
        _connection?.send('sync.request', {'lastEventId': state.lastEventId});
        break;

      case 'sync.replay':
        final events = (payload['events'] as List?)
                ?.whereType<Map>()
                .map((item) => StoredEvent.fromJson(asMap(item)))
                .toList() ??
            const <StoredEvent>[];
        for (final event in events) {
          final db = _db;
          if (db != null && event.eventId > state.lastEventId) {
            unawaited(db.saveEvent(event));
            unawaited(db.setLastEventId(event.eventId));
          }
          _applyEvent(event.type, event.sessionId, event.payload);
          if (event.eventId > state.lastEventId) {
            state = state.copyWith(lastEventId: event.eventId);
          }
        }
        if (payload['hasMore'] == true) {
          _connection?.send('sync.request', {
            'lastEventId': asInt(payload['nextEventId'], state.lastEventId),
          });
        }
        break;

      case 'sync.snapshot':
        await _applySnapshot(payload);
        break;

      case 'sync.complete':
        _retryAttempt = 0;
        state = state.copyWith(
          connection: ConnectionStatus.connected,
          clearConnectionError: true,
        );
        break;

      case 'session.created':
      case 'session.updated':
        final session = SessionInfo.fromJson(asMap(payload['session']));
        _upsertSession(session);
        if (type == 'session.created' && _pendingOpenNew) {
          _pendingOpenNew = false;
          openSession(session.id);
          final prompt = _pendingPrompt;
          _pendingPrompt = null;
          if (prompt != null) sendPrompt(prompt);
        }
        break;

      case 'session.closed':
        _removeSession(asString(payload['sessionId']));
        break;

      case 'user.message':
      case 'message.completed':
      case 'tool.use':
      case 'tool.result':
      case 'context.compacted':
      case 'tool.denied':
        _applyEvent(type, sessionId, payload);
        break;

      case 'message.delta':
        _applyDelta(sessionId, payload);
        break;

      case 'run.started':
        _setSessionStatus(sessionId, 'running');
        break;

      case 'run.result':
        _applyEvent(type, sessionId, payload);
        _setSessionStatus(sessionId, 'idle');
        break;

      case 'run.interrupted':
        _setSessionStatus(sessionId, 'idle');
        break;

      case 'status':
        final status = asString(payload['state']);
        if (status == 'running' || status == 'idle') {
          _setSessionStatus(sessionId, status);
        }
        break;

      case 'permission.request':
        final request = PermissionRequestInfo.fromJson(
          payload,
          sessionId: sessionId ?? asString(payload['sessionId']),
        );
        state = state.copyWith(
          permissions: [
            ...state.permissions
                .where((item) => item.permissionId != request.permissionId),
            request,
          ],
        );
        _setSessionStatus(request.sessionId, 'waiting_permission');
        break;

      case 'permission.resolved':
        final permissionId = asString(payload['permissionId']);
        final decidedBy = asMap(payload['decidedBy']);
        final actorId = asString(decidedBy['id']);
        final actorName = asString(decidedBy['name']);
        final otherDevice = actorId.isNotEmpty && actorId != state.pairing?.deviceId;
        state = state.copyWith(
          permissions: state.permissions
              .where((item) => item.permissionId != permissionId)
              .toList(),
          notice: otherDevice ? '已由 $actorName 处理' : state.notice,
        );
        _setSessionStatus(sessionId, 'running');
        break;

      case 'question.request':
        final request = QuestionRequestInfo.fromJson(
          payload,
          sessionId: sessionId ?? asString(payload['sessionId']),
        );
        state = state.copyWith(
          questions: [
            ...state.questions
                .where((item) => item.permissionId != request.permissionId),
            request,
          ],
        );
        _setSessionStatus(request.sessionId, 'waiting_permission');
        break;

      case 'question.resolved':
        final permissionId = asString(payload['permissionId']);
        final decidedBy = asMap(payload['decidedBy']);
        final actorId = asString(decidedBy['id']);
        final actorName = asString(decidedBy['name']);
        final otherDevice = actorId.isNotEmpty && actorId != state.pairing?.deviceId;
        state = state.copyWith(
          questions: state.questions
              .where((item) => item.permissionId != permissionId)
              .toList(),
          notice: otherDevice ? '问题已由 $actorName 回答' : state.notice,
        );
        _setSessionStatus(sessionId, 'running');
        break;

      case 'devices.list':
        final devices = (payload['devices'] as List?)
                ?.whereType<Map>()
                .map((item) => DeviceInfo.fromJson(asMap(item)))
                .toList() ??
            const <DeviceInfo>[];
        state = state.copyWith(devices: devices);
        break;

      case 'device.revoked': {
        final deviceId = asString(payload['deviceId']);
        if (deviceId == state.pairing?.deviceId) {
          await _handleAuthRevoked('设备已被撤销');
        } else {
          state = state.copyWith(
            devices: state.devices
                .where((item) => item.id != deviceId)
                .toList(),
            notice: '设备已撤销',
          );
        }
        break;
      }

      case 'device.tokenRotated': {
        final deviceId = asString(payload['deviceId']);
        final token = payload['token'];
        final pairing = state.pairing;
        if (pairing != null &&
            deviceId == pairing.deviceId &&
            token is String &&
            token.isNotEmpty) {
          final updated = SavedPairing(
            wsUrl: pairing.wsUrl,
            fingerprint: pairing.fingerprint,
            deviceId: pairing.deviceId,
            token: token,
            serverName: pairing.serverName,
          );
          await _storage.savePairing(updated);
          state = state.copyWith(
            pairing: updated,
            notice: '本机 token 已轮换，正在重新连接',
          );
          await _connect();
        } else if (pairing != null && deviceId != pairing.deviceId) {
          state = state.copyWith(
            notice: '已轮换该设备的 token，它需要重新配对',
          );
        }
        break;
      }

      case 'error':
        state = state.copyWith(
          connectionError: asString(payload['message'], '服务端错误'),
        );
        break;

      default:
        break;
    }
  }

  Future<void> _applySnapshot(Map<String, dynamic> payload) async {
    final sessions = (payload['sessions'] as List?)
            ?.whereType<Map>()
            .map((item) => SessionInfo.fromJson(asMap(item)))
            .toList() ??
        const <SessionInfo>[];
    final events = (payload['messages'] as List?)
            ?.whereType<Map>()
            .map((item) => StoredEvent.fromJson(asMap(item)))
            .toList() ??
        const <StoredEvent>[];
    final pending = (payload['pendingPermissions'] as List?)
            ?.whereType<Map>()
            .map((item) => asMap(item))
            .toList() ??
        const <Map<String, dynamic>>[];
    final lastEventId = asInt(payload['lastEventId']);

    final db = _db;
    if (db != null) {
      await db.clearEvents();
      await db.saveSessions(sessions);
      for (final event in events) {
        await db.saveEvent(event);
      }
      await db.setLastEventId(lastEventId);
    }

    state = state.copyWith(
      sessions: sessions,
      messages: {},
      usage: {},
      permissions: pending
          .map((item) => PermissionRequestInfo.fromJson(
                item,
                sessionId: asString(item['sessionId']),
              ))
          .toList(),
      questions: [],
      lastEventId: lastEventId,
    );

    for (final event in events) {
      _applyEvent(event.type, event.sessionId, event.payload);
    }
  }

  void _applyEvent(
    String type,
    String? sessionId,
    Map<String, dynamic> payload,
  ) {
    switch (type) {
      case 'user.message':
        final runId = asString(payload['runId']);
        final id = runId.isNotEmpty
            ? runId
            : asString(payload['clientMsgId'], _uuid.v4());
        _upsertMessage(
          sessionId,
          ChatMessage(
            id: 'user_$id',
            kind: ChatKind.user,
            text: asString(payload['text']),
            attachments: asMapList(payload['attachments']),
            createdAt: asInt(payload['ts']),
          ),
        );
        break;

      case 'message.completed':
        final msgId = asString(payload['msgId'], _uuid.v4());
        final blocks = asMapList(payload['blocks']);
        final text = blocks
            .where((block) => block['type'] == 'text')
            .map((block) => asString(block['text']))
            .join();
        if (text.trim().isEmpty) return;
        _upsertMessage(
          sessionId,
          ChatMessage(
            id: 'msg_$msgId',
            kind: ChatKind.assistant,
            text: text,
            blocks: blocks,
            streaming: false,
            parentToolUseId: payload['parentToolUseId'] as String?,
            createdAt: asInt(payload['ts']),
          ),
        );
        break;

      case 'tool.use':
        final toolUseId = asString(payload['toolUseId'], _uuid.v4());
        _upsertMessage(
          sessionId,
          ChatMessage(
            id: 'tool_$toolUseId',
            kind: ChatKind.tool,
            toolUseId: toolUseId,
            toolName: asString(payload['name'], 'Tool'),
            toolInput: asMap(payload['input']),
            parentToolUseId: payload['parentToolUseId'] as String?,
            createdAt: asInt(payload['ts']),
          ),
        );
        break;

      case 'tool.result':
        final toolUseId = asString(payload['toolUseId']);
        if (toolUseId.isEmpty) break;
        _updateTool(
          sessionId,
          toolUseId,
          asString(payload['content']),
          asBool(payload['isError']),
        );
        break;

      case 'context.compacted':
        _upsertMessage(
          sessionId,
          ChatMessage(
            id: 'compact_${asInt(payload['preCompactTokens'], DateTime.now().millisecondsSinceEpoch)}',
            kind: ChatKind.system,
            text: '上下文已压缩，历史消息仍保留在本地。',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        break;

      case 'tool.denied':
        _upsertMessage(
          sessionId,
          ChatMessage(
            id: 'denied_${asString(payload['toolUseId'], _uuid.v4())}',
            kind: ChatKind.system,
            text: '工具调用被自动拒绝：${asString(payload['toolName'], '未知工具')}',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        break;

      case 'run.result':
        if (sessionId != null) {
          state = state.copyWith(
            usage: {
              ...state.usage,
              sessionId: SessionUsage.fromResult(payload),
            },
          );
        }
        break;
    }
  }

  void _applyDelta(String? sessionId, Map<String, dynamic> payload) {
    if (asString(payload['kind']) == 'thinking') return;
    final msgId = asString(payload['msgId']);
    final text = asString(payload['text']);
    final sid = sessionId ?? state.currentSessionId;
    if (msgId.isEmpty || text.isEmpty || sid == null) return;

    final list = List<ChatMessage>.from(state.messages[sid] ?? const []);
    final index = list.indexWhere((item) => item.id == 'msg_$msgId');
    if (index >= 0) {
      final item = list[index];
      if (!item.streaming) return;
      item.text += text;
    } else {
      list.add(ChatMessage(
        id: 'msg_$msgId',
        kind: ChatKind.assistant,
        text: text,
        streaming: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    state = state.copyWith(messages: {...state.messages, sid: list});
  }

  void _upsertMessage(String? sessionId, ChatMessage message) {
    final sid = sessionId ?? state.currentSessionId;
    if (sid == null) return;
    final list = List<ChatMessage>.from(state.messages[sid] ?? const []);
    final index = list.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      list[index] = message;
    } else {
      list.add(message);
    }
    state = state.copyWith(messages: {...state.messages, sid: list});
  }

  void _updateTool(
    String? sessionId,
    String toolUseId,
    String content,
    bool isError,
  ) {
    final sid = sessionId ?? state.currentSessionId;
    if (sid == null) return;
    final list = List<ChatMessage>.from(state.messages[sid] ?? const []);
    var index = list.indexWhere(
      (item) => item.kind == ChatKind.tool && item.toolUseId == toolUseId,
    );
    if (index >= 0) {
      final item = list[index];
      item.toolResult = content;
      item.toolIsError = isError;
    } else {
      list.add(ChatMessage(
        id: 'tool_$toolUseId',
        kind: ChatKind.tool,
        toolUseId: toolUseId,
        toolName: 'Tool',
        toolResult: content,
        toolIsError: isError,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      index = list.length - 1;
    }
    state = state.copyWith(messages: {...state.messages, sid: list});
  }

  /* ---------------- sessions ---------------- */

  void _upsertSession(SessionInfo session) {
    final list = List<SessionInfo>.from(state.sessions);
    final index = list.indexWhere((item) => item.id == session.id);
    if (index >= 0) {
      list[index] = session;
    } else {
      list.add(session);
    }
    list.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
    state = state.copyWith(sessions: list);
    final db = _db;
    if (db != null) unawaited(db.saveSession(session));
  }

  void _removeSession(String sessionId) {
    final list = state.sessions.where((item) => item.id != sessionId).toList();
    state = state.copyWith(
      sessions: list,
      clearCurrentSession: state.currentSessionId == sessionId,
    );
  }

  void _setSessionStatus(String? sessionId, String status) {
    if (sessionId == null) return;
    final list = List<SessionInfo>.from(state.sessions);
    final index = list.indexWhere((item) => item.id == sessionId);
    if (index < 0) return;
    final updated = list[index].copyWith(
      status: status,
      live: status != 'closed',
    );
    list[index] = updated;
    state = state.copyWith(sessions: list);
    final db = _db;
    if (db != null) unawaited(db.saveSession(updated));
  }

  void openSession(String sessionId) {
    SessionInfo? found;
    for (final session in state.sessions) {
      if (session.id == sessionId) {
        found = session;
        break;
      }
    }
    state = state.copyWith(
      currentSessionId: sessionId,
      lastCwd: found?.cwd,
    );
    _connection?.send(
      'session.resume',
      {'sessionId': sessionId},
      sessionId: sessionId,
    );
  }

  void goHome() {
    state = state.copyWith(clearCurrentSession: true);
  }

  void createSession(
    String cwd, {
    String? title,
    String permissionMode = 'default',
  }) {
    final trimmed = cwd.trim();
    if (trimmed.isEmpty) return;
    _pendingOpenNew = true;
    state = state.copyWith(lastCwd: trimmed);
    _connection?.send('session.create', {
      'cwd': trimmed,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      'permissionMode': permissionMode,
    });
  }

  void createSessionAndSend(String text, {String permissionMode = 'default'}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final allowed = state.server?.allowedRoots ?? const <String>[];
    final cwd = state.lastCwd ?? (allowed.isNotEmpty ? allowed.first : null);
    if (cwd == null) {
      state = state.copyWith(
        connectionError: '没有可用的工作目录，请先新建会话',
      );
      return;
    }
    _pendingPrompt = trimmed;
    createSession(cwd, permissionMode: permissionMode);
  }

  void reconnect() {
    unawaited(_connect());
  }

  void requestDevices() {
    _connection?.send('devices.list', {});
  }

  void revokeDevice(String deviceId) {
    _connection?.send('device.revoke', {'deviceId': deviceId});
  }

  void rotateDeviceToken(String deviceId) {
    _connection?.send('device.rotateToken', {'deviceId': deviceId});
  }

  void clearNotice() {
    state = state.copyWith(clearNotice: true);
  }

  void sendPrompt(String text) {
    final sessionId = state.currentSessionId;
    final trimmed = text.trim();
    if (sessionId == null || trimmed.isEmpty) return;
    _connection?.send(
      'prompt.send',
      {
        'sessionId': sessionId,
        'clientMsgId': 'c_${_uuid.v4()}',
        'text': trimmed,
        'attachments': <Map<String, dynamic>>[],
      },
      sessionId: sessionId,
    );
  }

  Future<bool> sendPromptWithAttachments(
    String text,
    List<PendingAttachment> attachments,
  ) async {
    final sessionId = state.currentSessionId;
    final pairing = state.pairing;
    if (sessionId == null || pairing == null) return false;
    if (state.connection != ConnectionStatus.connected) {
      state = state.copyWith(notice: '尚未连接电脑');
      return false;
    }
    if (attachments.isEmpty) {
      sendPrompt(text);
      return true;
    }

    state = state.copyWith(uploading: true, clearNotice: true);
    try {
      final service = AttachmentService(pairing: pairing);
      final uploaded = <Map<String, dynamic>>[];
      for (final attachment in attachments) {
        uploaded.add(await service.upload(attachment));
      }
      _connection?.send(
        'prompt.send',
        {
          'sessionId': sessionId,
          'clientMsgId': 'c_${_uuid.v4()}',
          'text': text.trim(),
          'attachments': uploaded,
        },
        sessionId: sessionId,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        notice: '附件上传失败：${error.toString().replaceFirst('Exception: ', '')}',
      );
      return false;
    } finally {
      state = state.copyWith(uploading: false);
    }
  }

  void interrupt() {
    final sessionId = state.currentSessionId;
    if (sessionId == null) return;
    _connection?.send(
      'run.interrupt',
      {'sessionId': sessionId},
      sessionId: sessionId,
    );
  }

  void respondPermission(
    PermissionRequestInfo request,
    String decision, {
    String? message,
  }) {
    _connection?.send(
      'permission.respond',
      {
        'permissionId': request.permissionId,
        'requestId': request.requestId,
        'decision': decision,
        if (message != null) 'message': message,
      },
      sessionId: request.sessionId,
    );
    state = state.copyWith(
      permissions: state.permissions
          .where((item) => item.permissionId != request.permissionId)
          .toList(),
    );
  }

  void respondQuestion(
    QuestionRequestInfo request,
    Map<String, String> answers,
  ) {
    _connection?.send(
      'question.respond',
      {'permissionId': request.permissionId, 'answers': answers},
      sessionId: request.sessionId,
    );
    state = state.copyWith(
      questions: state.questions
          .where((item) => item.permissionId != request.permissionId)
          .toList(),
    );
  }

  void setPermissionMode(String mode) {
    final sessionId = state.currentSessionId;
    if (sessionId == null) return;
    _connection?.send(
      'session.setPermissionMode',
      {'sessionId': sessionId, 'mode': mode},
      sessionId: sessionId,
    );
    final list = List<SessionInfo>.from(state.sessions);
    final index = list.indexWhere((item) => item.id == sessionId);
    if (index >= 0) {
      list[index] = list[index].copyWith(permissionMode: mode);
      state = state.copyWith(sessions: list);
    }
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    unawaited(_storage.saveThemeMode(mode));
  }

  Future<void> disconnect() async {
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _connection?.close();
    _connection = null;
    await _storage.clearPairing();
    await _db?.clearAll();
    state = AppState.initial().copyWith(
      initialized: true,
      themeMode: state.themeMode,
    );
  }
}
