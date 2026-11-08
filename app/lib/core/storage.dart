import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStorage {
  static const _secure = FlutterSecureStorage();
  static const _kUrl = 'server_url';
  static const _kFingerprint = 'cert_fingerprint';
  static const _kDeviceId = 'device_id';
  static const _kToken = 'device_token';
  static const _kServerName = 'server_name';
  static const _kThemeMode = 'theme_mode';

  Future<SavedPairing?> loadPairing() async {
    final url = await _secure.read(key: _kUrl);
    final fingerprint = await _secure.read(key: _kFingerprint);
    final deviceId = await _secure.read(key: _kDeviceId);
    final token = await _secure.read(key: _kToken);
    if (url == null || fingerprint == null || deviceId == null || token == null) {
      return null;
    }
    final serverName = await _secure.read(key: _kServerName) ?? '';
    return SavedPairing(
      wsUrl: url,
      fingerprint: fingerprint,
      deviceId: deviceId,
      token: token,
      serverName: serverName,
    );
  }

  Future<void> savePairing(SavedPairing pairing) async {
    await _secure.write(key: _kUrl, value: pairing.wsUrl);
    await _secure.write(key: _kFingerprint, value: pairing.fingerprint);
    await _secure.write(key: _kDeviceId, value: pairing.deviceId);
    await _secure.write(key: _kToken, value: pairing.token);
    await _secure.write(key: _kServerName, value: pairing.serverName);
  }

  Future<void> clearPairing() async {
    await _secure.delete(key: _kUrl);
    await _secure.delete(key: _kFingerprint);
    await _secure.delete(key: _kDeviceId);
    await _secure.delete(key: _kToken);
    await _secure.delete(key: _kServerName);
  }

  Future<ThemeMode> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_kThemeMode)) {
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.light;
    }
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final value = switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_kThemeMode, value);
  }
}
