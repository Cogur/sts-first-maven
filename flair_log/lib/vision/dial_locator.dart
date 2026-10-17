import 'dart:math' as math;
import 'dart:typed_data';

import 'dial_geometry.dart';
import 'luma_frame.dart';

/// Finds round gauge faces in a frame: a bright face inside a darker rim,
/// like the Flair gauge (white face, black guard) and most espresso gauges.
///
/// 1. Coarse search on a downscaled copy: for every centre and radius, the
///    "face score" is a low percentile, around the circumference, of
///    (brightest of a few points just inside) − (darkest of two points just
///    outside). Needle, numerals and a coloured band only spoil part of the
///    circumference, so the percentile ignores them.
/// 2. Refinement at full resolution: local search, then edge points along
///    rays and a robust ellipse fit, because a phone looking at the gauge
///    from an angle sees an ellipse.
class DialLocator {
  /// Width of the downscaled image used for the coarse search.
  static const int workWidth = 360;

  /// Minimum face score (luma units) for a candidate.
  static const double minScore = 18;

  /// Returns up to [maxResults] dial candidates, best first, in upright
  /// pixel coordinates of [f].
  ///
  /// With a hint (a tap on the gauge) only dials containing that point are
  /// considered and the threshold is lower. [minRadius]/[maxRadius] (full
  /// resolution pixels) restrict the size, e.g. when re-finding a known dial.
  static List<DialGeometry> find(
    LumaFrame f, {
    int maxResults = 4,
    double? hintX,
    double? hintY,
    double? minRadius,
    double? maxRadius,
  }) {
    final s = _Small.of(f, workWidth);
    final k = s.scale;
    final hint = hintX != null && hintY != null ? (hintX / k, hintY / k) : null;
    final threshold = hint != null ? minScore * 0.6 : minScore;

    var rMin = math.max(7.0, (minRadius ?? 0) / k);
    var rMax = math.min(s.w, s.h) * 0.48;
    if (maxRadius != null) rMax = math.min(rMax, maxRadius / k);
    if (rMax < rMin) rMax = rMin;

    const n = 24;
    final cosT = List.generate(n, (i) => math.cos(2 * math.pi * i / n));
    final sinT = List.generate(n, (i) => math.sin(2 * math.pi * i / n));
    final d = Float64List(n);

    final found = <(double, double, double, double)>[]; // score, x, y, r
    for (var r = rMin; r <= rMax; r *= 1.08) {
      final step = math.max(1.0, r * 0.2);
      final x0 = hint != null ? math.max(r * 0.8, hint.$1 - r * 0.7) : r * 0.8;
      final x1 = hint != null ? math.min(s.w - r * 0.8, hint.$1 + r * 0.7) : s.w - r * 0.8;
      final y0 = hint != null ? math.max(r * 0.8, hint.$2 - r * 0.7) : r * 0.8;
      final y1 = hint != null ? math.min(s.h - r * 0.8, hint.$2 + r * 0.7) : s.h - r * 0.8;
      for (var y = y0; y <= y1; y += step) {
        for (var x = x0; x <= x1; x += step) {
          final sc = _smallScore(s, x, y, r, cosT, sinT, d, threshold);
          if (sc >= threshold) found.add((sc, x, y, r));
        }
      }
    }
    if (found.isEmpty) return const [];
    found.sort((a, b) => b.$1.compareTo(a.$1));

    // Non-maximum suppression: one candidate per dial.
    final coarse = <(double, double, double, double)>[];
    for (final c in found) {
      final dup = coarse.any((o) {
        final dist = math.sqrt(math.pow(o.$2 - c.$2, 2) + math.pow(o.$3 - c.$3, 2));
        return dist < 0.6 * math.max(o.$4, c.$4);
      });
      if (!dup) coarse.add(c);
      if (coarse.length >= math.min(16, maxResults * 3)) break;
    }

    final refined = <DialGeometry>[];
    final top = coarse.first.$1;
    for (final c in coarse) {
      // Weak coarse candidates rarely become the winner; skip them.
      if (c.$1 < 0.4 * top && refined.length >= maxResults) break;
      final g = refine(f, DialGeometry.circle(c.$2 * k, c.$3 * k, c.$4 * k));
      if (g != null && g.score >= threshold) refined.add(g);
    }
    refined.sort((a, b) => b.score.compareTo(a.score));
    final out = <DialGeometry>[];
    for (final g in refined) {
      final dup = out.any((o) =>
          math.sqrt(math.pow(o.cx - g.cx, 2) + math.pow(o.cy - g.cy, 2)) <
          0.6 * math.max(o.radius, g.radius));
      if (!dup) out.add(g);
      if (out.length >= maxResults) break;
    }
    return out;
  }

  static double _smallScore(_Small s, double cx, double cy, double r,
      List<double> cosT, List<double> sinT, Float64List d, double threshold) {
    var m = 0, missing = 0, below = 0;
    for (var i = 0; i < cosT.length; i++) {
      final c = cosT[i], sn = sinT[i];
      final a = s.at(cx + 0.55 * r * c, cy + 0.55 * r * sn);
      final b = s.at(cx + 0.7 * r * c, cy + 0.7 * r * sn);
      final e = s.at(cx + 0.85 * r * c, cy + 0.85 * r * sn);
      final o1 = s.at(cx + 1.12 * r * c, cy + 1.12 * r * sn);
      final o2 = s.at(cx + 1.25 * r * c, cy + 1.25 * r * sn);
      if (a < 0 || b < 0 || e < 0 || o1 < 0) {
        missing++;
        continue;
      }
      final inner = math.max(a, math.max(b, e));
      final outer = o2 < 0 ? o1 : math.min(o1, o2);
      final v = (inner - outer).toDouble();
      // The 25th percentile can only reach the threshold if at most a
      // quarter of the angles fall below it: stop early otherwise.
      if (v < threshold && ++below > cosT.length ~/ 4) {
        return double.negativeInfinity;
      }
      d[m++] = v;
    }
    if (missing > cosT.length ~/ 5 || m == 0) return double.negativeInfinity;
    return _percentile(d, m, 0.25);
  }

  /// "Bright face all round, dark rim all round": the 20th percentile over
  /// directions of the brightest point just inside, minus the 80th
  /// percentile of the darkest point just outside. A bright patch *inside*
  /// a dial, a lamp reflection or a tile corner fails one of the two halves.
  /// This ranks candidates; it is the score [find] returns.
  static double strictScore(LumaFrame f, DialGeometry g, {int n = 64}) =>
      _strict(f, g, n).$1;

  /// (score, face level, rim level).
  static (double, double, double) _strict(LumaFrame f, DialGeometry g, int n) {
    final inner = Float64List(n), outer = Float64List(n);
    var m = 0;
    for (var i = 0; i < n; i++) {
      final t = 2 * math.pi * i / n;
      int at(double rho) {
        final p = g.point(t, rho);
        return f.sample(p.$1, p.$2);
      }

      final a = at(0.55), b = at(0.7), c = at(0.85), o1 = at(1.1), o2 = at(1.2);
      if (a < 0 || b < 0 || c < 0 || o1 < 0) continue;
      inner[m] = math.max(a, math.max(b, c)).toDouble();
      outer[m] = (o2 < 0 ? o1 : math.min(o1, o2)).toDouble();
      m++;
    }
    if (m < n * 0.8) return (double.negativeInfinity, 0, 0);
    final fl = _percentile(inner, m, 0.2), dl = _percentile(outer, m, 0.8);
    return (fl - dl, fl, dl);
  }

  /// Face score of an ellipse at full resolution (also used for tracking).
  static double faceScore(LumaFrame f, DialGeometry g, {int n = 48}) {
    final d = Float64List(n);
    var m = 0, missing = 0;
    for (var i = 0; i < n; i++) {
      final t = 2 * math.pi * i / n;
      int at(double rho) {
        final p = g.point(t, rho);
        return f.sample(p.$1, p.$2);
      }

      final a = at(0.55), b = at(0.7), e = at(0.85), o1 = at(1.12), o2 = at(1.25);
      if (a < 0 || b < 0 || e < 0 || o1 < 0) {
        missing++;
        continue;
      }
      final inner = math.max(a, math.max(b, e));
      final outer = o2 < 0 ? o1 : math.min(o1, o2);
      d[m++] = (inner - outer).toDouble();
    }
    if (missing > n ~/ 5 || m == 0) return double.negativeInfinity;
    return _percentile(d, m, 0.25);
  }

  /// Contrast exactly across the rim (just inside vs just outside), averaged
  /// over the circumference. Unlike [faceScore] it peaks sharply at the true
  /// position and size, so it is what tracking optimises.
  static double rimScore(LumaFrame f, DialGeometry g, {int n = 64}) {
    var sum = 0.0;
    var m = 0;
    for (var i = 0; i < n; i++) {
      final t = 2 * math.pi * i / n;
      int at(double rho) {
        final p = g.point(t, rho);
        return f.sample(p.$1, p.$2);
      }

      final a = at(0.9), b = at(0.96), c = at(1.04), d = at(1.1);
      if (a < 0 || b < 0 || c < 0 || d < 0) continue;
      sum += math.max(a, b) - math.min(c, d);
      m++;
    }
    return m < n * 0.8 ? double.negativeInfinity : sum / m;
  }

  /// Polishes a rough dial position at full resolution.
  ///
  /// - Centre: every feature of a gauge (rim, coloured bands, tick arc, hub)
  ///   is concentric, so edge pixels vote along their gradient direction for
  ///   the point they curve around (a circular Hough transform). The needle
  ///   is straight and spreads its votes thinly.
  /// - Radius: the black rim is the first radius at which almost every
  ///   direction is dark (75th percentile over angles). Bands and logos
  ///   cover only part of the circle and do not trigger it.
  /// - Shape: per-angle edge points just inside the rim, robust circle fit,
  ///   and an ellipse when the view is clearly oblique.
  static DialGeometry? refine(LumaFrame f, DialGeometry rough) {
    // A poor start (e.g. only the white middle of a dial with dark bands)
    // converges in one or two more passes.
    // An ellipse fit is final: the centre vote that seeds the next pass is
    // biased for ellipses.
    var g = _refineOnce(f, rough);
    for (var i = 0; i < 2 && g != null && g.rx == g.ry; i++) {
      final next = _refineOnce(f, g);
      if (next == null) break;
      final moved = math.sqrt(math.pow(next.cx - g.cx, 2) + math.pow(next.cy - g.cy, 2));
      final grew = (next.radius - g.radius).abs();
      g = next;
      if (moved < 0.02 * g.radius && grew < 0.02 * g.radius) break;
    }
    return g;
  }

  static DialGeometry? _refineOnce(LumaFrame f, DialGeometry rough) {
    final r0 = rough.radius;
    // Centre candidates: where we started and the strongest votes. Things
    // next to the gauge (a shiny stem, the lever) can pull the top vote off.
    final centers = <(double, double)>[
      (rough.cx, rough.cy),
      ..._hough(f, rough.cx, rough.cy,
          workRadius: 40, r0: r0, window: 1.7, sMin: 0.3, sMax: 1.5, searchLimit: 0.5, peaks: 3),
    ];

    // Rim radius (and centre): the best "bright face all round, dark rim all
    // round" contrast (see [strictScore]), with a small search around each
    // centre candidate.
    var bestStrict = double.negativeInfinity;
    var rf = r0;
    var face = 0.0, dark = 0.0;
    var (cx, cy) = (rough.cx, rough.cy);
    final cStep = math.max(1.0, 0.03 * r0);
    for (final (ox, oy) in centers) {
      for (var sc = 0.6; sc <= 1.5; sc *= 1.025) {
        for (final (dx, dy) in [(0.0, 0.0), (cStep, 0.0), (-cStep, 0.0), (0.0, cStep), (0.0, -cStep)]) {
          final st = _strict(f, DialGeometry.circle(ox + dx, oy + dy, r0 * sc), 48);
          if (st.$1 > bestStrict) {
            bestStrict = st.$1;
            rf = r0 * sc;
            face = st.$2;
            dark = st.$3;
            (cx, cy) = (ox + dx, oy + dy);
          }
        }
      }
    }
    if (!bestStrict.isFinite || face - dark < 20) return null;
    final scanned = DialGeometry.circle(cx, cy, rf);
    final scannedScore = strictScore(f, scanned);

    // Second pass with the measured rim radius: votes only from the gauge
    // itself (rim inner and outer edge), not from cables around it. Kept
    // only if it does not make the fit worse.
    final c2 = _houghCenter(f, cx, cy, rf, window: 1.45, searchLimit: 0.15);
    if (c2 != null &&
        strictScore(f, DialGeometry.circle(c2.$1, c2.$2, rf)) >= scannedScore - 2) {
      (cx, cy) = c2;
    }

    // Edge points: along each ray, the start of the first *long* dark run
    // (the rim). Tick marks and numerals are short runs and are skipped; a
    // dark band against the rim gives a smaller concentric ring of points,
    // which the consensus fit below outvotes.
    // Rim threshold close to the guard's darkness: grey printed bands count
    // as face, only the black guard (and very dark bands) count as rim.
    final edgeThr = dark + 0.35 * (face - dark);
    final pts = <(double, double)>[];
    const rays = 180;
    final stepPx = math.max(0.5, rf / 200);
    final runLen = math.max(3, (0.12 * rf / stepPx).round());
    for (var i = 0; i < rays; i++) {
      final t = 2 * math.pi * i / rays;
      final c = math.cos(t), s = math.sin(t);
      final prof = <int>[];
      for (var rr = 0.5 * rf; rr <= 1.45 * rf; rr += stepPx) {
        final v = f.sample(cx + rr * c, cy + rr * s);
        if (v < 0) break;
        prof.add(v);
      }
      for (var j = 1; j + runLen < prof.length; j++) {
        if (prof[j - 1] < edgeThr || prof[j] >= edgeThr) continue;
        var nDark = 0;
        for (var q = j; q < j + runLen; q++) {
          if (prof[q] < edgeThr) nDark++;
        }
        if (nDark >= runLen - 1) {
          // Sub-sample position of the threshold crossing.
          final a = prof[j - 1].toDouble(), b = prof[j].toDouble();
          final frac = (a - edgeThr) / (a - b);
          final rr = 0.5 * rf + (j - 1 + frac) * stepPx;
          pts.add((cx + rr * c, cy + rr * s));
          break;
        }
      }
    }

    var geo = DialGeometry.circle(cx, cy, rf);
    if (pts.length >= 20) {
      final rnd = math.Random(42); // deterministic
      // Consensus circle.
      var bestIn = <(double, double)>[];
      for (var it = 0; it < 300; it++) {
        final s3 = [for (var q = 0; q < 3; q++) pts[rnd.nextInt(pts.length)]];
        final c = _fitCircle(s3);
        if (c == null || c.$3 < 0.5 * rf || c.$3 > 1.5 * rf) continue;
        final inl = [
          for (final p in pts)
            if ((math.sqrt(math.pow(p.$1 - c.$1, 2) + math.pow(p.$2 - c.$2, 2)) - c.$3).abs() <
                0.025 * c.$3)
              p
        ];
        if (inl.length > bestIn.length) bestIn = inl;
      }
      if (bestIn.length >= 12) {
        final c = _fitCircle(bestIn);
        if (c != null) geo = DialGeometry.circle(c.$1, c.$2, c.$3);
      }
      // Consensus ellipse (a phone looking at the gauge from an angle).
      var bestE = <(double, double)>[];
      DialGeometry? bestEllipse;
      for (var it = 0; it < 400; it++) {
        final s5 = [for (var q = 0; q < 6; q++) pts[rnd.nextInt(pts.length)]];
        final e = _fitEllipse(s5, geo.cx, geo.cy);
        if (e == null) continue;
        final ratio = math.min(e.rx, e.ry) / math.max(e.rx, e.ry);
        if (ratio < 0.5 || e.radius < 0.5 * rf || e.radius > 1.5 * rf) continue;
        final inl = [
          for (final p in pts)
            if ((e.polarOf(p.$1, p.$2).$2 - 1).abs() < 0.025) p
        ];
        if (inl.length > bestE.length) {
          bestE = inl;
          bestEllipse = e;
        }
      }
      if (bestEllipse != null &&
          bestE.length > bestIn.length * 1.5 &&
          bestE.length > 0.6 * pts.length) {
        final e = _fitEllipse(bestE, bestEllipse.cx, bestEllipse.cy) ?? bestEllipse;
        final ratio = math.min(e.rx, e.ry) / math.max(e.rx, e.ry);
        // The ellipse must also look like a face (bright inside, dark rim
        // outside) at least as well as the circle does; a mix of rim and
        // band edges does not.
        if (ratio < 0.96 &&
            ratio >= 0.5 &&
            faceScore(f, e, n: 64) >= faceScore(f, geo, n: 64) - 5) {
          geo = e;
        }
      }
    }
    // Never end up worse than the plain radius scan.
    var score = strictScore(f, geo);
    if (!score.isFinite || score < scannedScore - 3) {
      geo = scanned;
      score = scannedScore;
    }
    return geo.moved(geo.cx, geo.cy, score: score);
  }

  /// Circular Hough transform for the common centre of the dial's circles.
  static (double, double)? _houghCenter(LumaFrame f, double cx, double cy, double r0,
          {double window = 1.7, double searchLimit = 0.5}) {
    final p = _hough(f, cx, cy,
          workRadius: 40,
          r0: r0,
          window: window,
          sMin: 0.3,
          sMax: 1.5,
          searchLimit: searchLimit);
    return p.isEmpty ? null : p.first;
  }

  /// Candidates for the needle pivot: small round shapes near the dial
  /// centre, strongest first. The dial face can look off-centre from an
  /// oblique view (the rim hides part of it), but the needle turns around
  /// the hub. Printed logos can also look round, so the caller picks the
  /// candidate from which the needle is seen most clearly.
  static List<(double, double)> hubCandidates(
      LumaFrame f, double cx, double cy, double r,
      {bool Function(double x, double y)? allow}) {
    if (r < 20) return const []; // hub too small to see
    return _hough(f, cx, cy,
        allow: allow,
        workRadius: 160,
        r0: r,
        window: 0.55,
        sMin: 0.025,
        sMax: 0.12,
        searchLimit: 0.4,
        minPeakRatio: 2.0,
        peaks: 4);
  }

  /// Gradient-voting circle centre search around (cx, cy). Sizes are
  /// fractions of [r0]: votes come from pixels within [window], at distances
  /// [sMin]..[sMax]; the peak is searched within [searchLimit].
  static List<(double, double)> _hough(
    LumaFrame f,
    double cx,
    double cy, {
    required double workRadius,
    required double r0,
    required double window,
    required double sMin,
    required double sMax,
    required double searchLimit,
    double minPeakRatio = 0,
    int peaks = 1,
    bool Function(double x, double y)? allow,
  }) {
    // Resample so that r0 spans [workRadius] pixels: bounded cost.
    final k = r0 / workRadius;
    final half = (math.max(window, searchLimit + sMax) * r0 / k).ceil() + 2;
    final n = 2 * half + 1;
    final img = Float32List(n * n);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final v = f.sample(cx + (x - half) * k, cy + (y - half) * k);
        img[y * n + x] = v < 0 ? double.nan : v.toDouble();
      }
    }
    final acc = Float32List(n * n);
    final rk = r0 / k;
    final s0 = math.max(1, (sMin * rk).floor()), s1 = (sMax * rk).ceil();
    final win2 = math.pow(window * rk, 2);
    for (var y = 1; y < n - 1; y++) {
      for (var x = 1; x < n - 1; x++) {
        if (math.pow(x - half, 2) + math.pow(y - half, 2) > win2) continue;
        double p(int dx, int dy) => img[(y + dy) * n + x + dx];
        final gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1));
        final gy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1));
        if (gx.isNaN || gy.isNaN) continue;
        final mag = math.sqrt(gx * gx + gy * gy);
        if (mag < 60) continue; // ~15 luma step across the 3x3 kernel
        final ux = gx / mag, uy = gy / mag;
        final w = math.min(mag, 400.0);
        for (var s = s0; s <= s1; s++) {
          for (final sg in const [1, -1]) {
            final vx = (x + sg * s * ux).round(), vy = (y + sg * s * uy).round();
            if (vx >= 0 && vy >= 0 && vx < n && vy < n) acc[vy * n + vx] += w;
          }
        }
      }
    }
    // Box-smoothed votes near the rough centre.
    final lim = (searchLimit * rk).ceil();
    final sm = <(double, int, int)>[];
    var total = 0.0;
    for (var y = half - lim; y <= half + lim; y++) {
      for (var x = half - lim; x <= half + lim; x++) {
        if (x < 2 || y < 2 || x >= n - 2 || y >= n - 2) continue;
        if (allow != null && !allow(cx + (x - half) * k, cy + (y - half) * k)) continue;
        var sum = 0.0;
        for (var j = -2; j <= 2; j++) {
          for (var i = -2; i <= 2; i++) {
            sum += acc[(y + j) * n + x + i];
          }
        }
        total += sum;
        sm.add((sum, x, y));
      }
    }
    if (sm.isEmpty) return const [];
    final mean = total / sm.length;
    sm.sort((a, b) => b.$1.compareTo(a.$1));
    final out = <(double, double)>[];
    final picked = <(int, int)>[];
    final sep = math.max(3.0, 0.06 * rk);
    for (final (sum, bx, by) in sm) {
      if (sum <= 0 || (minPeakRatio > 0 && sum < minPeakRatio * mean)) break;
      if (picked.any((p) => math.sqrt(math.pow(p.$1 - bx, 2) + math.pow(p.$2 - by, 2)) < sep)) {
        continue;
      }
      picked.add((bx, by));
      // Sub-pixel: centroid of the 5x5 neighbourhood.
      var sw = 0.0, sx = 0.0, sy = 0.0;
      for (var j = -2; j <= 2; j++) {
        for (var i = -2; i <= 2; i++) {
          final x = bx + i, y = by + j;
          if (x < 0 || y < 0 || x >= n || y >= n) continue;
          final w = acc[y * n + x];
          sw += w;
          sx += w * i;
          sy += w * j;
        }
      }
      final ox = sw > 0 ? sx / sw : 0.0, oy = sw > 0 ? sy / sw : 0.0;
      out.add((cx + (bx - half + ox) * k, cy + (by - half + oy) * k));
      if (out.length >= peaks) break;
    }
    return out;
  }

  /// Algebraic (Kåsa) circle fit.
  static (double, double, double)? _fitCircle(List<(double, double)> p) {
    final n = p.length;
    var mx = 0.0, my = 0.0;
    for (final q in p) {
      mx += q.$1;
      my += q.$2;
    }
    mx /= n;
    my /= n;
    var suu = 0.0, svv = 0.0, suv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0;
    for (final q in p) {
      final u = q.$1 - mx, v = q.$2 - my;
      suu += u * u;
      svv += v * v;
      suv += u * v;
      suuu += u * u * u;
      svvv += v * v * v;
      suvv += u * v * v;
      svuu += v * u * u;
    }
    final det = suu * svv - suv * suv;
    if (det.abs() < 1e-9) return null;
    final b1 = 0.5 * (suuu + suvv), b2 = 0.5 * (svvv + svuu);
    final uc = (b1 * svv - b2 * suv) / det;
    final vc = (suu * b2 - suv * b1) / det;
    final r = math.sqrt(uc * uc + vc * vc + (suu + svv) / n);
    return (mx + uc, my + vc, r);
  }

  /// Least-squares conic A x² + B xy + C y² + D x + E y = 1 in coordinates
  /// relative to (ox, oy) (a point inside the ellipse), converted to centre,
  /// semi-axes and tilt. Works on partial arcs.
  static DialGeometry? _fitEllipse(List<(double, double)> p, double ox, double oy) {
    if (p.length < 5) return null;
    final m = List.generate(5, (_) => Float64List(6));
    for (final q in p) {
      final x = q.$1 - ox, y = q.$2 - oy;
      final row = [x * x, x * y, y * y, x, y];
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 5; j++) {
          m[i][j] += row[i] * row[j];
        }
        m[i][5] += row[i];
      }
    }
    final sol = _solve(m);
    if (sol == null) return null;
    final a = sol[0], b = sol[1], c = sol[2], d = sol[3], e = sol[4];
    const f = -1.0;
    final disc = b * b - 4 * a * c;
    if (disc >= 0) return null; // not an ellipse
    final x0 = (2 * c * d - b * e) / disc;
    final y0 = (2 * a * e - b * d) / disc;
    final f0 = a * x0 * x0 + b * x0 * y0 + c * y0 * y0 + d * x0 + e * y0 + f;
    final th = 0.5 * math.atan2(b, a - c);
    final cs = math.cos(th), sn = math.sin(th);
    final a2 = a * cs * cs + b * cs * sn + c * sn * sn;
    final c2 = a * sn * sn - b * cs * sn + c * cs * cs;
    if (-f0 / a2 <= 0 || -f0 / c2 <= 0) return null;
    return DialGeometry(
      cx: ox + x0,
      cy: oy + y0,
      rx: math.sqrt(-f0 / a2),
      ry: math.sqrt(-f0 / c2),
      tilt: th,
    );
  }

  /// Gauss-Jordan on an augmented n×(n+1) matrix.
  static List<double>? _solve(List<Float64List> m) {
    final n = m.length;
    for (var col = 0; col < n; col++) {
      var piv = col;
      for (var r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[piv][col].abs()) piv = r;
      }
      if (m[piv][col].abs() < 1e-12) return null;
      final tmp = m[col];
      m[col] = m[piv];
      m[piv] = tmp;
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final k = m[r][col] / m[col][col];
        for (var j = col; j <= n; j++) {
          m[r][j] -= k * m[col][j];
        }
      }
    }
    return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
  }

  static double _percentile(Float64List d, int m, double q) {
    final v = Float64List.sublistView(d, 0, m)..sort();
    return v[(m * q).floor().clamp(0, m - 1)];
  }

}

/// Downscaled, upright greyscale copy for the coarse search.
class _Small {
  _Small(this.px, this.w, this.h, this.scale);

  final Uint8List px;
  final int w, h;

  /// Full-resolution pixels per small pixel.
  final double scale;

  factory _Small.of(LumaFrame f, int targetW) {
    final k = math.max(1.0, f.uprightWidth / targetW);
    final w = (f.uprightWidth / k).floor(), h = (f.uprightHeight / k).floor();
    final px = Uint8List(w * h);
    final sub = math.min(3, k.ceil());
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var sum = 0, cnt = 0;
        for (var j = 0; j < sub; j++) {
          for (var i = 0; i < sub; i++) {
            final v = f.at((x * k + (i + 0.5) * k / sub).floor(),
                (y * k + (j + 0.5) * k / sub).floor());
            if (v >= 0) {
              sum += v;
              cnt++;
            }
          }
        }
        px[y * w + x] = cnt == 0 ? 0 : sum ~/ cnt;
      }
    }
    return _Small(px, w, h, k);
  }

  int at(double x, double y) {
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= w || yi >= h) return -1;
    return px[yi * w + xi];
  }
}
