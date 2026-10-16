# HomeGuard docs index

> **Branch note:** the HomeGuard code and these docs live on `claude/security-camera-mobile-app-kxp2a1` (docs added on `claude/ai-docs-knowledge-base`). Neither is on `master` yet. Merge them together so the rows below never point at code that is missing.

The map of HomeGuard's cross-cutting patterns. Agents get the same table from [`../AGENTS.md`](../AGENTS.md); this file is for humans and for agents that want the bigger picture.

**Open this when** you change networking, credentials, login/locking, live video, device protocols, door unlock, events, app composition or tests, or when you are new to the code.

If two docs might fit, open the broadest one and the closest one. Overlap is intentional.

## Map

```
                      composition-and-state.md   (AppServices, Provider, FlutterFlow seams)
                                   │
        ┌──────────────┬───────────┼──────────────┬────────────────┐
        │              │           │              │                │
 auth-session.md  connection-  device-        event-library.md  testing.md
        │         routing.md   protocols.md        ▲
        │              │           │               │ audit entries
 secrets-and-     live-streaming.md◄┘ (talk)   door-unlock.md
 storage.md
```

| Doc | Covers | Not covered (go to) |
|---|---|---|
| [connection-routing.md](connection-routing.md) | LAN → VPN/TLS route choice, cache, URL building | Player behavior → live-streaming |
| [secrets-and-storage.md](secrets-and-storage.md) | `SecureStore`, credential inheritance, settings, wipe, log redaction | Login state machine → auth-session |
| [auth-session.md](auth-session.md) | `AuthStatus`, sign-in, lockout, auto-lock, router redirect, lifecycle | Where secrets are stored → secrets-and-storage |
| [live-streaming.md](live-streaming.md) | `DeviceStreamView`, `RtspPlayerWidget`, recovery, snapshots | Route resolution → connection-routing |
| [device-protocols.md](device-protocols.md) | RTSP control client, digest, SDP, ONVIF, back-channel talk, device HTTP | UI of talk/unlock → live-streaming, door-unlock |
| [door-unlock.md](door-unlock.md) | Confirmation, hold, cooldown, relay call, audit | Event storage → event-library |
| [event-library.md](event-library.md) | `SecurityEvent`, `EventStore`, sync, import, name inference | Relay call → door-unlock |
| [composition-and-state.md](composition-and-state.md) | `AppServices`, Provider wiring, injection seams, FlutterFlow constraints | Porting steps → FLUTTERFLOW.md |
| [testing.md](testing.md) | Test layout, fakes, simulator tests, CI | Simulator setup → tools/simulator/README.md |

## Pairs

| Technical / pipeline | Product / UI |
|---|---|
| connection-routing.md | live-streaming.md |
| device-protocols.md | live-streaming.md (Talk button) |
| door-unlock.md | event-library.md |
| auth-session.md | secrets-and-storage.md |

## Do not cover here

- Feature list, first-time device setup, known limitations → [`../README.md`](../README.md)
- FlutterFlow porting steps → [`FLUTTERFLOW.md`](FLUTTERFLOW.md)
- Signing and Play releases → [`PLAY_STORE.md`](PLAY_STORE.md)
- Simulator usage → [`../tools/simulator/README.md`](../tools/simulator/README.md)

## How to add a doc

1. One focused Markdown file per cross-cutting pattern, named for the pattern (`form-save.md`), never for a ticket or a single class.
2. Use the shape of the existing docs: one-paragraph intro, **Use this document when**, **Not covered**, definitions, flow with file paths, invariants and pitfalls, related docs.
3. Add a row to the table above **and** to [`../AGENTS.md`](../AGENTS.md). Add a row only once the code it describes is on the default branch; for in-flight work, put a branch note at the top of the doc.
4. Only describe behavior you confirmed in the code.
