import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/device.dart';
import 'package:homeguard/core/network/connection_manager.dart';
import 'package:homeguard/core/network/reachability.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/utils/log.dart';

void main() {
  late Set<String> up;
  late List<String> probed;
  late StreamController<List<ConnectivityResult>> net;
  late ConnectionManager cm;

  Future<Duration?> probe(String host, int port, Duration _) async {
    probed.add('$host:$port');
    return up.contains('$host:$port') ? const Duration(milliseconds: 5) : null;
  }

  List<DeviceConfig> topology({RemoteMode mode = RemoteMode.vpn, String remote = 'nvr.vpn'}) => [
    DeviceConfig(
      id: 'nvr',
      name: 'NVR',
      kind: DeviceKind.nvr,
      lanHost: '192.168.1.10',
      remoteHost: remote,
      remoteMode: mode,
    ),
    const DeviceConfig(id: 'cam1', name: 'Cam', kind: DeviceKind.camera, parentId: 'nvr', channel: 1),
    const DeviceConfig(id: 'monitor', name: 'Mon', kind: DeviceKind.indoorMonitor, lanHost: '192.168.1.30'),
  ];

  setUp(() {
    up = {};
    probed = [];
    net = StreamController.broadcast();
    cm = ConnectionManager(
      probe: probe,
      connectivity: net.stream,
      // nvr.vpn → WireGuard address; everything else → public internet.
      lookup: (h) async => [InternetAddress(h == 'nvr.vpn' ? '10.8.0.2' : '93.184.216.34')],
    );
  });
  tearDown(() {
    cm.dispose();
    net.close();
  });

  test('prefers LAN when the NVR answers locally', () async {
    cm.updateDevices(topology());
    up = {'192.168.1.10:554', 'nvr.vpn:554'};
    final r = await cm.resolve('cam1');
    expect(r.kind, RouteKind.lan);
    expect(probed, ['192.168.1.10:554']); // remote never touched
  });

  test('falls back to the VPN route when LAN is down', () async {
    cm.updateDevices(topology());
    up = {'nvr.vpn:554'};
    final r = await cm.resolve('cam1');
    expect(r.kind, RouteKind.remote);
    expect(r.secure, isFalse);
    expect(r.rtspScheme, 'rtsp');
  });

  test('VPN mode refuses plaintext to a public internet address', () async {
    cm.updateDevices(topology(remote: 'nvr.example.com'));
    up = {'nvr.example.com:554'};
    final r = await cm.resolve('cam1');
    expect(r.reachable, isFalse);
    expect(probed, ['192.168.1.10:554']); // never connected in cleartext
  });

  test('TLS mode uses rtsps/https ports only', () async {
    cm.updateDevices(topology(mode: RemoteMode.tls, remote: 'nvr.example.com'));
    up = {'nvr.example.com:322'};
    final r = await cm.resolve('nvr');
    expect(r.kind, RouteKind.remote);
    expect(r.secure, isTrue);
    expect(r.rtspUri('/x').toString(), 'rtsps://nvr.example.com:322/x');
    expect(r.httpUri('/a?b=1').toString(), 'https://nvr.example.com/a?b=1');
    expect(probed, isNot(contains('nvr.example.com:554')));
  });

  test('LAN-only devices never try the internet', () async {
    cm.updateDevices(topology(mode: RemoteMode.disabled));
    final r = await cm.resolve('cam1');
    expect(r.reachable, isFalse);
    expect(probed, ['192.168.1.10:554']);
    expect(() => cm.require('cam1'), throwsA(isA<DeviceUnreachableException>()));
  });

  test('indoor monitor is probed on its HTTP port', () async {
    cm.updateDevices(topology());
    up = {'192.168.1.30:80'};
    expect((await cm.resolve('monitor')).kind, RouteKind.lan);
  });

  test('results are cached, and a network change invalidates them', () async {
    cm.updateDevices(topology());
    up = {'192.168.1.10:554'};
    await cm.resolve('cam1');
    await cm.resolve('cam1');
    expect(probed, hasLength(1));
    net.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(Duration.zero);
    expect(cm.cached('cam1'), isNull);
    up = {};
    expect((await cm.resolve('cam1')).kind, RouteKind.unreachable);
    expect(probed, hasLength(3)); // LAN + remote re-probed after the change
  });

  test('RTSP URL percent-encodes credentials and brackets IPv6', () {
    final r = ResolvedRoute(
      kind: RouteKind.lan,
      host: 'fd00::5',
      rtspPort: 554,
      httpPort: 80,
      secure: false,
      latency: null,
      checkedAt: DateTime(2026),
    );
    expect(
      r.rtspUrl('/chID=1&streamType=main', const Credentials('admin', 'p@ss:w/rd')),
      'rtsp://admin:p%40ss%3Aw%2Frd@[fd00::5]:554/chID=1&streamType=main',
    );
  });

  test('private address detection', () {
    for (final a in ['10.0.0.1', '172.16.5.1', '192.168.0.2', '100.64.1.1', 'fd12::1', '127.0.0.1']) {
      expect(isPrivateAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '2001:4860::8888']) {
      expect(isPrivateAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('log redaction strips credentials', () {
    expect(Log.redact('rtsp://admin:pw@10.0.0.1:554/x'), 'rtsp://***@10.0.0.1:554/x');
    expect(Log.redact('Authorization: Digest username="a", response="b"'), 'Authorization: ***');
    expect(Log.redact('/cgi?user=admin&password=x&ch=1'), '/cgi?user=***&password=***&ch=1');
  });

  test('device RTSP templates expand placeholders', () {
    const d = DeviceConfig(id: 'c', name: 'c', kind: DeviceKind.camera, channel: 3);
    expect(d.rtspPath(StreamQuality.sub), '/chID=3&streamType=sub&linkType=tcp');
    final d2 = d.copyWith(rtspPathTemplate: '/Streaming/Channels/{channel}0{streamIndex}');
    expect(d2.rtspPath(StreamQuality.main), '/Streaming/Channels/300');
  });
}
