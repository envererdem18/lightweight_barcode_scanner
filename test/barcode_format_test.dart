import 'package:flutter_test/flutter_test.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';

void main() {
  group('BarcodeFormat', () {
    test('every requestable format has a distinct bit', () {
      final seen = <int>{};
      for (final format in BarcodeFormat.all) {
        expect(format.value, isNot(0), reason: '${format.name} has no bit');
        expect(seen.add(format.value), isTrue, reason: '${format.name} collides');
      }
    });

    test('unknown cannot be requested', () {
      expect(BarcodeFormat.all, isNot(contains(BarcodeFormat.unknown)));
      expect(BarcodeFormat.unknown.value, 0);
    });

    test('toMask combines bits and an empty set means "all"', () {
      expect(BarcodeFormat.toMask({}), 0);
      expect(
        BarcodeFormat.toMask({BarcodeFormat.qrCode, BarcodeFormat.ean13}),
        BarcodeFormat.qrCode.value | BarcodeFormat.ean13.value,
      );
    });

    test('fromValue round-trips and falls back to unknown', () {
      for (final format in BarcodeFormat.all) {
        expect(BarcodeFormat.fromValue(format.value), format);
      }
      expect(BarcodeFormat.fromValue(1 << 30), BarcodeFormat.unknown);
    });

    test('preset groups only contain requestable formats', () {
      expect(BarcodeFormat.retail, everyElement(isIn(BarcodeFormat.all)));
      expect(BarcodeFormat.industrial, everyElement(isIn(BarcodeFormat.all)));
    });
  });
}
