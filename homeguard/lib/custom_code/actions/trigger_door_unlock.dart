// FlutterFlow custom action: "triggerDoorUnlock"
// Return type: String (empty on success, otherwise the error message).
// Argument: deviceId (String) — e.g. "door".

import '../../core/app_services.dart';

Future<String> triggerDoorUnlock(String deviceId) async {
  final result = await AppServices.instance.relay.unlock(deviceId);
  return result.ok ? '' : result.message;
}
