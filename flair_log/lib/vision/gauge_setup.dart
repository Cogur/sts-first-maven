import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'dial_geometry.dart';
import 'dial_locator.dart';
import 'gauge_calibration.dart';
import 'gauge_reader.dart';
import 'luma_frame.dart';

/// What the app worked out by itself about a gauge from one still frame.
class DialAnalysis {
  const DialAnalysis({
    required this.face,
    required this.pivotX,
    required this.pivotY,
    required this.polarity,
    this.restAngle,
    this.restConfidence = 0,
    this.lineAngle,
  });

  final DialGeometry face;
  final double pivotX, pivotY;
  final int polarity;

  /// Dial angle of the needle in this frame (taken as 0 bar), if found.
  final double? restAngle;
  final double restConfidence;

  DialGeometry get needleGeometry => face.moved(pivotX, pivotY);

  /// Direction of the straight dark line through the dial (mod 180°), an
  /// independent check of the needle direction.
  final double? lineAngle;

  /// Found if clearly visible, or a little less clear but confirmed by the
  /// straight-line search (small or busy dials).
  bool get needleFound {
    final a = restAngle;
    if (a == null) return false;
    if (restConfidence >= GaugeReader.minConfidence) return true;
    final l = lineAngle;
    if (l == null || restConfidence < 2.5) return false;
    var d = (a - l) % math.pi;
    if (d < 0) d += math.pi;
    return math.min(d, math.pi - d) < 8 * math.pi / 180;
  }
}

// ---- background tasks -------------------------------------------------------
//
// Work is sent to another isolate with `compute(topLevelFunction, request)`,
// never with `Isolate.run(() => ...)` from widget code: a closure shares its
// captured context with the other closures of the same method (setState
// callbacks holding ui.Image, the State, ...), and sending that fails with
// "object is unsendable". That bug left calibration stuck on "Looking for
// the gauge…". Requests below contain only sendable data.

class FindRequest {
  const FindRequest(this.frame,
      {this.tapX, this.tapY, this.minRadius, this.maxRadius, this.maxResults = 4});
  final LumaFrame frame;
  final double? tapX, tapY, minRadius, maxRadius;
  final int maxResults;
}

List<DialGeometry> findDialsTask(FindRequest r) => GaugeSetup.findDials(r.frame,
    tapX: r.tapX,
    tapY: r.tapY,
    minRadius: r.minRadius,
    maxRadius: r.maxRadius,
    maxResults: r.maxResults);

class AnalyseRequest {
  const AnalyseRequest(this.frame, this.face);
  final LumaFrame frame;
  final DialGeometry face;
}

DialAnalysis analyseTask(AnalyseRequest r) => GaugeSetup.analyse(r.frame, r.face);

class RelocateRequest {
  const RelocateRequest(this.frame, this.calibration, this.keepZero);
  final LumaFrame frame;
  final GaugeCalibration calibration;
  final bool keepZero;
}

GaugeCalibration? relocateTask(RelocateRequest r) =>
    GaugeSetup.relocate(r.frame, r.calibration, keepZero: r.keepZero);

/// Calibration steps as pure functions; the `...InBackground` variants run
/// them on another isolate.
class GaugeSetup {
  static Future<List<DialGeometry>> findDialsInBackground(LumaFrame f,
          {double? tapX, double? tapY, double? minRadius, double? maxRadius, int maxResults = 4}) =>
      _background(
          findDialsTask,
          FindRequest(f,
              tapX: tapX,
              tapY: tapY,
              minRadius: minRadius,
              maxRadius: maxRadius,
              maxResults: maxResults));

  static Future<DialAnalysis> analyseInBackground(LumaFrame f, DialGeometry face) =>
      _background(analyseTask, AnalyseRequest(f, face));

  static Future<GaugeCalibration?> relocateInBackground(LumaFrame f, GaugeCalibration c,
          {bool keepZero = false}) =>
      _background(relocateTask, RelocateRequest(f, c, keepZero));

  /// Largest phone rotation accepted from the needle at rest.
  static const double maxRelocateTurn = 25 * math.pi / 180;

  /// Finds the calibrated gauge in a new view (the phone is not in exactly
  /// the same place every time). Uses the same steps as calibration: the
  /// round thing with the clearest needle, its pivot, and the needle at rest
  /// (the lever is up when a session starts), which marks zero. How far
  /// that is from the stored zero tells how much the phone is turned; the
  /// learned background is turned with it and the appearance template is
  /// recorded afresh. The bar-per-degree scale is kept.
  ///
  /// With [keepZero] (the gauge was lost mid-shot, the needle is not at rest)
  /// only the position is updated.
  static GaugeCalibration? relocate(LumaFrame f, GaugeCalibration c, {bool keepZero = false}) {
    for (final d in findDials(f, maxResults: 4)) {
      final a = analyse(f, d);
      if (!a.needleFound) continue; // no needle: not a gauge (shot mirror, cup)
      var rot = 0.0;
      if (!keepZero) {
        var diff = (a.restAngle! - c.zeroAngle) % (2 * math.pi);
        if (diff > math.pi) diff -= 2 * math.pi;
        if (diff.abs() <= maxRelocateTurn) rot = diff;
      }
      final r = Relocation(a.face, rot, a.restConfidence);
      return GaugeReader.relocated(c, r, f.uprightWidth, f.uprightHeight,
          pivotX: a.pivotX,
          pivotY: a.pivotY,
          template: keepZero ? null : GaugeReader.captureTemplate(f, a.face));
    }
    return null;
  }

  /// Runs [task] on another isolate; if that is not possible, on this one
  /// (a short freeze is better than hanging forever).
  static Future<R> _background<Q, R>(R Function(Q) task, Q request) async {
    try {
      return await compute(task, request);
    } catch (e) {
      debugPrint('Background task failed ($e), running it here instead');
      return task(request);
    }
  }

  /// Needle clarity that marks a candidate as a gauge rather than another
  /// round thing (a shot mirror, a cup seen from above, a knob).
  static const double gaugeNeedle = 6;

  /// Step 1: candidate dials in the whole frame, best first: round things
  /// with a needle before those without, then by rim contrast. With a tap
  /// position only dials around that point are considered.
  static List<DialGeometry> findDials(LumaFrame f,
      {double? tapX, double? tapY, double? minRadius, double? maxRadius, int maxResults = 4}) {
    final found = DialLocator.find(f,
        hintX: tapX,
        hintY: tapY,
        minRadius: minRadius,
        maxRadius: maxRadius,
        maxResults: math.max(8, maxResults));
    // A gauge never sits inside another gauge's face: drop circles nested in
    // a bigger candidate (bright patches between the needle and the ticks,
    // the hub area).
    bool nested(DialGeometry g) => found.any((h) =>
        h.radius > 1.3 * g.radius &&
        math.sqrt(math.pow(g.cx - h.cx, 2) + math.pow(g.cy - h.cy, 2)) + g.radius <=
            1.15 * h.radius);
    final ranked = [
      for (final g in found)
        if (!nested(g)) (g, GaugeReader.anyNeedle(f, g)?.$1.confidence ?? 0.0)
    ];
    ranked.sort((a, b) {
      final na = a.$2 >= gaugeNeedle, nb = b.$2 >= gaugeNeedle;
      if (na != nb) return na ? -1 : 1;
      // Among gauges the clearest needle wins; otherwise the best rim.
      return na ? b.$2.compareTo(a.$2) : b.$1.score.compareTo(a.$1.score);
    });
    return [for (final r in ranked.take(maxResults)) r.$1];
  }

  /// Step 2: pivot, needle polarity and the needle's rest position.
  static DialAnalysis analyse(LumaFrame f, DialGeometry face) {
    final hubs = DialLocator.hubCandidates(f, face.cx, face.cy, face.radius);
    final pivot = GaugeReader.choosePivot(f, face, hubs);
    final ng = face.moved(pivot.$1, pivot.$2);
    final hit = GaugeReader.anyNeedle(f, ng);
    final line = GaugeReader.needleLine(f, face);
    return DialAnalysis(
      lineAngle: line == null ? null : math.atan2(line.$4, line.$3),
      face: face,
      pivotX: pivot.$1,
      pivotY: pivot.$2,
      polarity: hit?.$2 ?? 1,
      restAngle: hit?.$1.angle,
      restConfidence: hit?.$1.confidence ?? 0,
    );
  }

  /// Dial angle of an image point as seen from the pivot.
  static double angleAt(DialAnalysis a, double x, double y) =>
      a.needleGeometry.polarOf(x, y).$1;

  /// Step 3: the calibration, including a first background of the empty dial
  /// learned from this frame (everything away from the needle).
  static GaugeCalibration build({
    required LumaFrame frame,
    required DialAnalysis analysis,
    required double zeroAngle,
    required double markAngle,
    required double markValue,
    bool trackMovement = true,
    double zoom = 1,
  }) {
    final ng = analysis.needleGeometry;
    final polar = GaugeReader.samplePolar(frame, ng);
    // The lever is up, so the needle sits on the confirmed zero: everything
    // else is the empty dial. (If the user had to tap 0 because detection
    // picked something else, that something is learned as background.)
    final bg = GaugeReader.learnBackground(null, polar, zeroAngle);
    return GaugeCalibration.fromDial(
      face: analysis.face,
      pivotX: analysis.pivotX,
      pivotY: analysis.pivotY,
      frameWidth: frame.uprightWidth,
      frameHeight: frame.uprightHeight,
      zeroAngle: zeroAngle,
      markAngle: markAngle,
      markValue: markValue,
      polarity: analysis.polarity,
      trackMovement: trackMovement,
      zoom: zoom,
      background: bg,
      template: GaugeReader.captureTemplate(frame, analysis.face),
    );
  }

  /// Square region (left, top, size) around a dial for a zoomed view.
  static (double, double, double) zoomRegion(DialGeometry face, {double factor = 2.6}) {
    final size = factor * math.max(face.rx, face.ry);
    return (face.cx - size / 2, face.cy - size / 2, size);
  }
}
