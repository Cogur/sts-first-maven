# Using HomeGuard code in FlutterFlow

`lib/custom_code/` is laid out the way FlutterFlow generates custom code, so you can move it over file by file. The app also runs on its own (`flutter run`), so you can check behaviour before you port anything.

## 1. Dependencies

In FlutterFlow, open **Settings → Project Dependencies** and add these packages, using the versions in `pubspec.yaml`:

```
media_kit, media_kit_video, media_kit_libs_video   # RTSP playback (libmpv)
flutter_secure_storage, local_auth                  # keystore + biometrics
record                                              # microphone PCM for intercom
http, crypto, xml, uuid, connectivity_plus, path_provider, file_picker, intl
```

Add this to **Custom Code → main.dart → Initial Actions** (or a custom `main` snippet):

```dart
MediaKit.ensureInitialized();
AppServices.instance = AppServices();
await AppServices.instance.registry.load();
await AppServices.instance.events.load();
```

## 2. Shared code (Custom Files)

Copy everything under `lib/core/` into FlutterFlow **Custom Code → Custom Files**, keeping the folder structure. It is plain Dart with no FlutterFlow imports, so it compiles as is:
- the RTSP client, SDP parser and digest auth
- the ONVIF client
- the G.711 encoders
- the connection manager
- the services

## 3. Custom widget

| Widget | File | Parameters |
|---|---|---|
| `RtspPlayerWidget` | `custom_code/widgets/rtsp_player_widget.dart` | `width`, `height`, `rtspUrl` (String), `playerTag` (String), `muted` (bool), `stallTimeoutSeconds` (int) |

To build `rtspUrl` in FlutterFlow, call a small custom function that wraps `ResolvedRoute.rtspUrl()`. Alternatively, have `checkLanReachability` store the route in App State and build the URL from there. The widget handles the rest itself: reconnecting, stall detection, back-off and background release.

## 4. Custom actions

All actions take only primitive arguments and return primitives or JSON, so they can be bound in the FlutterFlow action editor.

| Action | Args | Returns | Purpose |
|---|---|---|---|
| `checkLanReachability` | `deviceId` | `"lan" \| "remote" \| "unreachable"` | Fresh TCP probe, LAN first |
| `probeRtspStream` | `deviceId` | JSON | RTSP OPTIONS/DESCRIBE + SDP: codecs, back-channel, latency |
| `captureSnapshot` | `playerTag`, `deviceId` | file path | Grabs the current frame as JPEG and stores it as an event |
| `toggleIntercom` | `deviceId` | `"talking" \| "idle" \| "error: …"` | ONVIF back-channel talk |
| `triggerDoorUnlock` | `deviceId` | `""` or error | HTTP relay with Digest auth and an audit log entry |
| `discoverOnvifDevices` | – | `List<JSON>` | WS-Discovery over UDP multicast |

Put a **local authentication** action (FlutterFlow's built-in biometric action) before `triggerDoorUnlock` to keep the same confirmation behaviour as the native app.

## 5. Pages

The four tabs (`features/live`, `features/events`, `features/access`, `features/settings`) can be rebuilt visually in FlutterFlow, or brought in as custom widgets. Either way, they bind to the same services through `AppServices.instance`.
