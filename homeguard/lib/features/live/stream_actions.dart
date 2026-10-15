import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/services/device_registry.dart';
import '../../core/services/intercom_service.dart';
import '../../custom_code/actions/capture_snapshot.dart';
import '../../theme/app_theme.dart';
import '../access/unlock_flow.dart';

/// Overlay quick actions: talk, snapshot, unlock.
class StreamActions extends StatelessWidget {
  const StreamActions({super.key, required this.deviceId, required this.playerTag, this.compact = false});

  final String deviceId;
  final String playerTag;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final talk = context.watch<IntercomService>();
    final device = registry.byId(deviceId);
    if (device == null) return const SizedBox.shrink();
    final unlockTarget = device.canUnlock ? device : registry.unlockable.firstOrNull;
    final talking = talk.state == TalkState.talking && talk.activeDevice == deviceId;
    final connecting = talk.state == TalkState.connecting && talk.activeDevice == deviceId;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (device.supportsTalk)
          _ActionButton(
            icon: talking ? Icons.mic : Icons.mic_none,
            label: talking ? 'End talk' : 'Talk',
            color: talking ? AppColors.danger : null,
            busy: connecting,
            compact: compact,
            onPressed: () async {
              HapticFeedback.selectionClick();
              final messenger = ScaffoldMessenger.of(context);
              if (talking) {
                await talk.stop();
              } else {
                await talk.start(deviceId);
                if (talk.state == TalkState.error) {
                  messenger.showSnackBar(SnackBar(content: Text(talk.error ?? 'Talk failed')));
                }
              }
            },
          ),
        _ActionButton(
          icon: Icons.photo_camera_outlined,
          label: 'Snapshot',
          compact: compact,
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final path = await captureSnapshot(playerTag, deviceId);
            HapticFeedback.lightImpact();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  path.isEmpty ? 'Snapshot failed — stream not ready' : 'Snapshot saved to Events',
                ),
              ),
            );
          },
        ),
        if (unlockTarget != null)
          _ActionButton(
            icon: Icons.lock_open,
            label: 'Unlock',
            color: AppColors.secure,
            compact: compact,
            onPressed: () => confirmAndUnlock(context, unlockTarget.id),
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.busy = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 44.0 : 60.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: (color ?? Colors.white).withValues(alpha: 0.18),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: busy ? null : onPressed,
              child: SizedBox.square(
                dimension: size,
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, color: color ?? Colors.white, size: compact ? 22 : 28),
              ),
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}
