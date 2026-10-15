import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../utils/log.dart';

/// Thin wrapper over `local_auth` so the rest of the app never deals with
/// platform exceptions.
class BiometricService {
  BiometricService([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
    } on PlatformException catch (e) {
      Log.w('bio', 'availability check failed: ${e.code}');
      return false;
    } on LocalAuthException catch (e) {
      Log.w('bio', 'availability check failed: ${e.code.name}');
      return false;
    }
  }

  /// Returns true only on a successful biometric match.
  ///
  /// [biometricOnly] blocks the device-PIN fallback. Login uses the fallback
  /// (so a failed sensor does not lock the owner out); door unlock does not.
  Future<bool> authenticate(String reason, {bool biometricOnly = false}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      Log.w('bio', 'authenticate failed: ${e.code.name}');
      return false;
    } on PlatformException catch (e) {
      Log.w('bio', 'authenticate failed: ${e.code}');
      return false;
    }
  }
}
