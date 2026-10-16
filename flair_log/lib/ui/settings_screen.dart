import 'package:flutter/material.dart';

import '../app_scope.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          children: [
            const _Header('Recording'),
            SwitchListTile(
              title: const Text('Start automatically'),
              subtitle: Text(
                  'When pressure reaches ${s.autoStartPressure.toStringAsFixed(1)} bar '
                  'or ${s.autoStartWeight.toStringAsFixed(1)} g are in the cup'),
              value: s.autoStart,
              onChanged: (v) => s.autoStart = v,
            ),
            _SliderTile(
              label: 'Start pressure',
              value: s.autoStartPressure,
              min: 0.2,
              max: 3,
              unit: 'bar',
              onChanged: (v) => s.autoStartPressure = v,
            ),
            SwitchListTile(
              title: const Text('Stop automatically'),
              subtitle: const Text('3 s after the pressure drops back to zero'),
              value: s.autoStop,
              onChanged: (v) => s.autoStop = v,
            ),
            _SliderTile(
              label: 'Stop at yield',
              value: s.targetYield,
              min: 0,
              max: 80,
              unit: 'g',
              zeroLabel: 'off',
              onChanged: (v) => s.targetYield = v.roundToDouble(),
            ),
            const _Header('Gauge'),
            CheckboxListTile(
              title: const Text('Smooth gauge movement'),
              subtitle: const Text(
                  'Removes needle flicker; follows the lever without visible lag'),
              value: s.smoothGauge,
              onChanged: (v) => s.smoothGauge = v ?? true,
            ),
            CheckboxListTile(
              title: const Text('Ignore impossible jumps'),
              subtitle: const Text(
                  'Drops readings that would need a faster pressure change than a '
                  'hand on the lever can make, so misreads don\'t spike the graph'),
              value: s.rejectGaugeJumps,
              onChanged: (v) => s.rejectGaugeJumps = v ?? true,
            ),
            ListTile(
              title: const Text('Calibration'),
              subtitle: Text(s.calibration == null
                  ? 'Not calibrated — open Brew and tap the target icon'
                  : '${s.calibration!.minValue.toStringAsFixed(0)}–'
                      '${s.calibration!.maxValue.toStringAsFixed(0)} bar, '
                      '${s.calibration!.trackMovement ? 'following the gauge' : 'fixed position'}'),
              trailing: s.calibration == null
                  ? null
                  : TextButton(
                      onPressed: () => s.calibration = null,
                      child: const Text('Reset')),
            ),
            const _Header('Try it out'),
            SwitchListTile(
              title: const Text('Demo mode'),
              subtitle: const Text('Simulated gauge and scale, no hardware needed'),
              value: s.demoMode,
              onChanged: (v) async {
                s.demoMode = v;
                await app.scales.disconnect();
                if (v) await app.scales.connectDemo();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.zeroLabel,
  });

  final String label;
  final double value, min, max;
  final String unit;
  final String? zeroLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              value == 0 && zeroLabel != null
                  ? zeroLabel!
                  : '${value.toStringAsFixed(value < 10 ? 1 : 0)} $unit',
              textAlign: TextAlign.end,
            ),
          ),
        ]),
      );
}
