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
- The *first* calibration (old app) failed because the tapped circle was 1.5× the face: half of each
  needle ray sampled the black rim, and tracking followed the background.

## Tests and fixtures

- `test/gauge_reader_test.dart`: synthetic Flair-like dial (`test/support/synthetic_gauge.dart`: rim,
  bands, thick tail, logo stroke, screws, optional oblique view and decoy line) and real photos.
- `test/fixtures/flair_real_{1,2,3}.pgm`: the gauge as shown by the app on a real Flair 58 (overlay
  removed), lever up. Hand-measured hub positions and the needle direction (~142°) are in the test.
  `embed()` puts them into a whole-machine sized frame.
- When a real photo fails, add it as a fixture (greyscale PGM) with its measured hub and needle angle.
