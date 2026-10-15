import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../settings/settings_controller.dart';

/// Confirms (biometric or dialog) and fires a door relay. Shows the outcome.
Future<void> confirmAndUnlock(BuildContext context, String deviceId) async {
  final services = context.read<AppServices>();
  final settings = context.read<SettingsController>();
  final messenger = ScaffoldMessenger.of(context);
  final device = services.registry.byId(deviceId);
  if (device == null) return;

  bool confirmed;
  if (settings.confirmUnlockWithBiometrics && await services.biometrics.isAvailable()) {
    confirmed = await services.biometrics.authenticate(
      'Confirm to unlock ${device.name}',
      biometricOnly: true,
    );
  } else {
    if (!context.mounted) return;
    confirmed =
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            icon: const Icon(Icons.lock_open),
            title: Text('Unlock ${device.name}?'),
            content: const Text('The door relay will be triggered.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlock')),
            ],
          ),
        ) ??
        false;
  }
  if (!confirmed) return;

  HapticFeedback.mediumImpact();
  final result = await services.relay.unlock(deviceId);
  messenger.showSnackBar(
    SnackBar(
      content: Text(result.message),
      backgroundColor: result.ok ? const Color(0xFF1E7D4A) : const Color(0xFF8E2A20),
    ),
  );
}
