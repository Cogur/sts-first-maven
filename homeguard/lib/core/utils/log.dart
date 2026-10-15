import 'package:flutter/foundation.dart';

/// Logging that never leaks credentials.
///
/// Debug builds print to the console; release builds keep only warnings and
/// errors in a small in-memory ring buffer that the Network Status screen can
/// show. Nothing is written to disk.
abstract final class Log {
  static const _capacity = 200;
  static final List<String> _ring = [];

  static List<String> get recent => List.unmodifiable(_ring);

  static void d(String tag, String message) {
    if (kDebugMode) debugPrint('[$tag] ${redact(message)}');
  }

  static void w(String tag, String message) => _keep('W', tag, message);
  static void e(String tag, String message) => _keep('E', tag, message);

  static void _keep(String level, String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} $level/$tag ${redact(message)}';
    if (kDebugMode) debugPrint(line);
    _ring.add(line);
    if (_ring.length > _capacity) _ring.removeAt(0);
  }

  static final _userInfo = RegExp(r'([a-z][a-z0-9+.-]*://)[^/@\s]+@', caseSensitive: false);
  static final _authHeader = RegExp(r'(Authorization:\s*)(\S+\s+)?[^\r\n]+', caseSensitive: false);
  static final _queryCreds = RegExp(
    r'([?&](?:password|pwd|pass|token|user|username)=)[^&\s]+',
    caseSensitive: false,
  );

  /// Strips `user:pass@` from URLs, auth headers and credential query params.
  static String redact(String input) => input
      .replaceAllMapped(_userInfo, (m) => '${m[1]}***@')
      .replaceAllMapped(_authHeader, (m) => '${m[1]}***')
      .replaceAllMapped(_queryCreds, (m) => '${m[1]}***');

  static String redactUrl(String url) => redact(url);
}
