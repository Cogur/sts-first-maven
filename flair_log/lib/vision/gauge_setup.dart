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
  });

  final DialGeometry face;
  final double pivotX, pivotY;
  final int polarity;

  /// Dial angle of the needle in this frame (taken as 0 bar), if found.
  final double? restAngle;
  final double restConfidence;

  DialGeometry get needleGeometry => face.moved(pivotX, pivotY);

  bool get needleFound =>
      restAngle != null && restConfidence >= GaugeReader.minConfidence;
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

List<DialGeometry> findDialsTask(FindRequest r) => DialLocator.find(r.frame,
    hintX: r.tapX,
    hintY: r.tapY,
    minRadius: r.minRadius,
    maxRadius: r.maxRadius,
    maxResults: r.maxResults);

class AnalyseRequest {
  const AnalyseRequest(this.frame, this.face);
  final LumaFrame frame;
  final DialGeometry face;
}

DialAnalysis analyseTask(AnalyseRequest r) => GaugeSetup.analyse(r.frame, r.face);

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

  /// Step 1: candidate dials in the whole frame (best first). With a tap
  /// position only dials around that point are considered.
  static List<DialGeometry> findDials(LumaFrame f, {double? tapX, double? tapY}) =>
      DialLocator.find(f, hintX: tapX, hintY: tapY);

  /// Step 2: pivot, needle polarity and the needle's rest position.
  static DialAnalysis analyse(LumaFrame f, DialGeometry face) {
    final hubs = DialLocator.hubCandidates(f, face.cx, face.cy, face.radius);
    final pivot = GaugeReader.choosePivot(f, face, hubs);
    final ng = face.moved(pivot.$1, pivot.$2);
    final hit = GaugeReader.anyNeedle(f, ng);
    return DialAnalysis(
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
