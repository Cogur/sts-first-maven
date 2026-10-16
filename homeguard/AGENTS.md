# HomeGuard: agent router

Always-on routing for work inside `homeguard/`. The human-readable twin is [`docs/AI_DOCS_INDEX.md`](docs/AI_DOCS_INDEX.md).

1. **Do not preload** the index or every doc. When a row below matches the task, read that doc and its pair (if any). Nothing matches → work from the code.
2. **Say what you follow.** At the start of a task, name the doc files you are using.
3. **Keep docs true.** If your change makes a doc wrong, update it in the same change. New pattern → new doc + a row here and in the index.

## Routing

| Task mentions… | Read |
|---|---|
| route, LAN, remote, VPN, TLS, reachability, host, port, `ResolvedRoute`, `ConnectionManager`, offline, network change | [`docs/connection-routing.md`](docs/connection-routing.md) |
| credentials, password, keystore, `SecureStore`, settings persistence, remember me, wipe / erase, logging, redaction | [`docs/secrets-and-storage.md`](docs/secrets-and-storage.md) |
| login, sign in/out, lock, auto-lock, biometrics, lockout, `AuthController`, router redirect, app lifecycle | [`docs/auth-session.md`](docs/auth-session.md) |
| live view, grid, fullscreen, player, `RtspPlayerWidget`, stall, reconnect, snapshot, `playerTag`, HD/SD, sub-stream | [`docs/live-streaming.md`](docs/live-streaming.md) |
| RTSP client, digest auth, SDP, probe, ONVIF, discovery, back-channel, talk, intercom, G.711, device HTTP / CGI | [`docs/device-protocols.md`](docs/device-protocols.md) |
| unlock, relay, door, hold-to-unlock, access log, cooldown | [`docs/door-unlock.md`](docs/door-unlock.md) |
| events, timeline, `EventStore`, `SecurityEvent`, monitor sync, SD-card import, file name parsing, audit record | [`docs/event-library.md`](docs/event-library.md) |
| new service, Provider, `AppServices`, `ChangeNotifier`, dependency injection, FlutterFlow, custom action/widget | [`docs/composition-and-state.md`](docs/composition-and-state.md) |
| tests, fake, simulator, CI, test APK, `flutter analyze` | [`docs/testing.md`](docs/testing.md) |

## Pairs (read both)

| Technical / pipeline | Product / UI |
|---|---|
| `connection-routing.md` | `live-streaming.md` |
| `device-protocols.md` | `live-streaming.md` (Talk button) |
| `door-unlock.md` | `event-library.md` (audit entries) |
| `auth-session.md` | `secrets-and-storage.md` |

## Existing docs (route here, do not duplicate)

| Topic | File |
|---|---|
| Features, architecture overview, first-time device setup, known limitations | [`README.md`](README.md) |
| Porting `lib/custom_code/` into FlutterFlow | [`docs/FLUTTERFLOW.md`](docs/FLUTTERFLOW.md) |
| Signing, Play Store upload, release workflow | [`docs/PLAY_STORE.md`](docs/PLAY_STORE.md) |
| Privacy policy text | [`docs/PRIVACY_POLICY.md`](docs/PRIVACY_POLICY.md) |
| Running the fake NVR / door / monitor | [`tools/simulator/README.md`](tools/simulator/README.md) |

## Commands

```bash
cd homeguard
flutter pub get && flutter analyze && flutter test    # what CI runs
HOMEGUARD_SIM_HOST=127.0.0.1 flutter test test/simulator_test.dart   # needs tools/simulator running
```

## Where new material goes

- Behavior of the app, contracts, pitfalls → `homeguard/docs/<pattern>.md` + a row above and in the index.
- Personal agent preferences (answer length, how *you* like to work) → not this repo; they live in the user's own agent rules.
- Unsure which → ask before creating a file.
