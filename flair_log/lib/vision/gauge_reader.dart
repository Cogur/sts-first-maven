import 'dart:math' as math;
import 'dart:typed_data';

import 'dial_geometry.dart';
import 'dial_locator.dart';
import 'gauge_calibration.dart';
import 'luma_frame.dart';

/// Result of analysing one frame.
class GaugeReading {
  const GaugeReading({
    required this.value,
    required this.angle,
    required this.confidence,
    required this.face,
    required this.needle,
    required this.tracked,
  });

  /// Gauge value (bar).
  final double value;

  /// Needle dial angle, radians.
  final double angle;

  /// Robust z-score of the needle peak; >= [GaugeReader.minConfidence] is a
  /// clear needle.
  final double confidence;

  /// Where the dial face was found in this frame.
  final DialGeometry face;

  /// Sampling geometry around the pivot (for drawing the needle).
  final DialGeometry needle;

  /// False when the gauge could not be followed in this frame.
  final bool tracked;

  bool get isValid => confidence >= GaugeReader.minConfidence;
}

/// A needle found in one polar sample.
class NeedleHit {
  const NeedleHit(this.angle, this.confidence);
  final double angle;
  final double confidence;
}

/// Reads the needle of an analogue dial.
///
/// Each frame is sampled in polar coordinates around the needle pivot:
/// [GaugeBackground.angles] directions × [GaugeBackground.radii] rings from
/// [rho0] to [rho1] of the face radius. The needle is the direction that
/// differs from the empty dial at *almost every* ring (a low percentile over
/// rings), so printed numerals, the logo and the needle's short tail, which
/// only cover some rings, are ignored.
///
/// "Empty dial" is the learned [GaugeBackground] where available: whenever
/// the needle is read confidently, every direction well away from it is
/// blended into the background. After a shot or two the logo and text cancel
/// out completely. Directions not learned yet fall back to the ring median.
class GaugeReader {
  GaugeReader(this.calibration) : _bg = calibration.background?.copy();

  GaugeCalibration calibration;
  GaugeBackground? _bg;

  /// The background learned so far (persist it with the calibration).
  GaugeBackground? get background => _bg;

  /// Learning can be paused (e.g. while the user is not brewing).
  bool learn = true;

  static const double minConfidence = 4.0;
  static const double learnConfidence = 7.0;
  static const double rho0 = 0.28, rho1 = 0.82;
  static const int nA = GaugeBackground.angles;
  static const int nK = GaugeBackground.radii;
  static const double _keepOut = 15 * math.pi / 180;

  static final List<double> _cos =
      List.generate(nA, (a) => math.cos(2 * math.pi * a / nA));
  static final List<double> _sin =
      List.generate(nA, (a) => math.sin(2 * math.pi * a / nA));

  DialGeometry? _face;
  bool _wide = true;
  int _lostFrames = 0;

  /// Consecutive frames in which the gauge could not be followed.
  int get lostFrames => _lostFrames;

  void updateCalibration(GaugeCalibration c) {
    calibration = c;
    _tmpl = null;
    _bg = c.background?.copy();
    resetTracking();
  }

  /// Start again from the calibrated position (new shot, gauge at rest).
  void resetTracking() {
    _face = null;
    _wide = true;
    _lostFrames = 0;
  }

  /// Jump to a face position found elsewhere (e.g. by a full re-search).
  void reacquire(DialGeometry face) {
    _face = face;
    _wide = false;
    _lostFrames = 0;
  }

  GaugeReading? read(LumaFrame f) {
    var face = _face ?? calibration.face(f.uprightWidth, f.uprightHeight);
    if (face.radius < 6) return null;
    var tracked = true;
    if (calibration.trackMovement) {
      final t = track(f, face, wide: _wide);
      final need = _template != null
          ? minMatch
          : (calibration.faceScore > 0 ? 0.45 * calibration.faceScore : 15);
      if (t != null && t.score >= need) {
        // Keep the size near the calibrated one (no drift over many frames).
        final calR = calibration.face(f.uprightWidth, f.uprightHeight).radius;
        final k = t.radius / calR;
        face = k < 0.85 || k > 1.2
            ? t.moved(t.cx, t.cy, scale: k.clamp(0.85, 1.2) / k)
            : t;
        _face = face;
        _wide = false;
        _lostFrames = 0;
      } else {
        _wide = true;
        _lostFrames++;
        tracked = false;
      }
    }
    final ng = GaugeCalibration.needleGeometry(
        face, calibration.pivotDx, calibration.pivotDy);
    final polar = samplePolar(f, ng);
    final hit = findNeedle(polar, calibration.polarity,
        range: calibration.searchRange, background: _bg);
    if (hit == null) return null;
    if (learn && tracked && hit.confidence >= learnConfidence) {
      _bg = learnBackground(_bg, polar, hit.angle);
    }
    return GaugeReading(
      value: calibration.valueForAngle(hit.angle),
      angle: hit.angle,
      confidence: hit.confidence,
      face: face,
      needle: ng,
      tracked: tracked,
    );
  }

  // ---- polar sampling ----------------------------------------------------

  /// Luma at [nK] rings × [nA] directions around the pivot; -1 off-frame.
  static Int16List samplePolar(LumaFrame f, DialGeometry g) {
    final out = Int16List(nK * nA);
    final c = math.cos(g.tilt), s = math.sin(g.tilt);
    for (var k = 0; k < nK; k++) {
      final rho = rho0 + (rho1 - rho0) * k / (nK - 1);
      final ax = g.rx * rho, ay = g.ry * rho;
      for (var a = 0; a < nA; a++) {
        final u = ax * _cos[a], v = ay * _sin[a];
        out[k * nA + a] = f.sample(g.cx + u * c - v * s, g.cy + u * s + v * c);
      }
    }
    return out;
  }

  static double _angleOf(int a) => 2 * math.pi * a / nA;

  // ---- needle search -------------------------------------------------------

  /// Finds the needle in a polar sample. [range] limits the search (dial
  /// angles, may wrap); null searches the full circle.
  static NeedleHit? findNeedle(
    Int16List polar,
    int polarity, {
    (double, double)? range,
    GaugeBackground? background,
  }) {
    // Ring "face level" (75th percentile: the plain face colour even on a
    // busy dial) of this frame, and the lighting offset to the background.
    final ringMed = Float64List(nK);
    final offset = Float64List(nK);
    final tmp = Float64List(nA);
    for (var k = 0; k < nK; k++) {
      var m = 0;
      for (var a = 0; a < nA; a++) {
        final v = polar[k * nA + a];
        if (v >= 0) tmp[m++] = v.toDouble();
      }
      ringMed[k] = m == 0 ? -1 : _percentile(tmp, m, polarity > 0 ? 0.75 : 0.25);
      if (background != null && m > 0) {
        var n = 0;
        for (var a = 0; a < nA; a++) {
          if (background.known(a)) tmp[n++] = background.values[k * nA + a];
        }
        offset[k] = n < 20 ? 0 : ringMed[k] - _percentile(tmp, n, 0.5);
      }
    }

    // Score per direction: the needle must stand out in the inner half AND
    // in the outer half of the rings. The pointer reaches the scale; a tail
    // (counterweight) stops halfway, even when numerals or a screw happen to
    // continue its line (as on the Flair gauge, whose tail points at "10").
    final score = Float64List(nA);
    final inner = Float64List(nK), outer = Float64List(nK);
    for (var a = 0; a < nA; a++) {
      final useBg = background != null && background.known(a);
      var ni = 0, no = 0;
      for (var k = 0; k < nK; k++) {
        final v = polar[k * nA + a];
        if (v < 0 || ringMed[k] < 0) continue;
        final ref = useBg ? background.values[k * nA + a] + offset[k] : ringMed[k];
        final d = polarity * (ref - v);
        if (k < nK ~/ 2) {
          inner[ni++] = d;
        } else {
          outer[no++] = d;
        }
      }
      score[a] = ni < nK ~/ 4 || no < nK ~/ 4
          ? double.negativeInfinity
          : math.min(_percentile(inner, ni, 0.25), _percentile(outer, no, 0.25));
    }

    // No smoothing across directions: a thin needle covers only 1–2°.
    final sm = score;

    // Indices inside the search range.
    final idx = <int>[];
    if (range == null) {
      for (var a = 0; a < nA; a++) {
        idx.add(a);
      }
    } else {
      final i0 = (range.$1 / (2 * math.pi) * nA).floor();
      final i1 = (range.$2 / (2 * math.pi) * nA).ceil();
      for (var i = i0; i <= i1 && idx.length < nA; i++) {
        idx.add(((i % nA) + nA) % nA);
      }
    }

    var best = -1;
    final vals = <double>[];
    for (final a in idx) {
      if (!sm[a].isFinite) continue;
      vals.add(sm[a]);
      if (best < 0 || sm[a] > sm[best]) best = a;
    }
    if (best < 0 || vals.length < 10) return null;
    final v = Float64List.fromList(vals);
    final med = _percentile(v, v.length, 0.5);
    final absDev = Float64List.fromList(vals.map((x) => (x - med).abs()).toList());
    final mad = _percentile(absDev, absDev.length, 0.5);
    final conf = (sm[best] - med) / (1.4826 * mad + 1.0);

    var t = _angleOf(best);
    final y0 = sm[(best - 1 + nA) % nA], y1 = sm[best], y2 = sm[(best + 1) % nA];
    if (y0.isFinite && y2.isFinite) {
      final den = y0 - 2 * y1 + y2;
      if (den.abs() > 1e-9) {
        t += (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5) * 2 * math.pi / nA;
      }
    }
    return NeedleHit(t, conf);
  }

  /// Blends every direction away from the needle (and its tail) into the
  /// background.
  static GaugeBackground learnBackground(
      GaugeBackground? bg, Int16List polar, double needleAngle) {
    final b = bg ?? GaugeBackground.empty();
    // Lighting offset per ring relative to what is already known.
    final offset = Float64List(nK);
    final tmp = Float64List(nA);
    for (var k = 0; k < nK; k++) {
      var m = 0, n = 0;
      for (var a = 0; a < nA; a++) {
        final v = polar[k * nA + a];
        if (v >= 0) tmp[m++] = v.toDouble();
      }
      final cur = m == 0 ? 0.0 : _percentile(tmp, m, 0.5);
      for (var a = 0; a < nA; a++) {
        if (b.known(a)) tmp[n++] = b.values[k * nA + a];
      }
      offset[k] = n < 20 ? 0 : cur - _percentile(tmp, n, 0.5);
    }
    for (var a = 0; a < nA; a++) {
      final t = _angleOf(a);
      if (_angDist(t, needleAngle) < _keepOut ||
          _angDist(t, needleAngle + math.pi) < _keepOut) {
        continue;
      }
      var ok = true;
      for (var k = 0; k < nK; k++) {
        if (polar[k * nA + a] < 0) ok = false;
      }
      if (!ok) continue;
      final seen = b.seen[a];
      final alpha = seen == 0 ? 1.0 : (seen < 4 ? 0.5 : 0.08);
      for (var k = 0; k < nK; k++) {
        final i = k * nA + a;
        final v = polar[i] - offset[k];
        b.values[i] += alpha * (v - b.values[i]);
      }
      if (seen < 250) b.seen[a] = seen + 1;
    }
    return b;
  }

  static double _angDist(double a, double b) {
    final d = (a - b) % (2 * math.pi);
    final p = d < 0 ? d + 2 * math.pi : d;
    return math.min(p, 2 * math.pi - p);
  }

  // ---- calibration helpers -----------------------------------------------

  /// The needle (any direction) and its polarity, for a frame where the
  /// position of zero is not known yet.
  static (NeedleHit, int)? anyNeedle(LumaFrame f, DialGeometry needleGeometry) {
    final polar = samplePolar(f, needleGeometry);
    final dark = findNeedle(polar, 1);
    final light = findNeedle(polar, -1);
    if (dark == null && light == null) return null;
    if (light != null && (dark == null || light.confidence > dark.confidence)) {
      return (light, -1);
    }
    return (dark!, 1);
  }

  /// Chooses the needle pivot: the strongest hub candidate lying on the
  /// needle line; otherwise the point of that line closest to the face
  /// centre. (Judging candidates by needle clarity alone is ambiguous: every
  /// point on the needle's line sees a long straight dark line.)
  static (double, double) choosePivot(
      LumaFrame f, DialGeometry face, List<(double, double)> candidates) {
    final line = needleLine(f, face);
    if (line == null) {
      return candidates.isNotEmpty ? candidates.first : (face.cx, face.cy);
    }
    final (px, py, ux, uy) = line;
    double perp(double x, double y) => ((x - px) * -uy + (y - py) * ux).abs();
    final tol = math.max(1.5, 0.09 * face.radius);
    for (final c in candidates) {
      if (perp(c.$1, c.$2) <= tol) return c;
    }
    final t = (face.cx - px) * ux + (face.cy - py) * uy;
    return (px + t * ux, py + t * uy);
  }

  /// The longest straight dark line across the face (the needle, pointer and
  /// tail together): a Radon-style search over directions and offsets.
  /// Returns a point on the line and its unit direction.
  static (double, double, double, double)? needleLine(LumaFrame f, DialGeometry face) {
    final r = face.minRadius;
    // Face colour: 75th percentile inside the face.
    final lv = <double>[];
    for (var y = -0.8; y <= 0.8; y += 0.1) {
      for (var x = -0.8; x <= 0.8; x += 0.1) {
        if (x * x + y * y > 0.64) continue;
        final v = f.sample(face.cx + x * r, face.cy + y * r);
        if (v >= 0) lv.add(v.toDouble());
      }
    }
    if (lv.length < 20) return null;
    final faceLevel = _percentile(Float64List.fromList(lv), lv.length, 0.75);

    const ns = 64;
    final dev = Float64List(ns);
    var best = double.negativeInfinity;
    (double, double, double, double)? bestLine;
    final step = math.max(0.5, r / 150);
    for (var deg = 0.0; deg < 180; deg += 0.5) {
      final th = deg * math.pi / 180;
      final ux = math.cos(th), uy = math.sin(th);
      for (var rho = -0.35 * r; rho <= 0.35 * r; rho += step) {
        final ox = face.cx - uy * rho, oy = face.cy + ux * rho;
        final half = math.sqrt(math.max(0, 0.81 * r * r - rho * rho));
        var m = 0;
        for (var i = 0; i < ns; i++) {
          final t = -half + 2 * half * i / (ns - 1);
          final v = f.sample(ox + t * ux, oy + t * uy);
          if (v >= 0) dev[m++] = faceLevel - v;
        }
        if (m < ns ~/ 2) continue;
        // Most of the chord must be dark (pointer + hub + tail ≈ 75% of it).
        final sc = _percentile(dev, m, 0.3);
        if (sc > best) {
          best = sc;
          bestLine = (ox, oy, ux, uy);
        }
      }
    }
    return bestLine;
  }

  // ---- tracking ------------------------------------------------------------

  // Appearance template: rings from inside the face to the black guard.
  static const List<double> _tRho = [0.6, 0.7, 0.8, 0.88, 0.95, 1.05, 1.15, 1.25];
  static const int _tN = 90;
  static final List<double> _tCos =
      List.generate(_tN, (i) => math.cos(2 * math.pi * i / _tN));
  static final List<double> _tSin =
      List.generate(_tN, (i) => math.sin(2 * math.pi * i / _tN));

  /// Samples the appearance template of [face] (null if mostly off-frame).
  static Uint8List? captureTemplate(LumaFrame f, DialGeometry face) {
    final out = Uint8List(_tRho.length * _tN);
    var missing = 0;
    _sampleTemplate(f, face, (i, v) {
      if (v < 0) {
        missing++;
        out[i] = 0;
      } else {
        out[i] = v;
      }
    });
    return missing > out.length ~/ 5 ? null : out;
  }

  static void _sampleTemplate(LumaFrame f, DialGeometry g, void Function(int, int) emit) {
    final c = math.cos(g.tilt), s = math.sin(g.tilt);
    var i = 0;
    for (final rho in _tRho) {
      final ax = g.rx * rho, ay = g.ry * rho;
      for (var a = 0; a < _tN; a++) {
        final u = ax * _tCos[a], v = ay * _tSin[a];
        emit(i++, f.sample(g.cx + u * c - v * s, g.cy + u * s + v * c));
      }
    }
  }

  /// Zero-mean, unit-variance copy of a template.
  static Float64List? normalise(Uint8List t) {
    final n = t.length;
    var mean = 0.0;
    for (final v in t) {
      mean += v;
    }
    mean /= n;
    var ss = 0.0;
    for (final v in t) {
      ss += (v - mean) * (v - mean);
    }
    final sd = math.sqrt(ss / n);
    if (sd < 1) return null;
    return Float64List.fromList([for (final v in t) (v - mean) / sd]);
  }

  /// Normalised cross-correlation of the template with the frame at [g]
  /// (1 = identical up to brightness/contrast).
  static double match(LumaFrame f, DialGeometry g, Float64List tmpl) {
    final vals = Float64List(tmpl.length);
    final ok = List<bool>.filled(tmpl.length, false);
    var sum = 0.0, n = 0;
    _sampleTemplate(f, g, (i, v) {
      if (v >= 0) {
        vals[i] = v.toDouble();
        ok[i] = true;
        sum += v;
        n++;
      }
    });
    if (n < tmpl.length * 0.75) return -1;
    final mean = sum / n;
    var ss = 0.0, dot = 0.0;
    for (var i = 0; i < tmpl.length; i++) {
      if (!ok[i]) continue;
      final d = vals[i] - mean;
      ss += d * d;
      dot += d * tmpl[i];
    }
    if (ss <= 0) return -1;
    return dot / math.sqrt(ss * n);
  }

  Float64List? _tmpl;
  Float64List? get _template =>
      _tmpl ??= calibration.template == null ? null : normalise(calibration.template!);

  /// Correlation below which the gauge counts as lost.
  static const double minMatch = 0.55;

  /// Follows the dial: local search for the position (and a little scale)
  /// where the calibrated appearance matches best. Returns the geometry with
  /// the correlation as its score. Falls back to the face score without a
  /// template.
  DialGeometry? track(LumaFrame f, DialGeometry face, {bool wide = false}) {
    final tmpl = _template;
    double score(DialGeometry g) =>
        tmpl != null ? match(f, g, tmpl) : DialLocator.faceScore(f, g, n: 32);
    final r = face.radius;
    var best = face;
    var bestScore = score(face);
    final range = (wide ? 0.8 : 0.25) * r;
    final step = math.max(1.0, 0.05 * r);
    for (var dy = -range; dy <= range + 1e-9; dy += step) {
      for (var dx = -range; dx <= range + 1e-9; dx += step) {
        final g = face.moved(face.cx + dx, face.cy + dy);
        final s = score(g);
        if (s > bestScore) {
          bestScore = s;
          best = g;
        }
      }
    }
    if (!bestScore.isFinite) return null;
    final c = best;
    final fine = math.max(0.5, 0.012 * r);
    for (final sc in const [0.97, 1.0, 1.03]) {
      for (var dy = -step; dy <= step + 1e-9; dy += fine) {
        for (var dx = -step; dx <= step + 1e-9; dx += fine) {
          final g = c.moved(c.cx + dx, c.cy + dy, scale: sc);
          final s = score(g);
          if (s > bestScore) {
            bestScore = s;
            best = g;
          }
        }
      }
    }
    return best.moved(best.cx, best.cy, score: bestScore);
  }

  static double _percentile(Float64List d, int m, double q) {
    final v = Float64List.sublistView(d, 0, m)..sort();
    return v[(m * q).floor().clamp(0, m - 1)];
  }
}
