import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../vision/gauge_calibration.dart';

/// App settings persisted with shared_preferences.
class Settings extends ChangeNotifier {
  Settings._(this._prefs);

  static Future<Settings> load() async =>
      Settings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  GaugeCalibration? get calibration {
    final s = _prefs.getString('calibration');
    if (s == null) return null;
    try {
      return GaugeCalibration.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  set calibration(GaugeCalibration? c) {
    if (c == null) {
      _prefs.remove('calibration');
    } else {
      _prefs.setString('calibration', jsonEncode(c.toJson()));
    }
    notifyListeners();
  }

  String? get lastScaleId => _prefs.getString('lastScaleId');
  set lastScaleId(String? v) {
    v == null ? _prefs.remove('lastScaleId') : _prefs.setString('lastScaleId', v);
    notifyListeners();
  }

  bool get demoMode => _prefs.getBool('demoMode') ?? false;
  set demoMode(bool v) => _set('demoMode', v);

  /// Start recording automatically once pressure rises above this (bar).
  bool get autoStart => _prefs.getBool('autoStart') ?? true;
  set autoStart(bool v) => _set('autoStart', v);

  double get autoStartPressure => _prefs.getDouble('autoStartPressure') ?? 0.5;
  set autoStartPressure(double v) => _set('autoStartPressure', v);

  /// Also start when the scale shows this many grams in the cup.
  double get autoStartWeight => _prefs.getDouble('autoStartWeight') ?? 0.5;
  set autoStartWeight(double v) => _set('autoStartWeight', v);

  /// Stop automatically when pressure falls back to ~0 after the shot.
  bool get autoStop => _prefs.getBool('autoStop') ?? true;
  set autoStop(bool v) => _set('autoStop', v);

  /// Stop automatically when the cup reaches this weight (0 = off).
  double get targetYield => _prefs.getDouble('targetYield') ?? 0;
  set targetYield(double v) => _set('targetYield', v);

  double get lastDose => _prefs.getDouble('lastDose') ?? 18;
  set lastDose(double v) => _set('lastDose', v);

  void _set(String k, Object v) {
    switch (v) {
      case bool b:
        _prefs.setBool(k, b);
      case double d:
        _prefs.setDouble(k, d);
      case String s:
        _prefs.setString(k, s);
    }
    notifyListeners();
  }
}
