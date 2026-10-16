import 'dart:math' as math;

/// Describes where the pressure gauge is in the camera image and how to turn
/// a needle angle into bar.
///
/// Positions are stored in *normalised upright* coordinates (0..1 of the
/// upright frame width/height) so they survive small resolution changes.
/// Angles are in radians in screen space (x right, y down), so increasing
/// angle means clockwise — the direction a pressure gauge needle travels.
class GaugeCalibration {
  const GaugeCalibration({
    required this.centerX,
    required this.centerY,
    required this.radius,
    required this.zeroAngle,
    required this.sweep,
    this.minValue = 0,
    this.maxValue = 16,
    this.polarity = 1,
    this.trackMovement = true,
    this.zoom = 1.0,
    this.reference,
  });

  /// Dial centre, fraction of upright frame width / height.
  final double centerX;
  final double centerY;

  /// Dial face radius as a fraction of the upright frame width.
  final double radius;

  /// Angle of the [minValue] mark.
  final double zeroAngle;

  /// Clockwise angle from the [minValue] mark to the [maxValue] mark.
  final double sweep;

  /// Values printed at the two calibration marks (bar).
  final double minValue;
  final double maxValue;

  /// +1 when the needle is darker than the dial face, -1 when lighter.
  final int polarity;

  /// The Flair 58 gauge sits on the piston stem and moves down during the
  /// shot, so by default the reader follows it.
  final bool trackMovement;

  /// Camera zoom level that was active during calibration.
  final double zoom;

  /// Appearance signature of the bezel used for tracking (see GaugeReader).
  final List<double>? reference;

  /// Converts an angle (radians, screen space) to a gauge value.
  double valueForAngle(double angle) {
    final offset = clockwiseFromZero(angle);
    return minValue + offset / sweep * (maxValue - minValue);
  }

  /// Clockwise angular distance from the zero mark, mapped into
  /// [-(2π - sweep)/2, sweep + (2π - sweep)/2) so that small negative
  /// readings (needle resting just below zero) stay negative.
  double clockwiseFromZero(double angle) {
    var d = _wrap(angle - zeroAngle);
    final dead = 2 * math.pi - sweep;
    if (d > sweep + dead / 2) d -= 2 * math.pi;
    return d;
  }

  double angleForValue(double value) =>
      zeroAngle + (value - minValue) / (maxValue - minValue) * sweep;

  static double _wrap(double a) {
    final t = a % (2 * math.pi);
    return t < 0 ? t + 2 * math.pi : t;
  }

  /// Builds a calibration from three taps in upright pixel coordinates.
  factory GaugeCalibration.fromTaps({
    required double frameWidth,
    required double frameHeight,
    required double cx,
    required double cy,
    required double zeroX,
    required double zeroY,
    required double maxX,
    required double maxY,
    double minValue = 0,
    double maxValue = 16,
    double? radiusPx,
  }) {
    final a0 = math.atan2(zeroY - cy, zeroX - cx);
    final a1 = math.atan2(maxY - cy, maxX - cx);
    var sweep = _wrap(a1 - a0);
    if (sweep < 0.2) sweep = 2 * math.pi - 0.01;
    final r = radiusPx ??
        1.1 *
            math.max(
              math.sqrt(math.pow(zeroX - cx, 2) + math.pow(zeroY - cy, 2)),
              math.sqrt(math.pow(maxX - cx, 2) + math.pow(maxY - cy, 2)),
            );
    return GaugeCalibration(
      centerX: cx / frameWidth,
      centerY: cy / frameHeight,
      radius: r / frameWidth,
      zeroAngle: a0,
      sweep: sweep,
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  GaugeCalibration copyWith({
    double? centerX,
    double? centerY,
    double? radius,
    double? zeroAngle,
    double? sweep,
    double? minValue,
    double? maxValue,
    int? polarity,
    bool? trackMovement,
    double? zoom,
    List<double>? reference,
  }) =>
      GaugeCalibration(
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        radius: radius ?? this.radius,
        zeroAngle: zeroAngle ?? this.zeroAngle,
        sweep: sweep ?? this.sweep,
        minValue: minValue ?? this.minValue,
        maxValue: maxValue ?? this.maxValue,
        polarity: polarity ?? this.polarity,
        trackMovement: trackMovement ?? this.trackMovement,
        zoom: zoom ?? this.zoom,
        reference: reference ?? this.reference,
      );

  Map<String, dynamic> toJson() => {
        'centerX': centerX,
        'centerY': centerY,
        'radius': radius,
        'zeroAngle': zeroAngle,
        'sweep': sweep,
        'minValue': minValue,
        'maxValue': maxValue,
        'polarity': polarity,
        'trackMovement': trackMovement,
        'zoom': zoom,
        if (reference != null) 'reference': reference,
      };

  factory GaugeCalibration.fromJson(Map<String, dynamic> j) =>
      GaugeCalibration(
        centerX: (j['centerX'] as num).toDouble(),
        centerY: (j['centerY'] as num).toDouble(),
        radius: (j['radius'] as num).toDouble(),
        zeroAngle: (j['zeroAngle'] as num).toDouble(),
        sweep: (j['sweep'] as num).toDouble(),
        minValue: (j['minValue'] as num?)?.toDouble() ?? 0,
        maxValue: (j['maxValue'] as num?)?.toDouble() ?? 16,
        polarity: (j['polarity'] as num?)?.toInt() ?? 1,
        trackMovement: j['trackMovement'] as bool? ?? true,
        zoom: (j['zoom'] as num?)?.toDouble() ?? 1.0,
        reference: (j['reference'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
      );
}
