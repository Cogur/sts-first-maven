import 'dart:typed_data';

/// A single greyscale (luma / Y-plane) camera frame.
///
/// Camera sensors usually deliver frames rotated relative to how the phone is
/// held. All analysis code works in *upright* coordinates (what the user sees
/// in portrait), and [at] maps those back into the raw buffer using
/// [quarterTurns] — the number of clockwise 90° turns needed to make the raw
/// buffer upright.
class LumaFrame {
  LumaFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rowStride,
    this.quarterTurns = 0,
  }) : assert(quarterTurns >= 0 && quarterTurns < 4);

  /// Raw Y plane.
  final Uint8List bytes;

  /// Raw buffer dimensions (sensor orientation).
  final int width;
  final int height;
  final int rowStride;

  /// Clockwise quarter turns from raw buffer to upright.
  final int quarterTurns;

  int get uprightWidth => quarterTurns.isOdd ? height : width;
  int get uprightHeight => quarterTurns.isOdd ? width : height;

  /// Luma at upright pixel coordinate ([ux], [uy]), or -1 when out of bounds.
  int at(int ux, int uy) {
    int rx, ry;
    switch (quarterTurns) {
      case 0:
        rx = ux;
        ry = uy;
      case 1:
        rx = uy;
        ry = height - 1 - ux;
      case 2:
        rx = width - 1 - ux;
        ry = height - 1 - uy;
      default:
        rx = width - 1 - uy;
        ry = ux;
    }
    if (rx < 0 || ry < 0 || rx >= width || ry >= height) return -1;
    return bytes[ry * rowStride + rx];
  }

  /// Nearest-neighbour sample at a fractional upright coordinate.
  int sample(double ux, double uy) => at(ux.round(), uy.round());

  /// A deep copy (camera plugins reuse their buffers between frames).
  LumaFrame copy() => LumaFrame(
        bytes: Uint8List.fromList(bytes),
        width: width,
        height: height,
        rowStride: rowStride,
        quarterTurns: quarterTurns,
      );

  /// Renders a region of the upright frame into an RGBA buffer of
  /// [outW] x [outH] pixels (used for calibration stills and the live zoom).
  /// [left], [top], [size] are in upright pixels; the region is square.
  Uint8List toRgba({
    required double left,
    required double top,
    required double regionW,
    required double regionH,
    required int outW,
    required int outH,
  }) {
    final out = Uint8List(outW * outH * 4);
    final sx = regionW / outW;
    final sy = regionH / outH;
    var i = 0;
    for (var y = 0; y < outH; y++) {
      final uy = (top + (y + 0.5) * sy).floor();
      for (var x = 0; x < outW; x++) {
        final ux = (left + (x + 0.5) * sx).floor();
        final v = at(ux, uy);
        final g = v < 0 ? 0 : v;
        out[i++] = g;
        out[i++] = g;
        out[i++] = g;
        out[i++] = 255;
      }
    }
    return out;
  }
}
