import 'dart:convert';

int asInt(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

String asString(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;

bool asBool(dynamic value, [bool fallback = false]) =>
    value is bool ? value : fallback;

Map<String, dynamic> asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> asMapList(dynamic value) {
  if (value is List) {
    return value.whereType<Map>().map((item) => asMap(item)).toList();
  }
  return const [];
}

List<String> asStringList(dynamic value) {
  if (value is List) {
    return value.whereType<String>().toList();
  }
  return const [];
}

class SavedPairing {
  const SavedPairing({
    required this.wsUrl,
    required this.fingerprint,
    required this.deviceId,
    required this.token,
    required this.serverName,
  });

  final String wsUrl;
  final String fingerprint;
  final String deviceId;
  final String token;
  final String serverName;
}

class PairingResult {
  const PairingResult({
    required this.deviceId,
    required this.token,
    required this.serverName,
  });

  final String deviceId;
  final String token;
  final String serverName;
}

class ServerInfo {
  const ServerInfo({
    required this.bootId,
    required this.protocolVersion,
    required this.serverVersion,
    required this.minEventId,
    required this.maxEventId,
    required this.capabilities,
    required this.allowedRoots,
    required this.serverName,
    required this.maxTurns,
    required this.maxBudgetUsd,
  });

  final String bootId;
  final int protocolVersion;
  final String serverVersion;
  final int minEventId;
  final int maxEventId;
  final List<String> capabilities;
  final List<String> allowedRoots;
  final String serverName;
  final int maxTurns;
  final double maxBudgetUsd;

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        bootId: asString(json['bootId']),
        protocolVersion: asInt(json['protocolVersion']),
        serverVersion: asString(json['serverVersion']),
        minEventId: asInt(json['minEventId']),
        maxEventId: asInt(json['maxEventId']),
        capabilities: asStringList(json['capabilities']),
        allowedRoots: asStringList(json['allowedRoots']),
        serverName: asString(json['serverName']),
        maxTurns: asInt(json['maxTurns']),
        maxBudgetUsd: (json['maxBudgetUsd'] as num?)?.toDouble() ?? 0,
      );
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.current,
  });

  final String id;
  final String name;
  final int createdAt;
  final int? lastSeenAt;
  final bool current;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: asString(json['id']),
        name: asString(json['name'], 'unknown'),
        createdAt: asInt(json['createdAt']),
        lastSeenAt:
            json['lastSeenAt'] is num ? (json['lastSeenAt'] as num).toInt() : null,
        current: asBool(json['current']),
      );
}

class SessionUsage {
  const SessionUsage({
    required this.totalCostUsd,
    required this.inputTokens,
    required this.outputTokens,
    required this.numTurns,
    required this.isError,
  });

  final double totalCostUsd;
  final int inputTokens;
  final int outputTokens;
  final int numTurns;
  final bool isError;

  int get totalTokens => inputTokens + outputTokens;

  factory SessionUsage.fromResult(Map<String, dynamic> payload) {
    final usage = asMap(payload['usage']);
    return SessionUsage(
      totalCostUsd: (payload['totalCostUsd'] as num?)?.toDouble() ?? 0,
      inputTokens: asInt(usage['input_tokens']),
      outputTokens: asInt(usage['output_tokens']),
      numTurns: asInt(payload['numTurns']),
      isError: asBool(payload['isError']),
    );
  }
}

class PendingAttachment {
  const PendingAttachment({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
  });

  final String path;
  final String name;
  final String mime;
  final int size;
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.title,
    required this.cwd,
    required this.permissionMode,
    required this.sdkSessionId,
    required this.status,
    required this.live,
    required this.createdAt,
    required this.lastActiveAt,
  });

  final String id;
  final String title;
  final String cwd;
  final String permissionMode;
  final String? sdkSessionId;
  final String status;
  final bool live;
  final int createdAt;
  final int lastActiveAt;

  bool get isRunning => status == 'running';
  bool get isWaiting => status == 'waiting_permission';
  bool get isCold => !live;

  SessionInfo copyWith({
    String? permissionMode,
    String? status,
    bool? live,
    int? lastActiveAt,
  }) =>
      SessionInfo(
        id: id,
        title: title,
        cwd: cwd,
        permissionMode: permissionMode ?? this.permissionMode,
        sdkSessionId: sdkSessionId,
        status: status ?? this.status,
        live: live ?? this.live,
        createdAt: createdAt,
        lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      );

  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
        id: asString(json['id']),
        title: asString(json['title'], '未命名会话'),
        cwd: asString(json['cwd']),
        permissionMode: asString(json['permissionMode'], 'default'),
        sdkSessionId:
            json['sdkSessionId'] is String ? json['sdkSessionId'] as String : null,
        status: asString(json['status'], 'idle'),
        live: asBool(json['live']),
        createdAt: asInt(json['createdAt']),
        lastActiveAt: asInt(json['lastActiveAt']),
      );
}

enum ConnectionStatus { disconnected, connecting, syncing, connected, error }

enum ChatKind { user, assistant, system, tool }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.kind,
    this.text = '',
    this.blocks = const [],
    this.streaming = false,
    this.toolUseId,
    this.toolName,
    this.toolInput,
    this.toolResult,
    this.toolIsError = false,
    this.parentToolUseId,
    this.expanded = false,
    this.createdAt = 0,
    this.attachments = const [],
  });

  final String id;
  final ChatKind kind;
  String text;
  List<Map<String, dynamic>> blocks;
  bool streaming;
  String? toolUseId;
  String? toolName;
  Map<String, dynamic>? toolInput;
  String? toolResult;
  bool toolIsError;
  String? parentToolUseId;
  bool expanded;
  int createdAt;
  List<Map<String, dynamic>> attachments;

  String get displayText {
    final fromBlocks = blocks
        .where((block) => block['type'] == 'text')
        .map((block) => asString(block['text']))
        .join();
    return fromBlocks.isNotEmpty ? fromBlocks : text;
  }
}

class PermissionRequestInfo {
  const PermissionRequestInfo({
    required this.permissionId,
    required this.requestId,
    required this.sessionId,
    required this.toolUseId,
    required this.toolName,
    required this.input,
    required this.title,
    required this.displayName,
    required this.description,
    required this.decisionReason,
    required this.blockedPath,
    required this.defaultToNo,
    required this.suppressAlwaysAllowRule,
    required this.expiresAt,
    required this.agentId,
  });

  final String permissionId;
  final String requestId;
  final String sessionId;
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  final String? title;
  final String? displayName;
  final String? description;
  final String? decisionReason;
  final String? blockedPath;
  final bool defaultToNo;
  final bool suppressAlwaysAllowRule;
  final int expiresAt;
  final String? agentId;

  factory PermissionRequestInfo.fromJson(
    Map<String, dynamic> json, {
    required String sessionId,
  }) =>
      PermissionRequestInfo(
        permissionId: asString(json['permissionId']),
        requestId: asString(json['requestId']),
        sessionId: sessionId,
        toolUseId: asString(json['toolUseID']),
        toolName: asString(json['toolName'], 'Tool'),
        input: asMap(json['input']),
        title: json['title'] is String ? json['title'] as String : null,
        displayName:
            json['displayName'] is String ? json['displayName'] as String : null,
        description:
            json['description'] is String ? json['description'] as String : null,
        decisionReason: json['decisionReason'] is String
            ? json['decisionReason'] as String
            : null,
        blockedPath:
            json['blockedPath'] is String ? json['blockedPath'] as String : null,
        defaultToNo: asBool(json['defaultToNo']),
        suppressAlwaysAllowRule: asBool(json['suppressAlwaysAllowRule']),
        expiresAt: asInt(json['expiresAt']),
        agentId: json['agentID'] is String ? json['agentID'] as String : null,
      );
}

class QuestionRequestInfo {
  const QuestionRequestInfo({
    required this.permissionId,
    required this.sessionId,
    required this.questions,
  });

  final String permissionId;
  final String sessionId;
  final List<Map<String, dynamic>> questions;

  factory QuestionRequestInfo.fromJson(
    Map<String, dynamic> json, {
    required String sessionId,
  }) =>
      QuestionRequestInfo(
        permissionId: asString(json['permissionId']),
        sessionId: sessionId,
        questions: asMapList(json['questions']),
      );
}

class StoredEvent {
  const StoredEvent({
    required this.eventId,
    required this.type,
    required this.sessionId,
    required this.payload,
    required this.createdAt,
  });

  final int eventId;
  final String type;
  final String? sessionId;
  final Map<String, dynamic> payload;
  final int createdAt;

  factory StoredEvent.fromJson(Map<String, dynamic> json) => StoredEvent(
        eventId: asInt(json['eventId']),
        type: asString(json['type']),
        sessionId:
            json['sessionId'] is String ? json['sessionId'] as String : null,
        payload: asMap(json['payload']),
        createdAt: asInt(json['createdAt']),
      );

  Map<String, dynamic> toDb() => {
        'event_id': eventId,
        'type': type,
        'session_id': sessionId,
        'payload': jsonEncode(payload),
        'created_at': createdAt,
      };
}
