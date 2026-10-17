import 'dart:io';
import 'dart:typed_data';

import 'package:flair_log/vision/luma_frame.dart';

/// One frame of a diagnostic recording (lib/vision/diagnostic_recorder.dart),
/// rebuilt at full size: the recorded gauge region on a mid-grey frame.
class RecordedFrame {
  RecordedFrame(this.ms, this.frame, this.overview);
  final int ms;
  final LumaFrame frame;

  /// True for the half-resolution whole view at the start.
  final bool overview;
}

/// Reads a `.flr` recording, e.g. one sent from the phone, for replay tests.
List<RecordedFrame> loadRecording(String path) {
  final b = File(path).readAsBytesSync();
  final d = ByteData.sublistView(b);
  if (String.fromCharCodes(b.sublist(0, 4)) != 'FLR1') {
    throw FormatException('not a Flair Log recording: $path');
  }
  final w0 = d.getUint16(4, Endian.little), h0 = d.getUint16(6, Endian.little);
  final out = <RecordedFrame>[];
  var o = 8;
  while (o + 17 <= b.length) {
    final type = d.getUint8(o);
    final ms = d.getUint32(o + 1, Endian.little);
    final x = d.getUint16(o + 5, Endian.little), y = d.getUint16(o + 7, Endian.little);
    final w = d.getUint16(o + 9, Endian.little), h = d.getUint16(o + 11, Endian.little);
    final len = d.getUint32(o + 13, Endian.little);
    final px = Uint8List.fromList(ZLibCodec().decode(b.sublist(o + 17, o + 17 + len)));
    o += 17 + len;
    if (type == 2) {
      // Half-resolution overview: upscale back.
      final full = Uint8List(w0 * h0);
      for (var yy = 0; yy < h0; yy++) {
        for (var xx = 0; xx < w0; xx++) {
          full[yy * w0 + xx] = px[(yy ~/ 2).clamp(0, h - 1) * w + (xx ~/ 2).clamp(0, w - 1)];
        }
      }
      out.add(RecordedFrame(ms, LumaFrame(bytes: full, width: w0, height: h0, rowStride: w0), true));
    } else {
      final full = Uint8List(w0 * h0)..fillRange(0, w0 * h0, 128);
      for (var yy = 0; yy < h; yy++) {
        full.setRange((y + yy) * w0 + x, (y + yy) * w0 + x + w, px, yy * w);
      }
      out.add(RecordedFrame(ms, LumaFrame(bytes: full, width: w0, height: h0, rowStride: w0), false));
    }
  }
  return out;
}
