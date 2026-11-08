import 'package:flutter/material.dart';

import '../core/models.dart';

class AppState {
  const AppState({
    required this.initialized,
    required this.paired,
    required this.connection,
    required this.connectionError,
    required this.pairing,
    required this.server,
    required this.sessions,
    required this.currentSessionId,
    required this.messages,
    required this.permissions,
    required this.questions,
    required this.lastEventId,
    required this.themeMode,
    required this.lastCwd,
    required this.busy,
    required this.devices,
    required this.usage,
    required this.uploading,
    required this.notice,
  });

  factory AppState.initial() => const AppState(
        initialized: false,
        paired: false,
        connection: ConnectionStatus.disconnected,
        connectionError: null,
        pairing: null,
        server: null,
        sessions: [],
        currentSessionId: null,
        messages: {},
        permissions: [],
        questions: [],
        lastEventId: 0,
        themeMode: ThemeMode.light,
        lastCwd: null,
        busy: false,
        devices: [],
        usage: {},
        uploading: false,
        notice: null,
      );

  final bool initialized;
  final bool paired;
  final ConnectionStatus connection;
  final String? connectionError;
  final SavedPairing? pairing;
  final ServerInfo? server;
  final List<SessionInfo> sessions;
  final String? currentSessionId;
  final Map<String, List<ChatMessage>> messages;
  final List<PermissionRequestInfo> permissions;
  final List<QuestionRequestInfo> questions;
  final int lastEventId;
  final ThemeMode themeMode;
  final String? lastCwd;
  final bool busy;
  final List<DeviceInfo> devices;
  final Map<String, SessionUsage> usage;
  final bool uploading;
  final String? notice;

  SessionUsage? usageFor(String? sessionId) {
    if (sessionId == null) return null;
    return usage[sessionId];
  }

  SessionInfo? get currentSession {
    final id = currentSessionId;
    if (id == null) return null;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  List<ChatMessage> get currentMessages {
    final id = currentSessionId;
    if (id == null) return const [];
    return messages[id] ?? const [];
  }

  List<PermissionRequestInfo> get currentPermissions {
    final id = currentSessionId;
    if (id == null) return const [];
    return permissions.where((item) => item.sessionId == id).toList();
  }

  PermissionRequestInfo? permissionFor(String permissionId) {
    for (final item in permissions) {
      if (item.permissionId == permissionId) return item;
    }
    return null;
  }

  QuestionRequestInfo? questionFor(String permissionId) {
    for (final item in questions) {
      if (item.permissionId == permissionId) return item;
    }
    return null;
  }

  int get pendingCount => permissions.length;
  int get runningCount => sessions.where((item) => item.status == 'running').length;
  int get waitingCount => sessions.where((item) => item.status == 'waiting_permission').length;

  SessionInfo? get mostRecent => sessions.isEmpty ? null : sessions.first;

  AppState copyWith({
    bool? initialized,
    bool? paired,
    ConnectionStatus? connection,
    String? connectionError,
    bool clearConnectionError = false,
    SavedPairing? pairing,
    ServerInfo? server,
    List<SessionInfo>? sessions,
    String? currentSessionId,
    bool clearCurrentSession = false,
    Map<String, List<ChatMessage>>? messages,
    List<PermissionRequestInfo>? permissions,
    List<QuestionRequestInfo>? questions,
    int? lastEventId,
    ThemeMode? themeMode,
    String? lastCwd,
    bool? busy,
    List<DeviceInfo>? devices,
    Map<String, SessionUsage>? usage,
    bool? uploading,
    String? notice,
    bool clearNotice = false,
  }) =>
      AppState(
        initialized: initialized ?? this.initialized,
        paired: paired ?? this.paired,
        connection: connection ?? this.connection,
        connectionError:
            clearConnectionError ? null : (connectionError ?? this.connectionError),
        pairing: pairing ?? this.pairing,
        server: server ?? this.server,
        sessions: sessions ?? this.sessions,
        currentSessionId:
            clearCurrentSession ? null : (currentSessionId ?? this.currentSessionId),
        messages: messages ?? this.messages,
        permissions: permissions ?? this.permissions,
        questions: questions ?? this.questions,
        lastEventId: lastEventId ?? this.lastEventId,
        themeMode: themeMode ?? this.themeMode,
        lastCwd: lastCwd ?? this.lastCwd,
        busy: busy ?? this.busy,
        devices: devices ?? this.devices,
        usage: usage ?? this.usage,
        uploading: uploading ?? this.uploading,
        notice: clearNotice ? null : (notice ?? this.notice),
      );
}
