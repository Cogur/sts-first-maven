# Flair Log: agent router

Always-on routing for work inside `flair_log/`. Overview and code map: [`README.md`](README.md).

## Routing

| Task mentions… | Read |
|---|---|
| APK, build, install, CI, release page | [`../docs/build-apk.md`](../docs/build-apk.md) (shared), then [`docs/BUILD_APK.md`](docs/BUILD_APK.md) (app specifics) |
| gauge, needle, dial, calibration, tracking, pivot, camera, zoom, wrong/missing pressure, marker, printed sign | [`docs/gauge-reading.md`](docs/gauge-reading.md) (pipeline + Flair-specific pitfalls); code in `lib/vision/`; tests in `test/gauge_reader_test.dart` (real-photo fixtures) and `test/marker_test.dart` |
| flicker, jumps, smoothing, filter, noisy pressure | `lib/vision/needle_filter.dart` (thresholds documented in its header); tests in `test/needle_filter_test.dart` |
| scale, BOOKOO, Bluetooth, BLE | `lib/scale/` — protocol source in `bookoo_protocol.dart` header |
| recording, auto start/stop, flow | `lib/brew/brew_session.dart` |
| chart, graph | `lib/ui/widgets/brew_chart.dart` (three panels, one time axis, no dual axes) |

## Commands

```bash
cd flair_log
flutter pub get && flutter analyze && flutter test    # what CI runs
```

## Pitfalls

- Camera and BLE only work on a real phone. Use demo mode (Settings) or the tests elsewhere.
- Keep `flutter_blue_plus` on 2.x and `wakelock_plus` at 1.8.0 (see the shared build doc).
