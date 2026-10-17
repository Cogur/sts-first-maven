import 'dart:io';
import 'dart:typed_data';

import 'dial_geometry.dart';
import 'luma_frame.dart';

/// Records what the camera saw during a shot, so a failure on a real phone
/// can be replayed in a test (see test/support/recording.dart and
/// docs/gauge-reading.md).
///
/// File format (little endian), `.flr`:
/// - magic `FLR1`, u16 upright width, u16 upright height
/// - records: u8 type, u32 time ms since start, u16 x, u16 y, u16 w, u16 h,
///   u32 length, zlib-compressed greyscale pixels.
///   type 1: full-resolution crop at (x, y) of size w×h (the gauge region);
///   type 2: whole frame at half resolution (x = y = 0, w×h = half size),
///   at the start and then with every 8th kept frame (about once a second).
///
/// The crop region is fixed when the shot starts: around the gauge, extended
/// downwards because the gauge travels down with the piston. A fixed region
/// keeps the gauge in the recording even when tracking fails; the whole
/// views show where it went when the phone itself moved.
class DiagnosticRecorder {
  DiagnosticRecorder._(this.file, this._raf, this._x, this._y, this._w, this._h);

  /// Starts a recording next to the gauge [face] (null: centre of the frame).
  static Future<DiagnosticRecorder> start(
      String path, LumaFrame first, DialGeometry? face) async {
    final w0 = first.uprightWidth, h0 = first.uprightHeight;
    final r = face?.radius ?? w0 / 8;
    final cx = face?.cx ?? w0 / 2, cy = face?.cy ?? h0 / 2;
    final x = (cx - 2.2 * r).clamp(0, w0 - 1).toInt();
    final y = (cy - 2.0 * r).clamp(0, h0 - 1).toInt();
    final w = (4.4 * r).clamp(16, w0 - x).toInt();
    final h = (7.5 * r).clamp(16, h0 - y).toInt();
    final file = File(path);
    final raf = await file.open(mode: FileMode.write);
    final head = ByteData(8)
      ..setUint8(0, 0x46)
      ..setUint8(1, 0x4C)
      ..setUint8(2, 0x52)
      ..setUint8(3, 0x31)
      ..setUint16(4, w0, Endian.little)
      ..setUint16(6, h0, Endian.little);
    raf.writeFromSync(head.buffer.asUint8List());
    final rec = DiagnosticRecorder._(file, raf, x, y, w, h);
    rec._started = DateTime.now();
    rec._write(2, first, 0, 0, w0 ~/ 2, h0 ~/ 2, half: true);
    return rec;
  }

  final File file;
  final RandomAccessFile _raf;
  final int _x, _y, _w, _h;
  late DateTime _started;
  int frames = 0;
  bool _closed = false;
  int _skip = 0;

  static const int maxFrames = 420; // ~60 s at 7 fps

  /// Adds a frame (every second one is kept).
  void add(LumaFrame f) {
    if (_closed || frames >= maxFrames) return;
    final keep = _skip.isEven;
    _skip++;
    if (!keep) return;
    if (frames > 0 && frames % 8 == 0) {
      _write(2, f, 0, 0, f.uprightWidth ~/ 2, f.uprightHeight ~/ 2, half: true);
    }
    _write(1, f, _x, _y, _w, _h);
    frames++;
  }

  void _write(int type, LumaFrame f, int x, int y, int w, int h, {bool half = false}) {
    final px = Uint8List(w * h);
    var i = 0;
    for (var yy = 0; yy < h; yy++) {
      for (var xx = 0; xx < w; xx++) {
        final v = half ? f.at(xx * 2, yy * 2) : f.at(x + xx, y + yy);
        px[i++] = v < 0 ? 0 : v;
      }
    }
    final z = ZLibCodec(level: 1).encode(px);
    final head = ByteData(17)
      ..setUint8(0, type)
      ..setUint32(1, DateTime.now().difference(_started).inMilliseconds, Endian.little)
      ..setUint16(5, x, Endian.little)
      ..setUint16(7, y, Endian.little)
      ..setUint16(9, w, Endian.little)
      ..setUint16(11, h, Endian.little)
      ..setUint32(13, z.length, Endian.little);
    _raf.writeFromSync(head.buffer.asUint8List());
    _raf.writeFromSync(z);
  }

  Future<File> close() async {
    if (!_closed) {
      _closed = true;
      await _raf.close();
    }
    return file;
  }
}
