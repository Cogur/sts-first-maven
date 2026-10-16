# Composition and state

`AppServices` is the composition root: it builds every service once and is exposed two ways. Widgets get it (and the `ChangeNotifier` services) via Provider. FlutterFlow-style custom actions, which accept only primitive arguments, use the static `AppServices.instance`. Every platform dependency sits behind a constructor parameter so tests can replace it.

**Use this document when:** you add a service or controller, wire something into Provider, write a custom action/widget, or need a test seam.

**Not covered:** step-by-step porting into FlutterFlow → [FLUTTERFLOW.md](FLUTTERFLOW.md). Test layout → [testing.md](testing.md).

## Definitions

| Term | Meaning here |
|---|---|
| Core service | Plain Dart in `lib/core/`, no Flutter widgets, no FlutterFlow imports. |
| Controller | `ChangeNotifier` in `lib/features/<area>/` (`AuthController`, `SettingsController`) holding UI state. |
| Custom action | Top-level `Future<primitive/JSON> fn(String ...)` in `lib/custom_code/actions/`, exported from `index.dart`, with a header comment giving its FlutterFlow name, arguments and return type. |

## Flow

1. `main.dart`: `AppServices.instance = AppServices()` builds `SecureStore`, `BiometricService`, `ConnectionManager`, `DeviceHttpClient`, `EventStore`, then the dependent `DeviceRegistry`, `DoorRelayService`, `IntercomService`, `MonitorSyncService`.
2. `app.dart` `MultiProvider`: `Provider.value(AppServices)` + `ChangeNotifierProvider.value` for auth, settings, registry, connections, events, intercom.
3. Widgets: `context.watch<T>()` for state they render, `context.read<T>()` in callbacks. `DoorRelayService` and `MonitorSyncService` are not providers; reach them through `context.read<AppServices>()`.
4. Custom actions: `AppServices.instance.<service>`. Players are found through `RtspPlayerRegistry.instance[playerTag]`.

Injection seams: `ConnectionManager(probe, lookup, connectivity, timeouts)`, `EventStore(root, maxEvents)`, `SecureStore(FlutterSecureStorage)`, `BiometricService(LocalAuthentication)`, `DeviceHttpClient(inner)`, `IntercomService(recorder:)`, `AuthController(verifier:)`, and `AppServices(...)` for the base services.

## Invariants and pitfalls

- **New service:** construct it in `AppServices`, add a `ChangeNotifierProvider.value` only if widgets watch it, and take platform APIs as optional constructor parameters with real defaults.
- **Lint rule `prefer_initializing_formals: false`:** constructors assign private fields explicitly (`: _store = store`). That keeps the code compatible with FlutterFlow's older Dart. Follow it.
- Keep `lib/core/` free of FlutterFlow and page imports, so it can be copied into FF "Custom Files" unchanged.
- Custom actions take and return primitives or JSON only, and catch their own typed exceptions (return `''`/`{'ok': false}`/`'error: …'` instead of throwing).
- Pages may call custom actions directly (the Live overlay uses `captureSnapshot`, Settings uses `probeRtspStream`). This keeps one code path for the app and FlutterFlow.
- Other lints that are on: `avoid_print`, `cancel_subscriptions`, `close_sinks`, strict casts and raw types. Formatter width is 110.

## Related

- [testing.md](testing.md), [FLUTTERFLOW.md](FLUTTERFLOW.md)
