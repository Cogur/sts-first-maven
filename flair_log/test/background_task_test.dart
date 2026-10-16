import 'dart:isolate';
import 'dart:math' as math;

import 'package:flair_log/vision/gauge_setup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_gauge.dart';

void main() {
  // Regression: calibration hung on "Looking for the gauge…" because the
  // search was started with Isolate.run(() => ...) from a method whose other
  // closures held a ui.Image; sending the closure failed with "object is
  // unsendable" and the error was never shown.
  test('dial search runs in the background next to unsendable objects', () async {
    final port = ReceivePort(); // stands in for ui.Image / the State
    void unrelated() => port.close();

    final f = renderFlairLike(
        needleAngle: 143 * math.pi / 180, cx: 300, cy: 600, r: 50, width: 720, height: 1280);
    final dials = await GaugeSetup.findDialsInBackground(f);
    expect(dials, isNotEmpty);
    expect(dials.first.cx, closeTo(300, 2));

    final a = await GaugeSetup.analyseInBackground(f, dials.first);
    expect(a.needleFound, isTrue);
    expect(a.restAngle! * 180 / math.pi, closeTo(143, 3));
    unrelated();
  });
}
