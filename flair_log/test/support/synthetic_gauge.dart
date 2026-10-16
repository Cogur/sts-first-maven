import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flair_log/vision/luma_frame.dart';

/// Renders a Flair-58-like gauge into a larger scene:
/// white face, thick black guard, a dark band on the right of the face, a
/// long thin pointer with a thick short tail, a dark hub, two screws, a logo
/// stroke and numerals, on a tiled wall with a dark cable.
///
/// [tilt]/[squash] render the dial as seen from an angle (an ellipse).
/// Angles are screen angles in radians (0 = right, π/2 = down).
LumaFrame renderFlairLike({
  required double needleAngle,
  double cx = 540,
  double cy = 900,
  double r = 60,
  int width = 1080,
  int height = 1920,
  double squash = 1.0,
  double tilt = 0,
  double? decoyAngle,
  int decoyLuma = 70,
  int seed = 1,
  int quarterTurns = 0,
}) {
  final rnd = math.Random(seed);
  final up = Uint8List(width * height);
  final ct = math.cos(tilt), st = math.sin(tilt);
  final nx = math.cos(needleAngle), ny = math.sin(needleAngle);
  final pad = (1.4 * r).ceil();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var v = ((x % 150) < 5 || (y % 150) < 5) ? 150 : 200; // tiles
      if ((x - 120).abs() < 12) v = 35; // cable
      if ((x - cx).abs() < pad && (y - cy).abs() < pad) {
        // Dial coordinates (undo the oblique view).
        final dx = x - cx, dy = y - cy;
        final u = dx * ct + dy * st;
        final w = (-dx * st + dy * ct) / squash;
        final d = math.sqrt(u * u + w * w);
        final a = math.atan2(w, u);
        if (d < r) {
          v = 222;
          // dark band on the right outer face (STOP! BREAKAGE!)
          if (d > 0.78 * r && a > -0.5 && a < 1.1) v = 60;
          // grey band at the top (Espresso)
          if (d > 0.8 * r && a > -2.4 && a < -0.9) v = 150;
          // ticks on the left arc
          if (d > 0.86 * r && d < 0.95 * r && a > 2.3 && a < 3.6) {
            if (((a * 40).round() % 3) == 0) v = 40;
          }
          // numerals "5" and "10"
          for (final (na, nr) in [(-2.1, 0.68), (-0.85, 0.68)]) {
            final px = math.cos(na) * nr * r, py = math.sin(na) * nr * r;
            if ((u - px).abs() < 0.07 * r && (w - py).abs() < 0.09 * r) v = 45;
          }
          // screws on the right
          for (final (sa, sr) in [(-0.62, 0.58), (0.2, 0.5)]) {
            final px = math.cos(sa) * sr * r, py = math.sin(sa) * sr * r;
            final sd = math.sqrt(math.pow(u - px, 2) + math.pow(w - py, 2));
            if (sd < 0.06 * r) v = sd < 0.03 * r ? 180 : 70;
          }
          // logo: a long slanted stroke below the hub
          final lx = u - 0.05 * r, ly = w - 0.45 * r;
          if ((lx * 0.95 + ly * 0.3).abs() < 0.035 * r && ly.abs() < 0.3 * r) v = 50;
          // optional decoy: a printed line that looks like a needle
          if (decoyAngle != null) {
            final ux = math.cos(decoyAngle), uy = math.sin(decoyAngle);
            final al = u * ux + w * uy, pe = (u * uy - w * ux).abs();
            if (al > 0.22 * r && al < 0.88 * r && pe < 0.03 * r) v = decoyLuma;
          }
          // needle: thin pointer to 0.86 r, thick tail to 0.5 r
          final along = u * nx + w * ny;
          final perp = (u * ny - w * nx).abs();
          if (along > 0 && along < 0.86 * r && perp < math.max(0.9, 0.018 * r)) v = 35;
          if (along < 0 && along > -0.5 * r && perp < 0.05 * r) v = 30;
          if (d < 0.08 * r) v = d < 0.035 * r ? 190 : 40; // hub
        } else if (d < 1.3 * r) {
          v = 25; // black silicone guard
        }
      }
      v += rnd.nextInt(9) - 4;
      up[y * width + x] = v.clamp(0, 255);
    }
  }
  if (quarterTurns == 0) {
    return LumaFrame(bytes: up, width: width, height: height, rowStride: width);
  }
  // Raw sensor buffer that becomes upright after one clockwise turn.
  final rw = height, rh = width;
  final raw = Uint8List(rw * rh);
  for (var uy = 0; uy < height; uy++) {
    for (var ux = 0; ux < width; ux++) {
      raw[(rh - 1 - ux) * rw + uy] = up[uy * width + ux];
    }
  }
  return LumaFrame(bytes: raw, width: rw, height: rh, rowStride: rw, quarterTurns: 1);
}
