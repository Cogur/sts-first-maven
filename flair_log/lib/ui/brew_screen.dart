import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_scope.dart';
import '../brew/brew_session.dart';
import '../models/shot.dart';
import '../scale/scale.dart';
import '../storage/settings.dart';
import '../vision/camera_gauge_source.dart';
import '../vision/pressure_source.dart';
import 'calibration_screen.dart';
import 'scale_screen.dart';
import 'shot_detail_screen.dart';
import 'widgets/brew_chart.dart';
import 'widgets/gauge_view.dart';

class BrewScreen extends StatefulWidget {
  const BrewScreen({super.key});

  @override
  State<BrewScreen> createState() => _BrewScreenState();
}

class _BrewScreenState extends State<BrewScreen> {
  late final PressureSource _source;
  late final BrewSession _session;
  late final TextEditingController _dose;
  late final Settings _settings;
  bool _demo = false;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final app = AppScope.of(context);
    _demo = app.settings.demoMode;
    _source = _demo
        ? SimulatedPressureSource()
        : CameraGaugeSource(app.settings.calibration);
    _source.start();
    _session = BrewSession(
        pressure: _source, scale: app.scales, settings: app.settings)
      ..onFinished = _onFinished;
    _dose = TextEditingController(text: app.settings.lastDose.toStringAsFixed(1));
    app.scales.reconnectLast();
    _settings = app.settings..addListener(_syncFilter);
    _syncFilter();
    WakelockPlus.enable().catchError((_) {});
  }

  @override
  void dispose() {
    _settings.removeListener(_syncFilter);
    WakelockPlus.disable().catchError((_) {});
    _session.dispose();
    _source.dispose();
    _dose.dispose();
    super.dispose();
  }

  void _syncFilter() {
    _source.filter
      ..smooth = _settings.smoothGauge
      ..rejectJumps = _settings.rejectGaugeJumps;
  }

  Future<void> _onFinished(Shot shot) async {
    final app = AppScope.of(context);
    await app.shots.save(shot);
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ShotDetailScreen(shot: shot)));
    if (mounted) _session.reset();
  }

  void _saveDose() {
    final v = double.tryParse(_dose.text.replaceAll(',', '.'));
    if (v != null && v > 0) AppScope.of(context).settings.lastDose = v;
  }

  Future<void> _calibrate() async {
    final src = _source;
    if (src is! CameraGaugeSource) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            CalibrationScreen(source: src, settings: AppScope.of(context).settings)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final src = _source;
    final needsCal = src is CameraGaugeSource && src.calibration == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_demo ? 'Brew (demo)' : 'Brew'),
        actions: [
          _ScaleChip(onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ScaleScreen()))),
          if (src is CameraGaugeSource)
            IconButton(
              tooltip: 'Calibrate gauge',
              icon: const Icon(Icons.center_focus_strong),
              onPressed: _session.state == BrewState.recording ? null : _calibrate,
            ),
          ListenableBuilder(
            listenable: _settings,
            builder: (context, _) => PopupMenuButton<String>(
              tooltip: 'Gauge reading',
              icon: const Icon(Icons.tune),
              onSelected: (v) {
                if (v == 'smooth') _settings.smoothGauge = !_settings.smoothGauge;
                if (v == 'jumps') {
                  _settings.rejectGaugeJumps = !_settings.rejectGaugeJumps;
                }
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'smooth',
                  checked: _settings.smoothGauge,
                  child: const Text('Smooth gauge movement'),
                ),
                CheckedPopupMenuItem(
                  value: 'jumps',
                  checked: _settings.rejectGaugeJumps,
                  child: const Text('Ignore impossible jumps'),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_session, app.scales]),
          builder: (context, _) {
            return Column(
              children: [
                if (needsCal)
                  MaterialBanner(
                    content: const Text(
                        'Calibrate the gauge once so the app can read the needle.'),
                    actions: [
                      TextButton(onPressed: _calibrate, child: const Text('Calibrate')),
                    ],
                  ),
                SizedBox(
                  height: 190,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: src is CameraGaugeSource
                              ? GaugeView(source: src)
                              : _DemoDial(bar: _session.currentPressure ?? 0),
                        ),
                        const SizedBox(width: 16),
                        Expanded(child: _Readouts(session: _session)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: BrewChart(
                      samples: _session.samples,
                      showWeight: app.scales.isConnected || _session.samples.any((s) => s.weight != null),
                      showFlow: app.scales.isConnected || _session.samples.any((s) => s.flow != null),
                    ),
                  ),
                ),
                _controls(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final theme = Theme.of(context);
    final s = _session;
    final big = FilledButton.styleFrom(minimumSize: const Size.fromHeight(56));
    Widget child;
    switch (s.state) {
      case BrewState.idle:
      case BrewState.done:
        child = Row(children: [
          SizedBox(
            width: 96,
            child: TextField(
              controller: _dose,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Dose g', isDense: true),
              onChanged: (_) => _saveDose(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: big,
              onPressed: () {
                _saveDose();
                FocusScope.of(context).unfocus();
                s.arm();
              },
              icon: const Icon(Icons.coffee),
              label: const Text('Tare & get ready'),
            ),
          ),
        ]);
      case BrewState.armed:
        final auto = AppScope.of(context).settings.autoStart;
        child = Row(children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
            onPressed: s.stop,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: big,
              onPressed: s.start,
              icon: const Icon(Icons.play_arrow),
              label: Text(auto ? 'Pull the lever… (or tap)' : 'Start'),
            ),
          ),
        ]);
      case BrewState.recording:
        child = FilledButton.icon(
          style: big.copyWith(
            backgroundColor: WidgetStatePropertyAll(theme.colorScheme.error),
            foregroundColor: WidgetStatePropertyAll(theme.colorScheme.onError),
          ),
          onPressed: s.stop,
          icon: const Icon(Icons.stop),
          label: Text('Stop  ${s.elapsed.toStringAsFixed(1)} s'),
        );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: child);
  }
}

class _Readouts extends StatelessWidget {
  const _Readouts({required this.session});
  final BrewSession session;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    String f(double? v, int d) => v == null ? '–' : v.toStringAsFixed(d);
    Widget row(String label, String value, String unit, {bool hero = false}) =>
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(width: 62, child: Text(label, style: t.bodySmall?.copyWith(color: muted))),
            Text(value,
                style: (hero ? t.displaySmall : t.titleLarge)?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Text(unit, style: t.bodySmall?.copyWith(color: muted)),
          ],
        );
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Pressure', f(session.currentPressure, 1), 'bar', hero: true),
        row('Weight', f(session.currentWeight, 1), 'g'),
        row('Flow', f(session.currentFlow, 1), 'g/s'),
        row('Time', session.elapsed.toStringAsFixed(1), 's'),
      ],
    );
  }
}

class _ScaleChip extends StatelessWidget {
  const _ScaleChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scales = AppScope.of(context).scales;
    return ListenableBuilder(
      listenable: scales,
      builder: (context, _) {
        final st = scales.state;
        final r = scales.lastReading;
        final label = switch (st) {
          ScaleConnectionState.connected =>
            r?.battery != null ? '${r!.battery}%' : 'Scale',
          ScaleConnectionState.connecting => '…',
          ScaleConnectionState.disconnected => 'No scale',
        };
        return TextButton.icon(
          onPressed: onTap,
          icon: Icon(st == ScaleConnectionState.connected
              ? Icons.scale
              : Icons.bluetooth_searching),
          label: Text(label),
        );
      },
    );
  }
}

/// Stand-in dial for demo mode.
class _DemoDial extends StatelessWidget {
  const _DemoDial({required this.bar});
  final double bar;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _DemoDialPainter(bar, Theme.of(context).colorScheme,
            ChartColors.pressure(Theme.of(context).brightness)),
      );
}

class _DemoDialPainter extends CustomPainter {
  _DemoDialPainter(this.bar, this.cs, this.needle);
  final double bar;
  final ColorScheme cs;
  final Color needle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    canvas.drawCircle(c, r, Paint()..color = cs.surfaceContainerHighest);
    const a0 = 3 * math.pi / 4, sweep = 3 * math.pi / 2;
    final tick = Paint()
      ..color = cs.onSurfaceVariant
      ..strokeWidth = 1.5;
    for (var i = 0; i <= 16; i++) {
      final a = a0 + sweep * i / 16;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * r * (i.isEven ? 0.78 : 0.85), c + d * r * 0.92, tick);
    }
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.7), a0 + sweep * 6 / 16,
        sweep * 3 / 16, false,
        Paint()
          ..color = needle.withValues(alpha: 0.25)
          ..strokeWidth = 6
          ..style = PaintingStyle.stroke);
    final a = a0 + sweep * (bar.clamp(0, 16) / 16);
    canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * r * 0.8,
        Paint()
          ..color = needle
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, 5, Paint()..color = cs.onSurface);
  }

  @override
  bool shouldRepaint(covariant _DemoDialPainter old) => old.bar != bar;
}
