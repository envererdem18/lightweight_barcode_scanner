import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';

void main() {
  const imageSize = Size(1280, 720);

  group('BarcodeResult', () {
    test('boundingBox wraps the corner points', () {
      const result = BarcodeResult(
        value: 'x',
        format: BarcodeFormat.qrCode,
        imageSize: imageSize,
        cornerPoints: <Offset>[
          Offset(10, 20),
          Offset(110, 18),
          Offset(112, 130),
          Offset(8, 128),
        ],
      );
      expect(result.boundingBox, const Rect.fromLTRB(8, 18, 112, 130));
    });

    test('boundingBox is null without corners', () {
      const result = BarcodeResult(
        value: 'x',
        format: BarcodeFormat.qrCode,
        imageSize: imageSize,
      );
      expect(result.boundingBox, isNull);
    });

    test('identity combines format and value', () {
      const a = BarcodeResult(
        value: '123',
        format: BarcodeFormat.ean13,
        imageSize: imageSize,
      );
      const b = BarcodeResult(
        value: '123',
        format: BarcodeFormat.code128,
        imageSize: imageSize,
      );
      expect(a.identity, 'ean13:123');
      expect(a.identity, isNot(b.identity));
    });

    test('fromMap reads the native wire format', () {
      final result = BarcodeResult.fromMap(<Object?, Object?>{
        'value': 'HELLO',
        'format': BarcodeFormat.qrCode.value,
        'corners': <double>[1, 2, 3, 4, 5, 6, 7, 8],
        'bytes': Uint8List.fromList(<int>[1, 2, 3]),
      }, imageSize);

      expect(result.value, 'HELLO');
      expect(result.format, BarcodeFormat.qrCode);
      expect(result.imageSize, imageSize);
      expect(result.cornerPoints, hasLength(4));
      expect(result.cornerPoints!.first, const Offset(1, 2));
      expect(result.cornerPoints!.last, const Offset(7, 8));
      expect(result.rawBytes, <int>[1, 2, 3]);
    });

    test('fromMap tolerates a missing geometry and payload', () {
      final result = BarcodeResult.fromMap(<Object?, Object?>{
        'value': 'HELLO',
        'format': 1 << 29,
      }, imageSize);

      expect(result.format, BarcodeFormat.unknown);
      expect(result.cornerPoints, isNull);
      expect(result.rawBytes, isNull);
      expect(result.boundingBox, isNull);
    });
  });
}
