import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/device.dart';

class Credentials {
  const Credentials(this.username, this.password);
  final String username;
  final String password;

  bool get isEmpty => username.isEmpty;

  Map<String, String> toJson() => {'u': username, 'p': password};
  factory Credentials.fromJson(Map<String, Object?> j) =>
      Credentials(j['u'] as String? ?? '', j['p'] as String? ?? '');
}

/// The single persistence layer of the app.
///
/// Everything — credentials, device topology, preferences — lives in the
/// platform keystore (iOS Keychain, `this-device-only`, never synced to
/// iCloud; Android Keystore-backed AES-GCM). Nothing sensitive touches
/// SharedPreferences or plain files.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
    : _s =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
              storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
              resetOnError: true,
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _s;

  static const _kDevices = 'devices.v1';
  static const _kRemembered = 'login.remembered.v1';
  static const _kSettings = 'settings.v1';
  static String _kCred(String deviceId) => 'cred.$deviceId.v1';

  Future<Credentials?> readCredentials(String deviceId) async {
    final raw = await _s.read(key: _kCred(deviceId));
    if (raw == null) return null;
    return Credentials.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<void> writeCredentials(String deviceId, Credentials c) =>
      _s.write(key: _kCred(deviceId), value: jsonEncode(c.toJson()));

  Future<void> deleteCredentials(String deviceId) => _s.delete(key: _kCred(deviceId));

  Future<List<DeviceConfig>?> readDevices() async {
    final raw = await _s.read(key: _kDevices);
    if (raw == null) return null;
    return (jsonDecode(raw) as List).cast<Map<String, Object?>>().map(DeviceConfig.fromJson).toList();
  }

  Future<void> writeDevices(List<DeviceConfig> devices) =>
      _s.write(key: _kDevices, value: jsonEncode(devices.map((d) => d.toJson()).toList()));

  /// "Remember me" stores the username and host only. The password is kept
  /// with the NVR credentials and is released only after biometric unlock.
  Future<RememberedLogin?> readRemembered() async {
    final raw = await _s.read(key: _kRemembered);
    if (raw == null) return null;
    return RememberedLogin.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<void> writeRemembered(RememberedLogin? r) =>
      r == null ? _s.delete(key: _kRemembered) : _s.write(key: _kRemembered, value: jsonEncode(r.toJson()));

  Future<Map<String, Object?>> readSettings() async {
    final raw = await _s.read(key: _kSettings);
    return raw == null ? {} : jsonDecode(raw) as Map<String, Object?>;
  }

  Future<void> writeSettings(Map<String, Object?> settings) =>
      _s.write(key: _kSettings, value: jsonEncode(settings));

  /// Factory reset: removes every key the app owns.
  Future<void> wipe() => _s.deleteAll();
}

class RememberedLogin {
  const RememberedLogin({required this.username, required this.host, required this.biometricEnabled});

  final String username;
  final String host;
  final bool biometricEnabled;

  Map<String, Object?> toJson() => {'username': username, 'host': host, 'biometric': biometricEnabled};

  factory RememberedLogin.fromJson(Map<String, Object?> j) => RememberedLogin(
    username: j['username'] as String? ?? '',
    host: j['host'] as String? ?? '',
    biometricEnabled: j['biometric'] as bool? ?? false,
  );
}
