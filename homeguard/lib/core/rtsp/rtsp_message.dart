import 'dart:convert';
import 'dart:typed_data';

/// An RTSP/1.0 response, parsed from the control connection.
class RtspResponse {
  RtspResponse({required this.statusCode, required this.reason, required this.headers, required this.body});

  final int statusCode;
  final String reason;

  /// Header names are lower-cased; repeated headers keep every value.
  final Map<String, List<String>> headers;
  final String body;

  String? header(String name) => headers[name.toLowerCase()]?.first;
  List<String> headerAll(String name) => headers[name.toLowerCase()] ?? const [];
  int? get cseq => int.tryParse(header('cseq') ?? '');
  bool get ok => statusCode >= 200 && statusCode < 300;

  /// Session id without the `;timeout=` suffix.
  String? get session => header('session')?.split(';').first.trim();

  /// Server-advertised session timeout in seconds (RFC 2326 default 60).
  int get sessionTimeout {
    final raw = header('session');
    final m = RegExp(r'timeout\s*=\s*(\d+)').firstMatch(raw ?? '');
    return int.tryParse(m?.group(1) ?? '') ?? 60;
  }
}

/// Incremental parser for an RTSP-over-TCP byte stream.
///
/// The same socket carries text responses and, after PLAY, `$`-framed
/// interleaved RTP/RTCP packets (RFC 2326 §10.12). The parser separates them.
class RtspStreamParser {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  final List<RtspResponse> responses = [];
  final List<InterleavedPacket> packets = [];

  void add(List<int> data) {
    _buffer.add(_pending);
    _buffer.add(data);
    _pending = _buffer.takeBytes();
    _drain();
  }

  void _drain() {
    var offset = 0;
    while (offset < _pending.length) {
      if (_pending[offset] == 0x24) {
        // '$' channel(1) length(2) payload
        if (_pending.length - offset < 4) break;
        final channel = _pending[offset + 1];
        final len = (_pending[offset + 2] << 8) | _pending[offset + 3];
        if (_pending.length - offset < 4 + len) break;
        packets.add(
          InterleavedPacket(channel, Uint8List.sublistView(_pending, offset + 4, offset + 4 + len)),
        );
        offset += 4 + len;
        continue;
      }
      final headerEnd = _indexOfCrlfCrlf(_pending, offset);
      if (headerEnd < 0) break;
      final head = latin1.decode(_pending.sublist(offset, headerEnd));
      final lines = head.split('\r\n');
      final headers = <String, List<String>>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        headers
            .putIfAbsent(line.substring(0, colon).trim().toLowerCase(), () => [])
            .add(line.substring(colon + 1).trim());
      }
      final contentLength = int.tryParse(headers['content-length']?.first ?? '') ?? 0;
      final bodyStart = headerEnd + 4;
      if (_pending.length < bodyStart + contentLength) break;
      final body = utf8.decode(_pending.sublist(bodyStart, bodyStart + contentLength), allowMalformed: true);
      final status = lines.first.split(' ');
      if (status.length < 2 || !status.first.startsWith('RTSP/')) {
        throw FormatException('Not an RTSP response: ${lines.first}');
      }
      responses.add(
        RtspResponse(
          statusCode: int.tryParse(status[1]) ?? 0,
          reason: status.length > 2 ? status.sublist(2).join(' ') : '',
          headers: headers,
          body: body,
        ),
      );
      offset = bodyStart + contentLength;
    }
    _pending = Uint8List.sublistView(_pending, offset);
  }

  static int _indexOfCrlfCrlf(Uint8List b, int from) {
    for (var i = from; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

class InterleavedPacket {
  InterleavedPacket(this.channel, this.payload);
  final int channel;
  final Uint8List payload;
}
