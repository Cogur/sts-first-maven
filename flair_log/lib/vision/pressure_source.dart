import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'gauge_reader.dart';

class PressureSample {
  const PressureSample({required this.at, this.bar, this.reading});

  final DateTime at;

  /// null when the needle could not be read in this frame.
  final double? bar;
  final GaugeReading? reading;
}

/// Something that produces gauge pressure readings: the camera, or a
/// simulator for demo mode.
abstract class PressureSource extends ChangeNotifier {
  Stream<PressureSample> get samples;

  PressureSample? get latest;

  /// Called when the user arms a new shot (gauge back at rest).
  void prepareForShot();

  /// Called when the shot ends, e.g. to unlock focus.
  void shotFinished() {}

  Future<void> start();
  Future<void> stop();
}

/// Generates a plausible Flair 58 lever profile: pre-infusion, ramp to ~9 bar,
/// slow decline as the lever is pulled down, release.
class SimulatedPressureSource extends PressureSource {
  final _ctrl = StreamController<PressureSample>.broadcast();
  final _rnd = math.Random();
  Timer? _timer;
  DateTime? _t0;
  PressureSample? _latest;

  @override
  Stream<PressureSample> get samples => _ctrl.stream;
  @override
  PressureSample? get latest => _latest;

  @override
  void prepareForShot() =>
      _t0 = DateTime.now().add(const Duration(seconds: 2));

  static double profile(double t) {
    if (t < 0) return 0;
    if (t < 3) return 2.0 * t / 3; // pre-infusion ramp
    if (t < 7) return 2.0; // bloom
    if (t < 10) return 2.0 + (t - 7) / 3 * 7.0; // ramp to 9
    if (t < 18) return 9.0;
    if (t < 30) return 9.0 - (t - 18) / 12 * 3.0; // taper to 6
    if (t < 33) return 6.0 * (1 - (t - 30) / 3);
    return 0;
  }

  @override
  Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(milliseconds: 66), (_) {
      final t0 = _t0;
      final t = t0 == null
          ? -1.0
          : DateTime.now().difference(t0).inMilliseconds / 1000.0;
      var p = profile(t);
      if (p > 0) p += (_rnd.nextDouble() - 0.5) * 0.25;
      _latest = PressureSample(at: DateTime.now(), bar: math.max(0, p));
      _ctrl.add(_latest!);
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    _ctrl.close();
    super.dispose();
  }
}
