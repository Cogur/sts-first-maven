import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flair_log/vision/luma_frame.dart';

/// Loads a binary PGM (P5) greyscale image as an upright [LumaFrame].
LumaFrame loadPgm(String path) {
  final b = File(path).readAsBytesSync();
  var i = 0;
  String token() {
    while (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
      i++;
    }
    if (b[i] == 0x23) {
      while (b[i] != 0x0A) {
        i++;
      }
      return token();
    }
    final s = i;
    while (b[i] != 0x20 && b[i] != 0x0A && b[i] != 0x0D && b[i] != 0x09) {
      i++;
    }
    return String.fromCharCodes(b.sublist(s, i));
  }

  if (token() != 'P5') throw FormatException('not a P5 PGM: $path');
  final w = int.parse(token()), h = int.parse(token());
  token(); // maxval
  i++; // single whitespace before data
  return LumaFrame(
      bytes: Uint8List.fromList(b.sublist(i, i + w * h)),
      width: w,
      height: h,
      rowStride: w);
}

/// Pastes [src] scaled by [scale] into a large textured frame at (ox, oy),
/// imitating a phone that frames the whole machine.
LumaFrame embed(LumaFrame src,
    {int width = 1080, int height = 1920, double scale = 0.35, int ox = 380, int oy = 760}) {
  final out = Uint8List(width * height);
  final rnd = math.Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // tiles with grout and a vertical dark cable
      var v = ((x % 140) < 4 || (y % 140) < 4) ? 150 : 200;
      if ((x - 200).abs() < 9) v = 30;
      out[y * width + x] = (v + rnd.nextInt(7) - 3).clamp(0, 255);
    }
  }
  final sw = (src.width * scale).round(), sh = (src.height * scale).round();
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final v = src.at((x / scale).floor(), (y / scale).floor());
      if (v >= 0) out[(oy + y) * width + ox + x] = v;
    }
  }
  return LumaFrame(bytes: out, width: width, height: height, rowStride: width);
}
