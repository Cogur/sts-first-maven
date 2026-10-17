import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../vision/camera_gauge_source.dart';
import '../../vision/gauge_calibration.dart';
import '../../vision/gauge_reader.dart';
import '../../vision/pressure_source.dart';
import 'brew_chart.dart';

/// Zoomed greyscale view of the gauge exactly as the detector sees it, with
/// the detected needle drawn on top.
class GaugeView extends StatelessWidget {
  const GaugeView({super.key, required this.source});

  final CameraGaugeSource source;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final roi = source.roi;
        final cal = source.calibration;
        if (roi == null || cal == null) {
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Text(
              source.error ?? (cal == null ? 'Not calibrated' : 'Starting camera…'),
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          );
        }
        final lost = source.lastReading?.tracked == false;
        final note = source.status ?? (lost ? 'Gauge lost, searching…' : null);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(fit: StackFit.expand, children: [
            CustomPaint(
              painter: _GaugePainter(
                roi: roi,
                cal: cal,
                reading: source.lastReading,
                sample: source.latest,
                color: ChartColors.pressure(Brightness.dark),
              ),
            ),
            if (note != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(note,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.roi,
    required this.cal,
    required this.reading,
    required this.sample,
    required this.color,
  });

  final RoiView roi;
  final GaugeCalibration cal;
  final GaugeReading? reading;
  final PressureSample? sample;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final scale = s / roi.size;
    canvas.drawImageRect(
      roi.image,
      Rect.fromLTWH(0, 0, roi.image.width.toDouble(), roi.image.height.toDouble()),
      Rect.fromLTWH(0, 0, s, s),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final r = reading;
    if (r == null) return;
    Offset map((double, double) p) =>
        Offset((p.$1 - roi.left) * scale, (p.$2 - roi.top) * scale);

    // Dial face as found in this frame; orange while it is being searched.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = (r.tracked ? Colors.white : Colors.orangeAccent)
          .withValues(alpha: 0.7);
    final face = Path();
    for (var i = 0; i <= 72; i++) {
      final o = map(r.face.point(2 * math.pi * i / 72, 1));
      i == 0 ? face.moveTo(o.dx, o.dy) : face.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(face, ring);

    // Zero and reference marks.
    final ng = r.needle;
    for (final a in [cal.zeroAngle, cal.zeroAngle + cal.sweep]) {
      canvas.drawLine(map(ng.point(a, 0.88)), map(ng.point(a, 1.0)), ring);
    }

    void needle(double a, Paint p) =>
        canvas.drawLine(map(ng.point(a, 0.15)), map(ng.point(a, 0.95)), p);

    // Raw detection: thin line, orange when dropped as an impossible jump.
    if (r.isValid) {
      needle(
        r.angle,
        Paint()
          ..color = (sample?.rejected ?? false)
              ? Colors.orangeAccent
              : Colors.white.withValues(alpha: 0.45)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }
    // The value that is shown and recorded (after smoothing / rejection).
    final bar = sample?.bar;
    if (bar != null) {
      needle(
        cal.angleForValue(bar),
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => true;
}
