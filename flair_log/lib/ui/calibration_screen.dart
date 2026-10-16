import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../storage/settings.dart';
import '../vision/camera_gauge_source.dart';
import '../vision/dial_geometry.dart';
import '../vision/gauge_setup.dart';
import '../vision/luma_frame.dart';
import 'widgets/brew_chart.dart';

/// Guided calibration:
/// 1. aim (the whole machine may be in view) and take a still,
/// 2. the app finds round dials; the user confirms or taps the right one,
/// 3. the app finds the pivot and the needle at rest (= 0 bar); the user taps
///    one numbered mark on a zoomed view and enters its number.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.source, required this.settings});

  final CameraGaugeSource source;
  final Settings settings;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

enum _Phase { aim, finding, pick, analysing, scale }

class _CalibrationScreenState extends State<CalibrationScreen> {
  _Phase _phase = _Phase.aim;
  LumaFrame? _frame;
  ui.Image? _still;
  List<DialGeometry> _dials = [];
  int _selected = 0;
  String? _message;

  DialAnalysis? _analysis;
  ui.Image? _zoom;
  (double, double, double)? _region; // left, top, size in frame pixels
  double? _zeroAngle, _markAngle;
  bool _tapSetsZero = false;
  final _markCtrl = TextEditingController(text: '10');
  bool _track = true;

  @override
  void initState() {
    super.initState();
    final old = widget.source.calibration ?? widget.settings.calibration;
    if (old != null) {
      _markCtrl.text = _fmt(old.maxValue);
      _track = old.trackMovement;
    }
    widget.source.wantRoi = false;
  }

  @override
  void dispose() {
    widget.source.wantRoi = true;
    _still?.dispose();
    _zoom?.dispose();
    _markCtrl.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static Future<ui.Image> _image(LumaFrame f, double left, double top,
      double w, double h, int outW, int outH) {
    final c = Completer<ui.Image>();
    final rgba = f.toRgba(
        left: left, top: top, regionW: w, regionH: h, outW: outW, outH: outH);
    ui.decodeImageFromPixels(rgba, outW, outH, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // ---- step 1: capture and find ------------------------------------------

  Future<void> _capture() async {
    final f = await widget.source.grabFrame();
    final k = math.min(1.0, 900 / f.uprightWidth);
    final still = await _image(f, 0, 0, f.uprightWidth.toDouble(),
        f.uprightHeight.toDouble(), (f.uprightWidth * k).round(), (f.uprightHeight * k).round());
    if (!mounted) return;
    setState(() {
      _still?.dispose();
      _still = still;
      _frame = f;
      _dials = [];
      _message = null;
      _phase = _Phase.finding;
    });
    final dials = await Isolate.run(() => GaugeSetup.findDials(f));
    if (!mounted) return;
    setState(() {
      _dials = dials;
      _selected = 0;
      _phase = _Phase.pick;
      _message = dials.isEmpty
          ? 'No gauge found automatically. Tap on the gauge, or zoom in and retake.'
          : null;
    });
  }

  Future<void> _tapStill(double fx, double fy) async {
    // A tap inside a found dial selects it.
    for (var i = 0; i < _dials.length; i++) {
      if (_dials[i].polarOf(fx, fy).$2 <= 1.3) {
        setState(() => _selected = i);
        return;
      }
    }
    // Otherwise look for a dial right there.
    final f = _frame!;
    setState(() => _message = 'Looking for a gauge there…');
    final found = await Isolate.run(() => GaugeSetup.findDials(f, tapX: fx, tapY: fy));
    if (!mounted) return;
    setState(() {
      if (found.isEmpty) {
        _message = 'No round gauge there. Zoom the camera in a little and retake.';
      } else {
        _dials = [found.first, ..._dials];
        _selected = 0;
        _message = null;
      }
    });
  }

  // ---- step 2: analyse the chosen dial --------------------------------------

  Future<void> _analyse() async {
    final f = _frame!;
    final face = _dials[_selected];
    setState(() => _phase = _Phase.analysing);
    final a = await Isolate.run(() => GaugeSetup.analyse(f, face));
    final region = GaugeSetup.zoomRegion(a.face);
    final zoom = await _image(f, region.$1, region.$2, region.$3, region.$3, 720, 720);
    if (!mounted) return;
    setState(() {
      _analysis = a;
      _zoom?.dispose();
      _zoom = zoom;
      _region = region;
      _zeroAngle = a.needleFound ? a.restAngle : null;
      _markAngle = null;
      _tapSetsZero = !a.needleFound;
      _phase = _Phase.scale;
    });
  }

  void _tapZoom(double fx, double fy) {
    final a = _analysis!;
    final angle = GaugeSetup.angleAt(a, fx, fy);
    setState(() {
      if (_tapSetsZero) {
        _zeroAngle = angle;
        _tapSetsZero = false;
      } else {
        _markAngle = angle;
      }
    });
  }

  double? get _markValue {
    final v = double.tryParse(_markCtrl.text.replaceAll(',', '.'));
    return v != null && v > 0 ? v : null;
  }

  void _save() {
    final a = _analysis, z = _zeroAngle, m = _markAngle, v = _markValue;
    if (a == null || z == null || m == null || v == null) return;
    final cal = GaugeSetup.build(
      frame: _frame!,
      analysis: a,
      zeroAngle: z,
      markAngle: m,
      markValue: v,
      trackMovement: _track,
      zoom: widget.source.zoom,
    );
    widget.settings.calibration = cal;
    widget.source.setCalibration(cal);
    Navigator.of(context).pop(true);
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = switch (_phase) {
      _Phase.aim => _aimView(),
      _Phase.finding => _busy('Looking for the gauge…'),
      _Phase.pick => _pickView(),
      _Phase.analysing => _busy('Finding the needle…'),
      _Phase.scale => _scaleView(),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up gauge'),
        actions: [
          if (_phase == _Phase.pick || _phase == _Phase.scale)
            TextButton(
              onPressed: () => setState(() => _phase = _Phase.aim),
              child: const Text('Retake'),
            ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _busy(String text) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(text),
        ]),
      );

  Widget _aimView() {
    final src = widget.source;
    return ListenableBuilder(
      listenable: src,
      builder: (context, _) {
        final c = src.controller;
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Put the phone where it will stay while brewing, with the lever up '
                '(no pressure). The whole machine can be in the picture: the app '
                'finds the gauge itself. Leave room below the gauge, it moves down '
                'with the piston.',
              ),
            ),
            Expanded(
              child: c == null || !c.value.isInitialized
                  ? Center(child: Text(src.error ?? 'Starting camera…'))
                  : Center(child: CameraPreview(c)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.zoom_in),
                Expanded(
                  child: Slider(
                    min: src.minZoom,
                    max: math.max(src.minZoom + 0.01, math.min(src.maxZoom, 8)),
                    value: src.zoom.clamp(src.minZoom, math.min(src.maxZoom, 8)),
                    onChanged: (v) => src.setZoom(v),
                  ),
                ),
                IconButton(
                  tooltip: 'Torch',
                  icon: Icon(src.torch ? Icons.flashlight_on : Icons.flashlight_off),
                  onPressed: () => src.setTorch(!src.torch),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                onPressed: c?.value.isInitialized == true ? _capture : null,
                icon: const Icon(Icons.search),
                label: const Text('Find the gauge'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _pickView() {
    final f = _frame!;
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            _message ??
                (_dials.length == 1
                    ? 'Found the gauge. If the circle is wrong, tap the right one.'
                    : 'Is the highlighted circle your gauge? Tap the right one, or '
                        'tap on the gauge if it is not marked.'),
            style: theme.textTheme.titleSmall,
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: AspectRatio(
                aspectRatio: f.uprightWidth / f.uprightHeight,
                child: LayoutBuilder(builder: (context, box) {
                  final k = box.maxWidth / f.uprightWidth;
                  return GestureDetector(
                    onTapUp: (d) =>
                        _tapStill(d.localPosition.dx / k, d.localPosition.dy / k),
                    child: CustomPaint(
                      painter: _PickPainter(_still!, k, _dials, _selected,
                          theme.colorScheme.primary),
                      child: const SizedBox.expand(),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _dials.isEmpty ? null : _analyse,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('This is my gauge'),
          ),
        ),
      ],
    );
  }

  Widget _scaleView() {
    final a = _analysis!;
    final theme = Theme.of(context);
    final region = _region!;
    final v = _markValue;
    final String instruction;
    if (_tapSetsZero) {
      instruction = a.needleFound
          ? 'Tap the 0 mark.'
          : 'The needle is hard to see here. Tap the 0 mark.';
    } else if (_markAngle == null) {
      instruction = 'The blue line is the needle at rest = 0 bar. '
          'Now tap the ${_markCtrl.text} mark.';
    } else {
      instruction = 'Done. Tap again to correct the mark, or save.';
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(instruction, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(builder: (context, box) {
            final s = box.maxWidth;
            return GestureDetector(
              onTapUp: (d) => _tapZoom(region.$1 + d.localPosition.dx / s * region.$3,
                  region.$2 + d.localPosition.dy / s * region.$3),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(
                  painter: _ScalePainter(
                    image: _zoom!,
                    region: region,
                    analysis: a,
                    zeroAngle: _zeroAngle,
                    markAngle: _markAngle,
                    markLabel: _markCtrl.text,
                    needleColor: ChartColors.pressure(Brightness.dark),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Tap sets 0')),
                ButtonSegment(value: false, label: Text('Tap sets mark')),
              ],
              selected: {_tapSetsZero},
              onSelectionChanged: (s) => setState(() => _tapSetsZero = s.first),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: TextField(
              controller: _markCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Mark (bar)'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Follow the gauge as it moves'),
          subtitle: const Text('The Flair 58 gauge sits on the piston stem'),
          value: _track,
          onChanged: (x) => setState(() => _track = x),
        ),
        Text(
          'The app keeps learning what your dial looks like while you brew, so '
          'readings get cleaner after the first shots.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _zeroAngle != null && _markAngle != null && v != null ? _save : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Path _ellipse(DialGeometry g, Offset Function((double, double)) map, [double rho = 1]) {
  final p = Path();
  for (var i = 0; i <= 96; i++) {
    final o = map(g.point(2 * math.pi * i / 96, rho));
    i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
  }
  return p;
}

class _PickPainter extends CustomPainter {
  _PickPainter(this.still, this.k, this.dials, this.selected, this.accent);

  final ui.Image still;
  final double k;
  final List<DialGeometry> dials;
  final int selected;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      still,
      Rect.fromLTWH(0, 0, still.width.toDouble(), still.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    Offset map((double, double) p) => Offset(p.$1 * k, p.$2 * k);
    for (var i = dials.length - 1; i >= 0; i--) {
      final sel = i == selected;
      final path = _ellipse(dials[i], map, 1.25);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = sel ? 6 : 3
            ..color = Colors.black54);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = sel ? 3 : 1.5
            ..color = sel ? Colors.yellowAccent : Colors.white70);
    }
  }

  @override
  bool shouldRepaint(covariant _PickPainter old) => true;
}

class _ScalePainter extends CustomPainter {
  _ScalePainter({
    required this.image,
    required this.region,
    required this.analysis,
    required this.zeroAngle,
    required this.markAngle,
    required this.markLabel,
    required this.needleColor,
  });

  final ui.Image image;
  final (double, double, double) region;
  final DialAnalysis analysis;
  final double? zeroAngle, markAngle;
  final String markLabel;
  final Color needleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    Offset map((double, double) p) =>
        Offset((p.$1 - region.$1) / region.$3 * s, (p.$2 - region.$2) / region.$3 * s);
    final ng = analysis.needleGeometry;
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.yellowAccent.withValues(alpha: 0.8);
    canvas.drawPath(_ellipse(analysis.face, map), guide);
    canvas.drawCircle(map((analysis.pivotX, analysis.pivotY)), 4, Paint()..color = Colors.yellowAccent);

    void label(String t, Offset at) {
      final tp = TextPainter(
        text: TextSpan(
            text: t,
            style: const TextStyle(
                color: Colors.black, fontSize: 14, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      final r = Rect.fromCenter(center: at, width: tp.width + 10, height: tp.height + 4);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)),
          Paint()..color = Colors.yellowAccent);
      tp.paint(canvas, r.topLeft + const Offset(5, 2));
    }

    final z = zeroAngle, m = markAngle;
    if (z != null && m != null) {
      var sweep = (m - z) % (2 * math.pi);
      if (sweep < 0) sweep += 2 * math.pi;
      final arc = Path();
      for (var i = 0; i <= 60; i++) {
        final o = map(ng.point(z + sweep * i / 60, 0.7));
        i == 0 ? arc.moveTo(o.dx, o.dy) : arc.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
          arc,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = Colors.yellowAccent.withValues(alpha: 0.5));
    }
    if (z != null) {
      canvas.drawLine(
          map(ng.point(z, 0.15)),
          map(ng.point(z, 0.95)),
          Paint()
            ..color = needleColor
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round);
      label('0', map(ng.point(z, 1.12)));
    }
    if (m != null) {
      canvas.drawLine(map(ng.point(m, 0.8)), map(ng.point(m, 1.0)),
          guide..strokeWidth = 3);
      label(markLabel, map(ng.point(m, 1.12)));
    }
  }

  @override
  bool shouldRepaint(covariant _ScalePainter old) => true;
}
