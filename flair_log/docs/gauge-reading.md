# Reading the gauge with the camera

**Use this document when:** you change anything in `lib/vision/`, the calibration screen, or
see wrong / missing pressure readings.

## Pipeline

| Step | Code | What it does |
|---|---|---|
| Find the dial | `dial_locator.dart` `find` | Coarse search on a 360 px wide copy: a bright face inside a darker rim, scored as the 25th percentile around the circumference (needle, numerals and bands only spoil part of it). |
| Fit the face | `dial_locator.dart` `refine` | Centre by circular Hough voting (all dial circles are concentric); rim radius = first radius where 75 % of directions are dark; edge points = start of a *long* dark run; consensus (RANSAC) circle, or ellipse for an oblique view. |
| Find the pivot | `dial_locator.dart` `hubCandidates`, `gauge_reader.dart` `choosePivot` | Small round shapes near the centre (Hough), keeping the strongest one that lies on the needle line (`needleLine`, a Radon-style search). |
| Zero and scale | `calibration_screen.dart`, `gauge_setup.dart` | Lever up: the needle position is 0 bar. The user taps one numbered mark (10 on the Flair gauge) and types its number. |
| Read each frame | `gauge_reader.dart` `read` | Polar samples around the pivot (360 directions × 20 rings, 0.28–0.82 of the face radius). Needle = direction that differs from the empty dial in the inner half **and** the outer half of the rings. |
| Printed marker (optional) | `marker.dart` | A ring target the user prints (`assets/marker_sheet.pdf`) and sticks at the lower right of the gauge. Found by a centre-surround response on an integral image, then verified along 96 directions (all five bands, relative to a per-direction outer edge); circle fit gives centre and size, the wedge gives rotation to <1° (`_wedgeAngle`). Stored with the calibration (`GaugeCalibration.marker`). See *Printed marker* below. |
| Find it again | `gauge_setup.dart` `relocate` | The phone is not in the same place every session. With a marker in view, marker → face directly, checked by one tracked read. Otherwise, at session start (lever up), the same steps as calibration run on the new view: dial with the clearest needle, pivot on the needle line, needle at rest = zero. The difference to the stored zero is the phone's turn (accepted up to ±25°); background and template are turned with it, the template is recorded afresh; degrees-per-bar are kept. When the gauge is lost mid-shot only the position is updated (`keepZero`): the stored template is lined up with the found dial so face and pivot stay consistent. Runs in the background (`relocateInBackground`). |
| Follow the gauge | `gauge_reader.dart` `track` | Normalised cross-correlation of the calibrated appearance template (face edge, bands, rim) over position and ±3 % scale. Lost for >20 frames → `DialLocator.find` on a background isolate. |
| Learn the dial | `gauge_reader.dart` `learnBackground` | Every confident reading blends all directions ≥15° from the needle (and its tail) into a background image of the empty dial; it is saved with the calibration after each shot. Logo, text and screws then cancel out. |
| Clean up values | `needle_filter.dart` | Impossible jumps dropped, One Euro smoothing (two switches in Settings). |

## Things the Flair 58 gauge taught us (keep these in mind)

- **The needle has a thick tail pointing at "10" and a screw.** At rest that tail direction looks like a
  needle in its inner rings, and the "10" numeral and screw continue the line outward. Hence the
  inner-half **and** outer-half rule.
- **Dark bands inside the face** ("Espresso" grey band at the top, "STOP! BREAKAGE!" band on the right)
  fool naive edge finding: the rim threshold sits close to the guard's darkness, and the consensus
  fit outvotes the band edges. An edge score that rewards contrast (`rimScore`) drifts onto the band's
  inner edge; that is why tracking uses the appearance template.
- **The face centre is not the pivot** when the phone looks slightly up or down: the rim hides part of
  the face. 10–15 px at a 80 px radius in the test photos, i.e. several degrees of needle error.
- **Choosing the pivot by needle clarity is ambiguous**: every point on the needle's line sees a long
  straight dark line. Pivot = hub candidate *on* the line.
- **Circular Hough is biased for ellipses** (normals of an ellipse miss the centre), so an ellipse fit
  is final and is validated by the face score, not by the Hough centre.
- **Real whole-machine photos** (`test/fixtures/machine_*.jpg`, greyscale 1080 px wide, the
  user's kitchen) showed what the synthetic dial did not:
  - The **shot mirror** is a bright disc with a dark rim, i.e. very gauge-like, and the **cup** is round
    too. Candidates are ranked by `strictScore` (bright face *all round*, dark rim *all round*) and
    then by whether a needle is visible; circles nested inside a bigger candidate are dropped.
    After losing the gauge, a re-found dial is accepted only if it matches the calibrated template
    (≥0.8; the gauge scores ~1.0, the mirror ~0.67) **and** shows a needle (`tryReacquire`).
  - The bright **metal stem** and the black **lever** pull the centre vote off, so refinement keeps
    several centre candidates and never accepts a step that lowers the strict score.
  - The **lever passes in front of the gauge**: tracking matches the template per angular sector and
    averages the best 6 of 9; directions whose *rim* differs from the template are excluded from the
    needle search (otherwise lever edge + needle tail read as ~10 bar). Only rim points beyond the
    needle's reach *from the pivot* are checked, because the visible face looks off-centre (seen
    from below) and the needle tip would otherwise count as an occluder.
  - The **"f" logo loops** produce stronger round votes than the hub: the hub is searched only along
    the needle line (`choosePivot`).
  - The needle is searched first within ±30° of its last position (it moves at most ~12° per frame),
    then on the whole scale; readings beyond 1.5× the reference mark are treated as misreads.
  - A strongly oblique view (`machine_3.jpg`, looking up at the gauge) is not handled yet: frame
    the gauge from the front, or tap it.
  - **Matching the stored appearance does not work across phone positions**: the fitted face circle
    sits differently relative to the pivot from each viewpoint (whole-ring and per-ring correlation
    both failed, the mirror scored as high as the gauge). Relocation therefore re-runs the
    calibration analysis and uses the needle at rest for zero.
  - The occlusion check once flagged the needle's own direction: a 1–2 px tracking error makes the
    sharp rim edge differ on one ring. A direction counts as covered only if ≥2 of its 3 rim rings
    differ strongly, over ≥12°. Near the last needle position a lower confidence (2.5) is accepted.
- **Background work goes through `compute(topLevelFunction, request)`** (`GaugeSetup.findDialsInBackground`,
  `analyseInBackground`), never `Isolate.run(() => ...)` in widget code. A closure shares its captured
  context with the other closures of the same method; one holding a `ui.Image` or the `State` makes
  the send fail ("object is unsendable"). That once left calibration stuck on "Looking for the gauge…".
  Long steps show elapsed time, a Cancel button and a 45 s timeout. Regression test:
  `test/background_task_test.dart`.
- The *first* calibration (old app) failed because the tapped circle was 1.5× the face: half of each
  needle ray sampled the black rim, and tracking followed the background.

## Printed marker

The user's idea: a printed sign next to the gauge "so it can act like a hook". Design and
detection: `lib/vision/marker.dart` (header comment); printable sheet: `tool/marker_sheet.dart` →
`assets/marker_sheet.pdf` (12/16/20 mm ring diameter, cut line at 1.4 R, 50 mm ruler, instructions),
shared from Settings → *Print a marker*.

- **Calibration** stores the marker pose next to the face. The face/marker relation (position,
  scale, rotation) is what matters, so the marker may sit on the gauge (moves with it; best) or
  on the machine (static; the gauge moves away from it).
- **Each frame** (`GaugeReader.read`): the marker is searched near its last pose (`detectNear`, a few
  ms), the face is predicted from the relation, then the template tracker refines it in a small
  range. A successful track *confirms* the relation for this session (`_relToMarker`, updated each
  frame, so a static marker works while the gauge moves down). When the dial cannot be matched
  (lever, hand, blur) a confirmed relation alone gives the face, and the reading continues.
- **Dial angles count from the face's tilt axis.** A marker-predicted face carries the phone's turn
  in its tilt, so `relocated()` only shifts zero, template and background by the part of the turn
  the new tilt does not already hold (`dialRot`). `Relocation.rotation` is the turn on screen.
- **Relocation** trusts the marker only if one tracked read confirms the dial there; otherwise
  (static marker, gauge moved; marker moved) the dial search runs and links the marker anew. A
  marker stuck on after calibration is linked the same way at the next session start.
- Measured: no false detections in the five machine photos; centre within 1 px, radius within 8 %,
  rotation within 1° for R = 9–45 px, rotated and blurred. Test: `test/marker_test.dart`, including
  the sheet itself rendered at 40 dpi (`test/fixtures/marker_sheet_40dpi.png`; re-render it with
  `pdftoppm -r 40 -gray -png` when the sheet changes).
- Geometry is defined twice, in `marker.dart` (detector) and `tool/marker_sheet.dart` (print).
  Change both or neither.

## Diagnostic recordings (real shots)

Settings → *Record camera for diagnostics*. During each shot the app writes
`documents/diagnostics/shot_<ms>.flr` (`diagnostic_recorder.dart`): one half-resolution whole view,
then every second frame of a fixed full-resolution region around the gauge, extended downwards (the
gauge travels down), ≤420 frames, ~20–30 MB. It is attached to the shot export.

To reproduce a reported failure: put the file in `test/fixtures/`, load it with
`loadRecording()` (`test/support/recording.dart`) and replay the frames through `GaugeReader`
(see `test/recording_test.dart`). Keep it as a regression test if it is small enough, or trim it.

## Tests and fixtures

- `test/gauge_reader_test.dart`: synthetic Flair-like dial (`test/support/synthetic_gauge.dart`: rim,
  bands, thick tail, logo stroke, screws, optional oblique view and decoy line) and real photos.
- `test/fixtures/machine_{1..5}.jpg`: the whole machine from the brewing position (lever up), with
  hand-measured pivots; `moveNeedle()` / `shiftedFrame()` in `test/support/jpeg.dart` turn them into
  a needle sweep, a gauge moving down and a lever covering the rim.
- `test/fixtures/flair_real_{1,2,3}.pgm`: the gauge as shown by the app on a real Flair 58 (overlay
  removed), lever up. Hand-measured hub positions and the needle direction (~142°) are in the test.
  `embed()` puts them into a whole-machine sized frame.
- When a real photo fails, add it as a fixture (greyscale PGM) with its measured hub and needle angle.
