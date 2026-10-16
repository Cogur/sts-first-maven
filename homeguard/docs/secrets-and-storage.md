# Secrets and storage

HomeGuard has exactly one persistence layer for configuration: `SecureStore`, a wrapper over `flutter_secure_storage` (iOS Keychain this-device-only, Android Keystore-backed AES-GCM). Credentials, device topology, "remember me" and even non-secret preferences go there. Event media is the only thing written to files, inside the app sandbox. Logs never contain credentials.

**Use this document when:** you persist anything, read credentials for a device, add a setting, touch erase-all, or log something that might contain a URL or header.

**Not covered:** when credentials are cleared on lock/sign-out → [auth-session.md](auth-session.md). Event files → [event-library.md](event-library.md).

## Definitions

| Term | Meaning here |
|---|---|
| Key names | `devices.v1`, `settings.v1`, `login.remembered.v1`, `cred.<deviceId>.v1`. The `.v1` suffix is the schema version. |
| Own credentials | Credentials stored under a device's own id (`hasOwnCredentials`). Only top-level devices (`parentId == null`) are loaded. |
| `credentialsFor(id)` | Camera → its NVR's credentials. Door station / monitor → own credentials, else **the NVR's** (typical single-account install). |
| `RememberedLogin` | Username + host + biometric flag. **Never the password.** |

## Flow

- Topology: `DeviceRegistry.load()` reads `devices.v1`, or uses `DeviceConfig.defaultTopology()` (nvr, cam1–3, door, monitor) when empty. `upsert()` writes the whole list back. `lib/core/services/device_registry.dart`
- Credentials: `DeviceRegistry.setCredentials(id, c)` writes or (when null/empty) deletes `cred.<id>.v1`, and keeps an in-memory copy. `clearMemory()` drops the in-memory copies only.
- Settings: `SettingsController.load()/update()` stores a small JSON map (`autoLockMinutes`, `confirmUnlock`, `gridSub`, `muteGrid`) in `settings.v1`. `lib/features/settings/settings_controller.dart`
- Erase all (Settings page `_wipe`): `events.wipe()` → `store.wipe()` (`deleteAll`) → `auth.signOut(forget: true)`. `lib/features/settings/settings_page.dart`
- Logging: `Log.d` prints in debug only; `Log.w/e` also go to a 200-line in-memory ring buffer. Every message passes through `Log.redact` (strips `user:pass@`, `Authorization:` values and `password|pwd|pass|token|user|username` query params). Nothing is written to disk. `lib/core/utils/log.dart`

## Invariants and pitfalls

- **Do not add SharedPreferences, Hive, sqlite or plain files for settings.** Add a key to `SecureStore` (or a field in `settings.v1`).
- Changing a stored JSON shape: keep reading old data (`fromJson` uses `?? default` everywhere) or bump the key version and migrate.
- Read credentials through `DeviceRegistry.credentialsFor`, not `SecureStore.readCredentials`. Otherwise you miss the camera→NVR and door→NVR fallback and the in-memory lock state.
- Use `Log`, never `print` (the `avoid_print` lint is on). Run `Log.redactUrl` on URLs even in debug messages.
- `AndroidOptions(resetOnError: true)`: if the keystore is corrupted, data is wiped rather than crashing. Callers must cope with `null` reads.
- Android also sets `FLAG_SECURE` (`MainActivity.kt`) and `allowBackup="false"`; keep both when touching platform files.

## Related

- Pair: [auth-session.md](auth-session.md)
- Tests: `test/auth_test.dart` (password not kept without remember-me; lock drops password), `test/network_test.dart` (log redaction).
