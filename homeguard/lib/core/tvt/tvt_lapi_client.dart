import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../network/device_http_client.dart';
import '../security/secure_store.dart';
import '../utils/log.dart';

class RecordSegment {
  const RecordSegment({required this.channel, required this.start, required this.end, this.type = ''});
  final int channel;
  final DateTime start;
  final DateTime end;

  /// e.g. `manual`, `schedule`, `motion`, `alarm` (firmware dependent).
  final String type;

  Duration get length => end.difference(start);
  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
}

class TvtNatInfo {
  const TvtNatInfo({required this.enabled, this.serial, this.status, this.server});
  final bool enabled;

  /// Cloud ID shown in SuperLive Plus ("add by serial / QR code").
  final String? serial;
  final String? status;
  final String? server;
}

/// Client for the TVT "HTTP API" (`/LAPI/V1.0/...` and the flat
/// `/GetSnapshot/{ch}` form), enabled on the recorder as **API Server**.
///
/// The command set follows TVT's *HTTP API Protocol User Guide for IP Media
/// Device* (v1.5–2.0; copies circulate under OEM brands) as implemented in
/// pytvt. Firmware differs, so callers should check [supportedApis] first.
class TvtLapiClient {
  TvtLapiClient({
    required this.host,
    required this.credentials,
    this.port = 80,
    this.secure = false,
    DeviceHttpClient? http,
  }) : _http = http ?? DeviceHttpClient(timeout: const Duration(seconds: 8));

  final String host;
  final Credentials credentials;
  final int port;
  final bool secure;
  final DeviceHttpClient _http;
  Set<String>? _apis;

  Uri _uri(String path) => Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: path);

  /// Firmware answers either `/LAPI/V1.0/<group>/<name>` or the flat
  /// `/<CommandName>[/channel]` form of the HTTP API guide; remembered once seen.
  bool? _flat;

  /// Which URL form the device answered: `flat`, `LAPI`, or null if unknown.
  String? get urlStyle => _flat == null ? null : (_flat! ? 'flat' : 'LAPI');

  Future<XmlDocument> _post(String path, [String body = '', String? flat]) async {
    Future<http.Response> send(String p) => _http.send(
      'POST',
      _uri(p),
      credentials: credentials,
      body: body.isEmpty ? null : '<?xml version="1.0" encoding="utf-8"?>$body',
      headers: const {'Content-Type': 'application/xml', 'Accept': 'application/xml'},
    );
    http.Response res;
    if (_flat == true && flat != null) {
      res = await send(flat);
    } else {
      try {
        res = await send('/LAPI/V1.0$path');
        _flat = false;
      } on DeviceHttpException catch (e) {
        if (e.statusCode != 404 || flat == null) rethrow;
        res = await send(flat);
        _flat = true;
      }
    }
    final doc = XmlDocument.parse(res.body);
    final status = doc.findAllElements('statusCode').firstOrNull?.innerText.trim();
    if (status != null && status != '200' && status != '0') {
      final text = doc.findAllElements('statusString').firstOrNull?.innerText.trim() ?? '';
      throw DeviceHttpException('$path: device status $status $text'.trim());
    }
    return doc;
  }

  static String _text(XmlElement e, String name) => e.findElements(name).firstOrNull?.innerText.trim() ?? '';

  /// API names the device advertises, e.g. `SearchByTime`, `GetSnapshot`.
  Future<Set<String>> supportedApis() async {
    if (_apis != null) return _apis!;
    final doc = await _post('/System/SupportedAPIs', '', '/GetSupportedAPIs');
    return _apis = {
      for (final e in doc.findAllElements('apiName'))
        if (e.innerText.trim().isNotEmpty) e.innerText.trim(),
    };
  }

  Future<Map<String, String>> deviceInfo() async {
    final doc = await _post('/System/DeviceInfo', '', '/GetDeviceInfo');
    final root = doc.findAllElements('DeviceInfo').firstOrNull ?? doc.rootElement;
    return {
      for (final e in root.childElements)
        if (e.childElements.isEmpty) e.name.local: e.innerText.trim(),
    };
  }

  Future<TvtNatInfo> natInfo() async {
    XmlDocument doc;
    try {
      doc = await _post('/Network/NAT');
    } on DeviceHttpException {
      doc = await _post('/Network/NATConfig');
    }
    String pick(List<String> names) {
      for (final n in names) {
        final v = doc.findAllElements(n).firstOrNull?.innerText.trim();
        if (v != null && v.isNotEmpty) return v;
      }
      return '';
    }

    final enabled = pick(['enabled', 'natEnabled', 'enable']).toLowerCase();
    final serial = pick(['natSerial', 'serialNumber', 'cloudSN', 'p2pSerial', 'deviceSerial']);
    return TvtNatInfo(
      enabled: enabled == 'true' || enabled == '1',
      serial: serial.isEmpty ? null : serial,
      status: pick(['natStatus', 'status']),
      server: pick(['visitAddress', 'serverAddress']),
    );
  }

  /// Days of [year]/[month] that have recordings on [channel].
  Future<Set<DateTime>> recordDates(int channel, int year, int month) async {
    final doc = await _post(
      '/Playback/SearchRecordDate',
      '<SearchRecordDate><channelID>$channel</channelID><year>$year</year><month>$month</month></SearchRecordDate>',
      '/SearchRecordDate/$channel',
    );
    final out = <DateTime>{};
    for (final e in doc.findAllElements('date')) {
      final t = e.innerText.trim();
      final d = DateTime.tryParse(t) ?? _dayOfMonth(t, year, month);
      if (d != null) out.add(DateTime(d.year, d.month, d.day));
    }
    return out;
  }

  static DateTime? _dayOfMonth(String t, int year, int month) {
    final day = int.tryParse(t);
    return day == null || day < 1 || day > 31 ? null : DateTime(year, month, day);
  }

  /// Device-local wall-clock time, formatted as the HTTP API expects.
  static String formatTime(DateTime t, {bool isoT = true}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}${isoT ? 'T' : ' '}'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Recording segments of [channel] between [from] and [to].
  Future<List<RecordSegment>> searchByTime(int channel, DateTime from, DateTime to) async {
    Future<XmlDocument> run(bool isoT) => _post(
      '/Playback/SearchByTime',
      '<SearchByTime><channelID>$channel</channelID>'
          '<startTime>${formatTime(from, isoT: isoT)}</startTime>'
          '<endTime>${formatTime(to, isoT: isoT)}</endTime></SearchByTime>',
      '/SearchByTime/$channel',
    );
    XmlDocument doc;
    try {
      doc = await run(true);
    } on DeviceHttpException catch (e) {
      // Older documents use "YYYY-MM-DD hh:mm:ss".
      Log.d('lapi', 'SearchByTime ISO form rejected ($e), retrying');
      doc = await run(false);
    }
    final out = <RecordSegment>[];
    for (final e in doc.findAllElements('RecordSegment')) {
      final s = _parseTime(_text(e, 'startTime'));
      final end = _parseTime(_text(e, 'endTime'));
      if (s == null || end == null || !end.isAfter(s)) continue;
      out.add(
        RecordSegment(
          channel: int.tryParse(_text(e, 'channelID')) ?? channel,
          start: s,
          end: end,
          type: _text(e, 'recordType'),
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static DateTime? _parseTime(String t) => DateTime.tryParse(t.replaceFirst(' ', 'T'));

  /// JPEG of the live picture. Tries the documented flat URL first.
  Future<Uint8List> snapshot(int channel) async {
    DeviceHttpException? last;
    for (final path in ['/GetSnapshot/$channel', '/LAPI/V1.0/Image/Channels/$channel/Snapshot']) {
      try {
        final res = await _http.send(
          'GET',
          _uri(path),
          credentials: credentials,
          headers: const {'Accept': 'image/jpeg'},
        );
        if (res.bodyBytes.length > 100) return res.bodyBytes;
      } on DeviceHttpException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) rethrow;
        last = e;
      }
    }
    throw last ?? DeviceHttpException('Snapshot not available');
  }
}
