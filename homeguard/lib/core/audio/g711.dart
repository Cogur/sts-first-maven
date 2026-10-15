import 'dart:typed_data';

/// G.711 encoders used for the intercom back-channel.
///
/// NVRs, doorbells and indoor monitors that implement the ONVIF audio
/// back-channel almost universally accept 8 kHz mono G.711 (PCMU or PCMA).
/// Input is little-endian signed 16-bit PCM, as delivered by the microphone
/// recorder.
abstract final class G711 {
  static const int _bias = 0x84;
  static const int _clip = 32635;

  /// Encodes one 16-bit linear sample to 8-bit µ-law (PCMU, RTP payload 0).
  static int linearToUlaw(int sample) {
    var s = sample.clamp(-32768, 32767);
    final sign = (s >> 8) & 0x80;
    if (sign != 0) s = -s;
    if (s > _clip) s = _clip;
    s += _bias;
    var exponent = 7;
    for (var mask = 0x4000; (s & mask) == 0 && exponent > 0; mask >>= 1) {
      exponent--;
    }
    final mantissa = (s >> (exponent + 3)) & 0x0F;
    return (~(sign | (exponent << 4) | mantissa)) & 0xFF;
  }

  /// Encodes one 16-bit linear sample to 8-bit A-law (PCMA, RTP payload 8).
  static int linearToAlaw(int sample) {
    var s = sample.clamp(-32768, 32767);
    final sign = s >= 0 ? 0x80 : 0x00;
    if (s < 0) s = -s - 1;
    s >>= 3; // A-law works on 13-bit magnitude.
    int encoded;
    if (s < 32) {
      encoded = s >> 1;
    } else {
      var exponent = 1;
      while (s >= 64 && exponent < 7) {
        s >>= 1;
        exponent++;
      }
      encoded = (exponent << 4) | ((s >> 1) & 0x0F);
    }
    return (encoded | sign) ^ 0x55;
  }

  /// Decodes µ-law back to linear PCM (used by tests and loopback checks).
  static int ulawToLinear(int ulaw) {
    final u = ~ulaw & 0xFF;
    final sign = u & 0x80;
    final exponent = (u >> 4) & 0x07;
    final mantissa = u & 0x0F;
    final magnitude = (((mantissa << 3) + _bias) << exponent) - _bias;
    return sign != 0 ? -magnitude : magnitude;
  }

  /// Converts a block of little-endian PCM16 bytes to G.711.
  static Uint8List encodePcm16(Uint8List pcm, {bool alaw = false}) {
    final samples = pcm.length ~/ 2;
    final view = ByteData.sublistView(pcm);
    final out = Uint8List(samples);
    for (var i = 0; i < samples; i++) {
      final v = view.getInt16(i * 2, Endian.little);
      out[i] = alaw ? linearToAlaw(v) : linearToUlaw(v);
    }
    return out;
  }
}
