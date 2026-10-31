import 'dart:async';
import 'dart:io';

import '../rtsp/rtsp_client.dart';
import '../security/secure_store.dart';
import 'tvt_lapi_client.dart';
import 'tvt_net_client.dart';
import 'tvt_web_client.dart';

/// Read-only fact finding on one device, for the diagnostics screen. It never
/// changes settings. The report is what is needed to add support for a model
/// whose API is not documented (e.g. the door station's unlock command).
class TvtProbe {
  TvtProbe({this.timeout = const Duration(seconds: 2)});
  final Duration timeout;

  static const ports = {
    80: 'HTTP',
    443: 'HTTPS',
    554: 'RTSP',
    6036: 'TVT (recorder)',
    9008: 'TVT (camera/intercom)',
    8000: 'alt. HTTP/SDK',
    5060: 'SIP',
  };

  Future<bool> _open(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Masks the middle of a cloud serial so a report can be shared.
  static String mask(String s) =>
      s.length <= 6 ? '***' : '${s.substring(0, 3)}***${s.substring(s.length - 3)}';

  /// Stream paths tried in order. Stops at the first auth failure so a
  /// wrong password cannot run into the recorder's login lockout.
  static const rtspPaths = [
    '/chID=1&streamType=sub&linkType=tcp',
    '/chID=1&streamType=main&linkType=tcp',
    '/chID=1&streamType=main',
    '/chID=01&streamType=main',
    '/profile1',
  ];

  Future<void> _probeRtsp(String host, int port, Credentials creds, List<String> out) async {
    for (final path in rtspPaths) {
      try {
        final r = await RtspClient.probe(
          uri: Uri.parse('rtsp://$host:$port$path'),
          username: creds.username,
          password: creds.password,
          timeout: const Duration(seconds: 4),
          backchannel: false,
        );
        out.add(
          'RTSP $path: OK, video ${r.videoCodec}, audio ${r.audioCodec}${r.server == null ? '' : ', server ${r.server}'}',
        );
        // Report main too when sub works, but no further variants.
        if (path.contains('streamType=main') || path == rtspPaths[1]) return;
      } on RtspException catch (e) {
        out.add('RTSP $path: ${e.message}${e.detail == null ? '' : ' (${e.detail})'}');
        if (e.isAuthFailure) {
          out.add('  stopped probing to avoid locking the account');
          return;
        }
      }
    }
  }

  Future<List<String>> run(String host, Credentials? creds, {int httpPort = 80, int rtspPort = 554}) async {
    final out = <String>['# $host'];
    final open = <int>{};
    await Future.wait(
      ports.keys.map((p) async {
        if (await _open(host, p)) open.add(p);
      }),
    );
    out.add(
      'Open ports: ${open.isEmpty ? 'none' : (open.toList()..sort()).map((p) => '$p (${ports[p]})').join(', ')}',
    );

    for (final p in [6036, 9008].where(open.contains)) {
      try {
        final c = await TvtNetClient.connect(host, p);
        try {
          final init = await Future.any([
            Future.doWhile(() async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return c.init == null;
            }).then((_) => c.init),
            Future<void>.delayed(timeout).then((_) => null),
          ]);
          if (init == null) {
            out.add('Port $p: no TVT greeting');
            continue;
          }
          out.add(
            'Port $p: TVT protocol v${init.protocolVer}, device type ${init.devType}, '
            'product ${init.productType}, login encryption ${init.loginEncrypt}',
          );
          if (creds != null) {
            try {
              final info = await c.login(creds.username, creds.password);
              out.add('  login OK${info.channels.isEmpty ? '' : ', channels ${info.channels}'}');
              // HTTP through the logged-in session: needs no Digest password.
              for (final path in ['/GetSnapshot/1', '/LAPI/V1.0/System/DeviceInfo']) {
                try {
                  final body = await c.http(path).timeout(const Duration(seconds: 4));
                  final head = String.fromCharCodes(body.take(60).where((b) => b >= 32 && b < 127));
                  out.add('  tunnel $path: ${body.length} bytes${head.isEmpty ? '' : ' "$head"'}');
                } catch (e) {
                  out.add('  tunnel $path: ${e is TimeoutException ? 'no answer' : e}');
                }
              }
            } on TvtNetException catch (e) {
              out.add('  login: $e');
            }
          }
        } finally {
          await c.close();
        }
      } on TvtNetException catch (e) {
        out.add('Port $p: $e');
      }
    }

    if (creds != null && await _open(host, rtspPort)) await _probeRtsp(host, rtspPort, creds, out);

    if (open.contains(httpPort) && creds != null) {
      final web = TvtWebClient(
        host: host,
        port: httpPort,
        username: creds.username,
        password: creds.password,
      );
      try {
        await web.login();
        out.add('Web interface (NVMS-9000): login OK');
        try {
          final chans = await web.channels();
          out.add(
            '  Channels: ${chans.map((c) => '${c.number} ${c.online ? 'online' : 'OFFLINE'}${c.model.isEmpty ? '' : ' ${c.model}'}').join('; ')}',
          );
        } on TvtWebException catch (e) {
          out.add('  Channels: $e');
        }
        try {
          final r = await web.rtspServer();
          out.add('  RTSP service: ${r.enabled ? 'on' : 'off'}, port ${r.port}, ${r.authType}');
        } on TvtWebException catch (e) {
          out.add('  RTSP settings: $e');
        }
        try {
          out.add('  API Server: ${await web.apiServerEnabled() ? 'on' : 'off'}');
        } on TvtWebException catch (e) {
          out.add('  API Server: $e');
        }
      } on TvtWebException catch (e) {
        out.add('Web interface (NVMS-9000): ${e.notTvt ? 'not present' : e}');
      } finally {
        web.close();
      }

      final lapi = TvtLapiClient(host: host, port: httpPort, credentials: creds);
      try {
        final apis = (await lapi.supportedApis()).toList()..sort();
        out.add('HTTP API: ${apis.length} commands');
        out.add('  ${apis.join(', ')}');
        final door = apis.where(
          (a) => RegExp('door|lock|relay|alarmout|output', caseSensitive: false).hasMatch(a),
        );
        if (door.isNotEmpty) out.add('  Door/relay candidates: ${door.join(', ')}');
      } catch (e) {
        out.add('HTTP API command list: $e');
      }
      try {
        final info = await lapi.deviceInfo();
        out.add('HTTP API (${lapi.urlStyle} URLs): device info OK, ${info.length} fields');
        final model = info['deviceModel'] ?? info['model'] ?? info['productModel'];
        if (model != null) out.add('  model $model');
      } catch (e) {
        out.add('HTTP API device info: $e');
      }
      try {
        final jpeg = await lapi.snapshot(1);
        out.add('HTTP API snapshot (camera 1): OK, ${jpeg.length ~/ 1024} kB');
      } catch (e) {
        out.add('HTTP API snapshot (camera 1): $e');
      }
      try {
        final nat = await lapi.natInfo();
        out.add(
          'Cloud (P2P): ${nat.enabled ? 'on' : 'off'}'
          '${nat.serial == null ? '' : ', serial ${mask(nat.serial!)}'}'
          '${nat.status == null || nat.status!.isEmpty ? '' : ', status ${nat.status}'}',
        );
      } catch (_) {
        // Not every model exposes NAT settings over the HTTP API.
      }
    }
    return out;
  }
}
