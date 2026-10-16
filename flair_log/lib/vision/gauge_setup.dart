import 'dart:math' as math;

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

/// Calibration steps as pure functions, so the UI can run them on a
/// background isolate (`Isolate.run`).
class GaugeSetup {
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
