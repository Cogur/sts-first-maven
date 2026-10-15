/// Device kinds in a Techson / TVT-style installation.
enum DeviceKind {
  /// Network video recorder (e.g. TCR I12 S04-NS). Owns the camera channels.
  nvr,

  /// Camera recorded by the NVR; streams are pulled via the NVR channel.
  camera,

  /// Outdoor door station with RFID reader (e.g. TCTDB102).
  doorStation,

  /// Indoor monitor that stores event snapshots (e.g. TCTIS716).
  indoorMonitor,
}

/// How the app may reach a device when it is not on the local network.
enum RemoteMode {
  /// LAN only. Nothing is ever sent across the internet.
  disabled,

  /// The remote host is inside a trusted tunnel (WireGuard, Tailscale,
  /// IPsec). Plain RTSP/HTTP is allowed because the tunnel encrypts it.
  vpn,

  /// Direct exposure over the internet. Only `https://` and `rtsps://` are
  /// permitted; plaintext connections are refused.
  tls,
}

enum StreamQuality { main, sub }

class DeviceConfig {
  const DeviceConfig({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.lanHost = '',
    this.remoteHost = '',
    this.remoteMode = RemoteMode.disabled,
    this.httpPort = 80,
    this.httpsPort = 443,
    this.rtspPort = 554,
    this.rtspsPort = 322,
    this.channel = 1,
    this.rtspPathTemplate = tvtRtspTemplate,
    this.unlockPath = '',
    this.unlockMethod = 'GET',
    this.unlockBody = '',
    this.eventIndexPath = '',
    this.supportsTalk = false,
    this.enabled = true,
  });

  /// RTSP path template used by TVT-family recorders (SuperLive Plus devices).
  /// `{channel}` is 1-based, `{stream}` is `main` or `sub`.
  static const tvtRtspTemplate = '/chID={channel}&streamType={stream}&linkType=tcp';

  final String id;
  final String name;
  final DeviceKind kind;

  /// For cameras: the NVR they stream through. Hosts, ports and credentials
  /// are inherited from the parent.
  final String? parentId;
  final String lanHost;
  final String remoteHost;
  final RemoteMode remoteMode;
  final int httpPort;
  final int httpsPort;
  final int rtspPort;
  final int rtspsPort;
  final int channel;
  final String rtspPathTemplate;

  /// Relay trigger, relative to the device HTTP root, e.g.
  /// `/cgi-bin/accessControl.cgi?action=openDoor&channel=1`.
  final String unlockPath;
  final String unlockMethod;
  final String unlockBody;

  /// HTTP path on the indoor monitor that lists stored snapshots.
  final String eventIndexPath;
  final bool supportsTalk;
  final bool enabled;

  bool get hasVideo => kind == DeviceKind.camera || kind == DeviceKind.doorStation;
  bool get canUnlock => unlockPath.isNotEmpty;

  String rtspPath(StreamQuality quality) => rtspPathTemplate
      .replaceAll('{channel}', '$channel')
      .replaceAll('{channel0}', '${channel - 1}')
      .replaceAll('{stream}', quality.name)
      .replaceAll('{streamIndex}', quality == StreamQuality.main ? '0' : '1');

  DeviceConfig copyWith({
    String? name,
    String? lanHost,
    String? remoteHost,
    RemoteMode? remoteMode,
    int? httpPort,
    int? httpsPort,
    int? rtspPort,
    int? rtspsPort,
    int? channel,
    String? rtspPathTemplate,
    String? unlockPath,
    String? unlockMethod,
    String? unlockBody,
    String? eventIndexPath,
    bool? supportsTalk,
    bool? enabled,
  }) => DeviceConfig(
    id: id,
    name: name ?? this.name,
    kind: kind,
    parentId: parentId,
    lanHost: lanHost ?? this.lanHost,
    remoteHost: remoteHost ?? this.remoteHost,
    remoteMode: remoteMode ?? this.remoteMode,
    httpPort: httpPort ?? this.httpPort,
    httpsPort: httpsPort ?? this.httpsPort,
    rtspPort: rtspPort ?? this.rtspPort,
    rtspsPort: rtspsPort ?? this.rtspsPort,
    channel: channel ?? this.channel,
    rtspPathTemplate: rtspPathTemplate ?? this.rtspPathTemplate,
    unlockPath: unlockPath ?? this.unlockPath,
    unlockMethod: unlockMethod ?? this.unlockMethod,
    unlockBody: unlockBody ?? this.unlockBody,
    eventIndexPath: eventIndexPath ?? this.eventIndexPath,
    supportsTalk: supportsTalk ?? this.supportsTalk,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'parentId': parentId,
    'lanHost': lanHost,
    'remoteHost': remoteHost,
    'remoteMode': remoteMode.name,
    'httpPort': httpPort,
    'httpsPort': httpsPort,
    'rtspPort': rtspPort,
    'rtspsPort': rtspsPort,
    'channel': channel,
    'rtspPathTemplate': rtspPathTemplate,
    'unlockPath': unlockPath,
    'unlockMethod': unlockMethod,
    'unlockBody': unlockBody,
    'eventIndexPath': eventIndexPath,
    'supportsTalk': supportsTalk,
    'enabled': enabled,
  };

  factory DeviceConfig.fromJson(Map<String, Object?> j) => DeviceConfig(
    id: j['id']! as String,
    name: j['name'] as String? ?? '',
    kind: DeviceKind.values.byName(j['kind']! as String),
    parentId: j['parentId'] as String?,
    lanHost: j['lanHost'] as String? ?? '',
    remoteHost: j['remoteHost'] as String? ?? '',
    remoteMode: RemoteMode.values.asNameMap()[j['remoteMode']] ?? RemoteMode.disabled,
    httpPort: j['httpPort'] as int? ?? 80,
    httpsPort: j['httpsPort'] as int? ?? 443,
    rtspPort: j['rtspPort'] as int? ?? 554,
    rtspsPort: j['rtspsPort'] as int? ?? 322,
    channel: j['channel'] as int? ?? 1,
    rtspPathTemplate: j['rtspPathTemplate'] as String? ?? tvtRtspTemplate,
    unlockPath: j['unlockPath'] as String? ?? '',
    unlockMethod: j['unlockMethod'] as String? ?? 'GET',
    unlockBody: j['unlockBody'] as String? ?? '',
    eventIndexPath: j['eventIndexPath'] as String? ?? '',
    supportsTalk: j['supportsTalk'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? true,
  );

  /// Initial topology: 1 NVR with 3 camera channels, a door station and an
  /// indoor monitor. Hosts are filled in on the login screen / settings.
  static List<DeviceConfig> defaultTopology({String nvrHost = ''}) => [
    DeviceConfig(id: 'nvr', name: 'NVR', kind: DeviceKind.nvr, lanHost: nvrHost),
    for (var ch = 1; ch <= 3; ch++)
      DeviceConfig(id: 'cam$ch', name: 'Camera $ch', kind: DeviceKind.camera, parentId: 'nvr', channel: ch),
    const DeviceConfig(
      id: 'door',
      name: 'Front Door',
      kind: DeviceKind.doorStation,
      // Door stations differ by OEM; use ONVIF discovery in settings to
      // fill the real stream path.
      rtspPathTemplate: '/live/{stream}',
      supportsTalk: true,
    ),
    const DeviceConfig(id: 'monitor', name: 'Indoor Monitor', kind: DeviceKind.indoorMonitor),
  ];
}
