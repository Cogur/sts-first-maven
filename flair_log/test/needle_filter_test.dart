import 'dart:math' as math;

import 'package:flair_log/vision/needle_filter.dart';
import 'package:flutter_test/flutter_test.dart';

const fps = 15.0;
const dt = 1 / fps;

double sd(List<double> v) {
  final m = v.reduce((a, b) => a + b) / v.length;
  return math.sqrt(v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length);
}

/// Mean absolute frame-to-frame change: what the eye sees as flicker.
double flicker(List<double> v) {
  var s = 0.0;
  for (var i = 1; i < v.length; i++) {
    s += (v[i] - v[i - 1]).abs();
  }
  return s / (v.length - 1);
}

void main() {
  test('smoothing removes jitter while the needle holds steady', () {
    final rnd = math.Random(3);
    final f = NeedleFilter(rejectJumps: false);
    final raw = <double>[], out = <double>[];
    for (var i = 0; i < 150; i++) {
      final r = 9 + (rnd.nextDouble() - 0.5) * 0.6; // ±0.3 bar detection noise
      raw.add(r);
      out.add(f.update(r, i * dt)!);
    }
    final settled = out.sublist(30);
    expect(flicker(settled), lessThan(flicker(raw.sublist(30)) / 4));
    expect(sd(settled), lessThan(sd(raw.sublist(30)) / 2));
    expect(settled.last, closeTo(9, 0.15));
  });

  test('smoothing keeps up with a lever pull (little lag)', () {
    final f = NeedleFilter(rejectJumps: false);
    double? last;
    // 0 -> 9 bar in 1.5 s, then hold.
    for (var i = 0; i <= 45; i++) {
      final t = i * dt;
      last = f.update(math.min(9, t / 1.5 * 9), t);
    }
    expect(last, closeTo(9, 0.6), reason: 'at most ~0.6 bar behind at the end of the ramp');
    for (var i = 46; i < 60; i++) {
      last = f.update(9, i * dt);
    }
    expect(last, closeTo(9, 0.05));
  });

  test('a single wild reading is ignored', () {
    final f = NeedleFilter(smooth: false);
    for (var i = 0; i < 10; i++) {
      f.update(6, i * dt);
    }
    expect(f.update(14.5, 10 * dt), 6, reason: 'spike held back');
    expect(f.lastRejected, isTrue);
    expect(f.update(6.1, 11 * dt), closeTo(6.1, 1e-9));
    expect(f.rejectedCount, 1);

    // Without jump rejection the spike goes straight through.
    final g = NeedleFilter(smooth: false, rejectJumps: false);
    g.update(6, 0);
    expect(g.update(14.5, dt), 14.5);
  });

  test('alternating glitches never take over', () {
    final f = NeedleFilter(smooth: false);
    for (var i = 0; i < 40; i++) {
      // every other frame the detector locks onto a numeral at ~2 bar
      final r = i.isEven ? 8.0 : 2.0;
      final out = f.update(r, i * dt)!;
      expect(out, 8.0, reason: 'frame $i');
    }
  });

  test('a real fast release is followed after a few frames', () {
    final f = NeedleFilter(smooth: false);
    for (var i = 0; i < 10; i++) {
      f.update(9, i * dt);
    }
    // Pressure collapses within one frame (faster than the 30 bar/s limit).
    final outs = [for (var i = 10; i < 16; i++) f.update(0.2, i * dt)!];
    expect(outs.first, 9, reason: 'first frame is treated as suspicious');
    expect(outs.last, closeTo(0.2, 1e-9), reason: 'confirmed after a run of frames');
    expect(outs.indexWhere((v) => v < 1), lessThanOrEqualTo(2));
  });

  test('normal pulls and releases are never rejected', () {
    final f = NeedleFilter(smooth: false);
    // 0 -> 9 bar in 1.2 s, hold, release to 0 in 0.4 s.
    double p(double t) => t < 1.2
        ? t / 1.2 * 9
        : t < 3
            ? 9
            : math.max(0, 9 - (t - 3) / 0.4 * 9);
    for (var i = 0; i < 60; i++) {
      final t = i * dt;
      expect(f.update(p(t), t), closeTo(p(t), 1e-9), reason: 't=$t');
    }
    expect(f.rejectedCount, 0);
  });

  test('recovers from a bad first reading', () {
    final f = NeedleFilter(smooth: false);
    f.update(12, 0); // glitch right after reset
    final outs = [for (var i = 1; i < 6; i++) f.update(3, i * dt)!];
    expect(outs.last, 3);
  });

  test('missing readings produce no value and keep state', () {
    final f = NeedleFilter();
    f.update(5, 0);
    expect(f.update(null, dt), isNull);
    expect(f.update(5, 2 * dt), closeTo(5, 1e-9));
  });
}
