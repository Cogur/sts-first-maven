import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/shot.dart';
import '../scale/scale_manager.dart';
import '../storage/settings.dart';
import '../vision/pressure_source.dart';

enum BrewState { idle, armed, recording, done }

/// Combines gauge pressure and scale weight into a time series at 10 Hz and
/// handles automatic start / stop.
class BrewSession extends ChangeNotifier {
  BrewSession({
    required this.pressure,
    required this.scale,
    required this.settings,
  }) {
    _pSub = pressure.samples.listen(_onPressure);
    _wSub = scale.readings.listen((_) => _onWeight());
  }

  final PressureSource pressure;
  final ScaleManager scale;
  final Settings settings;

  static const sampleInterval = Duration(milliseconds: 100);
  static const maxDuration = 180.0;

  BrewState _state = BrewState.idle;
  BrewState get state => _state;

  final List<ShotSample> samples = [];
  DateTime? _t0;
  DateTime? startedAt;
  Timer? _ticker;
  StreamSubscription<PressureSample>? _pSub;
  StreamSubscription<void>? _wSub;

  double? currentPressure;
  double? currentWeight;
  double? currentFlow;
  double elapsed = 0;

  double _peakPressure = 0;
  double _lowSince = -1;
  int _aboveCount = 0;
  DateTime _armedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Called with the finished shot (manual or automatic stop).
  void Function(Shot shot)? onFinished;

  /// Weight history for computing flow when the scale doesn't report it.
  final List<(double, double)> _weightHist = [];

  // ---- live inputs -------------------------------------------------------

  void _onPressure(PressureSample s) {
    currentPressure = s.bar;
    if (_state == BrewState.armed && settings.autoStart) {
      final p = s.bar;
      if (p != null && p >= settings.autoStartPressure) {
        if (++_aboveCount >= 2) start();
      } else {
        _aboveCount = 0;
      }
    }
    if (_state != BrewState.recording) notifyListeners();
  }

  void _onWeight() {
    final r = scale.lastReading;
    if (r == null) return;
    currentWeight = r.weight;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    _weightHist.add((now, r.weight));
    _weightHist.removeWhere((e) => now - e.$1 > 1.5);
    currentFlow = r.flowRate ?? _derivedFlow();
    // Ignore the first moments after arming: the tare takes a little while.
    if (_state == BrewState.armed &&
        settings.autoStart &&
        DateTime.now().difference(_armedAt).inMilliseconds > 1500 &&
        r.weight >= settings.autoStartWeight) {
      start();
    }
    if (_state != BrewState.recording) notifyListeners();
  }

  /// Least-squares slope of the last second of weight readings.
  double? _derivedFlow() {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final pts = _weightHist.where((e) => now - e.$1 <= 1.0).toList();
    if (pts.length < 3) return null;
    final mx = pts.map((e) => e.$1).reduce((a, b) => a + b) / pts.length;
    final my = pts.map((e) => e.$2).reduce((a, b) => a + b) / pts.length;
    var num = 0.0, den = 0.0;
    for (final (x, y) in pts) {
      num += (x - mx) * (y - my);
      den += (x - mx) * (x - mx);
    }
    if (den == 0) return null;
    return math.max(0, num / den);
  }

  // ---- lifecycle ---------------------------------------------------------

  /// Tare, reset the timer and wait for the shot to begin.
  Future<void> arm() async {
    samples.clear();
    elapsed = 0;
    _peakPressure = 0;
    _lowSince = -1;
    _aboveCount = 0;
    pressure.prepareForShot();
    await scale.tare();
    await scale.resetTimer();
    _state = BrewState.armed;
    _armedAt = DateTime.now();
    notifyListeners();
  }

  void start() {
    if (_state == BrewState.recording) return;
    if (_state != BrewState.armed) {
      samples.clear();
      _peakPressure = 0;
      _lowSince = -1;
    }
    _state = BrewState.recording;
    _t0 = DateTime.now();
    startedAt = _t0;
    scale.startTimer();
    _ticker = Timer.periodic(sampleInterval, (_) => _tick());
    _tick();
    notifyListeners();
  }

  void _tick() {
    final t0 = _t0;
    if (t0 == null) return;
    final now = DateTime.now();
    elapsed = now.difference(t0).inMilliseconds / 1000.0;

    final ps = pressure.latest;
    final p = ps != null && now.difference(ps.at).inMilliseconds < 500
        ? ps.bar
        : null;
    final w = scale.freshReading;
    final weight = w?.weight;
    final flow = w == null ? null : (w.flowRate ?? _derivedFlow());
    currentPressure = p;
    currentWeight = weight ?? currentWeight;
    currentFlow = flow;

    samples.add(ShotSample(t: elapsed, pressure: p, weight: weight, flow: flow));

    if (p != null) {
      _peakPressure = math.max(_peakPressure, p);
      if (settings.autoStop && _peakPressure > 2.0) {
        if (p < 0.3) {
          if (_lowSince < 0) _lowSince = elapsed;
          if (elapsed - _lowSince > 3.0) {
            stop();
            return;
          }
        } else {
          _lowSince = -1;
        }
      }
    }
    final target = settings.targetYield;
    if (target > 0 && weight != null && weight >= target) {
      stop();
      return;
    }
    if (elapsed > maxDuration) {
      stop();
      return;
    }
    notifyListeners();
  }

  /// Ends the shot and returns it (null if nothing was recorded).
  Shot? stop() {
    if (_state != BrewState.recording) {
      _state = BrewState.idle;
      notifyListeners();
      return null;
    }
    _ticker?.cancel();
    _ticker = null;
    scale.stopTimer();
    pressure.shotFinished();
    _state = BrewState.done;

    // Trim the trailing "pressure released, waiting for auto-stop" tail.
    if (_lowSince > 0) {
      samples.removeWhere((s) => s.t > _lowSince + 0.5);
    }
    final shot = samples.length < 10
        ? null
        : Shot(
            id: startedAt!.millisecondsSinceEpoch.toString(),
            startedAt: startedAt!,
            samples: List.of(samples),
            dose: settings.lastDose,
          );
    _lastShot = shot;
    notifyListeners();
    if (shot != null) onFinished?.call(shot);
    return shot;
  }

  Shot? _lastShot;
  Shot? get lastShot => _lastShot;

  void reset() {
    _state = BrewState.idle;
    samples.clear();
    elapsed = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pSub?.cancel();
    _wSub?.cancel();
    super.dispose();
  }
}
