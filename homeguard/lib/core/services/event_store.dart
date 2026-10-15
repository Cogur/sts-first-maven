import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/security_event.dart';
import '../utils/log.dart';

/// Local-first event library: snapshots, clips and their metadata live in
/// the app sandbox (`Application Support/events`), excluded from shared
/// storage and gallery apps.
class EventStore extends ChangeNotifier {
  EventStore({Future<Directory> Function()? root, this.maxEvents = 2000})
    : _rootProvider = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _rootProvider;
  final int maxEvents;
  Directory? _dir;
  List<SecurityEvent> _events = [];
  bool _loaded = false;

  List<SecurityEvent> get events => _events;
  bool get loaded => _loaded;

  Future<Directory> _eventsDir() async {
    if (_dir != null) return _dir!;
    final root = await _rootProvider();
    final dir = Directory('${root.path}/events/media');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexFile() async => File('${(await _eventsDir()).parent.path}/index.json');

  Future<void> load() async {
    try {
      final f = await _indexFile();
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _events = list.cast<Map<String, Object?>>().map(SecurityEvent.fromJson).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }
    } on FormatException catch (e) {
      // A corrupt index must not brick the gallery; media files are kept and
      // can be re-imported.
      Log.e('events', 'index unreadable, starting fresh: ${e.message}');
      _events = [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final f = await _indexFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(_events.map((e) => e.toJson()).toList()), flush: true);
    await tmp.rename(f.path); // atomic replace
  }

  Future<SecurityEvent> addMedia({
    required Uint8List bytes,
    required String extension,
    required EventType type,
    required String deviceId,
    DateTime? timestamp,
    String? note,
  }) async {
    final id = const Uuid().v4();
    final file = File('${(await _eventsDir()).path}/$id.$extension');
    await file.writeAsBytes(bytes, flush: true);
    final event = SecurityEvent(
      id: id,
      type: type,
      timestamp: timestamp ?? DateTime.now(),
      deviceId: deviceId,
      mediaPath: file.path,
      mediaKind: SecurityEvent.mediaKindFromName(file.path),
      note: note,
    );
    await _insert(event);
    return event;
  }

  /// Records an event with no media (e.g. a door unlock audit entry).
  Future<SecurityEvent> addRecord({required EventType type, required String deviceId, String? note}) async {
    final event = SecurityEvent(
      id: const Uuid().v4(),
      type: type,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      note: note,
    );
    await _insert(event);
    return event;
  }

  Future<void> _insert(SecurityEvent e) async {
    _events = [e, ..._events]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    while (_events.length > maxEvents) {
      await _deleteMedia(_events.removeLast());
    }
    await _persist();
    notifyListeners();
  }

  /// Imports files copied from the indoor monitor's SD card (or downloaded
  /// from it). Type and time are inferred from the device's file names.
  Future<int> importFiles(
    Iterable<(String name, Uint8List bytes)> files, {
    String deviceId = 'monitor',
  }) async {
    var count = 0;
    for (final (name, bytes) in files) {
      final kind = SecurityEvent.mediaKindFromName(name);
      if (kind == MediaKind.none) continue;
      if (_events.any((e) => e.note == name)) continue; // already imported
      await addMedia(
        bytes: bytes,
        extension: name.split('.').last.toLowerCase(),
        type: EventType.fromHint(name),
        deviceId: deviceId,
        timestamp: SecurityEvent.timestampFromName(name),
        note: name,
      );
      count++;
    }
    return count;
  }

  bool hasSource(String name) => _events.any((e) => e.note == name);

  Future<void> delete(SecurityEvent e) async {
    _events = _events.where((x) => x.id != e.id).toList();
    await _deleteMedia(e);
    await _persist();
    notifyListeners();
  }

  Future<void> _deleteMedia(SecurityEvent e) async {
    final p = e.mediaPath;
    if (p == null) return;
    final f = File(p);
    if (await f.exists()) await f.delete();
  }

  Future<void> wipe() async {
    final dir = await _eventsDir();
    if (await dir.parent.exists()) await dir.parent.delete(recursive: true);
    _dir = null;
    _events = [];
    notifyListeners();
  }
}
