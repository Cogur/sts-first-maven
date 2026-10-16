# Live streaming

Video is decoded by libmpv through `media_kit`, wrapped in the FlutterFlow-shaped `RtspPlayerWidget`, which handles low-latency settings, stall detection, back-off reconnects and releasing the stream in the background. App pages never use the widget directly. They use `DeviceStreamView`, which resolves the route and builds the credentialed URL.

**Use this document when:** you touch the Live grid, fullscreen player, stream quality, overlay actions (talk/snapshot/unlock), player error handling, or snapshots.

**Not covered:** route choice and URL building → [connection-routing.md](connection-routing.md). Talk internals → [device-protocols.md](device-protocols.md). Unlock flow → [door-unlock.md](door-unlock.md).

## Definitions

| Term | Meaning here |
|---|---|
| `StreamQuality.sub` / `main` | Expanded into the device's `rtspPathTemplate` (`{stream}` → `sub`/`main`, `{streamIndex}` → `1`/`0`, `{channel}`, `{channel0}`). The grid uses sub by default (setting `gridSub`); fullscreen starts on main. |
| `playerTag` | String key under which a player registers in `RtspPlayerRegistry`, so primitive-only actions (`captureSnapshot`) can find it. Grid: `grid-<deviceId>`. |
| Stall | No `position` event for `stallTimeoutSeconds` (default 8). Checked every 2 s. |

## Flow

1. `LiveGridPage` / `FullscreenPlayerPage` → `DeviceStreamView(deviceId, quality, playerTag)`. `lib/features/live/`
2. `DeviceStreamView` calls `connections.resolve(id)` and listens to `ConnectionManager`. When its cached route disappears (invalidation), it resolves again.
3. A reachable route → `route.rtspUrl(device.rtspPath(quality), registry.credentialsFor(id))` → `RtspPlayerWidget(key: ValueKey('<id>-<quality>-<host>'))`. The key forces a fresh player when the host changes (e.g. LAN → VPN).
4. `RtspPlayerWidget` (`lib/custom_code/widgets/rtsp_player_widget.dart`):
   - Sets mpv properties for low latency (TCP transport, no cache, `nobuffer`, `low_delay`, short probing) and limits protocols to `rtsp, rtsps, rtp, udp, tcp, tls`.
   - On error, stall or "completed" → status `error` and retry after 1 s, 2 s, 4 s… up to 30 s. The first frame resets the counter.
   - On `paused` → stops the player (frees an NVR stream slot). On `resumed` → reopens.
   - Raw errors are mapped to short readable messages (`_humanize`).
5. `StreamActions` overlay: Talk (if `supportsTalk`) → `IntercomService`; Snapshot → `captureSnapshot(playerTag, deviceId)` → `EventStore.addMedia(type: manualSnapshot)`; Unlock → `confirmAndUnlock` on this device or the first unlockable one.

## Invariants and pitfalls

- **The `rtspUrl` contains the password.** Never display it, log it unredacted, or pass it to anything but the player.
- Keep the protocol whitelist. The clip player in event detail is separately limited to `file`.
- Two widgets with the same `playerTag` overwrite each other's registry entry. Use distinct tags per screen.
- Don't add your own reconnect loop around the widget; it already has watchdog plus back-off. Change `stallTimeoutSeconds` instead.
- Changing `rtspUrl` on an existing widget triggers `retry()`. Changing route host is handled by the key in `DeviceStreamView`.

## Related

- Pair: [connection-routing.md](connection-routing.md)
- FlutterFlow parameters of the widget: [FLUTTERFLOW.md](FLUTTERFLOW.md)
