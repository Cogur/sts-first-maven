# Testing

Tests run without devices: network, storage, biometrics and credential checks are injected fakes, and the RTSP client is tested against an in-process fake NVR. A separate, tagged test file runs end-to-end against the Docker simulator. CI runs analyze + test on every push that touches `homeguard/`, then builds an installable test APK.

**Use this document when:** you add or change tests, need a fake, run the simulator checks, or touch CI.

**Not covered:** how to start and use the simulator by hand → [../tools/simulator/README.md](../tools/simulator/README.md). Signing and Play releases → [PLAY_STORE.md](PLAY_STORE.md). How test APKs are built and published for any app in this repo (template, signing-key cache, reading build errors from the sandbox) → [../../docs/build-apk.md](../../docs/build-apk.md).

## Definitions

| Term | Meaning here |
|---|---|
| Unit tests | `test/*.dart` except the simulator file. They need no network beyond localhost. |
| `FakeNvr` | Local TCP RTSP server in `test/rtsp_client_test.dart` with digest auth, SDP and back-channel. |
| Simulator test | `test/simulator_test.dart`, tagged `simulator` (`dart_test.yaml`), **skipped unless `HOMEGUARD_SIM_HOST` is set**. |
| Test APK | `HOMEGUARD_TEST_BUILD=true` → app id suffix `.test`, signed with the debug key (`android/app/build.gradle.kts`). |

## Where things are tested

| Area | File |
|---|---|
| Routing policy, cache, URL encoding, private-address check, log redaction, path templates | `test/network_test.dart` |
| Sign-in, remember-me, biometric unlock, lockout, lock, login form | `test/auth_test.dart` |
| G.711, digest (RFC 2617 vector), RTSP stream parser, SDP | `test/protocol_test.dart` |
| RTSP client against `FakeNvr` | `test/rtsp_client_test.dart` |
| Name inference, index parsing, `EventStore` persistence | `test/events_test.dart` |
| Login, unlock and monitor sync against the simulator | `test/simulator_test.dart` |

## Commands

```bash
cd homeguard
flutter analyze
flutter test
# end-to-end, with tools/simulator running (docker compose up):
HOMEGUARD_SIM_HOST=127.0.0.1 flutter test test/simulator_test.dart
```

CI: `.github/workflows/homeguard-test-apk.yml` (push/PR on `homeguard/**`: pub get → analyze → test → test APK artifact, Flutter 3.47.7). `.github/workflows/homeguard-android-release.yml` is manual (signed AAB, optional Play upload).

## Invariants and pitfalls

- Inject fakes through constructors (see the seams in [composition-and-state.md](composition-and-state.md)). Don't add test-only branches to production code.
- Pass a fake `connectivity` stream to `ConnectionManager` in tests; the default subscribes to the real plugin.
- `EventStore(root: ...)` must point at a temp directory in tests.
- Keep simulator tests skippable by default so CI stays green without Docker.
- Not covered by any automated test: real Techson hardware, two-way talk against a real door station, iOS discovery entitlement.

## Related

- [composition-and-state.md](composition-and-state.md)
