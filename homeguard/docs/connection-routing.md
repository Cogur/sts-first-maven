# Connection routing (LAN first, then VPN/TLS)

Every network call to a device first asks `ConnectionManager` for a `ResolvedRoute`. It probes the LAN address over TCP, falls back to a configured remote route only when that route is safe, and caches the result for a short time. Nothing in the app should build a device URL any other way.

**Use this document when:** you add a call to a device, build an RTSP/HTTP URL, touch ports or hosts, change remote access, or debug "unreachable".

**Not covered:** what the player does with the URL → [live-streaming.md](live-streaming.md). Digest auth and protocol details → [device-protocols.md](device-protocols.md).

## Definitions

| Term | Meaning here |
|---|---|
| Host device | The device whose address is probed. Cameras have `parentId: 'nvr'` and resolve to the **NVR's** host and ports; everything else is its own host. |
| `RouteKind.lan` | `lanHost` answered a TCP connect within 800 ms. Always plain (`secure: false`). |
| `RouteKind.remote` | `remoteHost` answered within 3 s, and the remote mode allowed it. `secure` is true only in TLS mode. |
| `RemoteMode.vpn` | Plain RTSP/HTTP to `remoteHost`, allowed **only** if every DNS result is private/tunnel (RFC 1918, 100.64/10, ULA, loopback, link-local). |
| `RemoteMode.tls` | `rtsps://` on `rtspsPort` (default 322) and `https://` on `httpsPort`. Normal certificate validation. |
| `resolve` vs `require` | `resolve` returns `RouteKind.unreachable`; `require` throws `DeviceUnreachableException`. Services use `require`. |

## Flow

1. `DeviceRegistry.load()/upsert()` → `ConnectionManager.updateDevices()` (also invalidates the cache). `lib/core/services/device_registry.dart`
2. Caller → `connections.resolve(id)` or `require(id)`. `lib/core/network/connection_manager.dart`
3. Cache hit (< 30 s, same host device) → returned. Concurrent calls share one in-flight future per host.
4. Miss → `_resolve`: probe LAN; if it fails and remote is allowed, probe remote. The probe port is the **HTTP** port for the indoor monitor and the **RTSP** port for everything else. `lib/core/network/reachability.dart`
5. The result is stored only if no `invalidate()` ran meanwhile (generation check), then `notifyListeners()`.
6. Caller builds URLs from the route:
   - `route.rtspUrl(path, creds)`: credentials percent-encoded in the URL, **for the native player only**.
   - `route.rtspUri(path)`: no credentials, for `RtspClient` (it does digest itself).
   - `route.httpUri(pathAndQuery)`: for `DeviceHttpClient`.
   IPv6 hosts are bracketed automatically.

Cache invalidation happens on any connectivity change (`connectivity_plus`), on app resume (`lib/app.dart`), on device edits, and on the Live tab's refresh button.

## Invariants and pitfalls

- **Never concatenate `rtsp://host:port` yourself.** You would skip the TLS/VPN policy, the IPv6 brackets and credential encoding.
- **Never put credentials in a URL that goes anywhere but the native player.** Logs redact them (`Log.redact`), but `rtspUri`/`httpUri` exist so you don't rely on that.
- A VPN host that resolves to a public IP is refused on purpose (it would send passwords in cleartext). Don't "fix" this by falling back to plain HTTP; TLS mode exists for that case.
- `ResolvedRoute.rtspPort/httpPort` already reflect TLS vs plain. Don't read `device.rtspPort` after resolving.
- Camera routes are cached under the NVR's id: `cached('cam2')` returns the NVR's entry.
- `remoteMode == disabled` means LAN only. The app never tries the internet for that device.
- No ICMP: reachability is a TCP connect, because NVRs and mobile networks often drop pings.

## Related

- Pair: [live-streaming.md](live-streaming.md). `DeviceStreamView` re-resolves when the cache is cleared.
- Tests: `test/network_test.dart` (LAN preference, VPN refusal, TLS ports, cache invalidation, URL encoding).
