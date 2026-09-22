import 'dart:async';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';
import 'package:lightweight_barcode_scanner/src/platform/scanner_channel.dart';

/// Stands in for the platform without touching a MethodChannel.
class FakeScannerChannel extends ScannerChannel {
  FakeScannerChannel({
    this.permission = CameraPermissionStatus.granted,
    this.maxZoom = 8.0,
  });

  CameraPermissionStatus permission;
  double maxZoom;
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
      'maxZoom': maxZoom,
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
    AutoZoom autoZoom = AutoZoom.disabled,
    double initialZoom = 1,
  }) => BarcodeScannerController(
    formats: {BarcodeFormat.qrCode},
    scanMode: scanMode,
    autoZoom: autoZoom,
    initialZoom: initialZoom,
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

  group('auto zoom', () {
    // The ramp exists because a barcode that will not decode is usually one the
    // lens cannot focus on - see ScannerOptions.autoZoom. These tests drive its
    // timers rather than waiting on them.
    test('zooms in once a stretch of frames decodes nothing', () {
      fakeAsync((async) {
        final controller = build(autoZoom: AutoZoom.enabled);
        unawaited(controller.start());
        async.flushMicrotasks();
        expect(controller.zoom, 1.0);

        // Still inside the grace period: a working scan never sees the ramp.
        async.elapse(const Duration(milliseconds: 900));
        expect(controller.zoom, 1.0);

        async.elapse(const Duration(seconds: 2));
        expect(controller.zoom, greaterThan(1.0));
        expect(channel.calls.any((call) => call.startsWith('setZoom:')), isTrue);

        // ... and never past the ceiling, however long it stays quiet.
        async.elapse(const Duration(seconds: 30));
        expect(controller.zoom, lessThanOrEqualTo(2.0));

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('gives the field of view back on the first read', () {
      fakeAsync((async) {
        final controller = build(autoZoom: AutoZoom.enabled);
        unawaited(controller.start());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3));
        expect(controller.zoom, greaterThan(1.0));

        channel.emit(1, barcodeEvent('hello', BarcodeFormat.qrCode));
        async.flushMicrotasks();
        expect(controller.zoom, 1.0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('rests at initialZoom and ramps between it and 2x', () {
      fakeAsync((async) {
        final controller = build(autoZoom: AutoZoom.enabled, initialZoom: 1.4);
        unawaited(controller.start());
        async.flushMicrotasks();

        // The camera opens tight rather than at 1x.
        expect(controller.zoom, 1.4);

        async.elapse(const Duration(seconds: 30));
        expect(controller.zoom, greaterThan(1.4));
        // Absolute ceiling, not 2x the resting point.
        expect(controller.zoom, lessThanOrEqualTo(2.0));

        // Handing the framing back is a step, not a fall to 1x.
        channel.emit(1, barcodeEvent('hello', BarcodeFormat.qrCode));
        async.flushMicrotasks();
        expect(controller.zoom, 1.4);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('initialZoom is clamped to what the camera reports', () {
      fakeAsync((async) {
        channel.maxZoom = 1.2;
        final controller = build(initialZoom: 1.4);
        unawaited(controller.start());
        async.flushMicrotasks();

        expect(controller.zoom, 1.2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('stays out of the way when it is switched off', () {
      fakeAsync((async) {
        final controller = build();
        unawaited(controller.start());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        expect(controller.zoom, 1.0);
        expect(channel.calls.any((call) => call.startsWith('setZoom:')), isFalse);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a manual setZoom hands control back to the app for good', () {
      fakeAsync((async) {
        final controller = build(autoZoom: AutoZoom.enabled);
        unawaited(controller.start());
        async.flushMicrotasks();

        unawaited(controller.setZoom(3));
        async.flushMicrotasks();
        expect(controller.zoom, 3.0);

        async.elapse(const Duration(seconds: 10));
        expect(controller.zoom, 3.0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('honours the platform the mode names', () {
      // The test binding reports Android, so the Android-only mode should ramp
      // and the iOS-only mode should stay put on the very same channel.
      for (final (AutoZoom mode, bool shouldRamp) in <(AutoZoom, bool)>[
        (AutoZoom.enabledAndroidOnly, true),
        (AutoZoom.enabledIosOnly, false),
      ]) {
        fakeAsync((async) {
          channel = FakeScannerChannel();
          final controller = build(autoZoom: mode);
          unawaited(controller.start());
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 10));
          expect(
            controller.zoom > 1.0,
            shouldRamp,
            reason: '$mode on ${debugDefaultTargetPlatformOverride ?? "android"}',
          );

          controller.dispose();
          async.flushMicrotasks();
        });
      }
    });

    test('the iOS-only mode ramps once the platform is iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      fakeAsync((async) {
        final controller = build(autoZoom: AutoZoom.enabledIosOnly);
        unawaited(controller.start());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        expect(controller.zoom, greaterThan(1.0));

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('does nothing on a camera that cannot zoom', () {
      fakeAsync((async) {
        channel.maxZoom = 1.0;
        final controller = build(autoZoom: AutoZoom.enabled);
        unawaited(controller.start());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        expect(controller.zoom, 1.0);
        expect(channel.calls.any((call) => call.startsWith('setZoom:')), isFalse);

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });

}
