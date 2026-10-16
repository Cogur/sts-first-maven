// End-to-end checks against the device simulator in tools/simulator.
// Skipped unless HOMEGUARD_SIM_HOST is set, e.g.:
//   HOMEGUARD_SIM_HOST=127.0.0.1 flutter test test/simulator_test.dart
@Tags(['simulator'])
library;

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/device.dart';
import 'package:homeguard/core/models/security_event.dart';
import 'package:homeguard/core/network/connection_manager.dart';
import 'package:homeguard/core/network/device_http_client.dart';
import 'package:homeguard/core/rtsp/rtsp_client.dart';
import 'package:homeguard/core/security/biometric_service.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/services/device_registry.dart';
import 'package:homeguard/core/services/door_relay_service.dart';
import 'package:homeguard/core/services/event_store.dart';
import 'package:homeguard/core/services/monitor_sync_service.dart';
import 'package:homeguard/features/auth/auth_controller.dart';

class _NoBiometrics extends BiometricService {
  @override
  Future<bool> isAvailable() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final host = Platform.environment['HOMEGUARD_SIM_HOST'];
  final skip = host == null ? 'set HOMEGUARD_SIM_HOST to run against the simulator' : null;

  late DeviceRegistry registry;
  late ConnectionManager cm;
  late EventStore events;
  late AuthController auth;
  late Directory tmp;
  late DeviceHttpClient http;

  setUp(() async {
    // Real TCP probes and RTSP; only storage is mocked. These run on the host
    // network, so bypass the widget-test HTTP override.
    HttpOverrides.global = null;
    http = DeviceHttpClient();
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureStore(const FlutterSecureStorage());
    cm = ConnectionManager(connectivity: const Stream<List<ConnectivityResult>>.empty());
    registry = DeviceRegistry(store, cm);
    tmp = await Directory.systemTemp.createTemp('hg_sim');
    events = EventStore(root: () async => tmp);
    await events.load();
    auth = AuthController(store: store, biometrics: _NoBiometrics(), registry: registry, connections: cm);
    await auth.init();
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<void> signIn(String password) => auth.signIn(
    host: '$host:8554',
    username: 'admin',
    password: password,
    remember: false,
    enableBiometrics: false,
    cameraPathTemplate: '/cam{channel}_{stream}',
  );

  test('login verifies digest credentials against the simulated NVR', () async {
    await expectLater(
      signIn('wrong'),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', 'Invalid username or password')),
    );
    await signIn('admin123');
    expect(auth.status, AuthStatus.authenticated);
    expect(cm.cached('cam2')!.kind, RouteKind.lan);
    expect(registry.byId('cam3')!.rtspPath(StreamQuality.main), '/cam3_main');
  }, skip: skip);

  test(
    'all camera and door streams answer with H.264',
    () async {
      for (final path in ['/cam1_sub', '/cam2_sub', '/cam3_sub', '/door_main']) {
        final r = await RtspClient.probe(
          uri: Uri.parse('rtsp://$host:8554$path'),
          username: 'admin',
          password: 'admin123',
          timeout: const Duration(seconds: 15),
        );
        expect(r.videoCodec, 'H264', reason: path);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('door unlock and monitor sync work with digest auth', () async {
    await signIn('admin123');
    await registry.upsert(
      registry
          .byId('door')!
          .copyWith(
            lanHost: host,
            rtspPort: 8554,
            httpPort: 8080,
            rtspPathTemplate: '/door_{stream}',
            unlockPath: '/cgi-bin/accessControl.cgi?action=openDoor&channel=1',
          ),
    );
    await registry.upsert(
      registry.byId('monitor')!.copyWith(lanHost: host, httpPort: 8081, eventIndexPath: '/sdcard/snapshot/'),
    );

    final relay = DoorRelayService(registry, cm, http, events);
    final result = await relay.unlock('door');
    expect(result.ok, isTrue, reason: result.message);
    expect(events.events.first.type, EventType.doorUnlocked);

    final imported = await MonitorSyncService(registry, cm, http, events).sync('monitor');
    expect(imported, greaterThanOrEqualTo(4));
    final types = events.events.map((e) => e.type).toSet();
    expect(
      types,
      containsAll([EventType.faceDetected, EventType.doorbellRing, EventType.motion, EventType.rfidAccess]),
    );
    expect(await MonitorSyncService(registry, cm, http, events).sync('monitor'), 0); // no duplicates
  }, skip: skip);
}
