# HomeGuard: local-first security app

HomeGuard is a Flutter app for Android and iOS. It replaces SuperLive Plus for a Techson installation:

| Device | Model | How HomeGuard talks to it |
|---|---|---|
| NVR | TCR I12 S04-NS | RTSP (TVT path format `/chID={n}&streamType=main\|sub`), digest auth |
| Cameras ×3 | (via NVR channels 1–3) | RTSP through the NVR |
| Outdoor door station + Mifare RFID | TCTDB102 | RTSP/ONVIF video, ONVIF audio back-channel for talk, HTTP relay for unlock |
| Indoor monitor | TCTIS716 | HTTP index of SD-card snapshots/clips (sync), or manual SD-card import |

There is no cloud and no P2P relay. The app looks for every device on the LAN first. It only uses a remote route if you configured one, and only over a VPN tunnel or TLS.

---

## Features

**Authentication & security**
- Login with NVR IP/domain, username and password. The credentials are checked with a real RTSP `DESCRIBE` (digest auth) against camera 1.
- Remember me (keeps username and host) and an optional **Face ID / fingerprint** unlock.
- Everything is stored in **flutter_secure_storage**: iOS Keychain (`first_unlock_this_device`, no iCloud sync) and the Android Keystore (RSA-OAEP + AES-GCM). There are no SharedPreferences and no plaintext files.
- Brute-force lockout after 5 failed logins (30 s, then doubling up to 15 min).
- Auto-lock after N minutes in background (0 = lock immediately). Without biometrics, locking also deletes the password.
- Door unlock needs a biometric confirmation (biometric-only, no PIN fallback) or a dialog, plus a 1-second **hold-to-unlock** button and a 3 s relay debounce. Every attempt is written to the local audit log.
- Android: `FLAG_SECURE` (feeds stay out of screenshots and the recent-apps thumbnail), backups and device-transfer disabled, system CAs only.
- Logs redact `user:pass@`, `Authorization` headers and credential query parameters.

**LAN priority / remote fallback** (`lib/core/network/connection_manager.dart`)
1. TCP probe of the LAN host (800 ms timeout). If it answers, that route is used.
2. Otherwise the remote route, but only if it is configured:
   - **VPN mode** (WireGuard, Tailscale, IPsec). Plain RTSP/HTTP is allowed, but *only* if the host resolves to a private or tunnel address (RFC 1918, 100.64/10, ULA). A "VPN" host that resolves to a public IP is refused, because otherwise credentials would travel in cleartext.
   - **TLS mode**. Only `rtsps://` and `https://` are used, with normal certificate validation (no "accept all certs" switch).
3. Routes are cached for 30 s. The cache is cleared on any connectivity change (Wi-Fi ↔ cellular, VPN up/down) and when the app resumes.

**Live feeds**
- A responsive grid (2 or 3 columns) shows the 3 cameras and the door station. It uses sub-streams by default to save bandwidth and CPU.
- Fullscreen player: main stream, pinch-zoom, HD/SD toggle and mute.
- Overlay quick actions: **Talk** (two-way intercom), **Snapshot**, **Unlock**.
- The player (libmpv via media_kit) is tuned for low latency: TCP-interleaved RTSP, cache off, `nobuffer`/`low_delay`, short probing.
- Resilience:
  - A stall watchdog reconnects after 8 s without frames.
  - Reconnects use exponential back-off (1 s → 30 s).
  - The stream is released in background, which frees NVR stream slots.
  - Error messages are readable (auth failed, timeout, path not found…).
  - The live player's protocol whitelist is limited to RTSP/RTP/TCP/TLS.

**Two-way audio**
- Uses the standard ONVIF RTSP audio back-channel (`Require: www.onvif.org/ver20/backchannel`).
- Microphone audio (8 kHz PCM16, with echo cancellation and noise suppression) is encoded to G.711 µ-law or A-law. It is then sent as RTP packets (40 ms each) interleaved on the RTSP TCP connection, with keep-alives.
- The microphone is closed whenever the app leaves the foreground.

**Events & snapshots**
- Timeline grouped by day, with filter chips: *Face Detected, Motion, Call Received, Manual Snapshot, Door Unlocked, RFID Access*.
- Detail view: zoomable snapshot (up to 6×), local clip playback (file-only whitelist), timestamp, device and type tags, delete.
- Sources:
  - Snapshots taken in the app.
  - **Sync from the indoor monitor** over HTTP. The index can be a JSON list or an HTML directory listing. Links that point to other hosts are never followed.
  - **Import from the SD card** with the file picker.
- Event type and timestamp are inferred from device file names (e.g. `20260115_083012_FACE.jpg`).
- Data lives in the app sandbox with an atomic index write. A corrupt index does not crash the app. A size cap evicts the oldest events.

**Access control**
- Door-station preview with talk, snapshot and unlock buttons.
- Hold-to-unlock for each configured relay.
- Access log: unlocks, failed unlocks, RFID events and calls.

**Settings & network status**
- Status for each device: route (LAN, VPN, TLS or OFF), address and TCP latency.
- **RTSP probe**: handshake latency, video and audio codecs, whether a back-channel is present, server string.
- ONVIF **WS-Discovery** (UDP multicast) to find the door station and indoor monitor and assign them.
- **Detect via ONVIF**: GetProfiles + GetStreamUri with a WS-Security digest token. It fills in the door station's real RTSP path.
- Device editor (LAN/remote host, ports, channel, RTSP template, relay endpoint, method and body, event index path, credentials for each device).
- Erase-all (credentials, settings, snapshots).

---

## Architecture

```
lib/
  main.dart / app.dart / router.dart   composition, go_router (StatefulShellRoute, 4 tabs), auto-lock
  core/
    app_services.dart                  composition root (Provider + AppServices.instance for FF actions)
    models/                            DeviceConfig (topology), SecurityEvent
    security/                          SecureStore (keystore), BiometricService
    network/                           ConnectionManager (LAN→VPN/TLS), DeviceHttpClient (digest), reachability
    rtsp/                              RtspClient, stream parser, SDP, digest auth  ← pure Dart, unit-tested
    onvif/                             WS-Discovery (UDP), Media service SOAP + WS-Security
    audio/g711.dart                    µ-law / A-law encoders
    services/                          DeviceRegistry, EventStore, DoorRelay, Intercom, MonitorSync
  custom_code/                         FlutterFlow-shaped custom code
    actions/                           triggerDoorUnlock, checkLanReachability, probeRtspStream,
                                       captureSnapshot, toggleIntercom, discoverOnvifDevices
    widgets/rtsp_player_widget.dart    resilient low-latency RTSP player
  features/                            auth, shell, live, events, access, settings (UI + controllers)
  theme/                               dark-first security palette
```

State management is Provider with `ChangeNotifier` controllers, the same pattern FlutterFlow's `FFAppState` uses. All network and protocol code sits behind small interfaces: the TCP probe, DNS lookup, credential verifier, file root and secure storage can all be swapped in tests.

See [`docs/FLUTTERFLOW.md`](docs/FLUTTERFLOW.md) for moving the custom widget and actions into a FlutterFlow project.

---

## Build & run

Requires Flutter 3.38+ (developed with 3.47 / Dart 3.13).

```bash
cd homeguard
flutter pub get
flutter analyze
flutter test
flutter run            # device or emulator on the same LAN as the NVR
flutter build apk --release
flutter build ipa      # needs Xcode + signing
```

Before publishing:
- Change `applicationId` / bundle identifier (`com.homeguard.local.homeguard`).
- Configure release signing (the template signs release builds with the debug key).

Platform notes:
- **Android**: minSdk 28. `MainActivity` extends `FlutterFragmentActivity` (needed by `local_auth`).
- **iOS**: the Info.plist includes the Face ID, microphone and local network usage strings. **ONVIF discovery on iOS 14+ needs the `com.apple.developer.networking.multicast` entitlement**, which you request from Apple. Without it, discovery returns nothing; enter the IPs manually.

---

## First-time setup for the Techson devices

1. **Login**: enter the NVR's LAN IP (e.g. `192.168.1.100`) and the NVR admin account.
   - The default camera path is TVT's `/chID={channel}&streamType={stream}&linkType=tcp` on port 554.
   - If your firmware uses something else, change it under Settings → Camera N.
2. **Door station (TCTDB102)**: Settings → *Discover ONVIF devices*, then assign the device as *Front Door*. Next, open *Front Door* → **Detect via ONVIF** to fill the RTSP path.
   - Run **Probe stream** in Network status. If it reports *back-channel: no*, the unit does not expose ONVIF two-way audio; turn off "Two-way audio".
3. **Door relay**: enter the unlock endpoint from your door station's HTTP/CGI API documentation, e.g. `/cgi-bin/accessControl.cgi?action=openDoor&channel=1`.
   - Set the method and body if needed.
   - Requests use Digest/Basic auth with the device (or NVR) credentials.
4. **Indoor monitor (TCTIS716)**: set its LAN IP. If its web server exposes the SD-card snapshot folder, put that path in *SD-card index path* and use **Sync** on the Events tab. Otherwise copy the files from the SD card and use **Import**.
5. **Remote access (optional)**: set up a WireGuard/Tailscale tunnel to your home network. Then enter the NVR's tunnel address with mode **VPN tunnel**. Do not port-forward RTSP to the internet.

---

## Known limitations (please read)

- **Not yet validated against the physical devices.**
  - The protocol code is tested against an in-process fake NVR (digest auth, SDP, back-channel RTP framing). The connection policy, auth flow and event store are unit-tested.
  - Real-hardware testing with the TCR I12 / TCTDB102 / TCTIS716 still needs to happen.
- **Unlock and event endpoints are configurable, not hard-coded.** Techson does not publish the HTTP API for the TCTDB102 and TCTIS716. Take the exact relay and SD-card paths from the device documentation or its web UI.
- **Two-way talk needs ONVIF back-channel support.** If the door station only offers a proprietary or SIP intercom, talk will not work in this version. The probe tells you whether it is supported.
- **No push notifications for doorbell rings.** That would need a persistent SIP/vendor event connection or a cloud relay, and "no cloud" is a deliberate design choice here. Ring events show up after a monitor sync.
- **No local clip recording.** The app takes snapshots; clips come from the monitor or SD card.
- **iOS screenshot blocking is not implemented.** iOS has no `FLAG_SECURE` equivalent.
- **TLS remote mode requires a certificate that the OS trusts.** Self-signed NVR certificates are rejected; use VPN mode instead.
