import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/models/device.dart';
import '../../core/models/security_event.dart';
import '../../core/network/connection_manager.dart';
import '../../core/network/device_http_client.dart';
import '../../core/services/event_store.dart';
import '../../theme/app_theme.dart';
import 'event_widgets.dart';

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  final Set<EventType> _filter = {};
  bool _syncing = false;

  Future<void> _syncFromMonitor() async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.of(context);
    final monitor = services.registry.firstOfKind(DeviceKind.indoorMonitor);
    if (monitor == null) return;
    setState(() => _syncing = true);
    try {
      final n = await services.monitorSync.sync(monitor.id);
      messenger.showSnackBar(SnackBar(content: Text(n == 0 ? 'Up to date' : 'Imported $n new events')));
    } on DeviceHttpException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on DeviceUnreachableException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _importFromSdCard() async {
    final store = context.read<EventStore>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Select snapshots / clips from the monitor SD card',
      type: FileType.media,
    );
    if (picked.isEmpty) return;
    final files = <(String, Uint8List)>[];
    for (final f in picked) {
      files.add((f.name, await f.xFile.readAsBytes()));
    }
    final n = await store.importFiles(files);
    messenger.showSnackBar(SnackBar(content: Text('Imported $n of ${picked.length} files')));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<EventStore>();
    final events = store.events.where((e) => _filter.isEmpty || _filter.contains(e.type)).toList();
    final groups = <DateTime, List<SecurityEvent>>{};
    for (final e in events) {
      groups.putIfAbsent(DateTime(e.timestamp.year, e.timestamp.month, e.timestamp.day), () => []).add(e);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Events & Snapshots'),
        actions: [
          IconButton(
            tooltip: 'Sync from indoor monitor',
            onPressed: _syncing ? null : _syncFromMonitor,
            icon: _syncing
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Import from SD card',
            onPressed: _importFromSdCard,
            icon: const Icon(Icons.sd_card_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final t in EventType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(t.label),
                      avatar: Icon(eventIcon(t), size: 16),
                      selected: _filter.contains(t),
                      onSelected: (v) => setState(() => v ? _filter.add(t) : _filter.remove(t)),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: !store.loaded
                ? const Center(child: CircularProgressIndicator())
                : events.isEmpty
                ? const _EmptyState()
                : RefreshIndicator(
                    onRefresh: _syncFromMonitor,
                    child: CustomScrollView(
                      slivers: [
                        for (final entry in groups.entries) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                              child: Text(
                                _dayLabel(entry.key),
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            sliver: SliverGrid.builder(
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 220,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 1.1,
                              ),
                              itemCount: entry.value.length,
                              itemBuilder: (_, i) => _EventCard(event: entry.value[i]),
                            ),
                          ),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime d) {
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    if (d == t) return 'Today';
    if (d == t.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat.yMMMMEEEEd().format(d);
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});
  final SecurityEvent event;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/events/detail', extra: event),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: event.mediaKind == MediaKind.image && event.mediaPath != null
                  ? Image.file(
                      File(event.mediaPath!),
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                    )
                  : ColoredBox(
                      color: AppColors.surfaceHigh,
                      child: Icon(
                        event.mediaKind == MediaKind.video
                            ? Icons.play_circle_outline
                            : eventIcon(event.type),
                        size: 36,
                        color: AppColors.textMuted,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  EventTag(type: event.type, dense: true),
                  const Spacer(),
                  Text(
                    DateFormat.Hms().format(event.timestamp),
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 48, color: AppColors.textMuted),
          SizedBox(height: 12),
          Text('No events yet', style: TextStyle(fontSize: 16)),
          SizedBox(height: 6),
          Text(
            'Snapshots you take, door unlocks, and events synced or imported from the '
            'indoor monitor SD card appear here. Everything stays on this device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted),
          ),
        ],
      ),
    ),
  );
}
