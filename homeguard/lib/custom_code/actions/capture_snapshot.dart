// FlutterFlow custom action: "captureSnapshot"
// Return type: String — local file path of the saved JPEG, or empty on failure.
// Arguments: playerTag (String) — the RtspPlayerWidget's playerTag,
//            deviceId (String).

import '../../core/app_services.dart';
import '../../core/models/security_event.dart';
import '../widgets/rtsp_player_widget.dart';

Future<String> captureSnapshot(String playerTag, String deviceId) async {
  final player = RtspPlayerRegistry.instance[playerTag];
  if (player == null) return '';
  final bytes = await player.screenshot(format: 'image/jpeg');
  if (bytes == null || bytes.isEmpty) return '';
  final event = await AppServices.instance.events.addMedia(
    bytes: bytes,
    extension: 'jpg',
    type: EventType.manualSnapshot,
    deviceId: deviceId,
  );
  return event.mediaPath ?? '';
}
