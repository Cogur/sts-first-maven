import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:homeguard/core/tvt/tvt_net_protocol.dart';
import 'package:homeguard/core/tvt/tvt_web_client.dart';

/// Minimal NVMS-9000 web interface, enough for login and inventory.
class FakeTvtWeb {
  FakeTvtWeb({this.password = 'Secret1', this.rtspOn = false, this.legacy = false});
  final String password;
  bool rtspOn;
  final bool legacy;
  late HttpServer server;
  final commands = <String>[];
  String? lastRtspEdit;
  static const nonce = 'abc123';
  static const token = 'TOKEN42';

  int get port => server.port;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  String _ok(String content) =>
      '<?xml version="1.0" encoding="UTF-8"?><response><status>success</status>$content</response>';
  static const _fail =
      '<?xml version="1.0"?><response><status>fail</status><errorCode>536870948</errorCode></response>';

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final cmd = req.uri.path.substring(1);
    commands.add(cmd);
    String out;
    final loggedIn =
        body.contains('<token>$token</token>') ||
        (req.headers.value('authorization') ?? '').startsWith('Basic');
    switch (cmd) {
      case 'reqLogin':
        out = legacy
            ? '<?xml version="1.0"?><response><status>fail</status><errorCode>536870934</errorCode></response>'
            : _ok('<content><nonce>$nonce</nonce><token>$token</token></content>');
      case 'doLogin':
        final pw = RegExp(r'<password><!\[CDATA\[(.*?)\]\]></password>').firstMatch(body)?[1];
        final good = legacy
            ? base64.encode(utf8.encode(password))
            : TvtWebClient.hashPassword(password, nonce);
        out = pw == good ? _ok('<content><token>$token</token></content>') : _fail;
      case 'queryDevList' when loggedIn:
        out = _ok(
          '<content type="list" total="2">'
          '<item id="{G2}"><chlNum>2</chlNum><name><![CDATA[Garden]]></name><ip>10.0.0.12</ip><port>9008</port></item>'
          '<item id="{G1}"><chlNum>1</chlNum><name><![CDATA[Gate & Drive]]></name><ip>10.0.0.11</ip></item>'
          '</content>',
        );
      case 'queryOnlineChlList' when loggedIn:
        out = _ok('<content><item id="{G1}"/></content>');
      case 'queryRTSPServer' when loggedIn:
        out = _ok(
          '<content><rtspServerSwitch>$rtspOn</rtspServerSwitch><rtspAuthType>Digest</rtspAuthType>'
          '<rtspPort>554</rtspPort><anonymousAccess>false</anonymousAccess></content>',
        );
      case 'editRTSPServer' when loggedIn:
        lastRtspEdit = body;
        rtspOn = true;
        out = _ok('');
      default:
        out = _fail;
    }
    req.response
      ..headers.set('Set-Cookie', 'sessionId=s1; path=/')
      ..write(out);
    await req.response.close();
  }

  Future<void> stop() => server.close(force: true);
}

/// Fake device speaking the binary protocol (classic or head variant).
class FakeTvtDevice {
  FakeTvtDevice({this.protocolVer = 3, this.loginEncrypt = 2, this.password = 'pw'});
  final int protocolVer;
  final int loginEncrypt;
  final String password;
  late ServerSocket server;
  final received = <TvtPacket>[];
  static const nonce = 0x123456;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  Uint8List _initPacket() {
    final b = Uint8List(64);
    b.setRange(0, 4, ascii.encode('head'));
    final v = ByteData.sublistView(b);
    v.setUint32(4, 1, Endian.little);
    v.setUint32(12, protocolVer, Endian.little);
    b.setRange(32, 38, [0x00, 0x18, 0xAE, 0x01, 0x02, 0x03]);
    b[44] = loginEncrypt;
    b[45] = nonce & 0xff;
    b[46] = (nonce >> 8) & 0xff;
    b[47] = (nonce >> 16) & 0xff;
    return b;
  }

  void _serve(Socket s) {
    final init = _initPacket();
    s.add(init);
    s.add(TvtCodec.heartbeat());
    final parser = TvtStreamParser();
    // The client's stream has no init packet; mark it seen.
    parser.add(TvtCodec.heartbeat());
    parser.packets.clear();
    s.listen((chunk) {
      parser.add(chunk);
      for (final p in parser.packets) {
        received.add(p);
        if (p.cmd == TvtCmd.login || p.cmd == TvtCmd.headLogin) {
          s.add(_loginReply(p, TvtInit(init)));
        } else if (p.cmd == TvtCmd.httpRequest) {
          final body = ascii.encode('{"ok":true}');
          s.add(TvtCodec.encode(TvtCmd.replyHttp, [...List.filled(72, 0), ...body]));
        }
      }
      parser.packets.clear();
    });
  }

  Uint8List _loginReply(TvtPacket p, TvtInit init) {
    bool ok;
    if (p.cmd == TvtCmd.headLogin) {
      ok = _eq(p.data.sublist(100, 120), TvtCodec.headPassword(password, init.nonce));
    } else {
      ok = _eq(p.data.sublist(36, 68), TvtCodec.classicPassword(password, init));
    }
    if (!ok) {
      return TvtCodec.encode(p.cmd == TvtCmd.headLogin ? TvtCmd.replyHeadLoginFail : TvtCmd.replyLoginFail);
    }
    if (p.cmd == TvtCmd.headLogin) {
      final d = Uint8List(0xB8 + 40);
      d.setRange(0x8C, 0x8C + 6, ascii.encode('NVR-SN'));
      ByteData.sublistView(d).setUint16(0xB0, 2, Endian.little);
      ByteData.sublistView(d).setUint32(0xB8, 1, Endian.little);
      ByteData.sublistView(d).setUint32(0xB8 + 20, 2, Endian.little);
      return Uint8List.fromList([
        ...TvtCodec.encode(0x01000105, [1, 2, 3]),
        ...TvtCodec.encode(0x01000106, d),
      ]);
    }
    final d = Uint8List(200);
    d.setRange(52, 58, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    d.setRange(58, 63, ascii.encode('MyNVR'));
    return TvtCodec.encode(TvtCmd.replyLoginOk, d);
  }

  static bool _eq(List<int> a, List<int> b) =>
      a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

  Future<void> stop() => server.close();
}
