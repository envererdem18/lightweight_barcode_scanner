import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';

void main() {
  group('ScannerOptions', () {
    test('defaults are conservative', () {
      const options = ScannerOptions();
      expect(options.formats, isEmpty);
      expect(options.scanMode, ScanMode.continuous);
      expect(options.profile, DecoderProfile.balanced);
      expect(options.includeRawBytes, isFalse);
      expect(options.detectionsPerSecond, lessThanOrEqualTo(15));
    });

    test('rejects an impossible detection rate', () {
      expect(() => ScannerOptions(detectionsPerSecond: 0), throwsAssertionError);
      expect(() => ScannerOptions(detectionsPerSecond: 61), throwsAssertionError);
    });

    test('toMap matches the native wire format', () {
      const options = ScannerOptions(
        formats: {BarcodeFormat.qrCode, BarcodeFormat.ean13},
        scanMode: ScanMode.single,
        facing: CameraFacing.front,
        resolution: ScanResolution.high,
        profile: DecoderProfile.thorough,
        duplicateFilterDuration: Duration(milliseconds: 500),
        detectionsPerSecond: 8,
        scanRegion: Rect.fromLTWH(0.1, 0.2, 0.5, 0.25),
        includeRawBytes: true,
        torchEnabled: true,
      );

      expect(options.toMap(), <String, Object?>{
        'formats': BarcodeFormat.qrCode.value | BarcodeFormat.ean13.value,
        'scanMode': 'single',
        'facing': 'front',
        'resolution': 'high',
        'profile': 'thorough',
        'duplicateFilterMillis': 500,
        'detectionsPerSecond': 8,
        'includeRawBytes': true,
        'torchEnabled': true,
        'scanRegion': <double>[0.1, 0.2, 0.5, 0.25],
      });
    });

    test('toMap omits an absent scan region', () {
      expect(const ScannerOptions().toMap().containsKey('scanRegion'), isFalse);
    });

    test('copyWith can clear the scan region', () {
      const options = ScannerOptions(scanRegion: Rect.fromLTWH(0, 0, 1, 1));
      expect(options.copyWith(clearScanRegion: true).scanRegion, isNull);
      expect(options.copyWith().scanRegion, isNotNull);
    });
  });
}
