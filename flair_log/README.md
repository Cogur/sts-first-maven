# Flair Log

A Flutter app (Android & iOS) for the **Flair 58** manual espresso maker.
Point the phone camera at the pressure gauge, pull a shot, and the app reads
the needle frame by frame. It also records weight and flow from a Bluetooth
scale (BOOKOO Themis Mini / Ultra) and draws the shot as a graph.

## Features

- **Camera gauge reading.** One-time calibration: capture a still, then tap
  the needle hub, the 0 bar mark and the highest numbered mark. After that
  the needle is read about 15 times per second.
- **Follows the moving gauge.** On the Flair 58 the gauge sits on the piston
  stem and moves down during the shot. The reader tracks the bezel so the
  reading stays correct.
- **BOOKOO scale over Bluetooth LE.** Weight, flow rate and battery come from
  BOOKOO's published protocol (service `0x0FFE`). The app tares the scale and
  starts or stops the scale timer for you. It reconnects to the last scale
  automatically.
- **Automatic start and stop.** Recording starts when pressure passes 0.5 bar
  (or weight shows up in the cup). It stops 3 s after the pressure drops back
  to zero, or at an optional target yield.
- **Shot graph.** Pressure, weight and flow are drawn as three panels on one
  time axis, with the 6–9 bar espresso zone shaded. Drag across the graph to
  read exact values.
- **History.** Each shot is saved with dose, yield, ratio, peak and average
  pressure, time to first drops, beans, grind, notes and a rating. You can
  export a shot as CSV or JSON.
- **Demo mode** (Settings). A simulated gauge and scale let you try the app
  without the machine.

## Using it

1. Mount the phone (a small tripod or phone clamp) so it looks straight at the
   gauge with the lever up. Leave room below the gauge, because it travels
   down. Avoid strong reflections on the gauge glass.
2. **Brew → target icon → Calibrate.** Zoom in if the gauge is small, then
   tap *Capture still* and tap the three points. Enter the values printed at
   the first and last mark. The defaults are 0 and 16; check your gauge
   face. *Needle found: 0.0 bar* means it works.
3. Connect the scale (scale icon), put the cup on it, then tap
   **Tare & get ready**.
4. Pull the shot. Recording starts and stops on its own, or use the buttons.

## Code map

| Path | What it does |
|---|---|
| `lib/vision/gauge_reader.dart` | Needle detection (ray sampling + robust percentile score) and gauge tracking |
| `lib/vision/camera_gauge_source.dart` | Camera image stream → luma frames → readings, zoomed gauge view |
| `lib/vision/gauge_calibration.dart` | Angle ↔ bar mapping, calibration storage |
| `lib/scale/bookoo_protocol.dart` | BOOKOO packet parsing and commands |
| `lib/scale/bookoo_scale.dart`, `scale_manager.dart` | BLE connection (flutter_blue_plus), reconnects |
| `lib/brew/brew_session.dart` | 10 Hz recording, auto start/stop, flow from weight |
| `lib/ui/` | Screens; `widgets/brew_chart.dart` is the shot graph |

Bluetooth uses [flutter_blue_plus](https://pub.dev/packages/flutter_blue_plus),
which is free for personal and nonprofit use. Selling or publishing the app
commercially would need a commercial license.

To support another scale, implement `Scale` (`lib/scale/scale.dart`) and
return it from `ScaleManager`.

## Development

```bash
flutter pub get
flutter analyze
flutter test          # gauge reader on synthetic dials, BOOKOO protocol, brew session
flutter run           # on a connected phone (camera + BLE need a real device)
```

The APK is built by GitHub Actions on every push. See
[docs/BUILD_APK.md](docs/BUILD_APK.md).
