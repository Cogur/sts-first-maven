enum EventType {
  faceDetected('Face Detected'),
  motion('Motion'),
  doorbellRing('Call Received'),
  manualSnapshot('Manual Snapshot'),
  doorUnlocked('Door Unlocked'),
  rfidAccess('RFID Access'),
  other('Event');

  const EventType(this.label);
  final String label;

  /// Infers the event type from file names written by indoor monitors and
  /// NVRs, e.g. `20260115_083012_FACE.jpg`, `call_2026-01-15-08-30-12.jpg`.
  static EventType fromHint(String hint) {
    final h = hint.toLowerCase();
    if (h.contains('face')) return EventType.faceDetected;
    if (h.contains('call') || h.contains('ring') || h.contains('bell')) {
      return EventType.doorbellRing;
    }
    if (h.contains('motion') || h.contains('md_') || h.contains('vmd')) {
      return EventType.motion;
    }
    if (h.contains('card') || h.contains('rfid') || h.contains('ic_')) {
      return EventType.rfidAccess;
    }
    if (h.contains('unlock') || h.contains('open')) return EventType.doorUnlocked;
    if (h.contains('manual') || h.contains('snap')) return EventType.manualSnapshot;
    return EventType.other;
  }
}

enum MediaKind { image, video, none }

class SecurityEvent {
  const SecurityEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.deviceId,
    this.mediaPath,
    this.mediaKind = MediaKind.none,
    this.note,
  });

  final String id;
  final EventType type;
  final DateTime timestamp;
  final String deviceId;

  /// Absolute path inside the app sandbox.
  final String? mediaPath;
  final MediaKind mediaKind;
  final String? note;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'ts': timestamp.toUtc().toIso8601String(),
    'deviceId': deviceId,
    'mediaPath': mediaPath,
    'mediaKind': mediaKind.name,
    'note': note,
  };

  factory SecurityEvent.fromJson(Map<String, Object?> j) => SecurityEvent(
    id: j['id']! as String,
    type: EventType.values.asNameMap()[j['type']] ?? EventType.other,
    timestamp: DateTime.parse(j['ts']! as String).toLocal(),
    deviceId: j['deviceId'] as String? ?? '',
    mediaPath: j['mediaPath'] as String?,
    mediaKind: MediaKind.values.asNameMap()[j['mediaKind']] ?? MediaKind.none,
    note: j['note'] as String?,
  );

  static final _compact = RegExp(r'(20\d{2})(\d{2})(\d{2})[_\-T ]?(\d{2})(\d{2})(\d{2})');
  static final _separated = RegExp(
    r'(20\d{2})[-_.](\d{2})[-_.](\d{2})[-_.T ](\d{2})[-_.:](\d{2})[-_.:](\d{2})',
  );

  /// Extracts a timestamp embedded in a device file name, if any.
  static DateTime? timestampFromName(String name) {
    final m = _separated.firstMatch(name) ?? _compact.firstMatch(name);
    if (m == null) return null;
    final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (p[1] < 1 || p[1] > 12 || p[2] < 1 || p[2] > 31 || p[3] > 23 || p[4] > 59 || p[5] > 59) {
      return null;
    }
    return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
  }

  static MediaKind mediaKindFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'bmp', 'webp'}.contains(ext)) return MediaKind.image;
    if (const {'mp4', 'mov', 'avi', 'mkv', 'h264', 'h265', '264', '265', 'ts'}.contains(ext)) {
      return MediaKind.video;
    }
    return MediaKind.none;
  }
}
