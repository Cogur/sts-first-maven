# Device protocols (RTSP control, digest, ONVIF, talk, HTTP)

HomeGuard talks to devices with small pure-Dart clients in `lib/core/`. The native player only plays video. Everything else is done in Dart: credential checks, stream diagnostics, discovery, two-way audio and relay/CGI calls. RTSP and HTTP share one digest implementation.

**Use this document when:** you change `RtspClient`, digest auth, SDP parsing, ONVIF discovery/media calls, the intercom, G.711, or `DeviceHttpClient`.

**Not covered:** how a host/port is chosen → [connection-routing.md](connection-routing.md). The player → [live-streaming.md](live-streaming.md).

## Definitions

| Term | Meaning here |
|---|---|
| `RtspClient` | RTSP/1.0 control client over TCP or TLS (`rtsps`, default port 322). Matches responses by CSeq. Not a video decoder. |
| `RtspClient.probe` | Connect → `OPTIONS` → `DESCRIBE` (with the back-channel `Require` header) → close. Used for login verification and the "Probe stream" diagnostic. |
| Back-channel | ONVIF audio track the client *sends* on (`Require: www.onvif.org/ver20/backchannel`). Found by `SdpSession.backchannel`. |
| `AuthChallenge.pickBest` | Prefers Digest SHA-256, then Digest MD5, then Basic. Shared by RTSP and HTTP. |
| `DeviceHttpClient` | HTTP for relays and monitor indexes: 5 s hard timeout, no redirects, one 401 → digest/basic retry, typed `DeviceHttpException`. |

## Flows

**Two-way talk** (`lib/core/services/intercom_service.dart`):
1. Check microphone permission → `connections.require(id)` → `RtspClient(route.rtspUri(main path))`.
2. `startBackchannel()`: `DESCRIBE` → pick PCMU (PT 0) or PCMA (PT 8), else error → `SETUP` with `RTP/AVP/TCP;interleaved=0-1` → `PLAY` → keep-alive `GET_PARAMETER` every session-timeout/2 (5–30 s).
3. Microphone PCM16 8 kHz mono → `G711.encodePcm16` → `sendAudio` splits into ≤320-sample (40 ms) RTP packets, framed as `$`-interleaved data on the RTSP socket.
4. `stop()` cancels the mic, sends `TEARDOWN` (1 s best effort), and closes the socket.

**ONVIF** (`lib/core/onvif/onvif_client.dart`): `Onvif.discover()` sends a WS-Discovery multicast to 239.255.255.250:3702 for about 3 s. `getProfiles` / `getStreamUri` are SOAP calls with a WS-Security UsernameToken digest. The device editor uses them to fill the door station's RTSP path.

**Device HTTP**: callers pass `route.httpUri(path)` + `registry.credentialsFor(id)` to `DeviceHttpClient.send`. Only `http`/`https` schemes are accepted.

## Invariants and pitfalls

- `RtspClient.uri` must be **without** credentials (use `route.rtspUri`). It authenticates via the challenge and re-sends `Authorization` on every later request.
- Only G.711 is supported for talk. Any other back-channel codec is an explicit error, not a silent fallback.
- RTP timestamps advance 1 per byte because G.711 at 8 kHz is 1 byte per sample. Keep that if you change the codec.
- iOS 14+ needs the `com.apple.developer.networking.multicast` entitlement for discovery; without it `discover()` returns nothing.
- `DeviceHttpClient` does not follow redirects on purpose (credentials must not leave the device). Monitor sync also refuses index links to other hosts.
- Every device call needs a timeout. A hung device must not freeze the unlock button or the UI.

## Related

- Pair: [live-streaming.md](live-streaming.md) (the Talk button)
- Tests: `test/protocol_test.dart` (G.711, RFC 2617 vector, stream parser, SDP), `test/rtsp_client_test.dart` (in-process `FakeNvr`: digest, wrong password, closed port, PCMA back-channel).
