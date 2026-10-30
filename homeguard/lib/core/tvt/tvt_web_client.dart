import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../utils/log.dart';

/// Error from the NVR web interface. [code] is the device `errorCode`.
class TvtWebException implements Exception {
  TvtWebException(
    this.message, {
    this.code,
    this.authFailure = false,
    this.unreachable = false,
    this.notTvt = false,
  });
  final String message;
  final String? code;
  final bool authFailure;
  final bool unreachable;

  /// Something answered on the port, but not a TVT recorder web interface.
  final bool notTvt;
  @override
  String toString() => code == null ? message : '$message (errorCode $code)';
}

class TvtChannel {
  const TvtChannel({
    required this.number,
    required this.name,
    required this.id,
    this.ip = '',
    this.port = 0,
    this.model = '',
    this.online = false,
  });

  /// 1-based channel number, as used by the RTSP `chID` parameter.
  final int number;
  final String name;

  /// Device GUID used by the web interface.
  final String id;

  /// Address of the camera on the NVR's (PoE) network.
  final String ip;
  final int port;
  final String model;
  final bool online;
}

class TvtRtspServer {
  const TvtRtspServer({
    required this.enabled,
    required this.port,
    required this.authType,
    required this.anonymous,
  });
  final bool enabled;
  final int port;
  final String authType;
  final bool anonymous;
}

class TvtPorts {
  const TvtPorts({this.http = 80, this.https = 443, this.server = 6036, this.rtsp = 554});
  final int http;
  final int https;

  /// Binary SDK / SuperLive protocol port.
  final int server;
  final int rtsp;
}

/// Client for the NVMS-9000 web interface of TVT recorders: the same XML API
/// the NVR's own browser UI uses, so it accepts exactly the username and
/// password that work on the web page and in SuperLive Plus.
///
/// Protocol details follow the public reverse-engineering work in
/// pytvt (MIT, github.com/dannielperez/pytvt). TVT does not document it.
class TvtWebClient {
  TvtWebClient({
    required this.host,
    required this.username,
    required this.password,
    this.port = 80,
    this.secure = false,
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
  }) : _client = client ?? http.Client();

  final String host;
  final String username;
  final String password;
  final int port;
  final bool secure;
  final Duration timeout;
  final http.Client _client;

  String? _cookie;
  String? _token;
  String? _basicAuth;
  bool _loggedIn = false;

  bool get loggedIn => _loggedIn;

  /// Login hash used by current firmware:
  /// `SHA512(upper(MD5(password)) + "#" + nonce)`.
  static String hashPassword(String password, String nonce) {
    final md5Hex = md5.convert(utf8.encode(password)).toString().toUpperCase();
    return sha512.convert(utf8.encode('$md5Hex#$nonce')).toString();
  }

  static String _envelope(String? token, [String content = '']) =>
      '<?xml version="1.0" encoding="utf-8" ?><request version="1.0" systemType="NVMS-9000" '
      'clientType="WEB"><token>${token ?? 'null'}</token>$content</request>';

  static String cdata(String v) => '<![CDATA[${v.replaceAll(']]>', ']]]]><![CDATA[>')}]]>';

  Uri _uri(String cmd) => Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: '/$cmd');

  Future<String> _post(String cmd, [String content = '']) async {
    final req = http.Request('POST', _uri(cmd))
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
      ..body = _envelope(_token, content);
    if (_cookie != null) req.headers['Cookie'] = _cookie!;
    if (_basicAuth != null) req.headers['Authorization'] = _basicAuth!;
    try {
      final res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) _cookie = setCookie.split(';').first;
      Log.d('tvt-web', '$cmd → ${res.statusCode}');
      if (res.statusCode == 401) throw TvtWebException('NVR rejected the credentials', authFailure: true);
      if (res.statusCode >= 400) throw TvtWebException('$cmd: HTTP ${res.statusCode}');
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } on TimeoutException {
      throw TvtWebException('$host:$port did not answer', unreachable: true);
    } on SocketException catch (e) {
      throw TvtWebException(
        'Cannot reach $host:$port (${e.osError?.message ?? e.message})',
        unreachable: true,
      );
    } on http.ClientException catch (e) {
      throw TvtWebException('Cannot reach $host:$port (${e.message})', unreachable: true);
    }
  }

  static String? field(String xml, String name) {
    final m = RegExp('<$name(?:\\s[^>]*)?>(.*?)</$name>', dotAll: true).firstMatch(xml);
    if (m == null) return null;
    var v = m.group(1)!.trim();
    final cd = RegExp(r'^<!\[CDATA\[(.*)\]\]>$', dotAll: true).firstMatch(v);
    if (cd != null) v = cd.group(1)!;
    return v;
  }

  static bool isSuccess(String xml) => field(xml, 'status') == 'success';

  void _check(String xml, String cmd) {
    if (!isSuccess(xml)) {
      final code = field(xml, 'errorCode');
      throw TvtWebException('$cmd failed', code: code);
    }
  }

  static const _legacyNoNonce = '536870934';

  /// Challenge-response login (`reqLogin` → `doLogin`), with the plain
  /// base64 + HTTP Basic variant of old firmware as fallback.
  Future<void> login() async {
    String challenge;
    try {
      challenge = await _post('reqLogin');
    } on TvtWebException catch (e) {
      if (e.unreachable) rethrow;
      throw TvtWebException('Not a TVT/Techson recorder web interface ($e)', notTvt: true);
    }
    final nonce = field(challenge, 'nonce');
    if (nonce == null || nonce.isEmpty) {
      if (field(challenge, 'errorCode') == _legacyNoNonce) return _loginLegacy();
      throw TvtWebException(
        'Not a TVT/Techson recorder web interface',
        code: field(challenge, 'errorCode'),
        notTvt: field(challenge, 'status') == null,
      );
    }
    _token = field(challenge, 'token');
    final res = await _post(
      'doLogin',
      '<content><userName>${cdata(username)}</userName>'
          '<password>${cdata(hashPassword(password, nonce))}</password></content>',
    );
    if (!isSuccess(res)) {
      // A rejected doLogin is a wrong password or a locked account; the
      // device does not distinguish them in a documented way.
      throw TvtWebException('Invalid username or password', code: field(res, 'errorCode'), authFailure: true);
    }
    _token ??= field(res, 'token');
    _loggedIn = true;
  }

  Future<void> _loginLegacy() async {
    final res = await _post(
      'doLogin',
      '<content><userName>${cdata(username)}</userName>'
          '<password>${cdata(base64.encode(utf8.encode(password)))}</password></content>',
    );
    if (!isSuccess(res)) {
      throw TvtWebException('Invalid username or password', code: field(res, 'errorCode'), authFailure: true);
    }
    _basicAuth = 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    _loggedIn = true;
  }

  Future<String> command(String cmd, [String content = '']) async {
    if (!_loggedIn) throw TvtWebException('Not logged in');
    final res = await _post(cmd, content);
    _check(res, cmd);
    return res;
  }

  /// Camera channels with their online state.
  Future<List<TvtChannel>> channels() async {
    final devs = await command('queryDevList');
    final online = <String>{};
    try {
      final o = await command('queryOnlineChlList');
      online.addAll(RegExp(r'<item\s+id="([^"]+)"').allMatches(o).map((m) => m[1]!));
    } on TvtWebException catch (e) {
      Log.w('tvt-web', 'queryOnlineChlList: $e');
    }
    final out = <TvtChannel>[];
    for (final m in RegExp(r'<item\s+id="([^"]+)"[^>]*>(.*?)</item>', dotAll: true).allMatches(devs)) {
      final block = m[2]!;
      final number = int.tryParse(field(block, 'chlNum') ?? '') ?? 0;
      if (number <= 0) continue;
      out.add(
        TvtChannel(
          number: number,
          id: m[1]!,
          name: field(block, 'name') ?? 'Camera $number',
          ip: field(block, 'ip') ?? '',
          port: int.tryParse(field(block, 'port') ?? '') ?? 0,
          model: field(block, 'productModel') ?? '',
          online: online.contains(m[1]),
        ),
      );
    }
    out.sort((a, b) => a.number.compareTo(b.number));
    return out;
  }

  Future<TvtRtspServer> rtspServer() async {
    final x = await command('queryRTSPServer');
    return TvtRtspServer(
      enabled: field(x, 'rtspServerSwitch') == 'true',
      port: int.tryParse(field(x, 'rtspPort') ?? '') ?? 554,
      authType: field(x, 'rtspAuthType') ?? 'Digest',
      anonymous: field(x, 'anonymousAccess') == 'true',
    );
  }

  /// Turns on the recorder's RTSP service. Anonymous access is always
  /// disabled: streams must keep requiring the account password.
  Future<void> enableRtsp({int port = 554, String authType = 'Digest'}) => command(
    'editRTSPServer',
    '<content><rtspServerSwitch>true</rtspServerSwitch><rtspAuthType>$authType</rtspAuthType>'
        '<rtspPort>$port</rtspPort><anonymousAccess>false</anonymousAccess></content>',
  );

  /// Turns on the HTTP API service ("API Server"), needed for recording
  /// search and snapshots through [TvtLapiClient].
  Future<bool> apiServerEnabled() async {
    final x = await command('queryApiServer');
    return field(field(x, 'content') ?? x, 'apiserverSwitch') == 'true';
  }

  Future<void> enableApiServer({String authType = 'Digest'}) => command(
    'editApiServer',
    '<content><apiserverSwitch>true</apiserverSwitch>'
        '<authenticationType>$authType</authenticationType></content>',
  );

  Future<TvtPorts> ports() async {
    final x = await command('queryNetPortCfg');
    int p(String name, int d) => int.tryParse(field(x, name) ?? '') ?? d;
    return TvtPorts(
      http: p('httpPort', 80),
      https: p('httpsPort', 443),
      server: p('netPort', 6036),
      rtsp: p('rtspPort', 554),
    );
  }

  void close() => _client.close();
}
