import 'dart:math' as math;
import 'dart:typed_data';

import 'dial_geometry.dart';
import 'dial_locator.dart';
import 'gauge_calibration.dart';
import 'luma_frame.dart';
import 'marker.dart';

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

/// Where the calibrated gauge was found in a new view.
class Relocation {
  Relocation(this.face, this.rotation, this.score);

  /// Dial face in the new view.
  final DialGeometry face;

  /// How much the dial appears turned on screen compared with calibration
  /// (radians, clockwise): the phone is held a little differently.
  final double rotation;

  /// Appearance correlation (1 = identical).
  final double score;
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
  static const double windowConfidence = 2.5;
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
  DialGeometry? _prevFace;

  // Marker tracking: the marker's pose now, and the face as it was relative
  // to the marker when last confirmed (constant if the marker is on the
  // gauge; follows the piston if it is on the machine).
  MarkerPose? _marker;
  (DialGeometry, MarkerPose)? _relToMarker;

  /// The marker in the last frame (null if none / not seen).
  MarkerPose? get marker => _marker;

  // Size of the marker when last seen, and frames since: a lost marker is
  // searched in the whole picture at about that size.
  double? _markerR;
  int _markerMissed = 0;
  double _lastMatch = 1;
  bool _wide = true;
  int _lostFrames = 0;

  // The needle moves continuously: at most ~12° per frame even on a hard
  // pull. Searching near its last position first rules out look-alikes
  // elsewhere on the dial (numerals, a screw, the lever's edge).
  double? _lastAngle;
  int _sinceLast = 0;
  static const double _window = 30 * math.pi / 180;

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
    _prevFace = null;
    _relToMarker = null;
    _wide = true;
    _lostFrames = 0;
    _lastAngle = null;
  }

  /// Jump to a face position found elsewhere (e.g. by a full re-search).
  void reacquire(DialGeometry face) {
    _face = face;
    _prevFace = null;
    _wide = false;
    _lostFrames = 0;
  }

  GaugeReading? read(LumaFrame f) {
    var face = _face ?? calibration.face(f.uprightWidth, f.uprightHeight);
    if (face.radius < 6) return null;
    var tracked = true;

    // Printed marker: find it near its last pose, and predict the gauge from
    // it. This also covers frames where the dial itself cannot be matched
    // (lever in front of it, blur).
    DialGeometry? fromMarker;
    final w = f.uprightWidth, h = f.uprightHeight;
    final m0 = calibration.markerIn(w, h);
    final onGauge = calibration.markerOnGauge(w, h);
    if (m0 != null) {
      var seen = MarkerDetector.detectNear(f, _marker ?? m0);
      // Not near its last place (the phone was moved, or it was covered):
      // search the whole picture for a marker of about the same size, on
      // every other frame so a covered marker does not halve the frame rate.
      if (seen == null && _markerMissed++ % 2 == 0) {
        final r = _markerR ?? m0.r;
        seen = MarkerDetector.detect(f, rMin: 0.75 * r, rMax: 1.35 * r);
      }
      if (seen != null) {
        _markerMissed = 0;
        _markerR = seen.r;
      }
      _marker = seen;
      if (seen != null) {
        // On the gauge, the calibrated relation always holds; elsewhere the
        // one confirmed in this session (the gauge moves away from it).
        final rel = onGauge ? null : _relToMarker;
        fromMarker = faceFromMarker(rel?.$1 ?? calibration.face(w, h), rel?.$2 ?? m0, seen);
        face = fromMarker;
      }
    }

    if (calibration.trackMovement && onGauge && fromMarker != null) {
      // The marker is on the gauge, so it says where the dial is. The dial's
      // appearance only fine-tunes the position; when blur or the lever
      // spoil it, the marker alone is used.
      final t = track(f, fromMarker, range: 0.12);
      final ok = t != null && t.score >= (_template != null ? minMatch : 0);
      face = ok ? t : fromMarker;
      if (t != null) _lastMatch = t.score;
      _prevFace = _face;
      _face = face;
      _wide = false;
      _lostFrames = 0;
    } else if (calibration.trackMovement) {
      // The gauge moves steadily with the piston: start the search where it
      // will be if it keeps its speed (limited to a third of a radius).
      final prev = _prevFace;
      var start = fromMarker ?? face;
      if (fromMarker == null && prev != null && _face != null && !_wide) {
        var vx = face.cx - prev.cx, vy = face.cy - prev.cy;
        final v = math.sqrt(vx * vx + vy * vy), vmax = 0.33 * face.radius;
        if (v > vmax) {
          vx *= vmax / v;
          vy *= vmax / v;
        }
        start = face.moved(face.cx + vx, face.cy + vy);
      }
      final confirmed = fromMarker != null && _relToMarker != null;
      final t = track(f, start,
          range: confirmed ? 0.3 : (_wide ? 0.8 : (_lastMatch < 0.8 ? 0.5 : 0.3)));
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
        _prevFace = _face;
        _face = face;
        _wide = false;
        _lostFrames = 0;
        _lastMatch = t.score;
        final mk = _marker;
        if (mk != null) _relToMarker = (face, mk);
      } else if (confirmed) {
        // The dial could not be matched (lever in front, blur), but the
        // marker says where it is (relation confirmed in this session).
        face = fromMarker;
        _prevFace = _face;
        _face = face;
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
    // A marker on the dial is not part of the scale: its rings must not
    // look like a needle. Where it was not seen this frame, it is where the
    // calibration puts it relative to the dial.
    final mk = _marker ?? (onGauge ? _markerOnFace(face, w, h) : null);
    if (mk != null) _maskCircle(polar, ng, mk.cx, mk.cy, 1.4 * mk.r);
    final hidden = _hiddenDirections(f, face, ng);
    NeedleHit? hit;
    final last = _lastAngle;
    if (last != null && _sinceLast < 8) {
      hit = findNeedle(polar, calibration.polarity,
          range: (last - _window, last + _window), background: _bg, exclude: hidden);
      // Being right next to where the needle just was is evidence in
      // itself: a lower bar here than for a jump across the dial.
      if (hit != null && hit.confidence < windowConfidence) hit = null;
    }
    hit ??= findNeedle(polar, calibration.polarity,
        range: calibration.searchRange, background: _bg, exclude: hidden);
    if (hit == null) {
      _sinceLast++;
      return null;
    }
    if (hit.confidence >= minConfidence) {
      _lastAngle = hit.angle;
      _sinceLast = 0;
    } else {
      _sinceLast++;
    }
    if (learn && tracked && hidden == null && hit.confidence >= learnConfidence) {
      _bg = learnBackground(_bg, polar, hit.angle);
    }
    final value = calibration.valueForAngle(hit.angle);
    // Far beyond the scale (the Flair gauge ends ~13 bar with "10" marked):
    // a misread, whatever the confidence.
    final plausible = value > calibration.minValue - 1 &&
        value < calibration.minValue + 1.5 * (calibration.maxValue - calibration.minValue);
    return GaugeReading(
      value: value,
      angle: hit.angle,
      confidence: plausible ? hit.confidence : 0,
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

  /// Marks the polar samples inside a circle as missing.
  static void _maskCircle(Int16List polar, DialGeometry g, double cx, double cy, double rad) {
    final c = math.cos(g.tilt), s = math.sin(g.tilt);
    final r2 = rad * rad;
    for (var k = 0; k < nK; k++) {
      final rho = rho0 + (rho1 - rho0) * k / (nK - 1);
      final ax = g.rx * rho, ay = g.ry * rho;
      for (var a = 0; a < nA; a++) {
        final u = ax * _cos[a], v = ay * _sin[a];
        final dx = g.cx + u * c - v * s - cx, dy = g.cy + u * s + v * c - cy;
        if (dx * dx + dy * dy <= r2) polar[k * nA + a] = -1;
      }
    }
  }

  /// Where the calibrated marker is when the dial is at [face].
  MarkerPose? _markerOnFace(DialGeometry face, int w, int h) {
    final m0 = calibration.markerIn(w, h);
    if (m0 == null) return null;
    final f0 = calibration.face(w, h);
    final s = face.radius / f0.radius, rot = face.tilt - f0.tilt;
    final dx = m0.cx - f0.cx, dy = m0.cy - f0.cy;
    final c = math.cos(rot), sn = math.sin(rot);
    return MarkerPose(face.cx + s * (dx * c - dy * sn), face.cy + s * (dx * sn + dy * c),
        m0.r * s, m0.angle + rot, 0);
  }

  // ---- needle search -------------------------------------------------------

  /// Finds the needle in a polar sample. [range] limits the search (dial
  /// angles, may wrap); null searches the full circle.
  static NeedleHit? findNeedle(
    Int16List polar,
    int polarity, {
    (double, double)? range,
    GaugeBackground? background,
    List<bool>? exclude,
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
      if (!sm[a].isFinite || (exclude != null && exclude[a])) continue;
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

  // ---- relocation: the phone is not in the same place every time -----------

  /// The calibration moved to where [r] found the gauge in a frame of the
  /// given size: position and size from the new view, and zero mark, pivot,
  /// learned background and appearance template turned by the rotation.
  static GaugeCalibration relocated(GaugeCalibration c, Relocation r, int w, int h,
      {double? pivotX, double? pivotY, Uint8List? template, MarkerPose? marker}) {
    final rot = r.rotation;
    final cs = math.cos(rot), sn = math.sin(rot);
    // Dial angles (needle, zero, template and background columns) count from
    // the face's tilt axis. The part of the turn the new face's tilt already
    // carries must not be applied again.
    var dialRot = (rot - (r.face.tilt - c.tilt)) % (2 * math.pi);
    if (dialRot > math.pi) dialRot -= 2 * math.pi;
    // Template: a fresh one from the new view if given, else the old one
    // with its direction columns shifted by the rotation (4° steps).
    Uint8List? tmpl = template;
    final old = c.template;
    if (tmpl == null && old != null && old.length == _tRho.length * _tN) {
      var shift = (dialRot / (2 * math.pi) * _tN).round() % _tN;
      if (shift < 0) shift += _tN;
      tmpl = Uint8List(old.length);
      for (var k = 0; k < _tRho.length; k++) {
        for (var d = 0; d < _tN; d++) {
          tmpl[k * _tN + (d + shift) % _tN] = old[k * _tN + d];
        }
      }
    }
    // Background: same, at 1° resolution.
    GaugeBackground? bg;
    final ob = c.background;
    if (ob != null) {
      var shift = (dialRot / (2 * math.pi) * nA).round() % nA;
      if (shift < 0) shift += nA;
      bg = GaugeBackground.empty();
      for (var a = 0; a < nA; a++) {
        final na = (a + shift) % nA;
        bg.seen[na] = ob.seen[a];
        for (var k = 0; k < nK; k++) {
          bg.values[k * nA + na] = ob.values[k * nA + a];
        }
      }
    }
    final face = r.face;
    return GaugeCalibration(
      faceX: face.cx / w,
      faceY: face.cy / h,
      faceRx: face.rx / w,
      faceRy: face.ry / w,
      tilt: face.tilt,
      pivotDx: pivotX != null ? (pivotX - face.cx) / face.radius : c.pivotDx * cs - c.pivotDy * sn,
      pivotDy: pivotY != null ? (pivotY - face.cy) / face.radius : c.pivotDx * sn + c.pivotDy * cs,
      zeroAngle: c.zeroAngle + dialRot,
      sweep: c.sweep,
      minValue: c.minValue,
      maxValue: c.maxValue,
      polarity: c.polarity,
      trackMovement: c.trackMovement,
      zoom: c.zoom,
      faceScore: c.faceScore,
      background: bg,
      template: tmpl,
      marker: marker != null
          ? MarkerPose(marker.cx / w, marker.cy / h, marker.r / w, marker.angle, marker.score)
          : c.marker,
    );
  }

  /// The gauge face where the marker now says it is: the calibrated
  /// face-to-marker relation (position, size, rotation) applied to [now].
  static DialGeometry faceFromMarker(
      DialGeometry face0, MarkerPose m0, MarkerPose now) {
    final s = now.r / m0.r, rot = now.angle - m0.angle;
    final dx = face0.cx - m0.cx, dy = face0.cy - m0.cy;
    final c = math.cos(rot), sn = math.sin(rot);
    return DialGeometry(
      cx: now.cx + s * (dx * c - dy * sn),
      cy: now.cy + s * (dx * sn + dy * c),
      rx: face0.rx * s,
      ry: face0.ry * s,
      tilt: face0.tilt + rot,
      score: face0.score,
    );
  }

  // ---- occlusion ----------------------------------------------------------

  /// Directions (needle polar indices) where something covers the rim, e.g.
  /// the lever passing in front of the gauge. The needle never reaches the
  /// rim, so a rim that suddenly looks different from the calibrated
  /// template means an occluder, which would otherwise pass for a needle.
  /// Null when nothing is covered (or there is no template).
  List<bool>? _hiddenDirections(LumaFrame f, DialGeometry face, DialGeometry ng) {
    final raw = calibration.template;
    if (raw == null || raw.length != _tRho.length * _tN) return null;
    final vals = Float64List(raw.length);
    final ok = List<bool>.filled(raw.length, false);
    _sampleTemplate(f, face, (i, v) {
      if (v >= 0) {
        vals[i] = v.toDouble();
        ok[i] = true;
      }
    });
    // Brightness/contrast change since calibration: least squares v ≈ a·t + b.
    var n = 0, st = 0.0, sv = 0.0, stt = 0.0, stv = 0.0;
    for (var i = 0; i < raw.length; i++) {
      if (!ok[i]) continue;
      final t = raw[i].toDouble();
      n++;
      st += t;
      sv += vals[i];
      stt += t * t;
      stv += t * vals[i];
    }
    if (n < raw.length ~/ 2) return null;
    final den = n * stt - st * st;
    final a = den.abs() < 1e-9 ? 1.0 : (n * stv - st * sv) / den;
    final b = (sv - a * st) / n;
    // Mean residual per template direction on the rim rings. Only points
    // beyond the needle's reach *from the pivot* count: the visible face can
    // look off-centre (seen from below, the rim hides its top), so a rim ring
    // of the face can come within reach of the needle tip.
    const rimRings = [4, 5, 6]; // rho 0.95, 1.05, 1.15
    // Per direction: how many rim rings differ strongly from the template.
    // A pixel or two of tracking error makes the sharp rim edge differ on
    // one ring; an occluder changes the whole rim band.
    final diffs = <double>[];
    final res = List.generate(_tN, (_) => <double>[]);
    for (var d = 0; d < _tN; d++) {
      for (final k in rimRings) {
        final i = k * _tN + d;
        if (!ok[i]) continue;
        final p = face.point(2 * math.pi * d / _tN, _tRho[k]);
        if (ng.polarOf(p.$1, p.$2).$2 < 0.97) continue;
        final r = (vals[i] - (a * raw[i] + b)).abs();
        res[d].add(r);
        diffs.add(r);
      }
    }
    if (diffs.isEmpty) return null;
    diffs.sort();
    final typical = diffs[diffs.length ~/ 2];
    final limit = math.max(40.0, 4 * typical);
    final strong = [
      for (final r in res) r.length >= 2 && r.where((x) => x > limit).length >= 2
    ];
    // Only stretches of at least 3 directions (12°) count as covered.
    final covered = List<bool>.filled(_tN, false);
    for (var d = 0; d < _tN; d++) {
      if (!strong[d]) continue;
      var run = 1;
      while (run < _tN && strong[(d + run) % _tN]) {
        run++;
      }
      var back = 1;
      while (back < _tN && strong[(d - back + _tN) % _tN]) {
        back++;
      }
      if (run + back - 1 >= 3) covered[d] = true;
    }
    if (!covered.contains(true)) return null;
    // Map to needle directions: which template direction does the rim
    // point of each needle direction fall into?
    final out = List<bool>.filled(nA, false);
    for (var i = 0; i < nA; i++) {
      final p = ng.point(_angleOf(i), 0.95);
      final t = face.polarOf(p.$1, p.$2).$1;
      var d = (t / (2 * math.pi) * _tN).round() % _tN;
      if (d < 0) d += _tN;
      // Also the neighbours: the occluder's edge is fuzzy.
      out[i] = covered[d] || covered[(d + 1) % _tN] || covered[(d - 1 + _tN) % _tN];
    }
    return out;
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

  /// Chooses the needle pivot: the needle line is found first (Radon
  /// search), then the round hub is searched only *along that line*.
  /// Printed logos can look round too (the Flair "f" loops sit right below
  /// the hub), but they are off the needle's line. Without a visible hub, the
  /// point of the line closest to the face centre is used. [candidates] are
  /// extra hub positions to consider (from a wider search).
  static (double, double) choosePivot(
      LumaFrame f, DialGeometry face, List<(double, double)> candidates) {
    final line = needleLine(f, face);
    if (line == null) {
      return candidates.isNotEmpty ? candidates.first : (face.cx, face.cy);
    }
    final (px, py, ux, uy) = line;
    double perp(double x, double y) => ((x - px) * -uy + (y - py) * ux).abs();
    final tol = math.max(1.5, 0.06 * face.radius);
    final onLine = DialLocator.hubCandidates(f, face.cx, face.cy, face.radius,
        allow: (x, y) => perp(x, y) <= tol);
    if (onLine.isNotEmpty) return onLine.first;
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

  // The template is matched per angular sector, and only the best sectors
  // count: the lever or a hand covering part of the rim must not make the
  // gauge "lost".
  static const int _sectors = 9;
  static const int _bestSectors = 6;
  static const int _perSector = _tN ~/ _sectors; // 10 directions

  static int _sectorOf(int i) => (i % _tN) ~/ _perSector;

  /// Template normalised to zero mean / unit variance within each sector;
  /// NaN marks sectors without texture (nothing to match there).
  static Float64List? normalise(Uint8List t) {
    if (t.length != _tRho.length * _tN) return null; // older format
    final out = Float64List(t.length);
    var usable = 0;
    for (var sct = 0; sct < _sectors; sct++) {
      var sum = 0.0, n = 0;
      for (var i = 0; i < t.length; i++) {
        if (_sectorOf(i) != sct) continue;
        sum += t[i];
        n++;
      }
      final mean = sum / n;
      var ss = 0.0;
      for (var i = 0; i < t.length; i++) {
        if (_sectorOf(i) == sct) ss += (t[i] - mean) * (t[i] - mean);
      }
      final sd = math.sqrt(ss / n);
      for (var i = 0; i < t.length; i++) {
        if (_sectorOf(i) == sct) out[i] = sd < 2 ? double.nan : (t[i] - mean) / sd;
      }
      if (sd >= 2) usable++;
    }
    return usable < 3 ? null : out;
  }

  /// How well the frame at [g] matches the template: the mean normalised
  /// cross-correlation of the best-matching sectors (1 = identical up to
  /// brightness and contrast).
  static double match(LumaFrame f, DialGeometry g, Float64List tmpl) {
    final vals = Float64List(tmpl.length);
    final ok = List<bool>.filled(tmpl.length, false);
    _sampleTemplate(f, g, (i, v) {
      if (v >= 0) {
        vals[i] = v.toDouble();
        ok[i] = true;
      }
    });
    final scores = <double>[];
    for (var sct = 0; sct < _sectors; sct++) {
      var sum = 0.0, n = 0, total = 0;
      for (var i = 0; i < tmpl.length; i++) {
        if (_sectorOf(i) != sct || tmpl[i].isNaN) continue;
        total++;
        if (!ok[i]) continue;
        sum += vals[i];
        n++;
      }
      if (total == 0 || n < total * 0.8) continue;
      final mean = sum / n;
      var ss = 0.0, dot = 0.0;
      for (var i = 0; i < tmpl.length; i++) {
        if (_sectorOf(i) != sct || tmpl[i].isNaN || !ok[i]) continue;
        final d = vals[i] - mean;
        ss += d * d;
        dot += d * tmpl[i];
      }
      scores.add(ss <= 0 ? 0 : dot / math.sqrt(ss * n));
    }
    if (scores.length < 3) return -1;
    scores.sort((a, b) => b.compareTo(a));
    final k = math.min(_bestSectors, scores.length);
    return scores.take(k).reduce((a, b) => a + b) / k;
  }

  Float64List? _tmpl;
  Float64List? get _template =>
      _tmpl ??= calibration.template == null ? null : normalise(calibration.template!);

  /// Correlation below which the gauge counts as lost.
  static const double minMatch = 0.6;

  /// Stricter bar for jumping to a re-found dial: on the real setup the
  /// gauge matches itself at ~1.0, the shot mirror at ~0.67.
  static const double reacquireMatch = 0.8;
  static const double reacquireNeedle = 6;

  /// Follows the dial: local search for the position (and a little scale)
  /// where the calibrated appearance matches best. Returns the geometry with
  /// the correlation as its score. Falls back to the face score without a
  /// template.
  DialGeometry? track(LumaFrame f, DialGeometry face, {bool wide = false, double? range}) {
    final tmpl = _template;
    double score(DialGeometry g) =>
        tmpl != null ? match(f, g, tmpl) : DialLocator.faceScore(f, g, n: 32);
    final r = face.radius;
    var best = face;
    var bestScore = score(face);
    final reach = (range ?? (wide ? 0.8 : 0.25)) * r;
    final step = math.max(1.0, 0.05 * r);
    for (var dy = -reach; dy <= reach + 1e-9; dy += step) {
      for (var dx = -reach; dx <= reach + 1e-9; dx += step) {
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
