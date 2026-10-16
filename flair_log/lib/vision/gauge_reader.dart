import 'dart:math' as math;

import 'gauge_calibration.dart';
import 'luma_frame.dart';

/// Result of analysing one frame.
class GaugeReading {
  const GaugeReading({
    required this.value,
    required this.angle,
    required this.confidence,
    required this.centerX,
    required this.centerY,
    required this.radius,
    required this.trackingScore,
  });

  /// Gauge value in the calibration's unit (bar).
  final double value;

  /// Needle angle, radians, screen space.
  final double angle;

  /// Robust z-score of the needle peak; > ~4 is a clear needle.
  final double confidence;

  /// Where the dial centre was found in this frame (upright pixels).
  final double centerX;
  final double centerY;
  final double radius;

  /// Normalised cross-correlation of the bezel against the reference (1 =
  /// perfect). 1.0 when tracking is off.
  final double trackingScore;

  bool get isValid => confidence >= GaugeReader.minConfidence;
}

/// Finds the needle of an analogue dial gauge.
///
/// For each candidate angle the reader samples a ray from near the hub to just
/// inside the tick marks. The needle is the one ray that is darker (or
/// lighter) than the dial face at *almost every* radius, so the per-angle
/// score is a low percentile of the per-radius contrast. Printed numerals and
/// logos only cover a few radii and are ignored by this.
///
/// Because the Flair 58 gauge travels with the piston, the reader can also
/// follow the dial by matching an appearance signature of the bezel ring.
class GaugeReader {
  GaugeReader(this.calibration) {
    _buildTables();
  }

  GaugeCalibration calibration;

  static const double minConfidence = 4.0;

  // Needle ray region, fractions of dial radius.
  static const double _rayInner = 0.25;
  static const double _rayOuter = 0.80;
  static const int _rayRadii = 18;

  // Margin searched beyond the min/max marks.
  static const double _margin = 15 * math.pi / 180;
  static const double _angleStep = math.pi / 180; // 1°

  // Tracking ring.
  static const List<double> _ringRadii = [0.92, 1.0, 1.08, 1.16];
  static const int _ringAngles = 90;
  static const double _minTrackScore = 0.45;

  late List<double> _cos, _sin, _angles;
  late List<double> _ringCos, _ringSin;

  double? _trackX, _trackY;
  bool _wideSearch = true;

  void _buildTables() {
    final n = ((calibration.sweep + 2 * _margin) / _angleStep).ceil() + 1;
    _angles = List.generate(
        n, (i) => calibration.zeroAngle - _margin + i * _angleStep);
    _cos = _angles.map(math.cos).toList();
    _sin = _angles.map(math.sin).toList();
    _ringCos = List.generate(
        _ringAngles, (i) => math.cos(2 * math.pi * i / _ringAngles));
    _ringSin = List.generate(
        _ringAngles, (i) => math.sin(2 * math.pi * i / _ringAngles));
  }

  void updateCalibration(GaugeCalibration c) {
    calibration = c;
    _buildTables();
    resetTracking();
  }

  /// Forget the tracked position (e.g. before a new shot, while the gauge is
  /// back at its resting position).
  void resetTracking() {
    _trackX = null;
    _trackY = null;
    _wideSearch = true;
  }

  double _calCx(LumaFrame f) => calibration.centerX * f.uprightWidth;
  double _calCy(LumaFrame f) => calibration.centerY * f.uprightHeight;
  double _radiusPx(LumaFrame f) => calibration.radius * f.uprightWidth;

  GaugeReading? read(LumaFrame f) {
    final r = _radiusPx(f);
    if (r < 8) return null;

    var cx = _trackX ?? _calCx(f);
    var cy = _trackY ?? _calCy(f);
    var trackScore = 1.0;

    final ref = calibration.reference;
    if (calibration.trackMovement && ref != null) {
      final t = _track(f, cx, cy, r, ref, wide: _wideSearch);
      if (t != null && t.$3 >= _minTrackScore) {
        cx = t.$1;
        cy = t.$2;
        _trackX = cx;
        _trackY = cy;
        _wideSearch = false;
      } else {
        // Lost: widen the next search around the last known spot.
        _wideSearch = true;
      }
      trackScore = t?.$3 ?? 0;
    }

    final needle = _findNeedle(f, cx, cy, r, calibration.polarity);
    if (needle == null) return null;
    return GaugeReading(
      value: calibration.valueForAngle(needle.$1),
      angle: needle.$1,
      confidence: needle.$2,
      centerX: cx,
      centerY: cy,
      radius: r,
      trackingScore: trackScore,
    );
  }

  /// Returns (angle, confidence) of the needle for the given polarity.
  (double, double)? _findNeedle(
      LumaFrame f, double cx, double cy, double r, int polarity) {
    final nA = _angles.length;
    // values[k][a]
    final values = List.generate(_rayRadii, (_) => List<int>.filled(nA, -1));
    for (var k = 0; k < _rayRadii; k++) {
      final rr = r * (_rayInner + (_rayOuter - _rayInner) * k / (_rayRadii - 1));
      final row = values[k];
      for (var a = 0; a < nA; a++) {
        row[a] = f.sample(cx + rr * _cos[a], cy + rr * _sin[a]);
      }
    }

    final scores = List<double>.filled(nA, 0);
    final dev = List<double>.filled(_rayRadii, 0);
    final medians = List<double>.generate(_rayRadii, (k) {
      final v = values[k].where((x) => x >= 0).toList();
      return v.isEmpty ? -1 : _median(v.map((e) => e.toDouble()).toList());
    });

    for (var a = 0; a < nA; a++) {
      var n = 0;
      for (var k = 0; k < _rayRadii; k++) {
        final v = values[k][a];
        if (v < 0 || medians[k] < 0) continue;
        dev[n++] = polarity * (medians[k] - v);
      }
      if (n < _rayRadii ~/ 2) {
        scores[a] = double.negativeInfinity;
        continue;
      }
      final d = dev.sublist(0, n)..sort();
      scores[a] = d[(n * 0.25).floor()];
    }

    // Light angular smoothing.
    final smooth = List<double>.filled(nA, double.negativeInfinity);
    for (var a = 1; a < nA - 1; a++) {
      if (scores[a - 1].isFinite && scores[a].isFinite && scores[a + 1].isFinite) {
        smooth[a] = (scores[a - 1] + 2 * scores[a] + scores[a + 1]) / 4;
      }
    }

    var best = -1;
    for (var a = 0; a < nA; a++) {
      if (smooth[a].isFinite && (best < 0 || smooth[a] > smooth[best])) best = a;
    }
    if (best < 0) return null;

    final finite = smooth.where((s) => s.isFinite).toList();
    final med = _median(List.of(finite));
    final mad = _median(finite.map((s) => (s - med).abs()).toList());
    final confidence = (smooth[best] - med) / (1.4826 * mad + 1.0);

    // Parabolic sub-degree refinement.
    var angle = _angles[best];
    if (best > 0 &&
        best < nA - 1 &&
        smooth[best - 1].isFinite &&
        smooth[best + 1].isFinite) {
      final y0 = smooth[best - 1], y1 = smooth[best], y2 = smooth[best + 1];
      final denom = y0 - 2 * y1 + y2;
      if (denom.abs() > 1e-9) {
        final off = (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5);
        angle += off * _angleStep;
      }
    }
    return (angle, confidence);
  }

  /// Picks the needle polarity that gives the clearest needle in [f].
  int detectPolarity(LumaFrame f) {
    final cx = _calCx(f), cy = _calCy(f), r = _radiusPx(f);
    final dark = _findNeedle(f, cx, cy, r, 1);
    final light = _findNeedle(f, cx, cy, r, -1);
    return (light?.$2 ?? 0) > (dark?.$2 ?? 0) ? -1 : 1;
  }

  /// Bezel appearance signature at (cx, cy), z-normalised, or null if the
  /// ring is mostly outside the frame.
  List<double>? signatureAt(LumaFrame f, double cx, double cy, double r) {
    final n = _ringRadii.length * _ringAngles;
    final out = List<double>.filled(n, 0);
    var i = 0, missing = 0;
    var sum = 0.0;
    for (final rf in _ringRadii) {
      final rr = r * rf;
      for (var a = 0; a < _ringAngles; a++) {
        final v = f.sample(cx + rr * _ringCos[a], cy + rr * _ringSin[a]);
        if (v < 0) {
          missing++;
          out[i++] = double.nan;
        } else {
          out[i++] = v.toDouble();
          sum += v;
        }
      }
    }
    if (missing > n ~/ 4) return null;
    final mean = sum / (n - missing);
    var ss = 0.0;
    for (var j = 0; j < n; j++) {
      if (out[j].isNaN) {
        out[j] = 0;
      } else {
        out[j] -= mean;
        ss += out[j] * out[j];
      }
    }
    final sd = math.sqrt(ss / (n - missing));
    if (sd < 1) return null; // flat image, nothing to track
    for (var j = 0; j < n; j++) {
      out[j] /= sd;
    }
    return out;
  }

  /// Captures the tracking reference at the calibrated position.
  List<double>? captureReference(LumaFrame f) =>
      signatureAt(f, _calCx(f), _calCy(f), _radiusPx(f));

  double _ncc(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s / a.length;
  }

  (double, double, double)? _track(LumaFrame f, double cx, double cy,
      double r, List<double> ref,
      {required bool wide}) {
    if (ref.length != _ringRadii.length * _ringAngles) return null;
    var bestX = cx, bestY = cy, best = -2.0;

    void search(double ox, double oy, double range, double step) {
      final steps = (range / step).floor();
      for (var j = -steps; j <= steps; j++) {
        for (var i = -steps; i <= steps; i++) {
          final x = ox + i * step, y = oy + j * step;
          final s = signatureAt(f, x, y, r);
          if (s == null) continue;
          final score = _ncc(s, ref);
          if (score > best) {
            best = score;
            bestX = x;
            bestY = y;
          }
        }
      }
    }

    final coarse = math.max(1.0, r * 0.06);
    search(cx, cy, r * (wide ? 0.9 : 0.3), coarse);
    if (best < -1) return null;
    search(bestX, bestY, coarse, math.max(1.0, r * 0.01));
    return (bestX, bestY, best);
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    v.sort();
    final m = v.length ~/ 2;
    return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
  }
}
