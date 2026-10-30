import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Wire format of TVT's proprietary device protocol: what SuperLive Plus and
/// the vendor NET_SDK speak on port 6036 (recorders) and 9008 (cameras,
/// door stations). TVT does not document it; the layout here follows the
/// public reverse-engineering in 2BAD/tvt (Wireshark dissectors, MIT) and
/// pytvt (MIT).
///
/// Packet: `"1111"` | u32 len | cmd u32 | cmdId u32 | cmdVer u32 | dataLen u32 | data.
/// The device opens every connection with a 64-byte `"head"` init packet
/// that carries the login nonce. All integers are little-endian.
abstract final class TvtCmd {
  static const login = 0x101;
  static const logout = 0x102;
  static const streamStart = 0x201;
  static const streamStop = 0x202;
  static const keyframe = 0x203;
  static const manualRecord = 0x901;
  static const manualStop = 0x902;
  static const alarmOutStart = 0x0B01;
  static const alarmOutStop = 0x0B02;
  static const httpRequest = 0x1010D00;

  /// Login used by "head"-variant firmware (protocolVer >= 11).
  static const headLogin = 0x01000004;

  static const replyLoginOk = 0x1000101;
  static const replyLoginFail = 0x1000102;
  static const replyHeadLoginOk = 0x01000104;
  static const replyHeadLoginFail = 0x01000204;
  static const replyStreamStart = 0x100020D;
  static const replyLiveStream = 0x1000C01;
  static const replyHttp = 0x1010D01;

  static bool isLoginOk(int c) => c == replyLoginOk || c == replyHeadLoginOk;
  static bool isLoginFail(int c) => c == replyLoginFail || c == replyHeadLoginFail;
}

class TvtInit {
  TvtInit(this.raw)
    : devType = _u32(raw, 4),
      productType = _u32(raw, 8),
      protocolVer = _u32(raw, 12),
      encryptType = _u32(raw, 24),
      loginEncrypt = raw[44],
      nonce = raw[45] | (raw[46] << 8) | (raw[47] << 16);

  final Uint8List raw;
  final int devType;
  final int productType;
  final int protocolVer;
  final int encryptType;
  final int loginEncrypt;

  /// 24-bit login nonce.
  final int nonce;

  String get mac =>
      raw.sublist(32, 38).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();

  /// Newer firmware ("head" variant) hashes the password with the nonce.
  bool get headVariant => protocolVer >= 11;

  Uint8List get _xorKey => raw.sublist(44, 48);

  static int _u32(Uint8List b, int o) => ByteData.sublistView(b).getUint32(o, Endian.little);
}

class TvtPacket {
  const TvtPacket(this.cmd, this.data, {this.cmdId = 0, this.cmdVer = 0});
  final int cmd;
  final int cmdId;
  final int cmdVer;
  final Uint8List data;

  /// An empty `1111` frame: keep-alive / acknowledgement.
  bool get isHeartbeat => cmd == -1;
}

abstract final class TvtCodec {
  static final flag = ascii.encode('1111');
  static final headFlag = ascii.encode('head');
  static const initSize = 64;

  static Uint8List encode(int cmd, [List<int> data = const [], int cmdId = 0, int cmdVer = 0]) {
    final out = Uint8List(24 + data.length);
    final v = ByteData.sublistView(out);
    out.setRange(0, 4, flag);
    v.setUint32(4, 16 + data.length, Endian.little);
    v.setUint32(8, cmd, Endian.little);
    v.setUint32(12, cmdId, Endian.little);
    v.setUint32(16, cmdVer, Endian.little);
    v.setUint32(20, data.length, Endian.little);
    out.setRange(24, out.length, data);
    return out;
  }

  static Uint8List heartbeat() {
    final out = Uint8List(8)..setRange(0, 4, flag);
    return out;
  }

  static List<int> _fixed(String s, int len) {
    final b = utf8.encode(s);
    return [...b.take(len), ...List.filled((len - b.length).clamp(0, len), 0)];
  }

  /// Classic password field: 32 bytes, XORed with the 4-byte init key when
  /// the device asks for login encryption.
  static List<int> classicPassword(String password, TvtInit init) {
    final p = _fixed(password, 32);
    if (init.loginEncrypt == 0) return p;
    final k = init._xorKey;
    return [for (var i = 0; i < 32; i++) p[i] ^ k[i % 4]];
  }

  /// "head" variant: SHA1(upper(MD5(password)) + nonce as %08d).
  static List<int> headPassword(String password, int nonce) {
    final md5Hex = md5.convert(utf8.encode(password)).toString().toUpperCase();
    return sha1.convert(ascii.encode('$md5Hex${nonce.toString().padLeft(8, '0')}')).bytes;
  }

  /// "head" variant: username XORed byte-wise with the decimal nonce text.
  static List<int> headUsername(String username, int nonce) {
    final key = ascii.encode('$nonce');
    final b = _fixed(username, 64);
    return [for (var i = 0; i < 64; i++) b[i] == 0 ? 0 : b[i] ^ key[i % key.length]];
  }

  static Uint8List loginRequest(
    String username,
    String password,
    TvtInit init, {
    String client = 'HomeGuard',
  }) {
    if (init.headVariant) {
      final data = Uint8List(236);
      ByteData.sublistView(data).setUint32(0, 3, Endian.little);
      data.setRange(36, 100, headUsername(username, init.nonce));
      data.setRange(100, 120, headPassword(password, init.nonce));
      return encode(TvtCmd.headLogin, data, 0x0101, 0x0101);
    }
    final data = <int>[
      ..._le32(1), // connect type: normal
      ..._fixed(username, 32),
      ...classicPassword(password, init),
      ..._fixed(client, 28),
      ...List.filled(8 + 6 + 1 + 1, 0), // ip, mac, productType, reserved
      ..._le32(3), // protocol version N9000
    ];
    return encode(TvtCmd.login, data);
  }

  static Uint8List httpRequest(String path, int seq, {String method = 'GET', String body = ''}) {
    final req = utf8.encode(
      '$method $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n'
      '${body.isEmpty ? '' : 'Content-Length: ${utf8.encode(body).length}\r\n'}\r\n$body',
    );
    return encode(TvtCmd.httpRequest, [
      ..._le32(req.length),
      ..._le32(seq),
      ...List.filled(64, 0),
      ...req,
      0,
    ]);
  }

  /// Body of a tunnelled HTTP reply (skips length, seq and 64 reserved bytes).
  static Uint8List httpReplyBody(Uint8List data) => data.length < 72 ? data : data.sublist(72);

  static Uint8List alarmOut(int channel, {required bool on}) =>
      encode(on ? TvtCmd.alarmOutStart : TvtCmd.alarmOutStop, _le32(channel));

  static List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
}

/// Device facts from a successful login reply.
class TvtLoginInfo {
  const TvtLoginInfo({this.deviceName = '', this.mac = '', this.channels = const []});
  final String deviceName;
  final String mac;
  final List<int> channels;

  static TvtLoginInfo parse(Uint8List d, {required bool headVariant}) {
    if (headVariant && d.length >= 0xB8) {
      final count = ByteData.sublistView(d).getUint16(0xB0, Endian.little);
      final chans = <int>[];
      for (var i = 0, o = 0xB8; i < count && o + 20 <= d.length; i++, o += 20) {
        chans.add(ByteData.sublistView(d).getUint32(o, Endian.little));
      }
      return TvtLoginInfo(deviceName: _cstr(d.sublist(0x8C, 0xAC)), channels: chans);
    }
    if (d.length < 80) return const TvtLoginInfo();
    // ConfigDataLen + 5 PTZ u32 + 12 flag bytes + audio sample + right + sw ver + build date.
    const macOff = 4 + 20 + 12 + 4 + 4 + 4 + 4;
    final mac = d.sublist(macOff, macOff + 6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
    return TvtLoginInfo(mac: mac.toUpperCase(), deviceName: _cstr(d.sublist(macOff + 6, macOff + 40)));
  }

  static String _cstr(List<int> b) {
    final end = b.indexOf(0);
    return latin1.decode(end < 0 ? b : b.sublist(0, end)).trim();
  }
}

/// Incremental decoder for the device → client byte stream.
class TvtStreamParser {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  bool _sawInit = false;

  TvtInit? init;
  final packets = <TvtPacket>[];

  void add(List<int> chunk) {
    _buf.add(_pending);
    _buf.add(chunk);
    var data = _buf.takeBytes();
    var off = 0;
    while (true) {
      if (data.length - off < 8) break;
      final f = String.fromCharCodes(data.sublist(off, off + 4));
      if (!_sawInit && f == 'head') {
        if (data.length - off < TvtCodec.initSize) break;
        init = TvtInit(Uint8List.fromList(data.sublist(off, off + TvtCodec.initSize)));
        _sawInit = true;
        off += TvtCodec.initSize;
        continue;
      }
      if (f != '1111' && f != 'head') {
        throw const FormatException('Not a TVT device stream');
      }
      _sawInit = true;
      final len = ByteData.sublistView(data).getUint32(off + 4, Endian.little);
      if (len > 16 * 1024 * 1024) throw const FormatException('Oversized TVT packet');
      if (data.length - off - 8 < len) break;
      if (len == 0) {
        packets.add(TvtPacket(-1, Uint8List(0)));
      } else if (len >= 16) {
        final v = ByteData.sublistView(data, off + 8, off + 8 + len);
        final dataLen = v.getUint32(12, Endian.little).clamp(0, len - 16);
        packets.add(
          TvtPacket(
            v.getUint32(0, Endian.little),
            Uint8List.fromList(data.sublist(off + 24, off + 24 + dataLen)),
            cmdId: v.getUint32(4, Endian.little),
            cmdVer: v.getUint32(8, Endian.little),
          ),
        );
      }
      off += 8 + len;
    }
    _pending = Uint8List.fromList(data.sublist(off));
  }
}
