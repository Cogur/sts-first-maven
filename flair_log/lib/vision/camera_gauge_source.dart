import 'dart:async';
import 'dart:io' show Directory, Platform;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostic_recorder.dart';
import 'gauge_setup.dart';
import 'gauge_calibration.dart';
import 'gauge_reader.dart';
import 'luma_frame.dart';
import 'pressure_source.dart';

/// Region of the upright frame shown in the zoomed gauge view.
class RoiView {
  const RoiView(this.image, this.left, this.top, this.size);
  final ui.Image image;
  final double left, top, size; // upright pixels
}

/// Streams camera frames, runs the [GaugeReader] on them and publishes
/// pressure readings plus a zoomed greyscale view of the gauge.
class CameraGaugeSource extends PressureSource {
  CameraGaugeSource(GaugeCalibration? calibration)
      : _reader = calibration == null ? null : GaugeReader(calibration);

  CameraController? _controller;
  CameraController? get controller => _controller;

  GaugeReader? _reader;
  GaugeCalibration? get calibration => _reader?.calibration;

  String? error;
  bool get isReady => _controller?.value.isInitialized ?? false;

  final _ctrl = StreamController<PressureSample>.broadcast();
  @override
  Stream<PressureSample> get samples => _ctrl.stream;

  PressureSample? _latest;
  @override
  PressureSample? get latest => _latest;

  GaugeReading? lastReading;
  RoiView? roi;

  /// Called after a shot with the calibration including what the reader
  /// learned about the empty dial; the app persists it.
  void Function(GaugeCalibration calibration)? onLearned;

  bool _relocating = false;
  bool _sessionLocated = false;
  bool _inShot = false;
  DateTime _lastRelocate = DateTime.fromMillisecondsSinceEpoch(0);

  /// What the camera is busy with ("Finding the gauge…"), for the UI.
  String? status;

  /// Record what the camera sees during shots (Settings).
  bool recordDiagnostics = false;
  DiagnosticRecorder? _recorder;
  bool _recorderStarting = false;
  bool _wantRecording = false;

  /// Path of the recording of the current / last shot.
  String? recordingPath;

  /// Set to false when nobody is looking at the zoomed view, to save work.
  bool wantRoi = true;

  int _quarterTurns = 0;
  bool _busy = false;
  bool _roiBusy = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRoi = DateTime.fromMillisecondsSinceEpoch(0);
  Completer<LumaFrame>? _grab;

  double minZoom = 1, maxZoom = 1, zoom = 1;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
  bool torch = false;

  @override
  Future<void> start() async {
    if (_controller != null) return;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('No camera found');
      final cam = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(
        cam,
        // 1080p: the gauge can be small when the whole machine is in view.
        // Analysis samples only around the gauge, so cost does not grow.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      _controller = c;
      // Android delivers sensor-oriented buffers; iOS delivers them upright
      // for a portrait-locked app.
      _quarterTurns =
          !kIsWeb && Platform.isAndroid ? (cam.sensorOrientation ~/ 90) % 4 : 0;
      minZoom = await c.getMinZoomLevel();
      maxZoom = await c.getMaxZoomLevel();
      final z = calibration?.zoom ?? 1.0;
      await setZoom(z);
      await c.startImageStream(_onFrame);
      error = null;
    } catch (e) {
      error = 'Camera unavailable: $e';
    }
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      await c.dispose();
    }
  }

  Future<void> setZoom(double z) async {
    zoom = z.clamp(minZoom, maxZoom);
    try {
      await _controller?.setZoomLevel(zoom);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setTorch(bool on) async {
    torch = on;
    try {
      await _controller?.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
    notifyListeners();
  }

  void setCalibration(GaugeCalibration c) {
    final r = _reader;
    if (r == null) {
      _reader = GaugeReader(c);
    } else {
      r.updateCalibration(c);
    }
    filter.reset();
    notifyListeners();
  }

  /// Returns a copy of the next camera frame (for calibration).
  Future<LumaFrame> grabFrame() {
    _grab ??= Completer<LumaFrame>();
    return _grab!.future;
  }

  @override
  void prepareForShot() {
    _inShot = true;
    recordingPath = null;
    _wantRecording = recordDiagnostics;
    _reader?.resetTracking();
    filter.reset();
    // Freeze focus/exposure so the camera doesn't hunt during the shot.
    final c = _controller;
    if (c != null) {
      c.setFocusMode(FocusMode.locked).catchError((_) {});
      c.setExposureMode(ExposureMode.locked).catchError((_) {});
    }
  }

  @override
  void shotFinished() {
    _inShot = false;
    _wantRecording = false;
    _recorder?.close();
    _recorder = null;
    final reader = _reader;
    final bg = reader?.background;
    if (reader != null && bg != null) {
      final learned = reader.calibration.copyWith(background: bg.copy());
      reader.calibration = learned;
      onLearned?.call(learned);
    }
    final c = _controller;
    if (c != null) {
      c.setFocusMode(FocusMode.auto).catchError((_) {});
      c.setExposureMode(ExposureMode.auto).catchError((_) {});
    }
  }

  void _onFrame(CameraImage img) {
    final now = DateTime.now();
    if (_grab == null &&
        (_busy || now.difference(_lastFrame).inMilliseconds < 60)) {
      return;
    }
    _busy = true;
    _lastFrame = now;
    try {
      final p = img.planes.first;
      final frame = LumaFrame(
        bytes: p.bytes,
        width: img.width,
        height: img.height,
        rowStride: p.bytesPerRow,
        quarterTurns: _quarterTurns,
      );
      final g = _grab;
      if (g != null) {
        _grab = null;
        g.complete(frame.copy());
      }
      if (_wantRecording) _record(frame);
      final reader = _reader;
      if (reader == null) return;

      final r = reader.read(frame);
      lastReading = r;
      // Session start: look for the gauge once (the phone may stand
      // elsewhere than at calibration). Later: whenever it was lost.
      if (!_sessionLocated && !_inShot) {
        _relocate(frame, reader, keepZero: false);
      } else if (reader.lostFrames > 6) {
        _relocate(frame, reader, keepZero: _inShot);
      }
      final raw = r != null && r.isValid ? r.value : null;
      final bar = filter.update(raw, now.microsecondsSinceEpoch / 1e6);
      _latest = PressureSample(
        at: now,
        bar: bar,
        reading: r,
        rawBar: raw,
        rejected: filter.lastRejected,
      );
      _ctrl.add(_latest!);

      if (wantRoi && !_roiBusy && now.difference(_lastRoi).inMilliseconds > 90) {
        _lastRoi = now;
        _renderRoi(frame, r);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('frame error: $e');
    } finally {
      _busy = false;
    }
  }

  /// Finds the gauge again in the whole picture, in the background: at the
  /// start of a session (the phone is not in exactly the same place as at
  /// calibration) and whenever it was lost for a moment. During a shot only
  /// the position is updated; at the start, the needle at rest also re-sets
  /// zero (and so absorbs a slightly turned phone).
  void _relocate(LumaFrame frame, GaugeReader reader, {required bool keepZero}) {
    final now = DateTime.now();
    if (_relocating || now.difference(_lastRelocate).inMilliseconds < 1500) return;
    _relocating = true;
    _lastRelocate = now;
    status = 'Finding the gauge…';
    notifyListeners();
    final copy = frame.copy();
    GaugeSetup.relocateInBackground(copy, reader.calibration, keepZero: keepZero)
        .then((cal) {
      if (_disposed || cal == null) return;
      reader.updateCalibration(cal);
      filter.reset();
      _sessionLocated = true;
      onLearned?.call(cal); // remember the new position for next time
    }).catchError((Object e) {
      debugPrint('relocate failed: $e');
    }).whenComplete(() {
      _relocating = false;
      status = null;
      notifyListeners();
    });
  }

  void _record(LumaFrame frame) {
    final rec = _recorder;
    if (rec != null) {
      rec.add(frame);
      return;
    }
    if (_recorderStarting) return;
    _recorderStarting = true;
    final first = frame.copy();
    final face = lastReading?.face ??
        calibration?.face(frame.uprightWidth, frame.uprightHeight);
    getApplicationDocumentsDirectory().then((dir) async {
      await Directory('${dir.path}/diagnostics').create(recursive: true);
      final path =
          '${dir.path}/diagnostics/shot_${DateTime.now().millisecondsSinceEpoch}.flr';
      final r = await DiagnosticRecorder.start(path, first, face);
      if (_wantRecording && !_disposed) {
        _recorder = r;
        recordingPath = path;
      } else {
        await r.close();
      }
    }).catchError((Object e) {
      debugPrint('diagnostic recording failed: $e');
    }).whenComplete(() => _recorderStarting = false);
  }

  void _renderRoi(LumaFrame f, GaugeReading? r) {
    final cal = calibration;
    if (cal == null) return;
    final face = r?.face ?? cal.face(f.uprightWidth, f.uprightHeight);
    final cx = face.cx, cy = face.cy;
    final size = 2.6 * (face.rx > face.ry ? face.rx : face.ry);
    const out = 220;
    final left = cx - size / 2, top = cy - size / 2;
    final rgba = f.toRgba(
        left: left, top: top, regionW: size, regionH: size, outW: out, outH: out);
    _roiBusy = true;
    ui.decodeImageFromPixels(rgba, out, out, ui.PixelFormat.rgba8888, (img) {
      _roiBusy = false;
      if (_disposed) {
        img.dispose();
        return;
      }
      final old = roi;
      roi = RoiView(img, left, top, size);
      old?.image.dispose();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    roi?.image.dispose();
    _ctrl.close();
    super.dispose();
  }
}
