/// Minimal SDP (RFC 4566) model: just what stream probing and the
/// ONVIF audio back-channel need.
class SdpSession {
  SdpSession({required this.media, this.sessionControl});

  final List<SdpMedia> media;
  final String? sessionControl;

  Iterable<SdpMedia> get video => media.where((m) => m.type == 'video');
  Iterable<SdpMedia> get audio => media.where((m) => m.type == 'audio');

  /// ONVIF back-channel tracks are audio sections marked `a=sendonly`
  /// (from the server's point of view: the server *receives*).
  SdpMedia? get backchannel => audio.where((m) => m.direction == 'sendonly').firstOrNull;

  static SdpSession parse(String sdp) {
    final media = <SdpMedia>[];
    String? sessionControl;
    SdpMedia? current;
    for (final raw in sdp.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.length < 2 || line[1] != '=') continue;
      final value = line.substring(2);
      switch (line[0]) {
        case 'm':
          final parts = value.split(' ');
          current = SdpMedia(
            type: parts.first,
            payloadTypes: parts.skip(3).map(int.tryParse).whereType<int>().toList(),
          );
          media.add(current);
        case 'a':
          final colon = value.indexOf(':');
          final key = colon < 0 ? value : value.substring(0, colon);
          final attr = colon < 0 ? '' : value.substring(colon + 1);
          if (current == null) {
            if (key == 'control') sessionControl = attr;
            continue;
          }
          switch (key) {
            case 'control':
              current.control = attr;
            case 'rtpmap':
              final sp = attr.indexOf(' ');
              final pt = int.tryParse(attr.substring(0, sp < 0 ? attr.length : sp));
              if (pt != null && sp > 0) current.rtpmap[pt] = attr.substring(sp + 1);
            case 'sendonly' || 'recvonly' || 'sendrecv' || 'inactive':
              current.direction = key;
          }
      }
    }
    return SdpSession(media: media, sessionControl: sessionControl);
  }
}

class SdpMedia {
  SdpMedia({required this.type, required this.payloadTypes});

  final String type;
  final List<int> payloadTypes;
  final Map<int, String> rtpmap = {};
  String? control;
  String direction = 'sendrecv';

  /// Codec name for the first payload type, e.g. `H264`, `H265`, `PCMU`.
  String get codec {
    if (payloadTypes.isEmpty) return 'unknown';
    final pt = payloadTypes.first;
    final mapped = rtpmap[pt];
    if (mapped != null) return mapped.split('/').first.toUpperCase();
    return switch (pt) {
      0 => 'PCMU',
      8 => 'PCMA',
      26 => 'JPEG',
      _ => 'PT$pt',
    };
  }

  /// Resolves this track's control URL against the content base.
  String resolveControl(String base) {
    final c = control;
    if (c == null || c.isEmpty || c == '*') return base;
    if (c.startsWith('rtsp://') || c.startsWith('rtsps://')) return c;
    return base.endsWith('/') ? '$base$c' : '$base/$c';
  }
}
