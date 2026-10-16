import 'package:flair_log/scale/bookoo_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('commands carry an XOR checksum', () {
    expect(BookooProtocol.tare, [0x03, 0x0A, 0x01, 0x00, 0x00, 0x08]);
    expect(BookooProtocol.startTimer.take(5), [0x03, 0x0A, 0x04, 0x00, 0x00]);
    for (final c in [
      BookooProtocol.tare,
      BookooProtocol.startTimer,
      BookooProtocol.stopTimer,
      BookooProtocol.resetTimer,
      BookooProtocol.tareAndStartTimer,
    ]) {
      expect(c.length, 6);
      expect(BookooProtocol.checksum(c.sublist(0, 5)), c[5]);
    }
  });

  test('parses a weight packet', () {
    // 36.42 g, 1.85 g/s, 82 % battery, 12.345 s on the scale timer
    final p = BookooProtocol.encode(weight: 36.42, flow: 1.85, ms: 12345, battery: 82);
    expect(p.length, 20);
    final r = BookooProtocol.parse(p, strict: true)!;
    expect(r.weight, closeTo(36.42, 1e-9));
    expect(r.flowRate, closeTo(1.85, 1e-9));
    expect(r.battery, 82);
    expect(r.scaleTimeMs, 12345);
  });

  test('negative weight after tare drift', () {
    final r = BookooProtocol.parse(BookooProtocol.encode(weight: -0.3))!;
    expect(r.weight, closeTo(-0.3, 1e-9));
  });

  test('rejects unrelated packets', () {
    expect(BookooProtocol.parse([0x03, 0x0A, 0x01, 0, 0, 8]), isNull);
    expect(BookooProtocol.parse(List.filled(20, 0)), isNull);
    final bad = BookooProtocol.encode(weight: 1)..[19] ^= 0xFF;
    expect(BookooProtocol.parse(bad, strict: true), isNull);
    expect(BookooProtocol.parse(bad), isNotNull); // lenient by default
  });

  test('recognises scale names', () {
    expect(BookooProtocol.matchesName('BOOKOO_SC 1234'), isTrue);
    expect(BookooProtocol.matchesName('bookoo_em'), isTrue);
    expect(BookooProtocol.matchesName('ACAIA'), isFalse);
  });
}
