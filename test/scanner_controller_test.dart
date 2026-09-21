import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';
import 'package:lightweight_barcode_scanner/src/platform/scanner_channel.dart';

/// Stands in for the platform without touching a MethodChannel.
class FakeScannerChannel extends ScannerChannel {
  FakeScannerChannel({this.permission = CameraPermissionStatus.granted});

  CameraPermissionStatus permission;
  BarcodeScannerException? failOnCreate;
  final List<String> calls = <String>[];
  final Map<int, StreamController<Map<Object?, Object?>>> _events = {};
  int _nextId = 1;

  void emit(int sessionId, Map<Object?, Object?> event) =>
      _events[sessionId]!.add(event);

  bool isListening(int sessionId) => _events[sessionId]?.hasListener ?? false;

  @override
  Future<CameraPermissionStatus> requestPermission() async {
    calls.add('requestPermission');
    return permission;
  }

  @override
  Future<CameraPermissionStatus> checkPermission() async => permission;

  @override
  Future<int> create(ScannerOptions options) async {
    calls.add('create');
    final failure = failOnCreate;
    if (failure != null) throw failure;
    final id = _nextId++;
    _events[id] = StreamController<Map<Object?, Object?>>.broadcast();
    return id;
  }

  @override
  Future<ScannerPreview> start(int sessionId) async {
    calls.add('start');
    return ScannerPreview.fromMap(<Object?, Object?>{
      'textureId': 7,
      'previewWidth': 1280,
      'previewHeight': 720,
      'analysisWidth': 720,
      'analysisHeight': 1280,
      'rotationDegrees': 90,
      'facing': 'back',
      'isMirrored': false,
      'hasTorch': true,
      'minZoom': 1.0,
      'maxZoom': 8.0,
    });
  }

  @override
  Future<void> stop(int sessionId) async => calls.add('stop');

  @override
  Future<void> pause(int sessionId) async => calls.add('pause');

  @override
  Future<void> resume(int sessionId) async => calls.add('resume');

  @override
  Future<void> dispose(int sessionId) async {
    calls.add('dispose');
    await _events.remove(sessionId)?.close();
  }

  @override
  Future<void> setTorch(int sessionId, {required bool enabled}) async =>
      calls.add('setTorch:$enabled');

  @override
  Future<void> setZoom(int sessionId, double zoom) async =>
      calls.add('setZoom:$zoom');

  @override
  Future<void> setFocusPoint(int sessionId, Offset? point) async =>
      calls.add('setFocusPoint:$point');

  @override
  Future<ScannerPreview> switchCamera(int sessionId, CameraFacing facing) async {
    calls.add('switchCamera:${facing.name}');
    final preview = await start(sessionId);
    return preview;
  }

  @override
  Future<void> setFormats(int sessionId, Set<BarcodeFormat> formats) async =>
      calls.add('setFormats:${BarcodeFormat.toMask(formats)}');

  @override
  Future<void> setScanRegion(int sessionId, Rect? region) async =>
      calls.add('setScanRegion:$region');

  @override
  Future<void> setDuplicateFilter(int sessionId, Duration duration) async =>
      calls.add('setDuplicateFilter:${duration.inMilliseconds}');

  @override
  Stream<Map<Object?, Object?>> events(int sessionId) =>
      _events[sessionId]!.stream;
}

Map<Object?, Object?> barcodeEvent(String value, BarcodeFormat format) =>
    <Object?, Object?>{
      'type': 'barcodes',
      'imageWidth': 720,
      'imageHeight': 1280,
      'barcodes': <Object?>[
        <Object?, Object?>{
          'value': value,
          'format': format.value,
          'corners': <double>[0, 0, 10, 0, 10, 10, 0, 10],
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeScannerChannel channel;

  setUp(() => channel = FakeScannerChannel());

  BarcodeScannerController build({
    ScanMode scanMode = ScanMode.continuous,
  }) => BarcodeScannerController(
    formats: {BarcodeFormat.qrCode},
    scanMode: scanMode,
    channel: channel,
  );

  group('lifecycle', () {
    test('starts idle and reaches running', () async {
      final controller = build();
      expect(controller.state, ScannerState.idle);
      expect(controller.preview, isNull);

      await controller.start();

      expect(controller.state, ScannerState.running);
      expect(controller.isRunning, isTrue);
      expect(controller.preview?.textureId, 7);
      expect(channel.calls, containsAllInOrder(['create', 'start']));
      controller.dispose();
    });

    test('start is idempotent while running', () async {
      final controller = build();
      await controller.start();
      await controller.start();
      expect(
        channel.calls.where((call) => call == 'create').length,
        1,
        reason: 'a second start() must not open a second session',
      );
      controller.dispose();
    });

    test('stop releases the session and clears the preview', () async {
      final controller = build();
      await controller.start();
      await controller.stop();

      expect(controller.state, ScannerState.stopped);
      expect(controller.preview, isNull);
      expect(channel.calls, contains('dispose'));
      controller.dispose();
    });

    test('pause and resume keep the session', () async {
      final controller = build();
      await controller.start();

      await controller.pause();
      expect(controller.state, ScannerState.paused);

      await controller.resume();
      expect(controller.state, ScannerState.running);
      expect(channel.calls, isNot(contains('dispose')));
      controller.dispose();
    });

    test('pause does nothing when not running', () async {
      final controller = build();
      await controller.pause();
      expect(controller.state, ScannerState.idle);
      expect(channel.calls, isEmpty);
      controller.dispose();
    });

    test('a stopped controller can start again', () async {
      final controller = build();
      await controller.start();
      await controller.stop();
      await controller.start();
      expect(controller.state, ScannerState.running);
      controller.dispose();
    });

    test('dispose is terminal', () async {
      final controller = build();
      await controller.start();
      controller.dispose();

      expect(controller.state, ScannerState.disposed);
      expect(controller.start, throwsA(isA<BarcodeScannerException>()));
      expect(
        () => controller.setZoom(2),
        throwsA(
          isA<BarcodeScannerException>().having(
            (error) => error.code,
            'code',
            BarcodeScannerErrorCode.invalidState,
          ),
        ),
      );
    });
  });

  group('errors', () {
    test('a denied permission surfaces as an error state', () async {
      channel.permission = CameraPermissionStatus.denied;
      final controller = build();

      await expectLater(controller.start(), throwsA(isA<BarcodeScannerException>()));
      expect(controller.state, ScannerState.error);
      expect(controller.error?.code, BarcodeScannerErrorCode.permissionDenied);
      expect(controller.error?.isRecoverable, isTrue);
      controller.dispose();
    });

    test('a permanently denied permission is not recoverable', () async {
      channel.permission = CameraPermissionStatus.permanentlyDenied;
      final controller = build();

      await expectLater(controller.start(), throwsA(isA<BarcodeScannerException>()));
      expect(
        controller.error?.code,
        BarcodeScannerErrorCode.permissionPermanentlyDenied,
      );
      expect(controller.error?.isRecoverable, isFalse);
      controller.dispose();
    });

    test('a failed create leaves no dangling session', () async {
      channel.failOnCreate = const BarcodeScannerException(
        BarcodeScannerErrorCode.cameraUnavailable,
        'no camera',
      );
      final controller = build();

      await expectLater(controller.start(), throwsA(isA<BarcodeScannerException>()));
      expect(controller.state, ScannerState.error);
      controller.dispose();
    });

    test('a native error event moves the controller to error', () async {
      final controller = build();
      await controller.start();

      channel.emit(1, <Object?, Object?>{
        'type': 'error',
        'code': 'cameraInterrupted',
        'message': 'A call took the camera.',
      });
      await pumpEventQueue();

      expect(controller.state, ScannerState.error);
      expect(controller.error?.code, BarcodeScannerErrorCode.cameraInterrupted);
      controller.dispose();
    });

    test('controls require a running session', () async {
      final controller = build();
      expect(() => controller.setZoom(2), throwsA(isA<BarcodeScannerException>()));
      expect(
        () => controller.setFormats({BarcodeFormat.qrCode}),
        throwsA(isA<BarcodeScannerException>()),
      );
      controller.dispose();
    });
  });

  group('detections', () {
    test('barcode events reach the captures stream', () async {
      final controller = build();
      await controller.start();

      final captures = <BarcodeCapture>[];
      final subscription = controller.captures.listen(captures.add);

      channel.emit(1, barcodeEvent('HELLO', BarcodeFormat.qrCode));
      await pumpEventQueue();

      expect(captures, hasLength(1));
      expect(captures.single.imageSize, const Size(720, 1280));
      expect(captures.single.barcodes.single.value, 'HELLO');
      expect(captures.single.barcodes.single.format, BarcodeFormat.qrCode);

      await subscription.cancel();
      controller.dispose();
    });

    test('the barcodes stream flattens a capture', () async {
      final controller = build();
      await controller.start();

      final values = <String>[];
      final subscription = controller.barcodes.listen((b) => values.add(b.value));

      channel.emit(1, <Object?, Object?>{
        'type': 'barcodes',
        'imageWidth': 720,
        'imageHeight': 1280,
        'barcodes': <Object?>[
          <Object?, Object?>{'value': 'A', 'format': BarcodeFormat.qrCode.value},
          <Object?, Object?>{'value': 'B', 'format': BarcodeFormat.ean13.value},
        ],
      });
      await pumpEventQueue();

      expect(values, <String>['A', 'B']);
      await subscription.cancel();
      controller.dispose();
    });

    test('single mode pauses after the first barcode', () async {
      final controller = build(scanMode: ScanMode.single);
      await controller.start();

      channel.emit(1, barcodeEvent('ONCE', BarcodeFormat.qrCode));
      await pumpEventQueue();

      expect(controller.state, ScannerState.paused);
      controller.dispose();
    });

    test('an empty barcode list is ignored', () async {
      final controller = build();
      await controller.start();

      var captured = false;
      final subscription = controller.captures.listen((_) => captured = true);
      channel.emit(1, <Object?, Object?>{
        'type': 'barcodes',
        'barcodes': <Object?>[],
      });
      await pumpEventQueue();

      expect(captured, isFalse);
      await subscription.cancel();
      controller.dispose();
    });

    test('a preview event updates the geometry', () async {
      final controller = build();
      await controller.start();

      channel.emit(1, <Object?, Object?>{
        'type': 'preview',
        'textureId': 7,
        'previewWidth': 1920,
        'previewHeight': 1080,
        'analysisWidth': 1920,
        'analysisHeight': 1080,
        'rotationDegrees': 0,
        'facing': 'back',
        'isMirrored': false,
        'hasTorch': true,
        'minZoom': 1.0,
        'maxZoom': 8.0,
      });
      await pumpEventQueue();

      expect(controller.preview?.rotationDegrees, 0);
      expect(controller.preview?.orientedPreviewSize, const Size(1920, 1080));
      controller.dispose();
    });
  });

  group('controls', () {
    test('torch state is mirrored locally', () async {
      final controller = build();
      await controller.start();

      expect(controller.torchEnabled, isFalse);
      await controller.toggleTorch();
      expect(controller.torchEnabled, isTrue);
      expect(channel.calls, contains('setTorch:true'));

      await controller.toggleTorch();
      expect(controller.torchEnabled, isFalse);
      controller.dispose();
    });

    test('zoom is clamped to the camera range', () async {
      final controller = build();
      await controller.start();

      await controller.setZoom(99);
      expect(controller.zoom, 8.0);
      expect(channel.calls, contains('setZoom:8.0'));

      await controller.setZoom(0.1);
      expect(controller.zoom, 1.0);
      controller.dispose();
    });

    test('switchCamera flips the facing and resets torch and zoom', () async {
      final controller = build();
      await controller.start();
      await controller.setZoom(4);

      await controller.switchCamera();

      expect(controller.options.facing, CameraFacing.front);
      expect(controller.zoom, 1.0);
      expect(controller.torchEnabled, isFalse);
      expect(channel.calls, contains('switchCamera:front'));
      controller.dispose();
    });

    test('setScanRegion rejects coordinates outside 0..1', () async {
      final controller = build();
      await controller.start();
      expect(
        () => controller.setScanRegion(const Rect.fromLTWH(0, 0, 2, 2)),
        throwsAssertionError,
      );
      controller.dispose();
    });

    test('setScanRegion(null) clears the region', () async {
      final controller = build();
      await controller.start();
      await controller.setScanRegion(const Rect.fromLTWH(0.1, 0.1, 0.5, 0.5));
      expect(controller.options.scanRegion, isNotNull);

      await controller.setScanRegion(null);
      expect(controller.options.scanRegion, isNull);
      controller.dispose();
    });

    test('setFormats narrows the requested symbologies', () async {
      final controller = build();
      await controller.start();
      await controller.setFormats({BarcodeFormat.code128});

      expect(controller.options.formats, {BarcodeFormat.code128});
      expect(
        channel.calls,
        contains('setFormats:${BarcodeFormat.code128.value}'),
      );
      controller.dispose();
    });
  });
}
