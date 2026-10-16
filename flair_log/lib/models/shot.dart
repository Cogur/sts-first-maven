import 'dart:math' as math;

/// One time-aligned sample of a shot. Any channel can be missing (no scale
/// connected, needle not readable in that frame, ...).
class ShotSample {
  const ShotSample({required this.t, this.pressure, this.weight, this.flow});

  /// Seconds since the shot started.
  final double t;

  /// bar
  final double? pressure;

  /// grams in the cup
  final double? weight;

  /// g/s
  final double? flow;

  Map<String, dynamic> toJson() => {
        't': _r(t, 2),
        if (pressure != null) 'p': _r(pressure!, 2),
        if (weight != null) 'w': _r(weight!, 1),
        if (flow != null) 'f': _r(flow!, 2),
      };

  factory ShotSample.fromJson(Map<String, dynamic> j) => ShotSample(
        t: (j['t'] as num).toDouble(),
        pressure: (j['p'] as num?)?.toDouble(),
        weight: (j['w'] as num?)?.toDouble(),
        flow: (j['f'] as num?)?.toDouble(),
      );

  static double _r(double v, int d) {
    final m = math.pow(10, d);
    return (v * m).round() / m;
  }
}

class Shot {
  Shot({
    required this.id,
    required this.startedAt,
    required this.samples,
    this.dose,
    this.beans = '',
    this.grind = '',
    this.notes = '',
    this.rating = 0,
  });

  final String id;
  final DateTime startedAt;
  final List<ShotSample> samples;
  double? dose;
  String beans;
  String grind;
  String notes;
  int rating;

  double get duration => samples.isEmpty ? 0 : samples.last.t;

  double? get yieldWeight {
    for (final s in samples.reversed) {
      if (s.weight != null) return s.weight;
    }
    return null;
  }

  double? get peakPressure {
    final p = samples.map((s) => s.pressure).whereType<double>();
    return p.isEmpty ? null : p.reduce(math.max);
  }

  /// Mean pressure while the shot was actually under pressure (> 1 bar).
  double? get meanPressure {
    final p = samples
        .map((s) => s.pressure)
        .whereType<double>()
        .where((p) => p > 1)
        .toList();
    return p.isEmpty ? null : p.reduce((a, b) => a + b) / p.length;
  }

  /// Seconds until the first ~0.3 g reached the cup.
  double? get timeToFirstDrop {
    for (final s in samples) {
      if ((s.weight ?? 0) >= 0.3) return s.t;
    }
    return null;
  }

  double? get ratio {
    final y = yieldWeight, d = dose;
    if (y == null || d == null || d <= 0) return null;
    return y / d;
  }

  bool get hasPressure => samples.any((s) => s.pressure != null);
  bool get hasWeight => samples.any((s) => s.weight != null);
  bool get hasFlow => samples.any((s) => s.flow != null);

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        if (dose != null) 'dose': dose,
        'beans': beans,
        'grind': grind,
        'notes': notes,
        'rating': rating,
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  factory Shot.fromJson(Map<String, dynamic> j) => Shot(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        dose: (j['dose'] as num?)?.toDouble(),
        beans: j['beans'] as String? ?? '',
        grind: j['grind'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        samples: (j['samples'] as List)
            .map((e) => ShotSample.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  String toCsv() {
    final b = StringBuffer('time_s,pressure_bar,weight_g,flow_g_per_s\n');
    String f(double? v, int d) => v == null ? '' : v.toStringAsFixed(d);
    for (final s in samples) {
      b.writeln('${f(s.t, 2)},${f(s.pressure, 2)},${f(s.weight, 1)},${f(s.flow, 2)}');
    }
    return b.toString();
  }
}
