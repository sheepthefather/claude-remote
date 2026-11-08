import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../state/app_state.dart';
import 'models.dart';

@pragma('vm:entry-point')
void foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(ClaudeRemoteTaskHandler());
}

class ClaudeRemoteTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Keeps the app alive with a foreground service while connected, and posts
/// high-priority local notifications when a permission/question needs the user
/// while the app is in the background.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedPermissions = <String>{};
  final Set<String> _notifiedQuestions = <String>{};

  bool _initialized = false;
  bool _serviceRunning = false;
  bool _starting = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      settings: const InitializationSettings(android: androidInit),
    );
    final android = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'claude_remote_service',
        channelName: 'Claude Remote 连接',
        channelDescription: '保持与电脑的连接',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
      ),
    );
  }

  Future<void> sync(AppState state) async {
    if (!_initialized) return;
    await _syncService(state);
    await _syncNotifications(state);
  }

  Future<void> _syncService(AppState state) async {
    if (state.connection == ConnectionStatus.connected) {
      final text = state.pendingCount > 0
          ? '${state.pendingCount} 个操作等待确认'
          : (state.runningCount > 0
              ? '${state.runningCount} 个任务运行中'
              : '已连接 · ${state.sessions.length} 个会话');

      if (!_serviceRunning && !_starting) {
        _starting = true;
        try {
          final result = await FlutterForegroundTask.startService(
            serviceTypes: const [ForegroundServiceTypes.dataSync],
            notificationTitle: 'Claude Remote',
            notificationText: text,
            callback: foregroundTaskCallback,
          );
          if (result is ServiceRequestSuccess) _serviceRunning = true;
        } catch (_) {
          /* already running or blocked by the OS */
        } finally {
          _starting = false;
        }
      } else if (_serviceRunning) {
        try {
          await FlutterForegroundTask.updateService(
            notificationTitle: 'Claude Remote',
            notificationText: text,
          );
        } catch (_) {
          /* ignore */
        }
      }
    } else if (_serviceRunning) {
      _serviceRunning = false;
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {
        /* ignore */
      }
    }
  }

  Future<void> _syncNotifications(AppState state) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }

    for (final permission in state.permissions) {
      if (!_notifiedPermissions.add(permission.permissionId)) continue;
      await _show(
        permission.permissionId.hashCode & 0x7fffffff,
        'Claude 需要你确认',
        '${permission.toolName} · ${permission.title ?? permission.sessionId}',
      );
    }

    for (final question in state.questions) {
      if (!_notifiedQuestions.add(question.permissionId)) continue;
      await _show(
        question.permissionId.hashCode & 0x7fffffff,
        'Claude 有个问题',
        '打开 App 回答',
      );
    }
  }

  Future<void> _show(int id, String title, String body) async {
    try {
      await _local.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'claude_remote_alerts',
            'Claude Remote 提醒',
            channelDescription: '等待确认和任务完成提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (_) {
      /* notification permission may be denied */
    }
  }
}
