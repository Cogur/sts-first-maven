import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flair_log/vision/gauge_calibration.dart';
import 'package:flair_log/vision/gauge_reader.dart';
import 'package:flair_log/vision/luma_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders a synthetic gauge similar to the Flair one: light face, dark bezel,
/// tick marks, a few "numerals", and a dark needle.
LumaFrame renderGauge({
  required double needleAngle,
  double cx = 320,
  double cy = 240,
  double r = 120,
  int width = 640,
  int height = 480,
  bool lightNeedle = false,
  int quarterTurns = 0,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  final up = Uint8List(width * height);
  final face = lightNeedle ? 40 : 225;
  final ink = lightNeedle ? 230 : 30;
  // Blobs that look like printed numerals at fixed angles.
  final blobs = <(double, double)>[];
  for (var i = 0; i <= 8; i++) {
    final a = 3 * math.pi / 4 + i * (3 * math.pi / 2) / 8;
    blobs.add((cx + 0.62 * r * math.cos(a), cy + 0.62 * r * math.sin(a)));
  }
  blobs.add((cx, cy + 0.4 * r)); // logo
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - cx, dy = y - cy;
      final d = math.sqrt(dx * dx + dy * dy);
      var v = 120; // background
      if (d < r) {
        v = face;
        final a = math.atan2(dy, dx);
        // ticks every 1/16 of the sweep, on the outer ring
        if (d > 0.85 * r && d < 0.97 * r) {
          final rel = (a - 3 * math.pi / 4) % (2 * math.pi);
          final t = rel / (3 * math.pi / 2) * 16;
          if (rel <= 3 * math.pi / 2 + 0.02 && (t - t.round()).abs() < 0.08) {
            v = ink;
          }
        }
        for (final b in blobs) {
          if ((x - b.$1).abs() < 7 && (y - b.$2).abs() < 9) v = ink;
        }
        // needle: distance from point to the needle segment
        final nx = math.cos(needleAngle), ny = math.sin(needleAngle);
        final along = dx * nx + dy * ny;
        final perp = (dx * ny - dy * nx).abs();
        if (along > -0.15 * r && along < 0.9 * r && perp < 2.2) v = ink;
        if (d < 0.08 * r) v = ink; // hub
      } else if (d < 1.25 * r) {
        v = 20; // black silicone guard
        if ((math.atan2(dy, dx) * 5).round().isEven) v = 35;
      } else {
        // textured background
        v = 100 + ((x ~/ 23 + y ~/ 17) % 3) * 30;
      }
      v += rnd.nextInt(9) - 4; // sensor noise
      up[y * width + x] = v.clamp(0, 255);
    }
  }
  if (quarterTurns == 0) {
    return LumaFrame(bytes: up, width: width, height: height, rowStride: width);
  }
  // Store as a raw buffer rotated the "other way" so that turning it by
  // quarterTurns clockwise gives back the upright image.
  assert(quarterTurns == 1);
  final rw = height, rh = width; // raw dims
  final raw = Uint8List(rw * rh);
  for (var uy = 0; uy < height; uy++) {
    for (var ux = 0; ux < width; ux++) {
      // inverse of LumaFrame.at for turns=1: rx = uy, ry = rh - 1 - ux
      raw[(rh - 1 - ux) * rw + uy] = up[uy * width + ux];
    }
  }
  return LumaFrame(
      bytes: raw, width: rw, height: rh, rowStride: rw, quarterTurns: 1);
}

GaugeCalibration cal({double cx = 320, double cy = 240, double r = 120}) =>
    GaugeCalibration(
      centerX: cx / 640,
      centerY: cy / 480,
      radius: r / 640,
      zeroAngle: 3 * math.pi / 4, // bottom-left, like most pressure gauges
      sweep: 3 * math.pi / 2, // 270°
      minValue: 0,
      maxValue: 16,
    );

void main() {
  final c = cal();

  test('angle <-> value mapping', () {
    expect(c.valueForAngle(3 * math.pi / 4), closeTo(0, 1e-9));
    expect(c.valueForAngle(3 * math.pi / 4 + 3 * math.pi / 2), closeTo(16, 1e-9));
    expect(c.valueForAngle(-math.pi / 2), closeTo(8, 1e-9)); // straight up
    // slightly below zero stays negative rather than wrapping to ~21
    expect(c.valueForAngle(3 * math.pi / 4 - 0.05), lessThan(0));
    expect(c.valueForAngle(c.angleForValue(9.3)), closeTo(9.3, 1e-9));
  });

  test('reads the needle across the scale', () {
    final reader = GaugeReader(c);
    for (final bar in [0.0, 1.5, 4.0, 6.0, 8.2, 9.0, 11.0, 15.5]) {
      final f = renderGauge(needleAngle: c.angleForValue(bar), seed: bar.toInt());
      final r = reader.read(f)!;
      expect(r.isValid, isTrue, reason: 'confidence ${r.confidence} @ $bar');
      expect(r.value, closeTo(bar, 0.15), reason: 'at $bar bar');
    }
  });

  test('detects light needle polarity', () {
    final f = renderGauge(needleAngle: c.angleForValue(3), lightNeedle: true);
    final reader = GaugeReader(c);
    expect(reader.detectPolarity(f), -1);
    reader.updateCalibration(c.copyWith(polarity: -1));
    expect(reader.read(f)!.value, closeTo(3, 0.15));
    expect(GaugeReader(c).detectPolarity(
        renderGauge(needleAngle: c.angleForValue(3))), 1);
  });

  test('works on rotated sensor buffers', () {
    final f = renderGauge(needleAngle: c.angleForValue(7), quarterTurns: 1);
    expect(f.uprightWidth, 640);
    expect(GaugeReader(c).read(f)!.value, closeTo(7, 0.15));
  });

  test('follows the gauge as it moves down with the piston', () {
    final calFrame = renderGauge(needleAngle: c.angleForValue(0));
    final reader = GaugeReader(c);
    final ref = reader.captureReference(calFrame);
    expect(ref, isNotNull);
    reader.updateCalibration(c.copyWith(reference: ref));

    // Move the gauge 6 px per frame downward while pressure rises.
    for (var i = 0; i <= 12; i++) {
      final bar = i * 0.75;
      final f = renderGauge(
          needleAngle: c.angleForValue(bar), cy: 240.0 + i * 6, seed: i + 10);
      final r = reader.read(f)!;
      expect(r.centerY, closeTo(240.0 + i * 6, 2.5), reason: 'frame $i');
      expect(r.value, closeTo(bar, 0.2), reason: 'frame $i');
    }
  });

  test('without tracking a moved gauge is misread (sanity check)', () {
    final reader = GaugeReader(c.copyWith(trackMovement: false));
    final f = renderGauge(needleAngle: c.angleForValue(9), cy: 300);
    final r = reader.read(f);
    expect(r == null || (r.value - 9).abs() > 0.3 || !r.isValid, isTrue);
  });
}
