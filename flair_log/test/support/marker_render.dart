import 'dart:math';
import 'dart:typed_data';

import 'package:flair_log/vision/luma_frame.dart';

/// Luma of the printed marker at (u, v) in units of its outer radius, with
/// the wedge pointing "up" (−v). -1 outside the paper.
int markerLuma(double u, double v, {int ink = 35, int paper = 215}) {
  final d = sqrt(u * u + v * v);
  if (d > 1.3) return -1;
  if (d >= 1.0) return paper;
  if (d >= 0.8) return ink;
  if (d >= 0.6) {
    final a = atan2(u, -v); // 0 = up
    return a.abs() < 20 * pi / 180 ? ink : paper;
  }
  if (d >= 0.4) return ink;
  if (d >= 0.2) return paper;
  return ink;
}

/// Pastes the marker into [f] at (cx, cy), outer radius [r] pixels, wedge
/// rotated by [angle] (radians, clockwise from up), anti-aliased; optional
/// box blur of [blur] pixels (camera softness / motion).
LumaFrame withMarker(LumaFrame f, double cx, double cy, double r, double angle,
    {int blur = 0, int ink = 35, int paper = 215}) {
  final out = Uint8List.fromList(f.bytes);
  final w = f.width, h = f.height;
  final m = (1.35 * r).ceil();
  final ca = cos(-angle), sa = sin(-angle);
  for (var y = max(0, (cy - m).floor()); y < min(h, (cy + m).ceil()); y++) {
    for (var x = max(0, (cx - m).floor()); x < min(w, (cx + m).ceil()); x++) {
      var sum = 0, cnt = 0;
      for (var j = 0; j < 4; j++) {
        for (var i = 0; i < 4; i++) {
          final dx = x + (i + 0.5) / 4 - 0.5 - cx, dy = y + (j + 0.5) / 4 - 0.5 - cy;
          final u = (dx * ca - dy * sa) / r, v = (dx * sa + dy * ca) / r;
          final l = markerLuma(u, v, ink: ink, paper: paper);
          if (l >= 0) {
            sum += l;
            cnt++;
          }
        }
      }
      if (cnt == 16) out[y * w + x] = sum ~/ 16;
      if (cnt > 0 && cnt < 16) {
        out[y * w + x] = ((sum + (16 - cnt) * out[y * w + x]) / 16).round();
      }
    }
  }
  var res = LumaFrame(bytes: out, width: w, height: h, rowStride: w);
  if (blur > 0) res = boxBlur(res, blur, (cx - m - blur).floor(), (cy - m - blur).floor(), (cx + m + blur).ceil(), (cy + m + blur).ceil());
  return res;
}

/// Box blur of a region (simulates a soft camera / small motion).
LumaFrame boxBlur(LumaFrame f, int k, int x0, int y0, int x1, int y1) {
  final out = Uint8List.fromList(f.bytes);
  x0 = max(k, x0); y0 = max(k, y0); x1 = min(f.width - k, x1); y1 = min(f.height - k, y1);
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      var s = 0;
      for (var j = -k; j <= k; j++) {
        for (var i = -k; i <= k; i++) {
          s += f.bytes[(y + j) * f.width + x + i];
        }
      }
      out[y * f.width + x] = s ~/ ((2 * k + 1) * (2 * k + 1));
    }
  }
  return LumaFrame(bytes: out, width: f.width, height: f.height, rowStride: f.width);
}
