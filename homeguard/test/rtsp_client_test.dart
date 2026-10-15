import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/rtsp/rtsp_client.dart';
import 'package:homeguard/core/rtsp/rtsp_message.dart';

/// Minimal RTSP server emulating a TVT-style NVR with digest auth and an
/// ONVIF back-channel track.
class FakeNvr {
  FakeNvr({this.user = 'admin', this.pass = 's3cret!'});
  final String user;
  final String pass;
  late ServerSocket _server;
  final rtp = <InterleavedPacket>[];
  final methods = <String>[];
  static const nonce = 'abc123';
  static const realm = 'NVR';

  int get port => _server.port;

  static const sdp =
      'v=0\r\n'
      'a=control:*\r\n'
      'm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=1\r\n'
      'm=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=3\r\na=sendonly\r\n';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((s) {
      var buf = <int>[];
      s.listen((data) {
        buf.addAll(data);
        while (true) {
          if (buf.isNotEmpty && buf[0] == 0x24) {
            if (buf.length < 4) return;
            final len = (buf[2] << 8) | buf[3];
            if (buf.length < 4 + len) return;
            rtp.add(InterleavedPacket(buf[1], Uint8List.fromList(buf.sublist(4, 4 + len))));
            buf = buf.sublist(4 + len);
            continue;
          }
          final text = latin1.decode(buf);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          _handle(s, text.substring(0, end));
          buf = buf.sublist(end + 4);
        }
      });
    });
  }

  void _handle(Socket s, String req) {
    final lines = req.split('\r\n');
    final parts = lines.first.split(' ');
    final method = parts[0];
    final uri = parts[1];
    final headers = {
      for (final l in lines.skip(1))
        if (l.contains(':'))
          l.substring(0, l.indexOf(':')).toLowerCase(): l.substring(l.indexOf(':') + 1).trim(),
    };
    methods.add(method);
    final cseq = headers['cseq'];
    final auth = headers['authorization'];
    String h(String x) => md5.convert(utf8.encode(x)).toString();
    final expected = h('${h('$user:$realm:$pass')}:$nonce:${h('$method:$uri')}');
    if (auth == null || !auth.contains('response="$expected"')) {
      s.write(
        'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n'
        'WWW-Authenticate: Digest realm="$realm", nonce="$nonce"\r\n\r\n',
      );
      return;
    }
    switch (method) {
      case 'DESCRIBE':
        s.write(
          'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Base: $uri/\r\n'
          'Content-Type: application/sdp\r\nContent-Length: ${sdp.length}\r\n\r\n$sdp',
        );
      case 'SETUP':
        s.write(
          'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nSession: 99;timeout=60\r\n'
          'Transport: RTP/AVP/TCP;unicast;interleaved=4-5\r\n\r\n',
        );
      default:
        s.write('RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nServer: FakeNVR\r\n\r\n');
    }
  }

  Future<void> stop() => _server.close();
}

void main() {
  late FakeNvr nvr;
  setUp(() async {
    nvr = FakeNvr();
    await nvr.start();
  });
  tearDown(() => nvr.stop());

  Uri uri() => Uri.parse('rtsp://127.0.0.1:${nvr.port}/chID=1&streamType=sub&linkType=tcp');

  test('probe authenticates with digest and parses the SDP', () async {
    final r = await RtspClient.probe(uri: uri(), username: 'admin', password: 's3cret!');
    expect(r.videoCodec, 'H264');
    expect(r.hasBackchannel, isTrue);
    expect(r.server, 'FakeNVR');
  });

  test('wrong password surfaces as an auth failure', () async {
    await expectLater(
      RtspClient.probe(uri: uri(), username: 'admin', password: 'nope'),
      throwsA(isA<RtspException>().having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
    );
  });

  test('closed port surfaces as unreachable, not a hang', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    await expectLater(
      RtspClient.probe(uri: Uri.parse('rtsp://127.0.0.1:$port/x'), username: 'a', password: 'b'),
      throwsA(isA<RtspException>()),
    );
  });

  test('back-channel negotiates PCMA and streams interleaved RTP', () async {
    final c = RtspClient(uri: uri(), username: 'admin', password: 's3cret!');
    await c.connect();
    final pt = await c.startBackchannel();
    expect(pt, 8);
    c.sendAudio(Uint8List(400)); // 50 ms → split into 320 + 80 byte packets
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await c.close();

    expect(nvr.methods, containsAllInOrder(['DESCRIBE', 'SETUP', 'PLAY', 'TEARDOWN']));
    expect(nvr.rtp, hasLength(2));
    final first = ByteData.sublistView(nvr.rtp[0].payload);
    final second = ByteData.sublistView(nvr.rtp[1].payload);
    expect(nvr.rtp[0].channel, 4);
    expect(first.getUint8(0), 0x80); // RTP v2
    expect(first.getUint8(1), 0x80 | 8); // marker + PCMA
    expect(second.getUint8(1), 8);
    expect(second.getUint16(2), first.getUint16(2) + 1); // sequence
    expect(second.getUint32(4), first.getUint32(4) + 320); // timestamp
    expect(nvr.rtp[0].payload.length, 12 + 320);
    expect(nvr.rtp[1].payload.length, 12 + 80);
  });
}
