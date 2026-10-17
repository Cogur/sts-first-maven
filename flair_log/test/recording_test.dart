import 'dart:io';
import 'dart:math' as math;

import 'package:flair_log/vision/diagnostic_recorder.dart';
import 'package:flair_log/vision/gauge_reader.dart';
import 'package:flair_log/vision/gauge_setup.dart';
import 'package:flair_log/vision/luma_frame.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/jpeg.dart';
import 'support/recording.dart';

void main() {
  test('a recorded shot replays through the reader', () async {
    final f = loadJpeg('test/fixtures/machine_2.jpg');
    final a = GaugeSetup.analyse(f, GaugeSetup.findDials(f).first);
    final sweep = 177 * math.pi / 180;
    final cal = GaugeSetup.build(
        frame: f, analysis: a, zeroAngle: a.restAngle!,
        markAngle: a.restAngle! + sweep, markValue: 10);

    // A simulated shot: needle rises to 9 bar while the gauge moves down.
    LumaFrame frame(int i) {
      final bar = math.min(9.0, i * 0.5);
      final moved = moveNeedle(f, a.pivotX, a.pivotY, a.face.radius, a.restAngle!,
          a.restAngle! + bar / 10 * sweep);
      return shiftedFrame(moved, i * 3);
    }

    final dir = Directory.systemTemp.createTempSync('flr');
    final rec = await DiagnosticRecorder.start('${dir.path}/t.flr', f,
        cal.face(f.uprightWidth, f.uprightHeight));
    for (var i = 0; i < 40; i++) {
      rec.add(frame(i));
    }
    final file = await rec.close();
    expect(file.lengthSync(), lessThan(8 * 1024 * 1024));

    final frames = loadRecording(file.path);
    expect(frames.first.overview, isTrue);
    expect(frames.where((r) => r.overview).length, 3); // start + about once a second
    expect(frames.where((r) => !r.overview).length, 20); // every 2nd frame

    final reader = GaugeReader(cal);
    var i = 0;
    for (final r in frames.where((r) => !r.overview)) {
      final expected = math.min(9.0, (i * 2) * 0.5);
      final g = reader.read(r.frame)!;
      expect(g.tracked, isTrue, reason: 'frame $i');
      expect(g.value, closeTo(expected, 0.3), reason: 'frame $i');
      i++;
    }
  });
}
