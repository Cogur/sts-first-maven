import 'package:flutter/material.dart';

import '../../core/models/security_event.dart';
import '../../theme/app_theme.dart';

IconData eventIcon(EventType t) => switch (t) {
  EventType.faceDetected => Icons.face_retouching_natural,
  EventType.motion => Icons.directions_run,
  EventType.doorbellRing => Icons.notifications_active_outlined,
  EventType.manualSnapshot => Icons.photo_camera_outlined,
  EventType.doorUnlocked => Icons.lock_open,
  EventType.rfidAccess => Icons.contactless_outlined,
  EventType.other => Icons.event_note_outlined,
};

Color eventColor(EventType t) => switch (t) {
  EventType.faceDetected => const Color(0xFFB57BFF),
  EventType.motion => AppColors.warning,
  EventType.doorbellRing => AppColors.primary,
  EventType.manualSnapshot => AppColors.textMuted,
  EventType.doorUnlocked => AppColors.secure,
  EventType.rfidAccess => const Color(0xFF26C6DA),
  EventType.other => AppColors.textMuted,
};

class EventTag extends StatelessWidget {
  const EventTag({super.key, required this.type, this.dense = false});
  final EventType type;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = eventColor(type);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(eventIcon(type), size: dense ? 11 : 14, color: c),
          const SizedBox(width: 4),
          Text(
            type.label,
            style: TextStyle(fontSize: dense ? 10 : 12, color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
