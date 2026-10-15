import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../core/models/security_event.dart';
import '../../core/services/device_registry.dart';
import '../../core/services/event_store.dart';
import '../../theme/app_theme.dart';
import 'event_widgets.dart';

class EventDetailPage extends StatelessWidget {
  const EventDetailPage({super.key, required this.event});
  final SecurityEvent event;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete event?'),
        content: const Text('The snapshot or clip is removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<EventStore>().delete(event);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.read<DeviceRegistry>().byId(event.deviceId);
    final path = event.mediaPath;
    return Scaffold(
      appBar: AppBar(
        title: Text(event.type.label),
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: switch (event.mediaKind) {
                MediaKind.image when path != null => InteractiveViewer(
                  minScale: 1,
                  maxScale: 6,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 48),
                    ),
                  ),
                ),
                MediaKind.video when path != null => _ClipPlayer(path: path),
                _ => Center(child: Icon(eventIcon(event.type), size: 72, color: AppColors.textMuted)),
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    EventTag(type: event.type),
                    if (event.mediaKind == MediaKind.video)
                      const Chip(label: Text('Video clip'), visualDensity: VisualDensity.compact),
                  ],
                ),
                const SizedBox(height: 12),
                _Row(icon: Icons.schedule, text: DateFormat.yMMMMd().add_Hms().format(event.timestamp)),
                _Row(icon: Icons.devices_other, text: device?.name ?? event.deviceId),
                if (event.note != null) _Row(icon: Icons.notes, text: event.note!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _ClipPlayer extends StatefulWidget {
  const _ClipPlayer({required this.path});
  final String path;
  @override
  State<_ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<_ClipPlayer> {
  // Local clips may only be read from the app sandbox.
  late final _player = Player(configuration: const PlayerConfiguration(protocolWhitelist: ['file']));
  late final _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(Uri.file(widget.path).toString()));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(controller: _controller);
}
