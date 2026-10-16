import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

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

  /// Set to false when nobody is looking at the zoomed view, to save work.
  bool wantRoi = true;

  int _quarterTurns = 0;
  bool _busy = false;
  bool _roiBusy = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRoi = DateTime.fromMillisecondsSinceEpoch(0);
  final List<double> _recent = [];
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
        ResolutionPreset.high,
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
    _recent.clear();
    notifyListeners();
  }

  /// Returns a copy of the next camera frame (for calibration).
  Future<LumaFrame> grabFrame() {
    _grab ??= Completer<LumaFrame>();
    return _grab!.future;
  }

  @override
  void prepareForShot() {
    _reader?.resetTracking();
    _recent.clear();
    // Freeze focus/exposure so the camera doesn't hunt during the shot.
    final c = _controller;
    if (c != null) {
      c.setFocusMode(FocusMode.locked).catchError((_) {});
      c.setExposureMode(ExposureMode.locked).catchError((_) {});
    }
  }

  @override
  void shotFinished() {
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
      final reader = _reader;
      if (reader == null) return;

      final r = reader.read(frame);
      lastReading = r;
      double? bar;
      if (r != null && r.isValid) {
        _recent.add(r.value);
        if (_recent.length > 3) _recent.removeAt(0);
        final s = List.of(_recent)..sort();
        bar = s[s.length ~/ 2];
      }
      _latest = PressureSample(at: now, bar: bar, reading: r);
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

  void _renderRoi(LumaFrame f, GaugeReading? r) {
    final cal = calibration;
    if (cal == null) return;
    final cx = r?.centerX ?? cal.centerX * f.uprightWidth;
    final cy = r?.centerY ?? cal.centerY * f.uprightHeight;
    final size = cal.radius * f.uprightWidth * 2.7;
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
