import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/shot.dart';

/// Series colours (validated categorical slots 1–3, light / dark steps).
class ChartColors {
  static Color pressure(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6);
  static Color weight(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFD95926) : const Color(0xFFEB6834);
  static Color flow(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF199E70) : const Color(0xFF1BAF7A);
}

class _Series {
  _Series(this.title, this.unit, this.color, this.decimals, this.pick,
      this.minMax, {this.band});
  final String title;
  final String unit;
  final Color color;
  final int decimals;
  final double? Function(ShotSample) pick;
  final double minMax; // y max is at least this
  final (double, double)? band; // shaded reference band
}

/// Pressure, weight and flow as three small-multiple panels sharing one time
/// axis. Drag across the chart to read exact values.
class BrewChart extends StatefulWidget {
  const BrewChart({
    super.key,
    required this.samples,
    this.minSeconds = 30,
    this.showWeight = true,
    this.showFlow = true,
  });

  final List<ShotSample> samples;
  final double minSeconds;
  final bool showWeight;
  final bool showFlow;

  @override
  State<BrewChart> createState() => _BrewChartState();
}

class _BrewChartState extends State<BrewChart> {
  double? _scrubX;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final series = <_Series>[
      _Series('Pressure', 'bar', ChartColors.pressure(b), 1, (s) => s.pressure,
          10, band: (6, 9)),
      if (widget.showWeight)
        _Series('Weight', 'g', ChartColors.weight(b), 1, (s) => s.weight, 40),
      if (widget.showFlow)
        _Series('Flow', 'g/s', ChartColors.flow(b), 1, (s) => s.flow, 3),
    ];
    return LayoutBuilder(builder: (context, c) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => setState(() => _scrubX = d.localPosition.dx),
        onHorizontalDragUpdate: (d) => setState(() => _scrubX = d.localPosition.dx),
        onHorizontalDragEnd: (_) => setState(() => _scrubX = null),
        onTapDown: (d) => setState(() => _scrubX = d.localPosition.dx),
        onTapUp: (_) => setState(() => _scrubX = null),
        child: CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _ChartPainter(
            samples: widget.samples,
            series: series,
            minSeconds: widget.minSeconds,
            scrubX: _scrubX,
            text: theme.colorScheme.onSurface,
            muted: theme.colorScheme.onSurfaceVariant,
            grid: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            surface: theme.colorScheme.surface,
          ),
        ),
      );
    });
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.samples,
    required this.series,
    required this.minSeconds,
    required this.scrubX,
    required this.text,
    required this.muted,
    required this.grid,
    required this.surface,
  });

  final List<ShotSample> samples;
  final List<_Series> series;
  final double minSeconds;
  final double? scrubX;
  final Color text, muted, grid, surface;

  static const _left = 34.0;
  static const _right = 8.0;
  static const _header = 20.0;
  static const _gap = 10.0;
  static const _xAxis = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final tMax = math.max(
        minSeconds, samples.isEmpty ? 0.0 : (samples.last.t / 5).ceil() * 5.0);
    final plotW = size.width - _left - _right;
    final panelH =
        (size.height - _xAxis - series.length * (_header + _gap) + _gap) /
            series.length;
    if (plotW <= 0 || panelH <= 10) return;

    double xOf(double t) => _left + t / tMax * plotW;

    // Scrub position -> nearest sample.
    ShotSample? scrub;
    if (scrubX != null && samples.isNotEmpty) {
      final t = ((scrubX! - _left) / plotW * tMax).clamp(0.0, samples.last.t);
      scrub = samples.reduce((a, b) => (a.t - t).abs() < (b.t - t).abs() ? a : b);
    }

    var top = 0.0;
    for (final s in series) {
      final plotTop = top + _header;
      final plotBottom = plotTop + panelH;
      final values = samples.map(s.pick).whereType<double>();
      final vMax = _niceMax(math.max(
          s.minMax, values.isEmpty ? 0 : values.reduce(math.max) * 1.1));
      double yOf(double v) =>
          plotBottom - (v.clamp(0, vMax) / vMax) * panelH;

      // Header: title (secondary ink) + current / scrubbed value (primary).
      final shown = scrub != null
          ? s.pick(scrub)
          : (samples.isEmpty ? null : _lastNonNull(s));
      _text(canvas, '${s.title} · ${s.unit}', Offset(_left, top + 2), muted, 12);
      // Small colour key so identity is not colour-alone across panels.
      canvas.drawLine(Offset(_left - 18, top + 10), Offset(_left - 6, top + 10),
          Paint()
            ..color = s.color
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round);
      _text(
        canvas,
        shown == null ? '–' : shown.toStringAsFixed(s.decimals),
        Offset(size.width - _right, top + 1),
        text,
        13,
        alignRight: true,
        bold: true,
      );

      // Reference band (espresso zone).
      if (s.band != null) {
        final (lo, hi) = s.band!;
        canvas.drawRect(
          Rect.fromLTRB(_left, yOf(hi), _left + plotW, yOf(lo)),
          Paint()..color = s.color.withValues(alpha: 0.07),
        );
      }

      // Grid + y labels.
      final gp = Paint()
        ..color = grid
        ..strokeWidth = 1;
      final step = _niceStep(vMax);
      for (var v = 0.0; v <= vMax + 1e-9; v += step) {
        final y = yOf(v);
        canvas.drawLine(Offset(_left, y), Offset(_left + plotW, y), gp);
        _text(canvas, _fmt(v), Offset(_left - 6, y - 7), muted, 10,
            alignRight: true);
      }

      // Line, broken where data is missing.
      final path = Path();
      var pen = false;
      for (final smp in samples) {
        final v = s.pick(smp);
        if (v == null) {
          pen = false;
          continue;
        }
        final o = Offset(xOf(smp.t), yOf(v));
        if (pen) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          pen = true;
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);

      // Scrub marker.
      if (scrub != null) {
        final v = s.pick(scrub);
        final x = xOf(scrub.t);
        canvas.drawLine(Offset(x, plotTop), Offset(x, plotBottom),
            Paint()
              ..color = muted
              ..strokeWidth = 1);
        if (v != null) {
          final o = Offset(x, yOf(v));
          canvas.drawCircle(o, 5, Paint()..color = surface);
          canvas.drawCircle(o, 4, Paint()..color = s.color);
        }
      }
      top = plotBottom + _gap;
    }

    // Shared time axis.
    final axisY = top - _gap + 4;
    final tStep = tMax <= 30 ? 5.0 : (tMax <= 90 ? 10.0 : 30.0);
    for (var t = 0.0; t <= tMax + 1e-9; t += tStep) {
      _text(canvas, '${t.toInt()}s', Offset(xOf(t), axisY), muted, 10,
          center: true);
    }
    if (scrub != null) {
      _text(canvas, '${scrub.t.toStringAsFixed(1)} s',
          Offset(xOf(scrub.t), axisY), text, 10,
          center: true, bold: true, background: surface);
    }
  }

  double? _lastNonNull(_Series s) {
    for (final smp in samples.reversed) {
      final v = s.pick(smp);
      if (v != null) return v;
    }
    return null;
  }

  static double _niceMax(double v) {
    final step = _niceStep(v);
    return (v / step).ceil() * step;
  }

  static double _niceStep(double v) {
    if (v <= 4) return 1;
    if (v <= 12) return 3;
    if (v <= 20) return 5;
    if (v <= 60) return 10;
    if (v <= 120) return 20;
    return 50;
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  void _text(Canvas c, String s, Offset at, Color color, double size,
      {bool alignRight = false,
      bool center = false,
      bool bold = false,
      Color? background}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    if (background != null) {
      c.drawRect(Rect.fromLTWH(dx - 3, at.dy - 1, tp.width + 6, tp.height + 2),
          Paint()..color = background);
    }
    tp.paint(c, Offset(dx, at.dy));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
