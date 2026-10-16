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
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CustomPaint(
            painter: _GaugePainter(
              roi: roi,
              cal: cal,
              reading: source.lastReading,
              sample: source.latest,
              color: ChartColors.pressure(Brightness.dark),
            ),
            child: const SizedBox.expand(),
          ),
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
    Offset map(double x, double y) =>
        Offset((x - roi.left) * scale, (y - roi.top) * scale);
    final c = map(r.centerX, r.centerY);
    final rad = r.radius * scale;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = (r.trackingScore > 0.45 ? Colors.white : Colors.orangeAccent)
          .withValues(alpha: 0.7);
    canvas.drawCircle(c, rad, ring);

    // Min / max marks.
    for (final a in [cal.zeroAngle, cal.zeroAngle + cal.sweep]) {
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * rad * 0.88, c + d * rad * 1.05, ring);
    }

    // Raw detection: thin line, orange when dropped as an impossible jump.
    if (r.isValid) {
      final d = Offset(math.cos(r.angle), math.sin(r.angle));
      canvas.drawLine(
        c + d * rad * 0.2,
        c + d * rad * 0.95,
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
      final a = cal.angleForValue(bar);
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + d * rad * 0.2,
        c + d * rad * 0.95,
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
