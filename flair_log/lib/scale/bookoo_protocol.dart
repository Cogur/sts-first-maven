import 'scale.dart';

/// BOOKOO Themis (Mini / Ultra) BLE protocol, as published by BOOKOO at
/// github.com/BooKooCode/OpenSource (bookoo_mini_scale/protocols.md).
///
/// - Service 0x0FFE
/// - 0xFF11: weight notifications (20 bytes)
/// - 0xFF12: commands (6 bytes)
/// Every packet ends with an XOR checksum of all preceding bytes.
class BookooProtocol {
  static const serviceUuid = '00000ffe-0000-1000-8000-00805f9b34fb';
  static const weightCharUuid = '0000ff11-0000-1000-8000-00805f9b34fb';
  static const commandCharUuid = '0000ff12-0000-1000-8000-00805f9b34fb';

  static const _product = 0x03;
  static const _typeWeight = 0x0B;
  static const _typeCommand = 0x0A;

  static int checksum(List<int> bytes) =>
      bytes.fold(0, (acc, b) => acc ^ (b & 0xFF));

  static List<int> command(int data1, [int data2 = 0, int data3 = 0]) {
    final p = [_product, _typeCommand, data1, data2, data3];
    return [...p, checksum(p)];
  }

  static final tare = command(0x01);
  static final startTimer = command(0x04);
  static final stopTimer = command(0x05);
  static final resetTimer = command(0x06);
  static final tareAndStartTimer = command(0x07);
  static List<int> beepLevel(int level) => command(0x02, 0, level.clamp(0, 5));
  static List<int> flowSmoothing(bool on) => command(0x08, on ? 1 : 0, 0);

  /// Whether a scan result name looks like a BOOKOO scale.
  static bool matchesName(String name) =>
      name.toUpperCase().startsWith('BOOKOO');

  /// Parses a weight notification; returns null for anything else.
  ///
  /// With [strict] the checksum must match. It is off by default because
  /// firmware revisions are not guaranteed to follow the document exactly,
  /// and the header check already rejects unrelated packets.
  static ScaleReading? parse(List<int> p, {bool strict = false}) {
    if (p.length < 20 || p[0] != _product || p[1] != _typeWeight) return null;
    if (strict && checksum(p.sublist(0, 19)) != p[19]) return null;

    int u24(int i) => (p[i] << 16) | (p[i + 1] << 8) | p[i + 2];
    int u16(int i) => (p[i] << 8) | p[i + 1];
    // The doc says "+/-" without giving codes; the scale sends ASCII '-'
    // (0x2D) for negative. Accept 0x01 as well to be safe.
    bool negative(int b) => b == 0x2D || b == 0x01;

    final ms = u24(2);
    final weight = u24(7) / 100.0 * (negative(p[6]) ? -1 : 1);
    final flow = u16(11) / 100.0 * (negative(p[10]) ? -1 : 1);
    return ScaleReading(
      weight: weight,
      flowRate: flow,
      battery: p[13],
      scaleTimeMs: ms,
    );
  }

  /// Builds a weight packet (used by tests and the simulator).
  static List<int> encode({
    required double weight,
    double flow = 0,
    int ms = 0,
    int battery = 100,
  }) {
    final w = (weight.abs() * 100).round();
    final fl = (flow.abs() * 100).round();
    final p = <int>[
      _product, _typeWeight,
      (ms >> 16) & 0xFF, (ms >> 8) & 0xFF, ms & 0xFF,
      0x00, // unit: grams
      weight < 0 ? 0x2D : 0x2B,
      (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
      flow < 0 ? 0x2D : 0x2B,
      (fl >> 8) & 0xFF, fl & 0xFF,
      battery,
      0x00, 0x32, // standby
      0x01, // buzzer
      0x00, // smoothing
      0x00, // reserved
    ];
    return [...p, checksum(p)];
  }
}
