import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../storage/settings.dart';
import '../vision/camera_gauge_source.dart';
import '../vision/gauge_calibration.dart';
import '../vision/gauge_reader.dart';
import '../vision/luma_frame.dart';
import 'widgets/brew_chart.dart';

/// Two steps: aim the camera, then mark the dial on a still frame.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.source, required this.settings});

  final CameraGaugeSource source;
  final Settings settings;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

enum _Step { center, zero, max, adjust }

class _CalibrationScreenState extends State<CalibrationScreen> {
  LumaFrame? _frame;
  ui.Image? _still;

  Offset? _center, _zero, _max; // upright pixels
  double _radiusScale = 1.1;
  final _minCtrl = TextEditingController(text: '0');
  final _maxCtrl = TextEditingController(text: '16');
  bool _track = true;
  int? _dragging;

  GaugeCalibration? _preview;
  GaugeReading? _previewReading;

  _Step get _step => _center == null
      ? _Step.center
      : _zero == null
          ? _Step.zero
          : _max == null
              ? _Step.max
              : _Step.adjust;

  @override
  void initState() {
    super.initState();
    final old = widget.source.calibration ?? widget.settings.calibration;
    if (old != null) {
      _minCtrl.text = _fmt(old.minValue);
      _maxCtrl.text = _fmt(old.maxValue);
      _track = old.trackMovement;
    }
    widget.source.wantRoi = false;
  }

  @override
  void dispose() {
    widget.source.wantRoi = true;
    _still?.dispose();
    _minCtrl.dispose();
    _maxCtrl.dispose();
    super.dispose();
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Future<void> _capture() async {
    final f = await widget.source.grabFrame();
    final maxW = 720;
    final k = math.min(1.0, maxW / f.uprightWidth);
    final w = (f.uprightWidth * k).round(), h = (f.uprightHeight * k).round();
    final rgba = f.toRgba(
        left: 0,
        top: 0,
        regionW: f.uprightWidth.toDouble(),
        regionH: f.uprightHeight.toDouble(),
        outW: w,
        outH: h);
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) return;
      setState(() {
        _still?.dispose();
        _still = img;
        _frame = f;
        _center = _zero = _max = null;
        _preview = null;
      });
    });
  }

  GaugeCalibration? _build() {
    final f = _frame;
    if (f == null || _center == null || _zero == null || _max == null) return null;
    final minV = double.tryParse(_minCtrl.text.replaceAll(',', '.')) ?? 0;
    final maxV = double.tryParse(_maxCtrl.text.replaceAll(',', '.')) ?? 16;
    if (maxV <= minV) return null;
    final c = _center!;
    final markR = math.max((_zero! - c).distance, (_max! - c).distance);
    var cal = GaugeCalibration.fromTaps(
      frameWidth: f.uprightWidth.toDouble(),
      frameHeight: f.uprightHeight.toDouble(),
      cx: c.dx,
      cy: c.dy,
      zeroX: _zero!.dx,
      zeroY: _zero!.dy,
      maxX: _max!.dx,
      maxY: _max!.dy,
      minValue: minV,
      maxValue: maxV,
      radiusPx: markR * _radiusScale,
    ).copyWith(trackMovement: _track, zoom: widget.source.zoom);
    final probe = GaugeReader(cal);
    cal = cal.copyWith(polarity: probe.detectPolarity(f));
    final ref = GaugeReader(cal).captureReference(f);
    return cal.copyWith(reference: ref);
  }

  void _refreshPreview() {
    final cal = _build();
    _preview = cal;
    _previewReading = cal == null ? null : GaugeReader(cal).read(_frame!);
  }

  void _save() {
    final cal = _build();
    if (cal == null) return;
    widget.settings.calibration = cal;
    widget.source.setCalibration(cal);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibrate gauge'),
        actions: [
          if (_still != null)
            TextButton(
              onPressed: () => setState(() {
                _still?.dispose();
                _still = null;
                _frame = null;
              }),
              child: const Text('Retake'),
            ),
        ],
      ),
      body: SafeArea(child: _still == null ? _aimView() : _markView()),
    );
  }

  // ---- step 1: aim -------------------------------------------------------

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
                'Mount the phone so it looks straight at the gauge with the lever up. '
                'Leave room below the gauge — it travels down with the piston. '
                'Keep the phone in the same place for brewing.',
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
                icon: const Icon(Icons.camera),
                label: const Text('Capture still'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---- step 2: mark ------------------------------------------------------

  String get _instruction => switch (_step) {
        _Step.center => '1/3  Tap the centre of the needle hub.',
        _Step.zero => '2/3  Tap the outer end of the 0 bar mark.',
        _Step.max => '3/3  Tap the outer end of the highest numbered mark.',
        _Step.adjust =>
          'Drag points to fine-tune. Fit the circle to the edge of the dial face.',
      };

  Widget _markView() {
    final f = _frame!;
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(_instruction, style: theme.textTheme.titleMedium),
        ),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: f.uprightWidth / f.uprightHeight,
              child: LayoutBuilder(builder: (context, box) {
                final k = box.maxWidth / f.uprightWidth;
                Offset toFrame(Offset p) => p / k;
                return GestureDetector(
                  onTapUp: (d) {
                    if (_step == _Step.adjust) return;
                    setState(() {
                      final p = toFrame(d.localPosition);
                      switch (_step) {
                        case _Step.center:
                          _center = p;
                        case _Step.zero:
                          _zero = p;
                        case _Step.max:
                          _max = p;
                          _refreshPreview();
                        case _Step.adjust:
                      }
                    });
                  },
                  onPanStart: (d) {
                    final pts = [_center, _zero, _max];
                    var best = -1;
                    var bestD = 40.0;
                    for (var i = 0; i < 3; i++) {
                      final p = pts[i];
                      if (p == null) continue;
                      final dd = (p * k - d.localPosition).distance;
                      if (dd < bestD) {
                        bestD = dd;
                        best = i;
                      }
                    }
                    _dragging = best < 0 ? null : best;
                  },
                  onPanUpdate: (d) {
                    final i = _dragging;
                    if (i == null) return;
                    setState(() {
                      final p = toFrame(d.localPosition);
                      if (i == 0) _center = p;
                      if (i == 1) _zero = p;
                      if (i == 2) _max = p;
                    });
                  },
                  onPanEnd: (_) => setState(() {
                    _dragging = null;
                    if (_step == _Step.adjust) _refreshPreview();
                  }),
                  child: CustomPaint(
                    painter: _MarkPainter(
                      still: _still!,
                      k: k,
                      center: _center,
                      zero: _zero,
                      max: _max,
                      radiusScale: _radiusScale,
                      cal: _preview,
                      reading: _previewReading,
                      needleColor: ChartColors.pressure(Brightness.dark),
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              }),
            ),
          ),
        ),
        if (_step == _Step.adjust) _adjustPanel(theme),
        if (_step != _Step.adjust)
          TextButton(
            onPressed: _center == null
                ? null
                : () => setState(() {
                      if (_max != null) {
                        _max = null;
                      } else if (_zero != null) {
                        _zero = null;
                      } else {
                        _center = null;
                      }
                    }),
            child: const Text('Undo'),
          ),
      ],
    );
  }

  Widget _adjustPanel(ThemeData theme) {
    final r = _previewReading;
    final ok = r != null && r.isValid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Text('Circle'),
            Expanded(
              child: Slider(
                min: 0.9,
                max: 1.5,
                value: _radiusScale,
                onChanged: (v) => setState(() => _radiusScale = v),
                onChangeEnd: (_) => setState(_refreshPreview),
              ),
            ),
          ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _minCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Value at 1st mark (bar)'),
                onChanged: (_) => setState(_refreshPreview),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _maxCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Value at last mark (bar)'),
                onChanged: (_) => setState(_refreshPreview),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Follow the gauge as it moves'),
            subtitle: const Text('The Flair 58 gauge sits on the piston stem'),
            value: _track,
            onChanged: (v) => setState(() {
              _track = v;
              _refreshPreview();
            }),
          ),
          Row(children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline,
                color: ok ? theme.colorScheme.primary : theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(ok
                  ? 'Needle found: ${r.value.toStringAsFixed(1)} bar '
                      '(${_preview!.polarity > 0 ? 'dark' : 'light'} needle, '
                      'clarity ${r.confidence.toStringAsFixed(0)})'
                  : 'Needle not found clearly — check the points, '
                      'lighting and reflections.'),
            ),
          ]),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _preview == null ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Save calibration'),
          ),
        ],
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.still,
    required this.k,
    required this.center,
    required this.zero,
    required this.max,
    required this.radiusScale,
    required this.cal,
    required this.reading,
    required this.needleColor,
  });

  final ui.Image still;
  final double k;
  final Offset? center, zero, max;
  final double radiusScale;
  final GaugeCalibration? cal;
  final GaugeReading? reading;
  final Color needleColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      still,
      Rect.fromLTWH(0, 0, still.width.toDouble(), still.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final line = Paint()
      ..color = Colors.yellowAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    void dot(Offset? p, String label) {
      if (p == null) return;
      final o = p * k;
      canvas.drawCircle(o, 9, Paint()..color = Colors.black54);
      canvas.drawCircle(o, 9, line);
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: const TextStyle(
                color: Colors.yellowAccent, fontSize: 12, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o + const Offset(12, -20));
    }

    final c = center;
    if (c != null) {
      for (final p in [zero, max]) {
        if (p != null) canvas.drawLine(c * k, p * k, line..strokeWidth = 1);
      }
      if (zero != null && max != null) {
        final r = math.max((zero! - c).distance, (max! - c).distance) * radiusScale;
        canvas.drawCircle(c * k, r * k, line..strokeWidth = 2);
        // Sweep arc between the marks.
        final cal = this.cal;
        if (cal != null) {
          canvas.drawArc(Rect.fromCircle(center: c * k, radius: r * k * 0.9),
              cal.zeroAngle, cal.sweep, false,
              Paint()
                ..color = Colors.yellowAccent.withValues(alpha: 0.5)
                ..strokeWidth = 4
                ..style = PaintingStyle.stroke);
        }
      }
    }
    final rd = reading;
    if (c != null && rd != null && rd.isValid) {
      final d = Offset(math.cos(rd.angle), math.sin(rd.angle));
      final r = rd.radius * k;
      canvas.drawLine(c * k + d * r * 0.2, c * k + d * r * 0.95,
          Paint()
            ..color = needleColor
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round);
    }
    dot(center, 'centre');
    dot(zero, 'min');
    dot(max, 'max');
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => true;
}
