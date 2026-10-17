import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flair_log/vision/luma_frame.dart';
import 'package:image/image.dart' as img;

/// Loads a (greyscale) JPEG test photo as an upright [LumaFrame].
LumaFrame loadJpeg(String path) {
  final im = img.decodeJpg(File(path).readAsBytesSync())!;
  final out = Uint8List(im.width * im.height);
  var i = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      out[i++] = img.getLuminance(im.getPixel(x, y)).toInt();
    }
  }
  return LumaFrame(bytes: out, width: im.width, height: im.height, rowStride: im.width);
}

/// Erases the real needle (pointer and tail around the pivot) by copying the
/// dial from 30° further round, then draws a needle at [newAngle]: a thin
/// dark pointer to 0.86 r and a thick tail to 0.5 r, like the Flair needle.
LumaFrame moveNeedle(LumaFrame f, double px, double py, double r, double restAngle,
    double newAngle) {
  final out = Uint8List.fromList(f.bytes);
  int at(int x, int y) => f.bytes[y * f.rowStride + x];
  final x0 = (px - r).floor(), x1 = (px + r).ceil();
  final y0 = (py - r).floor(), y1 = (py + r).ceil();
  bool onNeedle(double dx, double dy, double a, double pw, double tw) {
    final ux = cos(a), uy = sin(a);
    final along = dx * ux + dy * uy, perp = (dx * uy - dy * ux).abs();
    return (along > 0.12 * r && along < 0.95 * r && perp <= pw) ||
        (along < -0.1 * r && along > -0.62 * r && perp <= tw);
  }

  final pw = max(3.0, 0.045 * r), tw = max(5.0, 0.1 * r);
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - px, dy = y - py;
      if (!onNeedle(dx, dy, restAngle, pw, tw)) continue;
      const k = 30 * pi / 180;
      final sx = (px + dx * cos(k) - dy * sin(k)).round();
      final sy = (py + dx * sin(k) + dy * cos(k)).round();
      out[y * f.width + x] = at(sx, sy);
    }
  }
  final npw = 1.0 + 0.012 * r, ntw = 0.06 * r;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - px, dy = y - py;
      final ux = cos(newAngle), uy = sin(newAngle);
      final along = dx * ux + dy * uy, perp = (dx * uy - dy * ux).abs();
      if (along > 0.1 * r && along < 0.86 * r && perp <= npw) out[y * f.width + x] = 45;
      if (along < -0.08 * r && along > -0.5 * r && perp <= ntw) out[y * f.width + x] = 40;
    }
  }
  return LumaFrame(bytes: out, width: f.width, height: f.height, rowStride: f.width);
}

/// The frame moved down by [dy] pixels, optionally with a dark bar (the
/// lever) covering part of it: (left, top, right, bottom).
LumaFrame shiftedFrame(LumaFrame f, int dy, {(int, int, int, int)? bar}) {
  final out = Uint8List(f.width * f.height);
  for (var y = 0; y < f.height; y++) {
    final sy = (y - dy).clamp(0, f.height - 1);
    out.setRange(y * f.width, (y + 1) * f.width, f.bytes, sy * f.rowStride);
  }
  if (bar != null) {
    for (var y = max(0, bar.$2); y < min(f.height, bar.$4); y++) {
      for (var x = max(0, bar.$1); x < min(f.width, bar.$3); x++) {
        out[y * f.width + x] = 25;
      }
    }
  }
  return LumaFrame(bytes: out, width: f.width, height: f.height, rowStride: f.width);
}

/// The frame rotated by [deg] degrees (clockwise) about its centre, like a
/// phone held slightly turned.
LumaFrame rotatedFrame(LumaFrame f, double deg) {
  final a = deg * pi / 180, c = cos(a), s = sin(a);
  final cx = f.width / 2, cy = f.height / 2;
  final out = Uint8List(f.width * f.height);
  for (var y = 0; y < f.height; y++) {
    for (var x = 0; x < f.width; x++) {
      final dx = x - cx, dy = y - cy;
      final sx = (cx + dx * c + dy * s).round(), sy = (cy - dx * s + dy * c).round();
      out[y * f.width + x] =
          sx >= 0 && sy >= 0 && sx < f.width && sy < f.height ? f.bytes[sy * f.rowStride + sx] : 128;
    }
  }
  return LumaFrame(bytes: out, width: f.width, height: f.height, rowStride: f.width);
}
