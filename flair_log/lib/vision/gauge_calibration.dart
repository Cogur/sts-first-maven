import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dial_geometry.dart';
import 'marker.dart';

/// Everything the reader needs to know about one gauge in one camera setup.
///
/// Positions are fractions of the upright frame (x of width, y of height,
/// radii of width) so they survive resolution changes. Angles are *dial
/// angles* (see [DialGeometry.point]); increasing angle is clockwise on
/// screen, the direction a pressure needle travels.
class GaugeCalibration {
  const GaugeCalibration({
    required this.faceX,
    required this.faceY,
    required this.faceRx,
    required this.faceRy,
    this.tilt = 0,
    this.pivotDx = 0,
    this.pivotDy = 0,
    required this.zeroAngle,
    required this.sweep,
    this.minValue = 0,
    this.maxValue = 10,
    this.polarity = 1,
    this.trackMovement = true,
    this.zoom = 1.0,
    this.faceScore = 0,
    this.background,
    this.template,
    this.marker,
  });

  static const version = 2;

  /// Dial face ellipse (as found by the DialLocator).
  final double faceX, faceY, faceRx, faceRy, tilt;

  /// Needle pivot relative to the face centre, in face radii. The face can
  /// look off-centre from an oblique view; the needle turns around the pivot.
  final double pivotDx, pivotDy;

  /// Dial angle of the [minValue] mark (the needle at rest = 0 bar).
  final double zeroAngle;

  /// Clockwise dial angle from the [minValue] mark to the [maxValue] mark.
  final double sweep;

  /// Values at the two reference marks (bar). [maxValue] is the mark the
  /// user tapped (10 on the Flair gauge); readings beyond it extrapolate.
  final double minValue, maxValue;

  /// +1: needle darker than the face; -1: lighter.
  final int polarity;

  /// The Flair 58 gauge sits on the piston stem and moves during the shot.
  final bool trackMovement;

  /// Camera zoom during calibration.
  final double zoom;

  /// Face contrast at calibration; tracking is "lost" well below this.
  final double faceScore;

  /// What the empty dial looks like, learned while brewing.
  final GaugeBackground? background;

  /// Appearance of the face edge, bands and rim at calibration, used to
  /// follow the gauge (see GaugeReader.track).
  final Uint8List? template;

  /// The printed marker as seen at calibration (normalised like the face:
  /// x of width, y of height, r of width), if one was in the picture. The
  /// gauge's position, size and rotation are then known relative to it.
  final MarkerPose? marker;

  /// The marker in pixels of a frame of the given upright size.
  MarkerPose? markerIn(int w, int h) {
    final m = marker;
    return m == null ? null : MarkerPose(m.cx * w, m.cy * h, m.r * w, m.angle, m.score);
  }

  /// Whether the marker sits on the gauge itself: its centre is inside the
  /// gauge's outline (face plus guard), where nothing behind the gauge could
  /// be seen. It then moves with the gauge and alone tells where the dial
  /// is. A marker elsewhere may be on the machine, which the gauge moves
  /// away from during a shot.
  bool markerOnGauge(int w, int h) {
    final m = markerIn(w, h);
    if (m == null) return false;
    final f = face(w, h);
    final dx = m.cx - f.cx, dy = m.cy - f.cy;
    return dx * dx + dy * dy <= math.pow(1.25 * f.radius, 2);
  }

  /// Face ellipse in pixels of a frame of the given upright size.
  DialGeometry face(int w, int h) => DialGeometry(
        cx: faceX * w,
        cy: faceY * h,
        rx: faceRx * w,
        ry: faceRy * w,
        tilt: tilt,
        score: faceScore,
      );

  /// Sampling geometry for the needle: the face shape around the pivot.
  static DialGeometry needleGeometry(DialGeometry face, double pdx, double pdy) {
    final r = face.radius;
    return face.moved(face.cx + pdx * r, face.cy + pdy * r);
  }

  double valueForAngle(double angle) =>
      minValue + clockwiseFromZero(angle) / sweep * (maxValue - minValue);

  double angleForValue(double value) =>
      zeroAngle + (value - minValue) / (maxValue - minValue) * sweep;

  /// Clockwise distance from the zero mark in (-40°, 320°]: the needle can
  /// rest slightly below zero but never travels backwards a long way.
  double clockwiseFromZero(double angle) {
    var d = _wrap(angle - zeroAngle);
    if (d > 2 * math.pi - _below) d -= 2 * math.pi;
    return d;
  }

  static const double _below = 40 * math.pi / 180;

  /// Dial angles the reader searches: from a little below zero to 320°.
  (double, double) get searchRange => (zeroAngle - 25 * math.pi / 180,
      zeroAngle + math.min(2 * math.pi - _below, math.max(sweep * 1.6, 270 * math.pi / 180)));

  static double _wrap(double a) {
    final t = a % (2 * math.pi);
    return t < 0 ? t + 2 * math.pi : t;
  }

  GaugeCalibration copyWith({
    double? zeroAngle,
    double? sweep,
    double? minValue,
    double? maxValue,
    int? polarity,
    bool? trackMovement,
    double? zoom,
    GaugeBackground? background,
  }) =>
      GaugeCalibration(
        faceX: faceX,
        faceY: faceY,
        faceRx: faceRx,
        faceRy: faceRy,
        tilt: tilt,
        pivotDx: pivotDx,
        pivotDy: pivotDy,
        zeroAngle: zeroAngle ?? this.zeroAngle,
        sweep: sweep ?? this.sweep,
        minValue: minValue ?? this.minValue,
        maxValue: maxValue ?? this.maxValue,
        polarity: polarity ?? this.polarity,
        trackMovement: trackMovement ?? this.trackMovement,
        zoom: zoom ?? this.zoom,
        faceScore: faceScore,
        background: background ?? this.background,
        template: template,
        marker: marker,
      );

  /// Builds a calibration from a located face, a pivot and the dial angles of
  /// the zero mark and one numbered mark.
  factory GaugeCalibration.fromDial({
    required DialGeometry face,
    required double pivotX,
    required double pivotY,
    required int frameWidth,
    required int frameHeight,
    required double zeroAngle,
    required double markAngle,
    required double markValue,
    double minValue = 0,
    int polarity = 1,
    bool trackMovement = true,
    double zoom = 1,
    GaugeBackground? background,
    Uint8List? template,
    MarkerPose? marker,
  }) {
    var sweep = _wrap(markAngle - zeroAngle);
    if (sweep < 0.05) sweep = 2 * math.pi - 0.01;
    final r = face.radius;
    return GaugeCalibration(
      faceX: face.cx / frameWidth,
      faceY: face.cy / frameHeight,
      faceRx: face.rx / frameWidth,
      faceRy: face.ry / frameWidth,
      tilt: face.tilt,
      pivotDx: (pivotX - face.cx) / r,
      pivotDy: (pivotY - face.cy) / r,
      zeroAngle: zeroAngle,
      sweep: sweep,
      minValue: minValue,
      maxValue: markValue,
      polarity: polarity,
      trackMovement: trackMovement,
      zoom: zoom,
      faceScore: face.score,
      background: background,
      template: template,
      marker: marker == null
          ? null
          : MarkerPose(marker.cx / frameWidth, marker.cy / frameHeight,
              marker.r / frameWidth, marker.angle, marker.score),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'faceX': faceX,
        'faceY': faceY,
        'faceRx': faceRx,
        'faceRy': faceRy,
        'tilt': tilt,
        'pivotDx': pivotDx,
        'pivotDy': pivotDy,
        'zeroAngle': zeroAngle,
        'sweep': sweep,
        'minValue': minValue,
        'maxValue': maxValue,
        'polarity': polarity,
        'trackMovement': trackMovement,
        'zoom': zoom,
        'faceScore': faceScore,
        if (background != null) 'background': background!.toJson(),
        if (template != null) 'template': base64Encode(template!),
        if (marker != null)
          'marker': {
            'x': marker!.cx,
            'y': marker!.cy,
            'r': marker!.r,
            'a': marker!.angle,
          },
      };

  /// Returns null for calibrations from older app versions (they must be
  /// redone with the new finder).
  static GaugeCalibration? fromJson(Map<String, dynamic> j) {
    if (j['version'] != version) return null;
    double d(String k, [double def = 0]) => (j[k] as num?)?.toDouble() ?? def;
    return GaugeCalibration(
      faceX: d('faceX'),
      faceY: d('faceY'),
      faceRx: d('faceRx'),
      faceRy: d('faceRy'),
      tilt: d('tilt'),
      pivotDx: d('pivotDx'),
      pivotDy: d('pivotDy'),
      zeroAngle: d('zeroAngle'),
      sweep: d('sweep', math.pi),
      minValue: d('minValue'),
      maxValue: d('maxValue', 10),
      polarity: (j['polarity'] as num?)?.toInt() ?? 1,
      trackMovement: j['trackMovement'] as bool? ?? true,
      zoom: d('zoom', 1),
      faceScore: d('faceScore'),
      background: j['background'] == null
          ? null
          : GaugeBackground.fromJson(j['background'] as Map<String, dynamic>),
      template: j['template'] == null ? null : base64Decode(j['template'] as String),
      marker: j['marker'] == null
          ? null
          : () {
              final m = j['marker'] as Map<String, dynamic>;
              return MarkerPose((m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
                  (m['r'] as num).toDouble(), (m['a'] as num).toDouble(), 1);
            }(),
    );
  }
}

/// The dial face without the needle, in polar coordinates around the pivot:
/// [angles] dial angles × [radii] ring positions (see GaugeReader). Angles
/// where the needle has not been seen away from yet are "unknown".
class GaugeBackground {
  GaugeBackground(this.values, this.seen);

  GaugeBackground.empty()
      : values = Float32List(radii * angles),
        seen = Uint8List(angles);

  static const int angles = 360;
  static const int radii = 20;

  /// Luma per [radius * angles + angle].
  final Float32List values;

  /// How often each angle has been observed without the needle (saturates).
  final Uint8List seen;

  bool known(int a) => seen[a] > 0;

  double get coverage => seen.where((s) => s > 0).length / angles;

  GaugeBackground copy() =>
      GaugeBackground(Float32List.fromList(values), Uint8List.fromList(seen));

  Map<String, dynamic> toJson() => {
        'v': base64Encode(Uint8List.fromList(
            values.map((v) => v.round().clamp(0, 255)).toList())),
        's': base64Encode(seen),
      };

  factory GaugeBackground.fromJson(Map<String, dynamic> j) {
    final v = base64Decode(j['v'] as String);
    final s = base64Decode(j['s'] as String);
    if (v.length != radii * angles || s.length != angles) {
      return GaugeBackground.empty();
    }
    return GaugeBackground(
        Float32List.fromList(v.map((e) => e.toDouble()).toList()), s);
  }
}
