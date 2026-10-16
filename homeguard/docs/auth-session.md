# Auth session and app lock

`AuthController` is the single source of truth for whether the user may see the app. The router redirects purely on `AuthController.status`, and app lifecycle events in `lib/app.dart` lock the session, stop the microphone and invalidate routes. Login verifies credentials with a real RTSP `DESCRIBE` against the NVR (there is no vendor login API).

**Use this document when:** you change login, sign-out, locking, biometrics, lockout, navigation guards, or anything that should happen on background/resume.

**Not covered:** where credentials are stored and the inheritance rules → [secrets-and-storage.md](secrets-and-storage.md). Digest/RTSP details → [device-protocols.md](device-protocols.md).

## Definitions

| `AuthStatus` | Meaning | Router sends you to |
|---|---|---|
| `initializing` | `init()` not finished | `/splash` |
| `signedOut` | No usable password in memory/storage | `/login` |
| `locked` | Password stored, biometric unlock enabled and available | `/login` (biometric button) |
| `authenticated` | Signed in | `/live` (default tab) |

## Flow

1. `main.dart` builds `AppServices`, `SettingsController` and `AuthController`, runs the app, then `settings.load()` + `events.load()`, then `auth.init()`.
2. `init()`: reads remembered login, loads the registry. If not remembered, it **deletes** the NVR password. Status becomes `locked` if biometric unlock is possible and a password exists, else `signedOut`.
3. `signIn(...)` (`lib/features/auth/auth_controller.dart`):
   1. Lockout check.
   2. Normalize host (strips scheme, path, userinfo, port; keeps IPv6).
   3. **Write topology first** (NVR host, remote host/mode, optional port, optional camera path template), because route resolution reads the registry.
   4. `connections.resolve('nvr', force: true)`; unreachable → actionable message.
   5. Verify by RTSP probe of the **first camera's sub-stream** URL. A 401/403 counts as a failed attempt.
   6. Store credentials, optionally confirm biometrics, write `RememberedLogin`, set `authenticated`.
4. Lockout: from the 5th failure, 30 s doubling per failure, capped at 15 min. It is in memory only (it resets on app restart).
5. Lifecycle (`lib/app.dart`): on `paused`/`hidden` → start the auto-lock timer **and `intercom.stop()`**. On `resumed` → enforce the lock if the timer could not fire while suspended, then `connections.invalidate()`.
6. `lock()`: clears in-memory credentials. With biometric unlock → `locked`. Without → deletes the stored NVR password → `signedOut`.
7. `signOut(forget:)`: always deletes the NVR password. If not forgetting, keeps username/host but turns the biometric flag off, because there is no password left to restore.

## Invariants and pitfalls

- Guard pages through the `redirect` in `lib/router.dart` (`refreshListenable: auth`), not with checks inside pages.
- Login uses biometrics **with** device-PIN fallback; door unlock uses `biometricOnly: true`. Don't unify them.
- Without "remember me" or biometrics, a password must never survive an app restart.
- Anything that must not run in the background (mic, timers that hit devices) belongs in the lifecycle handler in `app.dart`. The player releases its own stream (see [live-streaming.md](live-streaming.md)).
- `autoLockMinutes == 0` means lock as soon as the app is backgrounded.

## Related

- Pair: [secrets-and-storage.md](secrets-and-storage.md)
- Tests: `test/auth_test.dart` (inject `CredentialVerifier`, `FakeBiometrics`, fake probe).
