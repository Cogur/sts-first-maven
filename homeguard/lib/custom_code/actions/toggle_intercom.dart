// FlutterFlow custom action: "toggleIntercom"
// Return type: String — new state ("talking", "idle") or "error: <message>".
// Argument: deviceId (String).
//
// Opens the ONVIF RTSP audio back-channel and streams the microphone as
// G.711 RTP over the RTSP TCP connection.

import '../../core/app_services.dart';
import '../../core/services/intercom_service.dart';

Future<String> toggleIntercom(String deviceId) async {
  final talk = AppServices.instance.intercom;
  if (talk.state == TalkState.talking && talk.activeDevice == deviceId) {
    await talk.stop();
  } else {
    await talk.start(deviceId);
  }
  return talk.state == TalkState.error ? 'error: ${talk.error}' : talk.state.name;
}
