import 'dart:async';

import 'package:flair_log/brew/brew_session.dart';
import 'package:flair_log/models/shot.dart';
import 'package:flair_log/scale/scale_manager.dart';
import 'package:flair_log/storage/settings.dart';
import 'package:flair_log/vision/pressure_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePressure extends PressureSource {
  final _c = StreamController<PressureSample>.broadcast();
  PressureSample? _latest;
  bool prepared = false;

  void emit(double? bar) {
    _latest = PressureSample(at: DateTime.now(), bar: bar);
    _c.add(_latest!);
  }

  @override
  Stream<PressureSample> get samples => _c.stream;
  @override
  PressureSample? get latest => _latest;
  @override
  void prepareForShot() => prepared = true;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  late Settings settings;
  late FakePressure pressure;
  late BrewSession session;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    pressure = FakePressure();
    session = BrewSession(
        pressure: pressure, scale: ScaleManager(settings), settings: settings);
  });

  tearDown(() => session.dispose());

  Future<void> feed(double bar, int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end)) {
      pressure.emit(bar);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('auto-starts on pressure and auto-stops after release', () async {
    Shot? finished;
    session.onFinished = (s) => finished = s;
    await session.arm();
    expect(session.state, BrewState.armed);
    expect(pressure.prepared, isTrue);

    await feed(0.1, 300);
    expect(session.state, BrewState.armed, reason: 'below threshold');

    await feed(3.0, 600);
    expect(session.state, BrewState.recording);
    await feed(9.0, 800);
    await feed(0.0, 3500); // released: auto stop after 3 s
    expect(session.state, BrewState.done);
    expect(finished, isNotNull);
    final shot = finished!;
    expect(shot.peakPressure, closeTo(9.0, 1e-9));
    // trailing zero-pressure tail is trimmed to ~0.5 s
    expect(shot.duration, lessThan(2.4));
    expect(shot.hasWeight, isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('manual start / stop without auto start', () async {
    settings.autoStart = false;
    await session.arm();
    await feed(5.0, 300);
    expect(session.state, BrewState.armed);
    session.start();
    await feed(5.0, 1200);
    final shot = session.stop();
    expect(shot, isNotNull);
    expect(shot!.samples.length, greaterThanOrEqualTo(10));
    expect(shot.meanPressure, closeTo(5.0, 1e-9));
  });

  test('shot json round trip', () {
    final s = Shot(
      id: '1',
      startedAt: DateTime(2026, 10, 16, 8, 30),
      dose: 18,
      beans: 'Ethiopia',
      samples: const [
        ShotSample(t: 0, pressure: 0.5),
        ShotSample(t: 0.1, pressure: 2.0, weight: 0.4, flow: 0.2),
      ],
    );
    final back = Shot.fromJson(s.toJson());
    expect(back.beans, 'Ethiopia');
    expect(back.samples[1].weight, 0.4);
    expect(back.ratio, closeTo(0.4 / 18, 1e-9));
    expect(s.toCsv().split('\n')[2], '0.10,2.00,0.4,0.20');
  });
}
