import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

class OnvifDevice {
  OnvifDevice({required this.address, required this.xaddrs, required this.scopes});
  final InternetAddress address;
  final List<Uri> xaddrs;
  final List<String> scopes;

  /// Human-readable name/hardware from `onvif://www.onvif.org/name/...` scopes.
  String get label {
    String? scope(String key) => scopes
        .where((s) => s.contains('/$key/'))
        .map((s) => Uri.decodeComponent(s.split('/$key/').last))
        .firstOrNull;
    return [scope('name'), scope('hardware')].whereType<String>().join(' · ');
  }
}

class OnvifProfile {
  OnvifProfile({required this.token, required this.name, this.width, this.height});
  final String token;
  final String name;
  final int? width;
  final int? height;
}

/// ONVIF WS-Discovery (UDP multicast) and Media service helpers.
///
/// Used to find the door station / indoor monitor on the LAN and read their
/// real RTSP stream paths, so users never have to guess vendor URLs.
abstract final class Onvif {
  static final _multicast = InternetAddress('239.255.255.250');
  static const _port = 3702;

  /// Sends a WS-Discovery Probe and collects ProbeMatches for [window].
  static Future<List<OnvifDevice>> discover({Duration window = const Duration(seconds: 3)}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.multicastHops = 2;
    final found = <String, OnvifDevice>{};
    final messageId = 'uuid:${const Uuid().v4()}';
    final probe =
        '''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
 <e:Header>
  <w:MessageID>$messageId</w:MessageID>
  <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
  <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
 </e:Header>
 <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
</e:Envelope>''';

    final done = Completer<void>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final doc = XmlDocument.parse(utf8.decode(dg.data, allowMalformed: true));
        final xaddrs = doc
            .findAllElements('XAddrs', namespaceUri: '*')
            .expand((e) => e.innerText.split(RegExp(r'\s+')))
            .map(Uri.tryParse)
            .whereType<Uri>()
            .where((u) => u.host.isNotEmpty)
            .toList();
        final scopes = doc
            .findAllElements('Scopes', namespaceUri: '*')
            .expand((e) => e.innerText.split(RegExp(r'\s+')))
            .toList();
        if (xaddrs.isNotEmpty) {
          found[dg.address.address] = OnvifDevice(address: dg.address, xaddrs: xaddrs, scopes: scopes);
        }
      } on XmlException {
        // Ignore non-ONVIF chatter on the discovery port.
      }
    });
    final bytes = utf8.encode(probe);
    // UDP is lossy: send the probe twice (WS-Discovery recommends repeats).
    socket.send(bytes, _multicast, _port);
    Timer(const Duration(milliseconds: 300), () => socket.send(bytes, _multicast, _port));
    Timer(window, () => done.complete());
    await done.future;
    await sub.cancel();
    socket.close();
    return found.values.toList();
  }

  static Future<List<OnvifProfile>> getProfiles(
    Uri xaddr, {
    required String username,
    required String password,
    http.Client? client,
  }) async {
    final body = await _call(
      xaddr,
      '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>',
      username: username,
      password: password,
      client: client,
    );
    return body.findAllElements('Profiles', namespaceUri: '*').map((p) {
      final res = p.findAllElements('Resolution', namespaceUri: '*').firstOrNull;
      int? dim(String n) =>
          int.tryParse(res?.findElements(n, namespaceUri: '*').firstOrNull?.innerText ?? '');
      return OnvifProfile(
        token: p.getAttribute('token') ?? '',
        name: p.findElements('Name', namespaceUri: '*').firstOrNull?.innerText ?? '',
        width: dim('Width'),
        height: dim('Height'),
      );
    }).toList();
  }

  static Future<Uri?> getStreamUri(
    Uri xaddr,
    String profileToken, {
    required String username,
    required String password,
    http.Client? client,
  }) async {
    final body = await _call(
      xaddr,
      '''<GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl">
  <StreamSetup>
   <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>
   <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>
  </StreamSetup>
  <ProfileToken>${_escape(profileToken)}</ProfileToken>
</GetStreamUri>''',
      username: username,
      password: password,
      client: client,
    );
    final uri = body.findAllElements('Uri', namespaceUri: '*').firstOrNull?.innerText.trim();
    return uri == null ? null : Uri.tryParse(uri);
  }

  static Future<XmlDocument> _call(
    Uri xaddr,
    String bodyXml, {
    required String username,
    required String password,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final envelope =
          '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Header>${wsseHeader(username, password)}</s:Header>
 <s:Body>$bodyXml</s:Body>
</s:Envelope>''';
      final res = await c
          .post(xaddr, headers: {'Content-Type': 'application/soap+xml; charset=utf-8'}, body: envelope)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 400 || res.statusCode == 401) {
        throw const HttpException('ONVIF authentication failed');
      }
      if (res.statusCode >= 400) {
        throw HttpException('ONVIF call failed (HTTP ${res.statusCode})');
      }
      return XmlDocument.parse(res.body);
    } finally {
      if (client == null) c.close();
    }
  }

  /// WS-Security UsernameToken with PasswordDigest:
  /// Base64(SHA1(nonce + created + password)). The password never travels.
  static String wsseHeader(String username, String password, {DateTime? now, List<int>? nonce}) {
    final n = nonce ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final created = '${(now ?? DateTime.now()).toUtc().toIso8601String().split('.').first}Z';
    final digest = base64.encode(
      sha1.convert([...n, ...utf8.encode(created), ...utf8.encode(password)]).bytes,
    );
    return '''<Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
  <UsernameToken>
   <Username>${_escape(username)}</Username>
   <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</Password>
   <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${base64.encode(n)}</Nonce>
   <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</Created>
  </UsernameToken>
 </Security>''';
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}
