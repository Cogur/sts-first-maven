import 'dart:convert';
import 'dart:typed_data';

import '../network/device_http_client.dart';
import '../security/secure_store.dart';
import '../tvt/tvt_lapi_client.dart';

/// Recording found through a HomeGuard Bridge, with the bridge stream that
/// plays it.
class BridgeRecording {
  const BridgeRecording(this.segment, this.path);
  final RecordSegment segment;
  final String path;
}

/// HTTPS API of a HomeGuard Bridge (`tools/bridge`). Always TLS.
class BridgeClient {
  BridgeClient({required this.host, required this.port, required this.credentials, DeviceHttpClient? http})
    : _http = http ?? DeviceHttpClient(timeout: const Duration(seconds: 25)); // P2P logins are slow

  final String host;
  final int port;
  final Credentials credentials;
  final DeviceHttpClient _http;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: host, port: port, path: path, queryParameters: query);

  Future<Object?> _json(String method, String path, [Map<String, String>? query]) async {
    final res = await _http.send(method, _uri(path, query), credentials: credentials);
    return jsonDecode(res.body);
  }

  Future<List<Map<String, Object?>>> devices() async {
    final j = await _json('GET', '/api/devices') as Map<String, Object?>;
    return (j['devices'] as List? ?? const []).cast<Map<String, Object?>>();
  }

  Future<Uint8List> snapshot(String recorderId, int channel) async => (await _http.send(
    'GET',
    _uri('/api/devices/$recorderId/channels/$channel/snapshot.jpg'),
    credentials: credentials,
  )).bodyBytes;

  /// Times are wall-clock times of the recorder (no time zone).
  Future<List<BridgeRecording>> recordings(String recorderId, int channel, DateTime from, DateTime to) async {
    final j = await _json('GET', '/api/devices/$recorderId/channels/$channel/recordings', {
      'from': TvtLapiClient.formatTime(from),
      'to': TvtLapiClient.formatTime(to),
    }) as Map<String, Object?>;
    final out = <BridgeRecording>[];
    for (final r in (j['recordings'] as List? ?? const []).cast<Map<String, Object?>>()) {
      final s = DateTime.tryParse(r['start'] as String? ?? '')?.toLocal();
      final e = DateTime.tryParse(r['end'] as String? ?? '')?.toLocal();
      final path = r['path'] as String?;
      if (s == null || e == null || path == null) continue;
      out.add(
        BridgeRecording(RecordSegment(channel: channel, start: s, end: e, type: '${r['type'] ?? ''}'), path),
      );
    }
    return out;
  }

  Future<void> pulseAlarmOutput(String deviceId, int output, Duration hold) => _http.send(
    'POST',
    _uri('/api/devices/$deviceId/alarm-outputs/$output/pulse', {'ms': '${hold.inMilliseconds}'}),
    credentials: credentials,
  );
}
