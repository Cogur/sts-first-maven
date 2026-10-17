import 'dart:math' as math;
import 'dart:typed_data';

import 'dial_locator.dart';
import 'luma_frame.dart';

/// Where the printed Flair Log marker is in a frame.
class MarkerPose {
  const MarkerPose(this.cx, this.cy, this.r, this.angle, this.score);

  /// Centre and outer radius of the black outer ring, upright pixels.
  final double cx, cy, r;

  /// Direction of the orientation wedge (radians, screen space; the wedge
  /// points "up" on the printed sheet).
  final double angle;

  /// Fraction of directions showing the ring pattern (0..1).
  final double score;

  @override
  String toString() => 'Marker(${cx.toStringAsFixed(1)}, ${cy.toStringAsFixed(1)}, '
      'r=${r.toStringAsFixed(1)}, ${(angle * 180 / math.pi).toStringAsFixed(1)}°, '
      '${score.toStringAsFixed(2)})';
}

/// Finds the printed marker: a target of concentric bands, as fractions of
/// the outer radius R:
///
///     0.0–0.2 black dot   0.2–0.4 white   0.4–0.6 black
///     0.6–0.8 white (one black 40° wedge = "up")   0.8–1.0 black
///     1.0–1.3 white paper margin
///
/// Along any direction this gives a black/white stripe pattern nothing else
/// near an espresso machine has (a gauge is one bright disc in one dark
/// ring), it survives blur and lighting, and it gives position, size and
/// rotation. Detection:
/// 1. "dark dot in a bright ring" response on an integral image, all
///    positions and sizes (global) or near the last pose (local);
/// 2. verification along 96 directions: the outer edge is found per
///    direction (so a slightly oblique view still works) and all five bands
///    are checked relative to it; circle fit on the edge points; the wedge
///    direction gives the rotation.
class MarkerDetector {
  static const double minR = 9, maxR = 140;
  static const double minScore = 0.7;

  /// Searches the whole frame.
  static MarkerPose? detect(LumaFrame f) {
    final ii = _Integral.of(f, 0, 0, f.uprightWidth, f.uprightHeight);
    final peaks = <(double, double, double, double)>[]; // response, x, y, r
    for (var r = minR; r <= maxR; r *= 1.15) {
      final step = math.max(1, (r / 8).floor());
      _scan(ii, r, step, 0, 0, f.uprightWidth, f.uprightHeight, peaks);
    }
    return _best(f, peaks, 40);
  }

  /// Searches near [near] (tracking): within 0.8 of its radius, ±25 % size.
  static MarkerPose? detectNear(LumaFrame f, MarkerPose near) {
    final m = (near.r * 2.2).ceil();
    final x0 = math.max(0, near.cx.floor() - m), y0 = math.max(0, near.cy.floor() - m);
    final x1 = math.min(f.uprightWidth, near.cx.ceil() + m);
    final y1 = math.min(f.uprightHeight, near.cy.ceil() + m);
    if (x1 - x0 < 8 || y1 - y0 < 8) return null;
    final ii = _Integral.of(f, x0, y0, x1, y1);
    final peaks = <(double, double, double, double)>[];
    for (var r = near.r * 0.75; r <= near.r * 1.25; r *= 1.06) {
      _scan(ii, r, 1, x0, y0, x1, y1, peaks,
          cx: near.cx, cy: near.cy, reach: 0.8 * near.r);
    }
    return _best(f, peaks, 6);
  }

  /// Centre-surround response: the white ring (0.2–0.4 R) minus the dark dot.
  static void _scan(_Integral ii, double r, int step, int x0, int y0, int x1, int y1,
      List<(double, double, double, double)> out,
      {double? cx, double? cy, double? reach}) {
    final a = math.max(1, (0.13 * r).round()); // inside the dot
    final b = math.max(a + 1, (0.3 * r).round()); // inside the white ring
    final lim = math.max(b, (1.3 * r).ceil());
    final local = <(double, double, double, double)>[];
    for (var y = y0 + lim; y < y1 - lim; y += step) {
      for (var x = x0 + lim; x < x1 - lim; x += step) {
        if (reach != null) {
          final dx = x - cx!, dy = y - cy!;
          if (dx * dx + dy * dy > reach * reach) continue;
        }
        final inner = ii.sum(x - a, y - a, x + a + 1, y + a + 1);
        final outer = ii.sum(x - b, y - b, x + b + 1, y + b + 1);
        final na = (2 * a + 1) * (2 * a + 1), nb = (2 * b + 1) * (2 * b + 1);
        final resp = (outer - inner) / (nb - na) - inner / na;
        if (resp > 35) local.add((resp, x.toDouble(), y.toDouble(), r));
      }
    }
    local.sort((p, q) => q.$1.compareTo(p.$1));
    // Keep the strongest few per size, well apart.
    final kept = <(double, double, double, double)>[];
    for (final p in local) {
      if (kept.any((k) => (k.$2 - p.$2).abs() < r && (k.$3 - p.$3).abs() < r)) continue;
      kept.add(p);
      if (kept.length >= 12) break;
    }
    out.addAll(kept);
  }

  static MarkerPose? _best(
      LumaFrame f, List<(double, double, double, double)> peaks, int maxVerify) {
    peaks.sort((p, q) => q.$1.compareTo(p.$1));
    MarkerPose? best;
    var n = 0;
    final tried = <(double, double, double)>[];
    for (final p in peaks) {
      if (n >= maxVerify) break;
      if (tried.any((t) =>
          (t.$1 - p.$2).abs() < 0.3 * p.$4 && (t.$2 - p.$3).abs() < 0.3 * p.$4 &&
          (t.$3 / p.$4 - 1).abs() < 0.12)) {
        continue;
      }
      tried.add((p.$2, p.$3, p.$4));
      n++;
      final m = verify(f, p.$2, p.$3, p.$4);
      if (m != null && (best == null || m.score > best.score)) best = m;
    }
    return best;
  }

  /// Checks the ring pattern at (cx, cy) with approximate radius [r];
  /// returns the refined pose or null.
  static MarkerPose? verify(LumaFrame f, double cx, double cy, double r) {
    var pose = _verifyOnce(f, cx, cy, r);
    if (pose == null) return null;
    // Refine once around the fitted centre and radius.
    return _verifyOnce(f, pose.cx, pose.cy, pose.r) ?? pose;
  }

  static const int _dirs = 96;

  static MarkerPose? _verifyOnce(LumaFrame f, double cx, double cy, double r) {
    final step = math.max(0.5, r / 40);
    final n = (1.45 * r / step).ceil();
    final prof = List.generate(_dirs, (_) => Float64List(n));
    final all = <double>[];
    for (var d = 0; d < _dirs; d++) {
      final t = 2 * math.pi * d / _dirs;
      final c = math.cos(t), s = math.sin(t);
      for (var i = 0; i < n; i++) {
        final v = f.sample(cx + i * step * c, cy + i * step * s);
        if (v < 0) return null; // marker must be fully in view
        prof[d][i] = v.toDouble();
        all.add(v.toDouble());
      }
    }
    all.sort();
    final black = all[(all.length * 0.1).floor()], white = all[(all.length * 0.9).floor()];
    if (white - black < 40) return null;
    final thr = (black + white) / 2;

    double at(Float64List p, double rho) {
      final i = (rho / step).round();
      return i < 0 || i >= p.length ? -1 : p[i];
    }

    final edges = <(double, double)>[];
    final wedge = <int>[];
    var good = 0;
    final paperRun = math.max(2, (0.1 * r / step).round());
    for (var d = 0; d < _dirs; d++) {
      final p = prof[d];
      // Outer edge: last dark→bright crossing between 0.75 R and 1.25 R
      // that stays bright (the paper margin).
      double? e;
      for (var i = (0.75 * r / step).floor(); i < (1.25 * r / step).ceil() && i + paperRun < n; i++) {
        if (p[i - 1] < thr && p[i] >= thr) {
          var ok = true;
          for (var q = i; q < i + paperRun; q++) {
            if (p[q] < thr) ok = false;
          }
          if (ok) {
            final frac = (thr - p[i - 1]) / (p[i] - p[i - 1]);
            e = (i - 1 + frac) * step;
          }
        }
      }
      if (e == null) continue;
      final b0 = at(p, 0.1 * e), w1 = at(p, 0.3 * e), b2 = at(p, 0.5 * e);
      final w3 = at(p, 0.7 * e), b4 = at(p, 0.9 * e);
      if (b0 < 0 || b4 < 0) continue;
      final core = b0 < thr && w1 >= thr && b2 < thr && b4 < thr;
      if (!core) continue;
      if (w3 < thr) wedge.add(d);
      good++;
      final t = 2 * math.pi * d / _dirs;
      edges.add((cx + e * math.cos(t), cy + e * math.sin(t)));
    }
    final score = good / _dirs;
    if (score < minScore || wedge.length < 4 || wedge.length > _dirs * 0.25) return null;
    final fit = DialLocator.fitCircle(edges);
    if (fit == null) return null;
    var sx = 0.0, sy = 0.0;
    for (final d in wedge) {
      sx += math.cos(2 * math.pi * d / _dirs);
      sy += math.sin(2 * math.pi * d / _dirs);
    }
    // The wedge must be one compact group, not scattered noise.
    if (math.sqrt(sx * sx + sy * sy) < 0.8 * wedge.length) return null;
    final angle = _wedgeAngle(f, fit.$1, fit.$2, fit.$3, math.atan2(sy, sx), thr);
    return MarkerPose(fit.$1, fit.$2, fit.$3, angle, score);
  }

  /// The wedge direction to a fraction of a degree: the middle between its
  /// two edges, found on a finely sampled circle through the wedge band
  /// (the 96 verification directions alone are 3.75° apart).
  static double _wedgeAngle(LumaFrame f, double cx, double cy, double r, double coarse, double thr) {
    const n = 720;
    final ring = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = 2 * math.pi * i / n, c = math.cos(t), s = math.sin(t);
      var v = 0.0;
      for (final rho in const [0.66, 0.7, 0.74]) {
        v += _bilinear(f, cx + rho * r * c, cy + rho * r * s);
      }
      ring[i] = v / 3;
    }
    double at(int i) => ring[((i % n) + n) % n];
    final i0 = (coarse / (2 * math.pi) * n).round();
    // Edge where the ring turns from dark (wedge) to bright, walking by [dir].
    double? edge(int dir) {
      for (var k = 0; k < n ~/ 4; k++) {
        final a = at(i0 + dir * k), b = at(i0 + dir * (k + 1));
        if (a < thr && b >= thr) return i0 + dir * (k + (thr - a) / (b - a));
      }
      return null;
    }

    final lo = edge(-1), hi = edge(1);
    if (lo == null || hi == null) return coarse;
    return (lo + hi) / 2 / n * 2 * math.pi;
  }

  static double _bilinear(LumaFrame f, double x, double y) {
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final a = f.at(x0, y0), b = f.at(x0 + 1, y0);
    final c = f.at(x0, y0 + 1), d = f.at(x0 + 1, y0 + 1);
    if (a < 0 || b < 0 || c < 0 || d < 0) return f.sample(x, y).toDouble();
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
  }
}

/// Summed-area table of a region of the upright frame.
class _Integral {
  _Integral(this.x0, this.y0, this.w, this.h, this.t);

  factory _Integral.of(LumaFrame f, int x0, int y0, int x1, int y1) {
    final w = x1 - x0, h = y1 - y0;
    final t = Int64List((w + 1) * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0;
      for (var x = 0; x < w; x++) {
        final v = f.at(x0 + x, y0 + y);
        row += v < 0 ? 0 : v;
        t[(y + 1) * (w + 1) + x + 1] = t[y * (w + 1) + x + 1] + row;
      }
    }
    return _Integral(x0, y0, w, h, t);
  }

  final int x0, y0, w, h;
  final Int64List t;

  /// Sum over [xa, xb) × [ya, yb) in frame coordinates.
  int sum(int xa, int ya, int xb, int yb) {
    final ax = (xa - x0).clamp(0, w), bx = (xb - x0).clamp(0, w);
    final ay = (ya - y0).clamp(0, h), by = (yb - y0).clamp(0, h);
    final s = w + 1;
    return t[by * s + bx] - t[ay * s + bx] - t[by * s + ax] + t[ay * s + ax];
  }
}
