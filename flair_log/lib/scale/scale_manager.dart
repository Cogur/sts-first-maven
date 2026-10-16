import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../storage/settings.dart';
import 'bookoo_protocol.dart';
import 'bookoo_scale.dart';
import 'scale.dart';
import 'simulated_scale.dart';

/// Owns the active scale: scanning, connecting, reconnecting, latest reading.
class ScaleManager extends ChangeNotifier {
  ScaleManager(this.settings);

  final Settings settings;

  Scale? _scale;
  Scale? get scale => _scale;

  ScaleConnectionState _state = ScaleConnectionState.disconnected;
  ScaleConnectionState get state => _state;
  bool get isConnected => _state == ScaleConnectionState.connected;

  ScaleReading? _last;
  ScaleReading? get lastReading => _last;
  DateTime? _lastAt;

  /// Latest weight if it is fresh (< 1 s old).
  ScaleReading? get freshReading =>
      _lastAt != null && DateTime.now().difference(_lastAt!).inMilliseconds < 1000
          ? _last
          : null;

  String? error;

  final _readings = StreamController<ScaleReading>.broadcast();
  Stream<ScaleReading> get readings => _readings.stream;

  StreamSubscription<ScaleReading>? _readSub;
  StreamSubscription<ScaleConnectionState>? _stateSub;
  bool _userDisconnected = false;

  // ---- scanning ----------------------------------------------------------

  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  Future<void> startScan() async {
    error = null;
    try {
      if (!await FlutterBluePlus.isSupported) {
        error = 'Bluetooth LE is not supported on this device';
        notifyListeners();
        return;
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      error = 'Scan failed: $e';
      notifyListeners();
    }
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  static bool isSupportedResult(ScanResult r) {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return BookooProtocol.matchesName(name) ||
        r.advertisementData.serviceUuids.any(
            (u) => u.str128.toLowerCase() == BookooProtocol.serviceUuid);
  }

  // ---- connecting --------------------------------------------------------

  Future<void> connectDevice(BluetoothDevice device) async {
    await stopScan();
    await _use(BookooScale(device));
  }

  Future<void> connectDemo() => _use(SimulatedScale());

  /// Reconnects to the last used scale, if any (called at start-up and when
  /// opening the brew screen).
  Future<void> reconnectLast() async {
    if (isConnected || _state == ScaleConnectionState.connecting) return;
    if (settings.demoMode) {
      await connectDemo();
      return;
    }
    final id = settings.lastScaleId;
    if (id == null || id == 'demo-scale') return;
    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return;
      await _use(BookooScale(BluetoothDevice.fromId(id)), remember: false);
    } catch (_) {/* stays disconnected; user can connect manually */}
  }

  Future<void> _use(Scale s, {bool remember = true}) async {
    await _teardown();
    _userDisconnected = false;
    _scale = s;
    error = null;
    _stateSub = s.connectionState.listen((st) {
      _state = st;
      notifyListeners();
      if (st == ScaleConnectionState.disconnected &&
          !_userDisconnected &&
          identical(_scale, s)) {
        _scheduleReconnect(s);
      }
    });
    _readSub = s.readings.listen((r) {
      _last = r;
      _lastAt = DateTime.now();
      _readings.add(r);
      notifyListeners();
    });
    try {
      await s.connect();
      if (remember) settings.lastScaleId = s.id;
    } catch (e) {
      error = 'Could not connect to ${s.name}: $e';
      notifyListeners();
    }
  }

  Timer? _reconnectTimer;
  void _scheduleReconnect(Scale s) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (!identical(_scale, s) || _userDisconnected || isConnected) return;
      try {
        await s.connect();
      } catch (_) {}
    });
  }

  Future<void> disconnect({bool forget = false}) async {
    _userDisconnected = true;
    await _teardown();
    if (forget) settings.lastScaleId = null;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _reconnectTimer?.cancel();
    await _readSub?.cancel();
    await _stateSub?.cancel();
    _readSub = null;
    _stateSub = null;
    final old = _scale;
    _scale = null;
    _last = null;
    _state = ScaleConnectionState.disconnected;
    if (old != null) {
      _userDisconnected = true;
      await old.disconnect();
    }
  }

  Future<void> tare() async => _scale?.tare();
  Future<void> startTimer() async => _scale?.startTimer();
  Future<void> stopTimer() async => _scale?.stopTimer();
  Future<void> resetTimer() async => _scale?.resetTimer();
}
