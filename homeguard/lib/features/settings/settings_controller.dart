import 'package:flutter/foundation.dart';

import '../../core/security/secure_store.dart';

/// User preferences (non-secret, but stored alongside secrets in the
/// keystore so the app has a single, encrypted persistence layer).
class SettingsController extends ChangeNotifier {
  SettingsController(this._store);

  final SecureStore _store;

  int _autoLockMinutes = 5;
  bool _confirmUnlockWithBiometrics = true;
  bool _gridUsesSubstream = true;
  bool _muteGridAudio = true;

  /// Minutes in background before the app re-locks. 0 = lock immediately.
  int get autoLockMinutes => _autoLockMinutes;
  bool get confirmUnlockWithBiometrics => _confirmUnlockWithBiometrics;
  bool get gridUsesSubstream => _gridUsesSubstream;
  bool get muteGridAudio => _muteGridAudio;

  Future<void> load() async {
    final s = await _store.readSettings();
    _autoLockMinutes = s['autoLockMinutes'] as int? ?? 5;
    _confirmUnlockWithBiometrics = s['confirmUnlock'] as bool? ?? true;
    _gridUsesSubstream = s['gridSub'] as bool? ?? true;
    _muteGridAudio = s['muteGrid'] as bool? ?? true;
    notifyListeners();
  }

  Future<void> update({
    int? autoLockMinutes,
    bool? confirmUnlockWithBiometrics,
    bool? gridUsesSubstream,
    bool? muteGridAudio,
  }) async {
    _autoLockMinutes = autoLockMinutes ?? _autoLockMinutes;
    _confirmUnlockWithBiometrics = confirmUnlockWithBiometrics ?? _confirmUnlockWithBiometrics;
    _gridUsesSubstream = gridUsesSubstream ?? _gridUsesSubstream;
    _muteGridAudio = muteGridAudio ?? _muteGridAudio;
    notifyListeners();
    await _store.writeSettings({
      'autoLockMinutes': _autoLockMinutes,
      'confirmUnlock': _confirmUnlockWithBiometrics,
      'gridSub': _gridUsesSubstream,
      'muteGrid': _muteGridAudio,
    });
  }
}
