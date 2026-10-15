// FlutterFlow custom action: "checkLanReachability"
// Return type: String — "lan", "remote" or "unreachable".
// Argument: deviceId (String).
//
// Forces a fresh TCP probe: LAN address first, then the configured secure
// remote route.

import '../../core/app_services.dart';

Future<String> checkLanReachability(String deviceId) async {
  final route = await AppServices.instance.connections.resolve(deviceId, force: true);
  return route.kind.name;
}
