import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/device.dart';
import 'package:homeguard/core/network/connection_manager.dart';
import 'package:homeguard/core/rtsp/rtsp_client.dart';
import 'package:homeguard/core/security/biometric_service.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/services/device_registry.dart';
import 'package:homeguard/features/auth/auth_controller.dart';
import 'package:homeguard/features/auth/login_page.dart';
import 'package:provider/provider.dart';

class FakeBiometrics extends BiometricService {
  FakeBiometrics({this.available = true, this.succeed = true});
  bool available;
  bool succeed;
  int prompts = 0;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String reason, {bool biometricOnly = false}) async {
    prompts++;
    return succeed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStore store;
  late FakeBiometrics bio;
  late ConnectionManager cm;
  late DeviceRegistry registry;
  late List<Uri> verified;
  String goodPassword = 'pw';
  Set<String> up = {};

  AuthController build() => AuthController(
    store: store,
    biometrics: bio,
    registry: registry,
    connections: cm,
    verifier: (uri, c) async {
      verified.add(uri);
      if (c.password != goodPassword) throw RtspException('bad', statusCode: 401);
    },
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = SecureStore(const FlutterSecureStorage());
    bio = FakeBiometrics();
    up = {'192.168.1.10:554'};
    verified = [];
    cm = ConnectionManager(
      probe: (h, p, _) async => up.contains('$h:$p') ? Duration.zero : null,
      lookup: (h) async => [InternetAddress(h)],
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
    );
    registry = DeviceRegistry(store, cm);
  });

  test('host normalisation', () {
    expect(AuthController.normalizeHost(' rtsp://admin:x@192.168.1.10:554/ch1 '), '192.168.1.10');
    expect(AuthController.normalizeHost('nvr.local'), 'nvr.local');
    expect(AuthController.normalizeHost('[fd00::1]:554'), 'fd00::1');
    expect(AuthController.normalizeHost('fd00::1'), 'fd00::1');
  });

  test('port parsing', () {
    expect(AuthController.parsePort('192.168.1.10:8554'), 8554);
    expect(AuthController.parsePort('rtsp://u:p@nvr.local:554/x'), 554);
    expect(AuthController.parsePort('[fd00::1]:8554'), 8554);
    expect(AuthController.parsePort('192.168.1.10'), isNull);
    expect(AuthController.parsePort('fd00::1'), isNull);
    expect(AuthController.parsePort('host:99999'), isNull);
  });

  test('custom port and camera path from the login screen are applied before verifying', () async {
    up = {'192.168.1.10:8554'};
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10:8554',
      username: 'admin',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
      cameraPathTemplate: '/cam{channel}_{stream}',
    );
    expect(verified.single.toString(), 'rtsp://192.168.1.10:8554/cam1_sub');
    expect(registry.byId('cam2')!.rtspPath(StreamQuality.main), '/cam2_main');
  });

  test('successful sign-in verifies against camera 1 sub-stream and stores credentials', () async {
    final auth = build();
    await auth.init();
    expect(auth.status, AuthStatus.signedOut);
    await auth.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: true,
      enableBiometrics: true,
    );
    expect(auth.status, AuthStatus.authenticated);
    expect(verified.single.toString(), 'rtsp://192.168.1.10:554/chID=1&streamType=sub&linkType=tcp');
    expect((await store.readCredentials('nvr'))!.password, 'pw');
    expect((await store.readRemembered())!.biometricEnabled, isTrue);
  });

  test('remembered + biometric launch starts locked and unlocks with biometrics', () async {
    final first = build();
    await first.init();
    await first.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: true,
      enableBiometrics: true,
    );

    registry = DeviceRegistry(store, cm);
    final second = build();
    await second.init();
    expect(second.status, AuthStatus.locked);
    bio.succeed = false;
    expect(await second.unlockWithBiometrics(), isFalse);
    expect(second.status, AuthStatus.locked);
    bio.succeed = true;
    expect(await second.unlockWithBiometrics(), isTrue);
    expect(second.status, AuthStatus.authenticated);
  });

  test('without remember-me the password does not survive a relaunch', () async {
    final first = build();
    await first.init();
    await first.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
    );
    registry = DeviceRegistry(store, cm);
    final second = build();
    await second.init();
    expect(second.status, AuthStatus.signedOut);
    expect(await store.readCredentials('nvr'), isNull);
  });

  test('wrong password is rejected and repeated failures trigger a lockout', () async {
    final auth = build();
    await auth.init();
    for (var i = 0; i < 5; i++) {
      await expectLater(
        auth.signIn(
          host: '192.168.1.10',
          username: 'admin',
          password: 'x',
          remember: false,
          enableBiometrics: false,
        ),
        throwsA(isA<LoginException>().having((e) => e.message, 'message', 'Invalid username or password')),
      );
    }
    expect(auth.lockoutRemaining, isNotNull);
    await expectLater(
      auth.signIn(
        host: '192.168.1.10',
        username: 'admin',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', startsWith('Too many attempts'))),
    );
    expect(await store.readCredentials('nvr'), isNull);
  });

  test('unreachable NVR gives an actionable error', () async {
    up = {};
    final auth = build();
    await auth.init();
    await expectLater(
      auth.signIn(
        host: '192.168.1.99',
        username: 'a',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', contains('same Wi-Fi'))),
    );
  });

  test('web page reachable but RTSP closed explains the port setting', () async {
    up = {'192.168.1.200:80'};
    final auth = build();
    await auth.init();
    await expectLater(
      auth.signIn(
        host: '192.168.1.200',
        username: 'a',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', contains('video (RTSP) port 554'))),
    );
  });

  test('remote VPN route is used when LAN is down', () async {
    up = {'10.8.0.2:554'};
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10',
      username: 'a',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
      remoteHost: '10.8.0.2',
      remoteMode: RemoteMode.vpn,
    );
    expect(verified.single.host, '10.8.0.2');
    expect(cm.cached('nvr')!.kind, RouteKind.remote);
  });

  test('lock without biometrics drops the stored password', () async {
    bio.available = false;
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10',
      username: 'a',
      password: 'pw',
      remember: true,
      enableBiometrics: false,
    );
    await auth.lock();
    expect(auth.status, AuthStatus.signedOut);
    expect(await store.readCredentials('nvr'), isNull);
    expect((await store.readRemembered())!.username, 'a');
  });

  testWidgets('login form validates required fields', (tester) async {
    final auth = build();
    await auth.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.ensureVisible(find.text('Connect securely'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect securely'));
    await tester.pump();
    expect(find.text('Required'), findsNWidgets(3));
    expect(find.text('Face ID / fingerprint sign-in'), findsOneWidget);
  });
}
