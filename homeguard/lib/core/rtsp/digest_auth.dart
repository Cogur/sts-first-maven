import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A parsed `WWW-Authenticate` challenge (RFC 2617 / RFC 7616 subset).
///
/// Shared by RTSP and HTTP: both NVR families and intercom units use the same
/// header grammar.
class AuthChallenge {
  AuthChallenge({required this.scheme, required this.params});

  final String scheme;
  final Map<String, String> params;

  bool get isDigest => scheme.toLowerCase() == 'digest';
  bool get isBasic => scheme.toLowerCase() == 'basic';
  String get realm => params['realm'] ?? '';
  String get nonce => params['nonce'] ?? '';
  String? get opaque => params['opaque'];
  String get algorithm => (params['algorithm'] ?? 'MD5').toUpperCase();

  /// `qop` may list several options; we support `auth` only.
  bool get supportsQopAuth => (params['qop'] ?? '').split(',').map((e) => e.trim()).contains('auth');

  static final _param = RegExp(r'(\w+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))');

  static AuthChallenge? parse(String header) {
    final trimmed = header.trim();
    final space = trimmed.indexOf(' ');
    if (space <= 0) {
      return trimmed.isEmpty ? null : AuthChallenge(scheme: trimmed, params: {});
    }
    final scheme = trimmed.substring(0, space);
    final params = <String, String>{};
    for (final m in _param.allMatches(trimmed.substring(space + 1))) {
      params[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
    }
    return AuthChallenge(scheme: scheme, params: params);
  }

  /// Picks the strongest challenge when a server sends several headers.
  static AuthChallenge? pickBest(Iterable<String> headers) {
    final parsed = headers.map(parse).whereType<AuthChallenge>().toList();
    return parsed.where((c) => c.isDigest && c.algorithm == 'SHA-256').firstOrNull ??
        parsed.where((c) => c.isDigest).firstOrNull ??
        parsed.where((c) => c.isBasic).firstOrNull;
  }
}

/// Builds `Authorization` header values for a given challenge.
class DigestAuthenticator {
  DigestAuthenticator({required this.username, required this.password, String Function()? cnonce})
    : _cnonce = cnonce ?? _randomCnonce;

  final String username;
  final String password;
  final String Function() _cnonce;
  int _nonceCount = 0;
  String? _lastNonce;

  String authorize({required AuthChallenge challenge, required String method, required String uri}) {
    if (challenge.isBasic) {
      return 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    }
    final hash = challenge.algorithm.startsWith('SHA-256') ? sha256 : md5;
    String h(String s) => hash.convert(utf8.encode(s)).toString();

    if (challenge.nonce != _lastNonce) {
      _lastNonce = challenge.nonce;
      _nonceCount = 0;
    }
    final ha1 = h('$username:${challenge.realm}:$password');
    final ha2 = h('$method:$uri');
    final parts = <String>[
      'username="$username"',
      'realm="${challenge.realm}"',
      'nonce="${challenge.nonce}"',
      'uri="$uri"',
    ];
    if (challenge.supportsQopAuth) {
      _nonceCount++;
      final nc = _nonceCount.toRadixString(16).padLeft(8, '0');
      final cnonce = _cnonce();
      final response = h('$ha1:${challenge.nonce}:$nc:$cnonce:auth:$ha2');
      parts.addAll(['response="$response"', 'qop=auth', 'nc=$nc', 'cnonce="$cnonce"']);
    } else {
      parts.add('response="${h('$ha1:${challenge.nonce}:$ha2')}"');
    }
    if (challenge.params.containsKey('algorithm')) {
      parts.add('algorithm=${challenge.params['algorithm']}');
    }
    if (challenge.opaque != null) parts.add('opaque="${challenge.opaque}"');
    return 'Digest ${parts.join(', ')}';
  }

  static String _randomCnonce() {
    final r = Random.secure();
    final bytes = List<int>.generate(8, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
