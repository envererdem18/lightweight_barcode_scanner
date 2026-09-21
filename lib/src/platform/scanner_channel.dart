import 'dart:async';

import 'package:flutter/services.dart';

import '../barcode_format.dart';
import '../scanner_options.dart';
import '../scanner_state.dart';
import 'scanner_preview.dart';

/// Thin transport over the platform channels.
///
/// Only decoded results and small control messages cross this boundary; camera
/// frames stay on the native side (see docs/ARCHITECTURE.md).
class ScannerChannel {
  ScannerChannel({MethodChannel? methodChannel})
    : _methods =
          methodChannel ??
          const MethodChannel('com.enver.lightweight_barcode_scanner/methods');

  static const String _eventChannelPrefix =
      'com.enver.lightweight_barcode_scanner/events';

  final MethodChannel _methods;

  Future<CameraPermissionStatus> requestPermission() async {
    final name = await _invoke<String>('requestPermission');
    return CameraPermissionStatus.fromName(name);
  }

  Future<CameraPermissionStatus> checkPermission() async {
    final name = await _invoke<String>('checkPermission');
    return CameraPermissionStatus.fromName(name);
  }

  /// Opens the camera and returns the session id used by every other call.
  Future<int> create(ScannerOptions options) async {
    final id = await _invoke<int>('create', options.toMap());
    return id ?? (throw const BarcodeScannerException(
      BarcodeScannerErrorCode.cameraInitializationFailed,
      'The platform did not return a scanner session id.',
    ));
  }

  Future<ScannerPreview> start(int sessionId) async {
    final map = await _invoke<Map<Object?, Object?>>('start', {
      'sessionId': sessionId,
    });
    if (map == null) {
      throw const BarcodeScannerException(
        BarcodeScannerErrorCode.cameraInitializationFailed,
        'The platform did not return preview information.',
      );
    }
    return ScannerPreview.fromMap(map);
  }

  Future<void> stop(int sessionId) =>
      _invoke<void>('stop', {'sessionId': sessionId});

  Future<void> pause(int sessionId) =>
      _invoke<void>('pause', {'sessionId': sessionId});

  Future<void> resume(int sessionId) =>
      _invoke<void>('resume', {'sessionId': sessionId});

  Future<void> dispose(int sessionId) =>
      _invoke<void>('dispose', {'sessionId': sessionId});

  Future<void> setTorch(int sessionId, {required bool enabled}) =>
      _invoke<void>('setTorch', {'sessionId': sessionId, 'enabled': enabled});

  Future<void> setZoom(int sessionId, double zoom) =>
      _invoke<void>('setZoom', {'sessionId': sessionId, 'zoom': zoom});

  Future<void> setFocusPoint(int sessionId, Offset? point) =>
      _invoke<void>('setFocusPoint', {
        'sessionId': sessionId,
        if (point != null) 'x': point.dx,
        if (point != null) 'y': point.dy,
      });

  Future<ScannerPreview> switchCamera(int sessionId, CameraFacing facing) async {
    final map = await _invoke<Map<Object?, Object?>>('switchCamera', {
      'sessionId': sessionId,
      'facing': facing.name,
    });
    if (map == null) {
      throw const BarcodeScannerException(
        BarcodeScannerErrorCode.cameraInitializationFailed,
        'The platform did not return preview information.',
      );
    }
    return ScannerPreview.fromMap(map);
  }

  Future<void> setFormats(int sessionId, Set<BarcodeFormat> formats) =>
      _invoke<void>('setFormats', {
        'sessionId': sessionId,
        'formats': BarcodeFormat.toMask(formats),
      });

  Future<void> setScanRegion(int sessionId, Rect? region) =>
      _invoke<void>('setScanRegion', {
        'sessionId': sessionId,
        if (region != null)
          'scanRegion': <double>[
            region.left,
            region.top,
            region.width,
            region.height,
          ],
      });

  Future<void> setDuplicateFilter(int sessionId, Duration duration) =>
      _invoke<void>('setDuplicateFilter', {
        'sessionId': sessionId,
        'duplicateFilterMillis': duration.inMilliseconds,
      });

  /// Events for one session: detections, state changes and errors.
  Stream<Map<Object?, Object?>> events(int sessionId) {
    return EventChannel('$_eventChannelPrefix/$sessionId')
        .receiveBroadcastStream()
        .map((event) => event as Map<Object?, Object?>);
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw BarcodeScannerException(
        BarcodeScannerErrorCode.fromName(error.code),
        error.message ?? 'The platform reported "${error.code}".',
        details: error.details,
      );
    } on MissingPluginException catch (error) {
      throw BarcodeScannerException(
        BarcodeScannerErrorCode.unsupportedOperation,
        'This platform does not implement "$method".',
        details: error,
      );
    }
  }
}
