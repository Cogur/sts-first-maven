# Flair Log

A Flutter app (Android & iOS) for the **Flair 58** manual espresso maker.
Point the phone camera at the pressure gauge, pull a shot, and the app reads
the needle frame by frame. It also records weight and flow from a Bluetooth
scale (BOOKOO Themis Mini / Ultra) and draws the shot as a graph.

## Features

- **Finds the gauge by itself.** Frame the whole machine (the gauge can be
  small in the picture) and tap *Find the gauge*. The app locates the round
  dial, fits its rim (also as an ellipse when the phone looks at it from an
  angle), finds the needle pivot, and takes the needle's rest position as
  0 bar. You only tap one numbered mark (10 on the Flair gauge) on a zoomed
  view.
- **Learns your gauge.** While you brew, the app builds a picture of the empty
  dial. Logo, text and screws then cancel out and the needle stands out more
  clearly with every shot. The learned picture is saved with the
  calibration.
- **Phone doesn't have to stand in the same place.** Each time the Brew
  screen opens (lever up), the app finds the gauge again anywhere in the
  picture and re-sets zero from the needle, which also corrects a phone that
  is turned a little. Calibrate once; place the phone roughly the same way.
- **Follows the moving gauge.** On the Flair 58 the gauge sits on the piston
  stem and moves down during the shot. The reader predicts the movement,
  matches the dial's appearance in every frame and ignores the part of the
  rim the lever covers. If it loses the gauge, it searches the whole picture
  again ("Finding the gauge…" on the gauge view).
- **Printed marker (optional).** Settings → *Print a marker* shares a PDF
  sheet of small ring targets. Stick one on the gauge, lower right (on the
  glass over the logo, or on the rubber guard), and calibrate again. The app
  then finds the gauge from the marker in every frame, also right after the
  phone was moved or bumped, and keeps reading while the lever covers the
  dial.
- **Diagnostic recording** (Settings): saves what the camera sees during a
  shot and adds it to the shot export, so a misbehaving reading can be
  replayed and fixed.
- About 15 readings per second from 1080p video. Details:
  [docs/gauge-reading.md](docs/gauge-reading.md).
- **Steady needle.** Two switches (Settings, or the slider icon on the Brew
  screen), both on by default:
  - *Smooth gauge movement* removes flicker. It smooths strongly while the
    needle is still and lightly while it moves, so a lever pull is followed
    without visible lag.
  - *Ignore impossible jumps* drops readings that would need a faster
    pressure change than a hand on the lever can make (above 10 bar/s
    rising or 30 bar/s falling). Misreads then don't spike the graph. A real
    fast release is still followed after 3 frames, about 0.2 s.

  In the zoomed gauge view the thick needle is the recorded value. The thin
  line is the raw detection, orange when it was thrown out.
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
2. Optional, but steadier: print the marker sheet (Settings → *Print a
   marker*, at 100 %) and stick one marker on the gauge, lower right: on the
   glass over the logo (keep the 0–11 bar scale free) or on the rubber
   guard, where the lever and your hand won't cover it.
3. **Brew → target icon.** With the lever up, tap *Find the gauge*. Check
   that the highlighted circle is your gauge (tap another one if not). On the
   zoomed view the blue line is the needle at 0. Tap the 10 mark and save.
   If the blue line is not on the needle, choose *Tap sets 0* and tap the 0
   mark yourself.
4. Connect the scale (scale icon), put the cup on it, then tap
   **Tare & get ready**.
5. Pull the shot. Recording starts and stops on its own, or use the buttons.

## Code map

| Path | What it does |
|---|---|
| `lib/vision/dial_locator.dart` | Finds round dials, fits rim (circle/ellipse), hub candidates |
| `lib/vision/gauge_reader.dart` | Needle detection, learned dial background, appearance tracking |
| `lib/vision/gauge_setup.dart` | Calibration steps as pure functions (run on a background isolate) |
| `lib/vision/marker.dart` | Printed marker detection; the sheet is made by `tool/marker_sheet.dart` → `assets/marker_sheet.pdf` |
| `lib/vision/camera_gauge_source.dart` | Camera image stream → luma frames → readings, zoomed gauge view |
| `lib/vision/gauge_calibration.dart` | Angle ↔ bar mapping, calibration storage |
| `lib/vision/needle_filter.dart` | Jump rejection (rate limit + confirmation) and One Euro smoothing of readings |
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
flutter test          # gauge finder/reader on synthetic dials and real photos, BOOKOO, brew session
flutter run           # on a connected phone (camera + BLE need a real device)
```

The APK is built by GitHub Actions on every push: the shared process is in
[../docs/build-apk.md](../docs/build-apk.md), and what is specific to this app is in
[docs/BUILD_APK.md](docs/BUILD_APK.md). Agents: start at [AGENTS.md](AGENTS.md).
