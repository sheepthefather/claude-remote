import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class AppDatabase {
  Database? _db;

  Future<void> open() async {
    final base = await getDatabasesPath();
    _db = await openDatabase(
      p.join(base, 'claude_remote.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            cwd TEXT NOT NULL,
            permission_mode TEXT NOT NULL,
            sdk_session_id TEXT,
            status TEXT NOT NULL,
            live INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            last_active_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE events (
            event_id INTEGER PRIMARY KEY,
            type TEXT NOT NULL,
            session_id TEXT,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<void> saveSession(SessionInfo session) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'sessions',
      {
        'id': session.id,
        'title': session.title,
        'cwd': session.cwd,
        'permission_mode': session.permissionMode,
        'sdk_session_id': session.sdkSessionId,
        'status': session.status,
        'live': session.live ? 1 : 0,
        'created_at': session.createdAt,
        'last_active_at': session.lastActiveAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveSessions(List<SessionInfo> sessions) async {
    final db = _db;
    if (db == null) return;
    final batch = db.batch();
    for (final session in sessions) {
      batch.insert(
        'sessions',
        {
          'id': session.id,
          'title': session.title,
          'cwd': session.cwd,
          'permission_mode': session.permissionMode,
          'sdk_session_id': session.sdkSessionId,
          'status': session.status,
          'live': session.live ? 1 : 0,
          'created_at': session.createdAt,
          'last_active_at': session.lastActiveAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<SessionInfo>> loadSessions() async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'sessions',
      where: "status != 'closed'",
      orderBy: 'last_active_at DESC',
    );
    return rows
        .map((row) => SessionInfo(
              id: row['id'] as String,
              title: row['title'] as String,
              cwd: row['cwd'] as String,
              permissionMode: row['permission_mode'] as String,
              sdkSessionId: row['sdk_session_id'] as String?,
              status: row['status'] as String,
              live: (row['live'] as int) == 1,
              createdAt: row['created_at'] as int,
              lastActiveAt: row['last_active_at'] as int,
            ))
        .toList();
  }

  Future<void> saveEvent(StoredEvent event) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'events',
      event.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<StoredEvent>> loadRecentEvents({int limit = 800}) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'events',
      orderBy: 'event_id DESC',
      limit: limit,
    );
    return rows.reversed.map((row) {
      Map<String, dynamic> payload = const {};
      try {
        final decoded = jsonDecode(row['payload'] as String);
        if (decoded is Map) {
          payload = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } catch (_) {
        /* skip malformed payload */
      }
      return StoredEvent(
        eventId: row['event_id'] as int,
        type: row['type'] as String,
        sessionId: row['session_id'] as String?,
        payload: payload,
        createdAt: row['created_at'] as int,
      );
    }).toList();
  }

  Future<int> lastEventId() async {
    final db = _db;
    if (db == null) return 0;
    final rows = await db.query(
      'meta',
      where: 'key = ?',
      whereArgs: ['last_event_id'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String? ?? '') ?? 0;
  }

  Future<void> setLastEventId(int eventId) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'meta',
      {'key': 'last_event_id', 'value': eventId.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearEvents() async {
    await _db?.delete('events');
  }

  Future<void> clearAll() async {
    final db = _db;
    if (db == null) return;
    await db.delete('events');
    await db.delete('sessions');
    await db.delete('meta');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
