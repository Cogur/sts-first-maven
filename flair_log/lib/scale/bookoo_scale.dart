import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'bookoo_protocol.dart';
import 'scale.dart';

/// BOOKOO Themis Mini / Ultra over Bluetooth LE.
class BookooScale implements Scale {
  BookooScale(this.device);

  final BluetoothDevice device;

  final _readings = StreamController<ScaleReading>.broadcast();
  final _state = StreamController<ScaleConnectionState>.broadcast();
  BluetoothCharacteristic? _command;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  @override
  String get name =>
      device.platformName.isNotEmpty ? device.platformName : device.advName;

  @override
  String get id => device.remoteId.str;

  @override
  Stream<ScaleReading> get readings => _readings.stream;

  @override
  Stream<ScaleConnectionState> get connectionState => _state.stream;

  @override
  Future<void> connect() async {
    _state.add(ScaleConnectionState.connecting);
    try {
      // Personal use falls under the FlutterBluePlus nonprofit license; a
      // commercial release would need a commercial license.
      await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 15),
          mtu: null);
      _connSub ??= device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _state.add(ScaleConnectionState.disconnected);
        }
      });

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid.str128.toLowerCase() == BookooProtocol.serviceUuid,
        orElse: () => throw StateError('Not a BOOKOO scale (no 0x0FFE service)'),
      );
      BluetoothCharacteristic? weight;
      for (final c in service.characteristics) {
        final u = c.uuid.str128.toLowerCase();
        if (u == BookooProtocol.weightCharUuid) weight = c;
        if (u == BookooProtocol.commandCharUuid) _command = c;
      }
      if (weight == null) throw StateError('Weight characteristic missing');

      await _notifySub?.cancel();
      _notifySub = weight.onValueReceived.listen((data) {
        final r = BookooProtocol.parse(data);
        if (r != null) _readings.add(r);
      });
      device.cancelWhenDisconnected(_notifySub!);
      await weight.setNotifyValue(true);
      _state.add(ScaleConnectionState.connected);
    } catch (e) {
      debugPrint('Bookoo connect failed: $e');
      _state.add(ScaleConnectionState.disconnected);
      try {
        await device.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _send(List<int> cmd) async {
    final c = _command;
    if (c == null) return;
    try {
      await c.write(cmd,
          withoutResponse: c.properties.writeWithoutResponse &&
              !c.properties.write);
    } catch (e) {
      debugPrint('Bookoo write failed: $e');
    }
  }

  @override
  Future<void> tare() => _send(BookooProtocol.tare);
  @override
  Future<void> startTimer() => _send(BookooProtocol.startTimer);
  @override
  Future<void> stopTimer() => _send(BookooProtocol.stopTimer);
  @override
  Future<void> resetTimer() => _send(BookooProtocol.resetTimer);

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _command = null;
    try {
      await device.disconnect();
    } catch (_) {}
    _state.add(ScaleConnectionState.disconnected);
  }
}
