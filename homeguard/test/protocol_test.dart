import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/audio/g711.dart';
import 'package:homeguard/core/rtsp/digest_auth.dart';
import 'package:homeguard/core/rtsp/rtsp_message.dart';
import 'package:homeguard/core/rtsp/sdp.dart';

void main() {
  group('G.711', () {
    test('silence encodes to the standard idle codes', () {
      expect(G711.linearToUlaw(0), 0xFF);
      expect(G711.linearToAlaw(0), 0xD5);
    });

    test('µ-law round-trip error stays within quantisation step', () {
      for (final v in [-32000, -8000, -1000, -100, 0, 100, 1000, 8000, 32000]) {
        final back = G711.ulawToLinear(G711.linearToUlaw(v));
        expect((back - v).abs(), lessThanOrEqualTo((v.abs() >> 4) + 16), reason: 'sample $v → $back');
      }
    });

    test('encodes little-endian PCM16 blocks', () {
      final pcm = Uint8List(4)..buffer.asByteData().setInt16(2, 1000, Endian.little);
      final out = G711.encodePcm16(pcm);
      expect(out, hasLength(2));
      expect(out[0], 0xFF);
      expect(out[1], G711.linearToUlaw(1000));
    });
  });

  group('Digest auth', () {
    test('matches the RFC 2617 §3.5 worked example', () {
      final challenge = AuthChallenge.parse(
        'Digest realm="testrealm@host.com", qop="auth,auth-int", '
        'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"',
      )!;
      final header = DigestAuthenticator(
        username: 'Mufasa',
        password: 'Circle Of Life',
        cnonce: () => '0a4f113b',
      ).authorize(challenge: challenge, method: 'GET', uri: '/dir/index.html');
      expect(header, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(header, contains('nc=00000001'));
      expect(header, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
    });

    test('prefers SHA-256 digest over MD5 and Basic', () {
      final best = AuthChallenge.pickBest([
        'Basic realm="x"',
        'Digest realm="x", nonce="1"',
        'Digest realm="x", nonce="2", algorithm=SHA-256',
      ])!;
      expect(best.algorithm, 'SHA-256');
    });

    test('basic auth header', () {
      final h = DigestAuthenticator(
        username: 'admin',
        password: 'p:w',
      ).authorize(challenge: AuthChallenge.parse('Basic realm="r"')!, method: 'GET', uri: '/');
      expect(h, 'Basic ${base64.encode(utf8.encode('admin:p:w'))}');
    });
  });

  group('RTSP stream parser', () {
    test('splits responses and interleaved packets across arbitrary chunks', () {
      const sdp = 'v=0\r\nm=video 0 RTP/AVP 96\r\n';
      final bytes = <int>[
        ...latin1.encode('RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: ${sdp.length}\r\n\r\n$sdp'),
        0x24,
        1,
        0,
        3,
        9,
        8,
        7,
        ...latin1.encode(
          'RTSP/1.0 401 Unauthorized\r\nCSeq: 3\r\n'
          'WWW-Authenticate: Digest realm="a", nonce="b"\r\nWWW-Authenticate: Basic realm="a"\r\n\r\n',
        ),
      ];
      final p = RtspStreamParser();
      for (var i = 0; i < bytes.length; i += 5) {
        p.add(bytes.sublist(i, i + 5 > bytes.length ? bytes.length : i + 5));
      }
      expect(p.responses, hasLength(2));
      expect(p.responses[0].cseq, 2);
      expect(p.responses[0].body, sdp);
      expect(p.responses[1].statusCode, 401);
      expect(p.responses[1].headerAll('www-authenticate'), hasLength(2));
      expect(p.packets.single.channel, 1);
      expect(p.packets.single.payload, [9, 8, 7]);
    });

    test('session header exposes id and timeout', () {
      final r = RtspResponse(
        statusCode: 200,
        reason: 'OK',
        headers: {
          'session': ['12345678;timeout=30'],
        },
        body: '',
      );
      expect(r.session, '12345678');
      expect(r.sessionTimeout, 30);
    });
  });

  group('SDP', () {
    const tvtSdp =
        'v=0\r\n'
        'o=- 1 1 IN IP4 192.168.1.100\r\n'
        's=Media Presentation\r\n'
        'a=control:*\r\n'
        'm=video 0 RTP/AVP 96\r\n'
        'a=rtpmap:96 H265/90000\r\n'
        'a=control:trackID=1\r\n'
        'm=audio 0 RTP/AVP 0\r\n'
        'a=rtpmap:0 PCMU/8000\r\n'
        'a=control:trackID=2\r\n'
        'a=recvonly\r\n'
        'm=audio 0 RTP/AVP 0 8\r\n'
        'a=control:trackID=3\r\n'
        'a=sendonly\r\n';

    test('parses codecs, controls and the ONVIF back-channel', () {
      final s = SdpSession.parse(tvtSdp);
      expect(s.sessionControl, '*');
      expect(s.video.single.codec, 'H265');
      expect(s.audio, hasLength(2));
      final bc = s.backchannel!;
      expect(bc.payloadTypes, [0, 8]);
      expect(bc.codec, 'PCMU');
      expect(bc.resolveControl('rtsp://h/chID=1/'), 'rtsp://h/chID=1/trackID=3');
      expect(bc.resolveControl('rtsp://h/x'), 'rtsp://h/x/trackID=3');
    });

    test('absolute control URLs are kept', () {
      final m = SdpMedia(type: 'audio', payloadTypes: [0])..control = 'rtsp://other/track';
      expect(m.resolveControl('rtsp://h/'), 'rtsp://other/track');
    });
  });
}
