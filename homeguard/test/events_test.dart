import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/security_event.dart';
import 'package:homeguard/core/services/event_store.dart';
import 'package:homeguard/core/services/monitor_sync_service.dart';

void main() {
  group('file name inference', () {
    test('timestamps in common device formats', () {
      expect(SecurityEvent.timestampFromName('20260115_083012_FACE.jpg'), DateTime(2026, 1, 15, 8, 30, 12));
      expect(
        SecurityEvent.timestampFromName('call_2026-01-15-08-30-12.jpg'),
        DateTime(2026, 1, 15, 8, 30, 12),
      );
      expect(SecurityEvent.timestampFromName('IMG_20261301_250000.jpg'), isNull); // invalid month
      expect(SecurityEvent.timestampFromName('snapshot.jpg'), isNull);
    });

    test('event types', () {
      expect(EventType.fromHint('20260115_FACE.jpg'), EventType.faceDetected);
      expect(EventType.fromHint('Call_0001.jpg'), EventType.doorbellRing);
      expect(EventType.fromHint('md_0001.jpg'), EventType.motion);
      expect(EventType.fromHint('card_swipe.jpg'), EventType.rfidAccess);
      expect(EventType.fromHint('random.jpg'), EventType.other);
    });

    test('media kinds', () {
      expect(SecurityEvent.mediaKindFromName('a.JPG'), MediaKind.image);
      expect(SecurityEvent.mediaKindFromName('a.mp4'), MediaKind.video);
      expect(SecurityEvent.mediaKindFromName('a.txt'), MediaKind.none);
    });
  });

  test('monitor index parsing: HTML listing and JSON', () {
    const html =
        '<a href="../">..</a><a href="20260101_120000_call.jpg">x</a>'
        '<a href=\'clips/motion_1.mp4\'>y</a><a href="readme.txt">z</a>';
    expect(MonitorSyncService.parseIndex(html), ['20260101_120000_call.jpg', 'clips/motion_1.mp4']);
    expect(MonitorSyncService.parseIndex('[{"path":"/sd/a.jpg"},"/sd/b.jpg"]'), ['/sd/a.jpg', '/sd/b.jpg']);
  });

  group('EventStore', () {
    late Directory tmp;
    late EventStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hg_events');
      store = EventStore(root: () async => tmp);
      await store.load();
    });
    tearDown(() => tmp.delete(recursive: true));

    test('persists, orders newest-first and survives reload', () async {
      await store.addRecord(type: EventType.doorUnlocked, deviceId: 'door');
      await store.addMedia(
        bytes: Uint8List.fromList([1, 2, 3]),
        extension: 'jpg',
        type: EventType.manualSnapshot,
        deviceId: 'cam1',
        timestamp: DateTime(2020),
      );
      expect(store.events.first.type, EventType.doorUnlocked);

      final reloaded = EventStore(root: () async => tmp);
      await reloaded.load();
      expect(reloaded.events, hasLength(2));
      expect(File(reloaded.events.last.mediaPath!).readAsBytesSync(), [1, 2, 3]);
    });

    test('import skips duplicates and non-media files', () async {
      final files = [('20260115_083012_FACE.jpg', Uint8List(1)), ('notes.txt', Uint8List(1))];
      expect(await store.importFiles(files), 1);
      expect(await store.importFiles(files), 0);
      expect(store.events.single.type, EventType.faceDetected);
      expect(store.events.single.timestamp, DateTime(2026, 1, 15, 8, 30, 12));
    });

    test('delete removes media from disk', () async {
      final e = await store.addMedia(
        bytes: Uint8List(1),
        extension: 'jpg',
        type: EventType.motion,
        deviceId: 'x',
      );
      await store.delete(e);
      expect(File(e.mediaPath!).existsSync(), isFalse);
      expect(store.events, isEmpty);
    });

    test('corrupt index does not crash loading', () async {
      await store.addRecord(type: EventType.motion, deviceId: 'x');
      File('${tmp.path}/events/index.json').writeAsStringSync('{not json');
      final s = EventStore(root: () async => tmp);
      await s.load();
      expect(s.events, isEmpty);
      expect(s.loaded, isTrue);
    });
  });
}
