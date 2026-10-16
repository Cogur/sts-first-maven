import 'dart:math' as math;

/// Cleans up the frame-by-frame gauge readings before they are shown and
/// recorded. Two independent stages, each switchable from Settings:
///
/// 1. **Jump rejection** ([rejectJumps]). A lever is moved by hand, so the
///    pressure cannot change faster than a human can push it. A reading that
///    would need a faster change than [maxRise] / [maxFall] (plus [tolerance]
///    for detection noise) is held back as a *candidate*. A single glitch
///    (needle confused with a numeral, a reflection, motion blur) is dropped
///    and the previous value is kept. If [confirmFrames] candidates in a row
///    form a plausible track among themselves, the move was real (e.g. a
///    fast release) and the filter snaps to it.
/// 2. **Smoothing** ([smooth]). A One Euro filter (Casiez et al., CHI 2012):
///    a low-pass whose cut-off rises with the needle's speed. Heavy smoothing
///    removes jitter while the needle rests or holds steady, and there is
///    little lag while the lever is being pulled.
///
/// Time is passed in explicitly (seconds) so the filter is deterministic and
/// testable, and frame-rate independent.
class NeedleFilter {
  NeedleFilter({
    this.smooth = true,
    this.rejectJumps = true,
    this.maxRise = 10,
    this.maxFall = 30,
    this.tolerance = 0.8,
    this.confirmFrames = 3,
    double minCutoff = 0.7,
    double beta = 0.3,
  }) : _euro = _OneEuro(minCutoff: minCutoff, beta: beta);

  bool smooth;
  bool rejectJumps;

  /// Fastest believable pressure rise / fall, bar per second.
  final double maxRise;
  final double maxFall;

  /// Allowed per-frame detection noise on top of the rate limit, bar.
  final double tolerance;

  /// Consecutive mutually consistent outliers needed to accept a real jump.
  final int confirmFrames;

  final _OneEuro _euro;

  double? _accepted;
  double _acceptedT = 0;
  final List<(double, double)> _candidates = [];
  double? _out;

  /// Whether the last raw reading was held back as implausible.
  bool lastRejected = false;

  /// Count of readings dropped since the last [reset].
  int rejectedCount = 0;

  /// Feed one reading taken at time [t] (seconds). Returns the value to show
  /// and record, or null if there is nothing to show yet.
  double? update(double? raw, double t) {
    lastRejected = false;
    if (raw == null) return null; // needle not found in this frame

    var v = raw;
    if (rejectJumps) {
      final a = _accepted;
      if (a != null && !_plausible(a, _acceptedT, v, t)) {
        if (_candidates.isNotEmpty) {
          final (ct, cv) = _candidates.last;
          if (!_plausible(cv, ct, v, t)) _candidates.clear();
        }
        _candidates.add((t, v));
        if (_candidates.length < confirmFrames) {
          lastRejected = true;
          rejectedCount++;
          return _out; // hold the previous value
        }
        // A consistent run of "impossible" readings: the needle really moved.
        _candidates.clear();
        _euro.reset();
      } else {
        _candidates.clear();
      }
      _accepted = v;
      _acceptedT = t;
    }

    _out = smooth ? _euro.filter(v, t) : v;
    return _out;
  }

  bool _plausible(double from, double fromT, double to, double t) {
    final dt = math.max(t - fromT, 1 / 30);
    final d = to - from;
    return d >= 0
        ? d <= tolerance + maxRise * dt
        : -d <= tolerance + maxFall * dt;
  }

  /// Forget history (new shot, recalibration).
  void reset() {
    _accepted = null;
    _candidates.clear();
    _out = null;
    lastRejected = false;
    rejectedCount = 0;
    _euro.reset();
  }
}

/// One Euro filter for a scalar signal.
class _OneEuro {
  _OneEuro({required this.minCutoff, required this.beta});

  final double minCutoff; // Hz, smoothing when the needle is still
  final double beta; // how fast the cut-off opens up with speed
  static const double _dCutoff = 1.0; // Hz, for the speed estimate

  double? _x, _dx, _t;

  static double _alpha(double cutoff, double dt) {
    final tau = 1 / (2 * math.pi * cutoff);
    return 1 / (1 + tau / dt);
  }

  double filter(double x, double t) {
    final px = _x, pt = _t;
    if (px == null || pt == null || t <= pt) {
      _x = x;
      _dx = 0;
      _t = t;
      return x;
    }
    final dt = t - pt;
    final dx = (x - px) / dt;
    final edx = _dx! + _alpha(_dCutoff, dt) * (dx - _dx!);
    final cutoff = minCutoff + beta * edx.abs();
    final fx = px + _alpha(cutoff, dt) * (x - px);
    _x = fx;
    _dx = edx;
    _t = t;
    return fx;
  }

  void reset() {
    _x = null;
    _dx = null;
    _t = null;
  }
}
