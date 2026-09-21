import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';

import 'scanner_controller_test.dart';

void main() {
  late FakeScannerChannel channel;

  setUp(() => channel = FakeScannerChannel());

  Future<BarcodeScannerController> pumpView(
    WidgetTester tester, {
    bool autoStart = true,
    void Function(BarcodeResult)? onDetected,
    void Function(BarcodeScannerException)? onError,
    Rect? scanWindow,
  }) async {
    final controller = BarcodeScannerController(
      formats: {BarcodeFormat.qrCode},
      channel: channel,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScannerView(
          controller: controller,
          autoStart: autoStart,
          onDetected: onDetected,
          onError: onError,
          scanWindow: scanWindow,
        ),
      ),
    );
    return controller;
  }

  testWidgets('shows a placeholder until the camera is up', (tester) async {
    final controller = await pumpView(tester, autoStart: false);
    expect(find.byType(Texture), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.dispose();
  });

  testWidgets('renders the preview texture once running', (tester) async {
    final controller = await pumpView(tester);
    await tester.pumpAndSettle();

    expect(controller.state, ScannerState.running);
    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 7);
    // The preview is rotated 90 degrees to sit upright.
    expect(
      tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
      1,
    );
    controller.dispose();
  });

  testWidgets('forwards detections to onDetected', (tester) async {
    final seen = <BarcodeResult>[];
    final controller = await pumpView(tester, onDetected: seen.add);
    await tester.pumpAndSettle();

    channel.emit(1, barcodeEvent('SCANNED', BarcodeFormat.qrCode));
    await tester.pumpAndSettle();

    expect(seen.single.value, 'SCANNED');
    controller.dispose();
  });

  testWidgets('renders and reports an error', (tester) async {
    channel.permission = CameraPermissionStatus.permanentlyDenied;
    final errors = <BarcodeScannerException>[];
    final controller = await pumpView(tester, onError: errors.add);
    await tester.pumpAndSettle();

    expect(controller.state, ScannerState.error);
    expect(errors, isNotEmpty);
    expect(find.textContaining('permission'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('applies the scan window after starting', (tester) async {
    final controller = await pumpView(
      tester,
      scanWindow: const Rect.fromLTWH(0.1, 0.2, 0.8, 0.4),
    );
    await tester.pumpAndSettle();

    expect(
      channel.calls,
      contains('setScanRegion:Rect.fromLTRB(0.1, 0.2, 0.9, 0.6)'),
    );
    controller.dispose();
  });

  testWidgets('releases the camera when the widget goes away', (tester) async {
    final controller = await pumpView(tester);
    await tester.pumpAndSettle();
    expect(controller.isRunning, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(controller.state, ScannerState.stopped);
    expect(channel.calls, contains('dispose'));
    controller.dispose();
  });

  testWidgets('releases the camera in the background and restarts on resume',
      (tester) async {
    final controller = await pumpView(tester);
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(controller.state, ScannerState.stopped);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.state, ScannerState.running);

    controller.dispose();
  });
}
