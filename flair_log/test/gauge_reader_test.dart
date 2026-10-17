import 'dart:math' as math;

import 'package:flair_log/vision/dial_locator.dart';
import 'package:flair_log/vision/gauge_calibration.dart';
import 'package:flair_log/vision/gauge_reader.dart';
import 'package:flair_log/vision/gauge_setup.dart';
import 'package:flair_log/vision/luma_frame.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/jpeg.dart';
import 'support/pgm.dart';
import 'support/synthetic_gauge.dart';

const deg = math.pi / 180;

/// Flair-like scale: 0 bar at ~143°, 10 bar 177° further clockwise.
const zero = 143 * deg;
const sweep10 = 177 * deg;
double angleFor(double bar) => zero + bar / 10 * sweep10;

double angDiff(double a, double b) {
  final d = (a - b) % (2 * math.pi);
  final p = d < 0 ? d + 2 * math.pi : d;
  return math.min(p, 2 * math.pi - p);
}

/// Runs the same steps as the calibration screen, with the user tapping
/// exactly on the 10 mark.
GaugeCalibration calibrate(LumaFrame f, {bool tapZero = false}) {
  final dials = GaugeSetup.findDials(f);
  expect(dials, isNotEmpty, reason: 'gauge not found');
  final a = GaugeSetup.analyse(f, dials.first);
  final ng = a.needleGeometry;
  double zeroAngle;
  if (tapZero) {
    // The user taps the 0 mark.
    final z = ng.point(zero, 0.9);
    zeroAngle = GaugeSetup.angleAt(a, z.$1, z.$2);
  } else {
    expect(a.needleFound, isTrue, reason: 'needle at rest not found');
    zeroAngle = a.restAngle!;
  }
  final mark = ng.point(zeroAngle + sweep10, 0.9);
  return GaugeSetup.build(
    frame: f,
    analysis: a,
    zeroAngle: zeroAngle,
    markAngle: GaugeSetup.angleAt(a, mark.$1, mark.$2),
    markValue: 10,
  );
}

void main() {
  group('dial locator', () {
    test('finds a small gauge in a whole-machine view', () {
      final f = renderFlairLike(
          needleAngle: zero, cx: 300, cy: 700, r: 40, width: 720, height: 1280);
      final d = DialLocator.find(f);
      expect(d, isNotEmpty);
      expect(d.first.cx, closeTo(300, 2));
      expect(d.first.cy, closeTo(700, 2));
      expect(d.first.radius, closeTo(40, 3));
    });

    test('fits an ellipse when the gauge is seen at an angle', () {
      final f = renderFlairLike(
          needleAngle: zero,
          cx: 360,
          cy: 640,
          r: 90,
          width: 720,
          height: 1280,
          squash: 0.75,
          tilt: 20 * deg);
      final g = DialLocator.find(f).first;
      final major = math.max(g.rx, g.ry), minor = math.min(g.rx, g.ry);
      expect(major, closeTo(90, 5));
      expect(minor, closeTo(67.5, 5));
      expect(g.cx, closeTo(360, 2));
      expect(g.cy, closeTo(640, 2));
    });

    test('works on rotated sensor buffers', () {
      final f = renderFlairLike(
          needleAngle: zero, cx: 300, cy: 500, r: 50, width: 720, height: 1280,
          quarterTurns: 1);
      expect(f.uprightWidth, 720);
      final g = DialLocator.find(f).first;
      expect(g.cx, closeTo(300, 2));
      expect(g.cy, closeTo(500, 2));
    });
  });

  group('reading', () {
    test('reads across the scale; the thick tail never wins', () {
      final cal = calibrate(renderFlairLike(
          needleAngle: zero, cx: 360, cy: 640, r: 60, width: 720, height: 1280));
      final reader = GaugeReader(cal);
      for (final bar in [0.0, 1.0, 3.0, 6.0, 8.5, 9.0, 10.0, 11.5]) {
        final f = renderFlairLike(
            needleAngle: angleFor(bar), cx: 360, cy: 640, r: 60, width: 720,
            height: 1280, seed: (bar * 10).toInt());
        final r = reader.read(f)!;
        expect(r.isValid, isTrue, reason: 'confidence ${r.confidence} @ $bar');
        expect(r.value, closeTo(bar, 0.25), reason: 'at $bar bar');
      }
    });

    test('oblique view reads correctly', () {
      LumaFrame frame(double bar) => renderFlairLike(
          needleAngle: angleFor(bar), cx: 360, cy: 640, r: 80, width: 720,
          height: 1280, squash: 0.8, tilt: 0, seed: bar.toInt());
      final cal = calibrate(frame(0));
      final reader = GaugeReader(cal);
      for (final bar in [2.0, 5.0, 9.0]) {
        // The renderer draws the needle in dial space, so an oblique view
        // keeps the dial-angle scale linear.
        expect(reader.read(frame(bar))!.value, closeTo(bar, 0.3), reason: '$bar');
      }
    });

    test('follows the gauge as it moves down with the piston', () {
      final cal = calibrate(renderFlairLike(
          needleAngle: zero, cx: 360, cy: 500, r: 60, width: 720, height: 1280));
      final reader = GaugeReader(cal);
      for (var i = 0; i <= 12; i++) {
        final bar = i * 0.75;
        final f = renderFlairLike(
            needleAngle: angleFor(bar), cx: 360, cy: 500.0 + i * 7, r: 60,
            width: 720, height: 1280, seed: i + 10);
        final r = reader.read(f)!;
        expect(r.tracked, isTrue, reason: 'frame $i');
        expect(r.face.cy, closeTo(500.0 + i * 7, 2.5), reason: 'frame $i');
        expect(r.value, closeTo(bar, 0.3), reason: 'frame $i');
      }
    });

    test('learned background removes a printed line that looks like a needle', () {
      // A printed line darker and longer than the needle itself.
      const decoy = 215 * deg; // ~4 bar, away from the tested positions
      LumaFrame frame(double bar, int seed) => renderFlairLike(
          needleAngle: angleFor(bar), cx: 360, cy: 640, r: 60, width: 720,
          height: 1280, decoyAngle: decoy, decoyLuma: 20, seed: seed);

      // The line is darker than the needle, so automatic rest detection may
      // pick it; the user then taps the 0 mark.
      final cal = calibrate(frame(0, 1), tapZero: true);
      expect(cal.background, isNotNull);
      expect(cal.background!.coverage, greaterThan(0.8));

      final reader = GaugeReader(cal);
      final noBg = GaugeReader(GaugeCalibration.fromJson(
          cal.toJson()..remove('background'))!);
      for (final bar in [6.0, 8.0, 9.0]) {
        final f = frame(bar, (bar * 3).toInt());
        expect(reader.read(f)!.value, closeTo(bar, 0.3), reason: 'with background, $bar');
        // Without the learned background the reader is fooled by the line.
        expect(noBg.read(f)!.value, isNot(closeTo(bar, 1)), reason: 'without, $bar');
      }
    });

    test('calibration survives a JSON round trip; old versions are dropped', () {
      final cal = calibrate(renderFlairLike(
          needleAngle: zero, cx: 360, cy: 640, r: 60, width: 720, height: 1280));
      final back = GaugeCalibration.fromJson(cal.toJson())!;
      expect(back.zeroAngle, cal.zeroAngle);
      expect(back.background!.coverage, closeTo(cal.background!.coverage, 1e-9));
      expect(GaugeCalibration.fromJson({'centerX': 0.5, 'radius': 0.1}), isNull);
    });

    test('value mapping', () {
      const c = GaugeCalibration(
          faceX: .5, faceY: .5, faceRx: .1, faceRy: .1, zeroAngle: zero, sweep: sweep10);
      expect(c.valueForAngle(zero), closeTo(0, 1e-9));
      expect(c.valueForAngle(zero + sweep10), closeTo(10, 1e-9));
      expect(c.valueForAngle(zero - 5 * deg), lessThan(0));
      expect(c.valueForAngle(c.angleForValue(12.5)), closeTo(12.5, 1e-9));
    });
  });

  group('real Flair 58 photos (from the app, lever up = 0 bar)', () {
    // Hub positions and needle direction measured by hand on the fixtures.
    const hubs = {1: (189.4, 163.0), 2: (123.7, 213.6), 3: (183.0, 167.0)};
    for (var i = 1; i <= 3; i++) {
      test('photo $i: finds gauge, pivot and needle at rest', () {
        final f = loadPgm('test/fixtures/flair_real_$i.pgm');
        final dials = GaugeSetup.findDials(f);
        expect(dials, isNotEmpty);
        final a = GaugeSetup.analyse(f, dials.first);
        final hub = hubs[i]!;
        expect(a.pivotX, closeTo(hub.$1, 4), reason: 'pivot x');
        expect(a.pivotY, closeTo(hub.$2, 4), reason: 'pivot y');
        expect(a.needleFound, isTrue);
        expect(a.restAngle! / deg, closeTo(142, 5), reason: 'needle direction');
        expect(a.polarity, 1);
      });
    }

    for (var i = 1; i <= 3; i++) {
      test('photo $i at half size in a whole-machine frame', () {
        final f = embed(loadPgm('test/fixtures/flair_real_$i.pgm'), scale: 0.5);
        final a = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
        expect(a.needleFound, isTrue);
        expect(a.restAngle! / deg, closeTo(142, 5));
      });
    }
  });

  group('whole-machine photos of the real setup (lever up)', () {
    // Pivot of the needle measured on the photos; 0 bar points lower-left.
    const hubs = {1: (523.0, 575.0), 2: (521.0, 711.0), 4: (424.0, 668.0), 5: (636.0, 569.0)};
    for (final i in hubs.keys) {
      test('photo $i: finds the gauge, pivot and needle at rest', () {
        final f = loadJpeg('test/fixtures/machine_$i.jpg');
        final dials = GaugeSetup.findDials(f);
        expect(dials, isNotEmpty);
        final a = GaugeSetup.analyse(f, dials.first);
        expect(a.pivotX, closeTo(hubs[i]!.$1, 5), reason: 'pivot x');
        expect(a.pivotY, closeTo(hubs[i]!.$2, 5), reason: 'pivot y');
        expect(a.needleFound, isTrue);
        expect(a.restAngle! / deg, closeTo(141, 5));
      });
    }

    test('photo 2: reads the needle across the scale on the real dial', () {
      final f = loadJpeg('test/fixtures/machine_2.jpg');
      final a = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
      final cal = GaugeSetup.build(
          frame: f, analysis: a, zeroAngle: a.restAngle!,
          markAngle: a.restAngle! + sweep10, markValue: 10);
      final reader = GaugeReader(cal);
      // A lever pull: the needle sweeps up in half-bar steps, then back.
      final bars = [for (var b = 0.0; b <= 11; b += 0.5) b, for (var b = 10.5; b >= 0; b -= 1.5) b];
      for (final bar in bars) {
        final moved = moveNeedle(f, a.pivotX, a.pivotY, a.face.radius, a.restAngle!,
            a.restAngle! + bar / 10 * sweep10);
        final r = reader.read(moved)!;
        expect(r.isValid, isTrue, reason: '$bar bar: confidence ${r.confidence}');
        expect(r.value, closeTo(bar, 0.3), reason: '$bar bar');
      }
    });

    test('photo 2: follows the gauge down while the lever covers part of it', () {
      final f = loadJpeg('test/fixtures/machine_2.jpg');
      final a = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
      final cal = GaugeSetup.build(
          frame: f, analysis: a, zeroAngle: a.restAngle!,
          markAngle: a.restAngle! + sweep10, markValue: 10);
      final reader = GaugeReader(cal);
      final face = cal.face(f.uprightWidth, f.uprightHeight);
      for (var i = 0; i <= 10; i++) {
        final dy = i * 6;
        final bar = i >= 4
            ? ((face.cx + 0.7 * face.radius).round(), (face.cy - 1.5 * face.radius + dy).round(),
                (face.cx + 1.6 * face.radius).round(), (face.cy + 1.5 * face.radius + dy).round())
            : null;
        final r = reader.read(shiftedFrame(f, dy, bar: bar))!;
        expect(r.tracked, isTrue, reason: 'frame $i');
        expect(r.face.cy, closeTo(face.cy + dy, 2), reason: 'frame $i');
        // The lever's dark edge plus the needle's tail must not read as ~10 bar.
        expect(r.value, closeTo(0, 0.3), reason: 'frame $i');
      }
    });

    test('phone placed differently: calibrated on photo 2, found again in 1, 4, 5', () {
      final f2 = loadJpeg('test/fixtures/machine_2.jpg');
      final a = GaugeSetup.analyse(f2, GaugeSetup.findDials(f2).first);
      final cal = GaugeSetup.build(
          frame: f2, analysis: a, zeroAngle: a.restAngle!,
          markAngle: a.restAngle! + sweep10, markValue: 10);
      for (final (i, hub) in [(1, hubs[1]!), (4, hubs[4]!), (5, hubs[5]!)]) {
        final f = loadJpeg('test/fixtures/machine_$i.jpg');
        final moved = GaugeSetup.relocate(f, cal);
        expect(moved, isNotNull, reason: 'photo $i');
        final face = moved!.face(f.uprightWidth, f.uprightHeight);
        final pivot = GaugeCalibration.needleGeometry(face, moved.pivotDx, moved.pivotDy);
        expect(pivot.cx, closeTo(hub.$1, 5), reason: 'photo $i pivot');
        expect(pivot.cy, closeTo(hub.$2, 5), reason: 'photo $i pivot');
        final r = GaugeReader(moved).read(f)!;
        expect(r.value, closeTo(0, 0.3), reason: 'photo $i at rest');
        expect(moved.sweep, cal.sweep);
      }
    });

    test('phone turned by 12°: found again and reads zero', () {
      final f2 = loadJpeg('test/fixtures/machine_2.jpg');
      final a = GaugeSetup.analyse(f2, GaugeSetup.findDials(f2).first);
      final cal = GaugeSetup.build(
          frame: f2, analysis: a, zeroAngle: a.restAngle!,
          markAngle: a.restAngle! + sweep10, markValue: 10);
      final f = rotatedFrame(f2, 12);
      final moved = GaugeSetup.relocate(f, cal)!;
      expect((moved.zeroAngle - cal.zeroAngle) / deg, closeTo(12, 7));
      expect(GaugeReader(moved).read(f)!.value, closeTo(0, 0.3));
    });

    test('the shot mirror is never taken for the gauge', () {
      final f = loadJpeg('test/fixtures/machine_5.jpg');
      final first = GaugeSetup.findDials(f).first;
      // The mirror sits at about (513, 902); the gauge at (636, 569).
      expect(first.cy, lessThan(700));
    });
  });
}
