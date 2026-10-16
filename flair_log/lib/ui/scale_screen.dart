import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../app_scope.dart';
import '../scale/scale.dart';
import '../scale/scale_manager.dart';

/// Scan for and connect to a Bluetooth scale.
class ScaleScreen extends StatefulWidget {
  const ScaleScreen({super.key});

  @override
  State<ScaleScreen> createState() => _ScaleScreenState();
}

class _ScaleScreenState extends State<ScaleScreen> {
  bool _showAll = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final m = AppScope.of(context).scales;
      if (!m.isConnected) m.startScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context).scales;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scale'),
        actions: [
          StreamBuilder<bool>(
            stream: m.isScanning,
            initialData: FlutterBluePlus.isScanningNow,
            builder: (context, snap) => snap.data == true
                ? IconButton(
                    tooltip: 'Stop scanning',
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: m.stopScan)
                : IconButton(
                    tooltip: 'Scan',
                    icon: const Icon(Icons.refresh),
                    onPressed: m.startScan),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: m,
        builder: (context, _) => ListView(
          children: [
            if (m.scale != null) _connectedCard(m, theme),
            if (m.error != null)
              ListTile(
                leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
                title: Text(m.error!),
              ),
            StreamBuilder<BluetoothAdapterState>(
              stream: FlutterBluePlus.adapterState,
              builder: (context, snap) {
                final s = snap.data;
                if (s == null || s == BluetoothAdapterState.on) {
                  return const SizedBox.shrink();
                }
                return ListTile(
                  leading: const Icon(Icons.bluetooth_disabled),
                  title: Text('Bluetooth is ${s.name}'),
                  subtitle: const Text('Turn Bluetooth on to find your scale.'),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(children: [
                Text('Nearby scales', style: theme.textTheme.titleSmall),
                const Spacer(),
                const Text('Show all'),
                Switch(value: _showAll, onChanged: (v) => setState(() => _showAll = v)),
              ]),
            ),
            StreamBuilder<List<ScanResult>>(
              stream: m.scanResults,
              initialData: const [],
              builder: (context, snap) {
                final results = (snap.data ?? [])
                    .where((r) =>
                        _showAll ? _name(r).isNotEmpty : ScaleManager.isSupportedResult(r))
                    .toList()
                  ..sort((a, b) => b.rssi.compareTo(a.rssi));
                if (results.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'Wake the scale up (press its power button) and keep it close.'),
                  );
                }
                return Column(
                  children: [
                    for (final r in results)
                      ListTile(
                        leading: Icon(ScaleManager.isSupportedResult(r)
                            ? Icons.scale
                            : Icons.bluetooth),
                        title: Text(_name(r)),
                        subtitle: Text('${r.device.remoteId.str} · ${r.rssi} dBm'),
                        trailing: const Icon(Icons.link),
                        onTap: () => m.connectDevice(r.device),
                      ),
                  ],
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Use demo scale'),
              subtitle: const Text('Simulated weight for trying the app'),
              onTap: m.connectDemo,
            ),
          ],
        ),
      ),
    );
  }

  static String _name(ScanResult r) => r.advertisementData.advName.isNotEmpty
      ? r.advertisementData.advName
      : r.device.platformName;

  Widget _connectedCard(ScaleManager m, ThemeData theme) {
    final r = m.lastReading;
    final st = m.state;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.scale),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(m.scale!.name.isEmpty ? m.scale!.id : m.scale!.name,
                      style: theme.textTheme.titleMedium)),
              Text(switch (st) {
                ScaleConnectionState.connected => 'Connected',
                ScaleConnectionState.connecting => 'Connecting…',
                ScaleConnectionState.disconnected => 'Disconnected',
              }),
            ]),
            const SizedBox(height: 12),
            Text(r == null ? '– g' : '${r.weight.toStringAsFixed(1)} g',
                style: theme.textTheme.displaySmall),
            if (r?.battery != null) Text('Battery ${r!.battery}%'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(onPressed: m.tare, child: const Text('Tare')),
              OutlinedButton(
                  onPressed: () => m.disconnect(forget: true),
                  child: const Text('Forget')),
            ]),
          ],
        ),
      ),
    );
  }
}
