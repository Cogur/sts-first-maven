import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flair_log/vision/gauge_calibration.dart';
import 'package:flair_log/vision/gauge_reader.dart';
import 'package:flair_log/vision/gauge_setup.dart';
import 'package:flair_log/vision/luma_frame.dart';
import 'package:flair_log/vision/marker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/jpeg.dart';
import 'support/marker_render.dart';

const deg = math.pi / 180;
const sweep10 = 177 * deg;

double angDiff(double a, double b) {
  final d = (a - b) % (2 * math.pi);
  final p = d < 0 ? d + 2 * math.pi : d;
  return math.min(p, 2 * math.pi - p);
}

void main() {
  group('marker detection', () {
    test('nothing is found in the photos without a marker', () {
      for (var i = 1; i <= 5; i++) {
        expect(MarkerDetector.detect(loadJpeg('test/fixtures/machine_$i.jpg')), isNull,
            reason: 'photo $i');
      }
    });

    test('position, size and rotation; small, turned and blurred', () {
      final f = loadJpeg('test/fixtures/machine_2.jpg');
      for (final (r, ang, blur) in [
        (12.0, 0.0, 0), (16.0, 10.0, 0), (20.0, 0.0, 0), (30.0, 25.0, 0),
        (30.0, -40.0, 1), (45.0, 170.0, 2),
      ]) {
        final g = withMarker(f, 640, 830, r, ang * deg, blur: blur);
        final m = MarkerDetector.detect(g);
        expect(m, isNotNull, reason: 'r=$r');
        expect(m!.cx, closeTo(640, 1), reason: 'r=$r');
        expect(m.cy, closeTo(830, 1), reason: 'r=$r');
        expect(m.r, closeTo(r, 0.08 * r), reason: 'r=$r');
        // Wedge "up" is −90° on screen; turned clockwise by ang.
        expect(angDiff(m.angle, (-90 + ang) * deg) / deg, lessThan(2), reason: 'r=$r');
        final near = MarkerDetector.detectNear(g, m);
        expect(near, isNotNull);
        expect(near!.cx, closeTo(640, 1));
      }
    });
  });

  test('the printable sheet: every size is found, also printed small', () {
    // assets/marker_sheet.pdf rendered at 40 dpi (1.57 px/mm), roughly a
    // gauge marker seen by a 1080p phone camera half a metre away:
    //   pdftoppm -r 40 -gray -png assets/marker_sheet.pdf
    // Re-render when the sheet layout changes (tool/marker_sheet.dart).
    final page = loadImage('test/fixtures/marker_sheet_40dpi.png');
    const pxPerMm = 40 / 25.4;
    // First marker of each row: ring diameter, centre (mm from top left).
    for (final (d, x, y) in [(16.0, 31.2, 73.2), (12.0, 28.4, 110.8), (20.0, 34.0, 151.2)]) {
      final x0 = ((x - d) * pxPerMm).round(), y0 = ((y - d) * pxPerMm).round();
      final s = (2 * d * pxPerMm).round();
      final m = MarkerDetector.detect(cropFrame(page, x0, y0, s, s));
      expect(m, isNotNull, reason: '$d mm');
      expect(m!.cx + x0, closeTo(x * pxPerMm, 1), reason: '$d mm');
      expect(m.cy + y0, closeTo(y * pxPerMm, 1), reason: '$d mm');
      expect(m.r, closeTo(d / 2 * pxPerMm, 0.6), reason: '$d mm');
      expect(angDiff(m.angle, -90 * deg) / deg, lessThan(1), reason: '$d mm');
    }
  });

  group('gauge with a marker (photo 2)', () {
    late LumaFrame base;
    late DialAnalysisData a;
    // Marker stuck on the gauge's rubber guard, lower right (~9 mm wide).
    const mx = 581.0, my = 771.0, mr = 20.0;

    setUpAll(() {
      final f = loadJpeg('test/fixtures/machine_2.jpg');
      final an = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
      base = withMarker(f, mx, my, mr, 0);
      a = DialAnalysisData(an.pivotX, an.pivotY, an.face.radius, an.restAngle!);
    });

    GaugeCalibration calibrateWithMarker(LumaFrame f) {
      final an = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
      expect(an.marker, isNotNull, reason: 'marker seen at calibration');
      return GaugeSetup.build(
          frame: f, analysis: an, zeroAngle: an.restAngle!,
          markAngle: an.restAngle! + sweep10, markValue: 10);
    }

    test('phone placed and turned differently: found instantly via the marker', () {
      final cal = calibrateWithMarker(base);
      for (final (d, s, tx, ty) in [(8.0, 1.0, 40.0, -30.0), (-12.0, 0.9, -60.0, 50.0), (3.0, 1.12, 20.0, 80.0)]) {
        final f = movedPhoneFrame(base, deg: d, scale: s, tx: tx, ty: ty);
        final sw = Stopwatch()..start();
        final moved = GaugeSetup.relocate(f, cal)!;
        expect(sw.elapsedMilliseconds, lessThan(3000));
        // Zero on screen: the dial angle plus the face's tilt axis.
        expect((moved.zeroAngle + moved.tilt - cal.zeroAngle - cal.tilt) / deg, closeTo(d, 1.5),
            reason: 'turn $d');
        final r = GaugeReader(moved).read(f)!;
        expect(r.value, closeTo(0, 0.3), reason: 'turn $d at rest');
      }
    });

    test('marker on the gauge: readings go on while the lever hides the dial rim', () {
      final cal = calibrateWithMarker(base);
      final reader = GaugeReader(cal);
      final face = cal.face(base.uprightWidth, base.uprightHeight);
      for (var i = 0; i <= 12; i++) {
        final bar = i * 0.5, dy = i * 5;
        final moved = moveNeedle(base, a.px, a.py, a.r, a.rest, a.rest + bar / 10 * sweep10);
        // Lever: a dark bar over the upper right of the gauge from frame 3 on.
        final lever = i >= 3
            ? ((face.cx + 0.3 * face.radius).round(), (face.cy - 1.6 * face.radius + dy).round(),
                (face.cx + 1.7 * face.radius).round(), (face.cy + 0.2 * face.radius + dy).round())
            : null;
        final r = reader.read(shiftedFrame(moved, dy, bar: lever))!;
        expect(reader.marker, isNotNull, reason: 'frame $i');
        expect(r.face.cy, closeTo(face.cy + dy, 3), reason: 'frame $i');
        expect(r.value, closeTo(bar, 0.35), reason: 'frame $i');
      }
    });

    test('marker on the machine, gauge lost mid-shot: found where it moved to', () {
      final plain = loadJpeg('test/fixtures/machine_2.jpg');
      LumaFrame frame(double bar, int dy) => withMarker(
          shiftedFrame(moveNeedle(plain, a.px, a.py, a.r, a.rest, a.rest + bar / 10 * sweep10), dy),
          650, 900, 24, 0);
      final cal = calibrateWithMarker(frame(0, 0));
      final face = cal.face(base.uprightWidth, base.uprightHeight);
      // 1.5 radii further down than the marker link says.
      final f = frame(6, 100);
      final moved = GaugeSetup.relocate(f, cal, keepZero: true)!;
      expect(moved.face(f.uprightWidth, f.uprightHeight).cy, closeTo(face.cy + 100, 4));
      expect(GaugeReader(moved).read(f)!.value, closeTo(6, 0.35));
    });

    test('a marker stuck on after calibration is linked at the next session', () {
      final plain = loadJpeg('test/fixtures/machine_2.jpg');
      final an = GaugeSetup.analyse(plain, GaugeSetup.findDials(plain).first);
      final cal = GaugeSetup.build(
          frame: plain, analysis: an, zeroAngle: an.restAngle!,
          markAngle: an.restAngle! + sweep10, markValue: 10);
      expect(cal.marker, isNull);
      final moved = GaugeSetup.relocate(base, cal)!;
      final m = moved.markerIn(base.uprightWidth, base.uprightHeight);
      expect(m, isNotNull);
      expect(m!.cx, closeTo(mx, 1));
      expect(GaugeReader(moved).read(base)!.value, closeTo(0, 0.3));
    });

    test('marker on the machine: the gauge moves away from it and is still read', () {
      final plain = loadJpeg('test/fixtures/machine_2.jpg');
      // Static marker on the brew cylinder, lower right of the gauge.
      LumaFrame frame(double bar, int dy) => withMarker(
          shiftedFrame(moveNeedle(plain, a.px, a.py, a.r, a.rest, a.rest + bar / 10 * sweep10), dy),
          650, 900, 24, 0);
      final cal = calibrateWithMarker(frame(0, 0));
      final reader = GaugeReader(cal);
      for (var i = 0; i <= 12; i++) {
        final r = reader.read(frame(i * 0.5, i * 5))!;
        expect(r.value, closeTo(i * 0.5, 0.35), reason: 'frame $i');
      }
    });
  });

  // Frames of the camera preview from a user's screen recording (upscaled to
  // 1080×1920): the 16 mm marker printed on an office printer (ink reads
  // ~100, paper ~240) and stuck on the gauge glass over the logo. Between
  // the two frames the phone was moved (hand-held).
  group('printed marker on the gauge glass (real frames)', () {
    late LumaFrame real1, real2;
    late GaugeCalibration cal;
    late DialAnalysisData a;

    setUpAll(() {
      real1 = loadImage('test/fixtures/marker_real_1.jpg');
      real2 = loadImage('test/fixtures/marker_real_2.jpg');
      final an = GaugeSetup.analyse(real1, GaugeSetup.findDials(real1).first);
      a = DialAnalysisData(an.pivotX, an.pivotY, an.face.radius, an.restAngle!);
      cal = GaugeSetup.build(
          frame: real1, analysis: an, zeroAngle: an.restAngle!,
          markAngle: an.restAngle! + sweep10, markValue: 10);
    });

    test('found at calibration, and known to sit on the gauge', () {
      final m = cal.markerIn(real1.uprightWidth, real1.uprightHeight);
      expect(m, isNotNull);
      expect(m!.cx, closeTo(349, 2));
      expect(m.cy, closeTo(975, 2));
      expect(m.r, closeTo(31, 2));
      expect(cal.markerOnGauge(real1.uprightWidth, real1.uprightHeight), isTrue);
    });

    test('also in dim light (a third of the contrast)', () {
      final dim = Uint8List.fromList(real1.bytes.map((v) => (v * 0.3 + 10).round()).toList());
      final m = MarkerDetector.detect(LumaFrame(
          bytes: dim, width: real1.width, height: real1.height, rowStride: real1.rowStride));
      expect(m, isNotNull);
      expect(m!.cx, closeTo(349, 2));
    });

    test('phone moved by hand: found again and reads zero', () {
      final moved = GaugeSetup.relocate(real2, cal)!;
      final r = GaugeReader(moved).read(real2)!;
      expect(r.value, closeTo(0, 0.3));
    });

    test('phone jumps between frames: never lost, no re-search needed', () {
      // The recording: the gauge jumped ~1.2 radii in 0.2 s and the app
      // lost it for 3.6 s. The marker is now searched in the whole picture
      // when it is not near its last place.
      final reader = GaugeReader(cal);
      for (final (i, f) in [
        real1,
        movedPhoneFrame(real1, ty: 110),
        movedPhoneFrame(real1, deg: -4, tx: -90, ty: 60),
        real2,
        real1,
      ].indexed) {
        var r = reader.read(f);
        // The whole-picture search runs at once, so at most one frame lags.
        r = reader.read(f)!;
        expect(r.tracked, isTrue, reason: 'frame $i');
        expect(r.value, closeTo(0, 0.35), reason: 'frame $i');
      }
    });

    test('needle sweep with the lever over the dial: the marker rings are no needle', () {
      final reader = GaugeReader(cal);
      final face = cal.face(real1.uprightWidth, real1.uprightHeight);
      for (var i = 0; i <= 10; i++) {
        final bar = i * 1.0, dy = i * 6;
        final f = moveNeedle(real1, a.px, a.py, a.r, a.rest, a.rest + bar / 10 * sweep10);
        final lever = i >= 3
            // Over the right-hand rim, where the Flair lever passes.
            ? ((face.cx + 0.7 * face.radius).round(), (face.cy - 1.6 * face.radius + dy).round(),
                (face.cx + 1.7 * face.radius).round(), (face.cy + 0.3 * face.radius + dy).round())
            : null;
        final r = reader.read(shiftedFrame(f, dy, bar: lever))!;
        expect(r.face.cy, closeTo(face.cy + dy, 3), reason: '$bar bar');
        expect(r.value, closeTo(bar, 0.35), reason: '$bar bar');
      }
    });
  });
}

class DialAnalysisData {
  DialAnalysisData(this.px, this.py, this.r, this.rest);
  final double px, py, r, rest;
}
