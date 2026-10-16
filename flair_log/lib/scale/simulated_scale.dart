import 'dart:async';
import 'dart:math' as math;

import 'scale.dart';

/// A fake scale for trying the app without hardware. Weight starts rising a
/// few seconds after the timer is started, like espresso dripping into a cup.
class SimulatedScale implements Scale {
  final _readings = StreamController<ScaleReading>.broadcast();
  final _state = StreamController<ScaleConnectionState>.broadcast();
  final _rnd = math.Random();
  Timer? _timer;
  double _weight = 0;
  double _offset = 0;
  DateTime? _started;

  @override
  String get name => 'Demo scale';
  @override
  String get id => 'demo-scale';
  @override
  Stream<ScaleReading> get readings => _readings.stream;
  @override
  Stream<ScaleConnectionState> get connectionState => _state.stream;

  @override
  Future<void> connect() async {
    _state.add(ScaleConnectionState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _offset = 210 + _rnd.nextDouble() * 20; // a cup on the scale
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    _state.add(ScaleConnectionState.connected);
  }

  void _tick() {
    var flow = 0.0;
    final s = _started;
    if (s != null) {
      final t = DateTime.now().difference(s).inMilliseconds / 1000.0;
      // First drops after ~8 s, ramps to ~2 g/s, tails off after 30 s.
      if (t > 8 && t < 40) {
        flow = 2.0 * (1 - math.exp(-(t - 8) / 3)) * (t > 30 ? math.exp(-(t - 30) / 3) : 1);
      }
    }
    _weight += flow * 0.1;
    final noise = (_rnd.nextDouble() - 0.5) * 0.08;
    _readings.add(ScaleReading(
      weight: double.parse((_weight + _offset + noise).toStringAsFixed(1)),
      flowRate: flow,
      battery: 87,
    ));
  }

  @override
  Future<void> tare() async {
    _offset = 0;
    _weight = 0;
  }

  @override
  Future<void> startTimer() async => _started = DateTime.now();
  @override
  Future<void> stopTimer() async => _started = null;
  @override
  Future<void> resetTimer() async => _started = null;

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _state.add(ScaleConnectionState.disconnected);
  }
}
