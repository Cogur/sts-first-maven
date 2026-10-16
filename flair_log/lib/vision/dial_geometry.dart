import 'dart:math' as math;

/// The dial face as seen by the camera, in upright pixel coordinates.
///
/// A phone that looks at the gauge at an angle sees the round face as an
/// ellipse. All sampling goes through [point], which maps a *dial angle* `t`
/// and a fraction `rho` of the face radius to an image point. For a round
/// dial seen at an angle (an affine view) the dial angle differs from the
/// printed angle only by a constant, so value = linear(t) still holds.
class DialGeometry {
  const DialGeometry({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    this.tilt = 0,
    this.score = 0,
  });

  /// Circle convenience constructor.
  const DialGeometry.circle(this.cx, this.cy, double r, {this.score = 0})
      : rx = r,
        ry = r,
        tilt = 0;

  final double cx, cy;

  /// Semi-axes of the face ellipse, pixels.
  final double rx, ry;

  /// Rotation of the [rx] axis, radians.
  final double tilt;

  /// How clearly the face stands out (luma units); set by the locator.
  final double score;

  /// Geometric-mean radius, pixels.
  double get radius => math.sqrt(rx * ry);

  double get minRadius => math.min(rx, ry);

  (double, double) point(double t, double rho) {
    final u = rx * rho * math.cos(t), v = ry * rho * math.sin(t);
    final c = math.cos(tilt), s = math.sin(tilt);
    return (cx + u * c - v * s, cy + u * s + v * c);
  }

  /// Dial angle and radius fraction of an image point (inverse of [point]).
  (double, double) polarOf(double x, double y) {
    final dx = x - cx, dy = y - cy;
    final c = math.cos(tilt), s = math.sin(tilt);
    final u = (dx * c + dy * s) / rx, v = (-dx * s + dy * c) / ry;
    return (math.atan2(v, u), math.sqrt(u * u + v * v));
  }

  DialGeometry moved(double x, double y, {double scale = 1, double? score}) =>
      DialGeometry(
        cx: x,
        cy: y,
        rx: rx * scale,
        ry: ry * scale,
        tilt: tilt,
        score: score ?? this.score,
      );

  DialGeometry scaledBy(double k) => DialGeometry(
        cx: cx * k,
        cy: cy * k,
        rx: rx * k,
        ry: ry * k,
        tilt: tilt,
        score: score,
      );

  @override
  String toString() =>
      'Dial(${cx.toStringAsFixed(1)}, ${cy.toStringAsFixed(1)}, '
      'r=${rx.toStringAsFixed(1)}/${ry.toStringAsFixed(1)}, '
      'tilt=${(tilt * 180 / math.pi).toStringAsFixed(0)}°, '
      'score=${score.toStringAsFixed(0)})';
}
