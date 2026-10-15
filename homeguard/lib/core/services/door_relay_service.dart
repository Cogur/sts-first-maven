import '../models/security_event.dart';
import '../network/connection_manager.dart';
import '../network/device_http_client.dart';
import 'device_registry.dart';
import 'event_store.dart';

class UnlockResult {
  const UnlockResult.success(this.message) : ok = true;
  const UnlockResult.failure(this.message) : ok = false;
  final bool ok;
  final String message;
}

/// Fires the door station / indoor monitor relay via its HTTP API.
///
/// Every attempt — successful or not — is written to the local audit log.
class DoorRelayService {
  DoorRelayService(this._registry, this._connections, this._http, this._events);

  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final DeviceHttpClient _http;
  final EventStore _events;
  final Map<String, DateTime> _lastTrigger = {};

  /// Debounce so a double-tap cannot pulse the relay twice.
  static const cooldown = Duration(seconds: 3);

  Future<UnlockResult> unlock(String deviceId) async {
    final device = _registry.byId(deviceId);
    if (device == null || !device.canUnlock) {
      return const UnlockResult.failure('No unlock endpoint configured for this device');
    }
    final last = _lastTrigger[deviceId];
    if (last != null && DateTime.now().difference(last) < cooldown) {
      return const UnlockResult.failure('Please wait before unlocking again');
    }
    _lastTrigger[deviceId] = DateTime.now();

    try {
      final route = await _connections.require(deviceId);
      await _http.send(
        device.unlockMethod,
        route.httpUri(device.unlockPath),
        credentials: _registry.credentialsFor(deviceId),
        body: device.unlockBody,
        headers: device.unlockBody.trimLeft().startsWith('{')
            ? const {'Content-Type': 'application/json'}
            : const {},
      );
      await _events.addRecord(
        type: EventType.doorUnlocked,
        deviceId: deviceId,
        note: 'Unlocked from app via ${route.kind.name.toUpperCase()}',
      );
      return UnlockResult.success('${device.name} unlocked');
    } on DeviceUnreachableException catch (e) {
      await _audit(deviceId, e.toString());
      return UnlockResult.failure(e.toString());
    } on DeviceHttpException catch (e) {
      await _audit(deviceId, e.message);
      return UnlockResult.failure(e.message);
    }
  }

  Future<void> _audit(String deviceId, String reason) =>
      _events.addRecord(type: EventType.other, deviceId: deviceId, note: 'Unlock FAILED: $reason');
}
