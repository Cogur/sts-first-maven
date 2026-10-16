# Door unlock

Opening a door is a three-layer flow: a UI confirmation (hold, then biometric or dialog), a service that fires the configured HTTP relay with a debounce, and an audit entry in the event library for every attempt. Endpoints are user-configured, because Techson does not publish the door station's API.

**Use this document when:** you touch any Unlock button, `confirmAndUnlock`, `DoorRelayService`, relay settings, or the Access tab log.

**Not covered:** how events are stored and listed → [event-library.md](event-library.md). HTTP/digest details → [device-protocols.md](device-protocols.md).

## Definitions

| Term | Meaning here |
|---|---|
| Unlockable device | `DeviceConfig.canUnlock` → `unlockPath` is not empty. Any device kind can be a relay target. |
| `unlockPath/Method/Body` | Relative path (with query) on the device's HTTP root, method (default GET) and optional body. A body starting with `{` gets `Content-Type: application/json`. |
| Cooldown | 3 s per device in `DoorRelayService`, so a double tap cannot pulse the relay twice. |
| Hold-to-unlock | `_HoldToUnlock` in the Access tab: a 1 s press animation that must complete before `onUnlock` runs. |

## Flow

1. UI entry points: Access tab hold button, and the Unlock action in `StreamActions` (live overlay). Both call `confirmAndUnlock(context, deviceId)`. `lib/features/access/unlock_flow.dart`
2. Confirmation: if setting `confirmUnlockWithBiometrics` is on and biometrics are available → `biometrics.authenticate(..., biometricOnly: true)`; otherwise an AlertDialog.
3. `DoorRelayService.unlock(id)` (`lib/core/services/door_relay_service.dart`): checks config → cooldown → `connections.require(id)` → `DeviceHttpClient.send(method, route.httpUri(unlockPath), credentials: registry.credentialsFor(id))`.
4. Audit:
   - Success → `EventStore.addRecord(type: doorUnlocked, note: 'Unlocked from app via LAN|REMOTE')`.
   - Failure → `addRecord(type: other, note: 'Unlock FAILED: <reason>')`.
5. A snackbar shows `UnlockResult.message`.
6. FlutterFlow: `triggerDoorUnlock(deviceId)` calls the service directly. The FF page must put a local-auth action in front of it (see [FLUTTERFLOW.md](FLUTTERFLOW.md)).

## Invariants and pitfalls

- **Every attempt is audited, success or failure.** New failure paths must go through `_audit`.
- **The Access log finds failed unlocks by the note prefix `'Unlock FAILED'`** (`access_control_page.dart`), not by event type. Change that string and failed attempts vanish from the log.
- Unlock never uses PIN fallback (`biometricOnly: true`). Login does. Keep them different.
- Don't call `DoorRelayService.unlock` from new UI without going through `confirmAndUnlock`.
- The cooldown starts **before** the request, so a failed attempt also blocks a retry for 3 s.

## Related

- Pair: [event-library.md](event-library.md)
- Tests: `test/simulator_test.dart` ("door unlock and monitor sync work with digest auth"; needs the simulator).
