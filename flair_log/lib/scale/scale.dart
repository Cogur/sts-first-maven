import 'dart:async';

/// One weight update from a scale.
class ScaleReading {
  const ScaleReading({
    required this.weight,
    this.flowRate,
    this.battery,
    this.scaleTimeMs,
  });

  /// Grams.
  final double weight;

  /// g/s as reported by the scale, if it reports it.
  final double? flowRate;

  /// Battery percent, if reported.
  final int? battery;

  /// Scale's own timer, if reported.
  final int? scaleTimeMs;
}

enum ScaleConnectionState { disconnected, connecting, connected }

/// A connected (or connecting) smart scale. Implement this to add support for
/// another brand.
abstract class Scale {
  String get name;
  String get id;

  Stream<ScaleReading> get readings;
  Stream<ScaleConnectionState> get connectionState;

  Future<void> connect();
  Future<void> disconnect();

  Future<void> tare();
  Future<void> startTimer();
  Future<void> stopTimer();
  Future<void> resetTimer();
}
