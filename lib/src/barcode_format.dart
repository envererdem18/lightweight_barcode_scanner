/// Barcode symbologies this package can decode.
///
/// The integer values are part of the cross-language ABI: they mirror
/// `lbs::Format` in `src/barcode_decoder.h` and are passed to the native layer
/// as a bit mask so the decoder only attempts the symbologies you asked for.
enum BarcodeFormat {
  /// Matches QR Code model 1 and 2.
  qrCode(1 << 0),

  /// Micro QR Code. Enabled implicitly when [qrCode] is requested.
  microQrCode(1 << 1),

  /// Rectangular Micro QR Code. Enabled implicitly when [qrCode] is requested.
  rmqrCode(1 << 2),

  ean8(1 << 3),
  ean13(1 << 4),

  /// UPC-A. Values are reported as a 13 digit GTIN (leading zero), see README.
  upcA(1 << 5),

  /// UPC-E. Values are reported in their expanded 13 digit GTIN form.
  upcE(1 << 6),

  code39(1 << 7),
  code93(1 << 8),
  code128(1 << 9),
  itf(1 << 10),
  codabar(1 << 11),

  /// GS1 DataBar, including the omnidirectional, stacked and limited variants.
  dataBar(1 << 12),

  /// GS1 DataBar Expanded / Expanded Stacked.
  dataBarExpanded(1 << 13),

  /// Returned when the native layer reports a symbology this version of the
  /// Dart API does not know about. Cannot be requested.
  unknown(0);

  const BarcodeFormat(this.value);

  /// The bit used on the wire. Never assume it equals [index].
  final int value;

  /// Every format that can be requested.
  static const Set<BarcodeFormat> all = {
    qrCode,
    microQrCode,
    rmqrCode,
    ean8,
    ean13,
    upcA,
    upcE,
    code39,
    code93,
    code128,
    itf,
    codabar,
    dataBar,
    dataBarExpanded,
  };

  /// The formats found on retail packaging.
  static const Set<BarcodeFormat> retail = {ean8, ean13, upcA, upcE};

  /// The formats most often used in logistics and industry.
  static const Set<BarcodeFormat> industrial = {
    code39,
    code93,
    code128,
    itf,
    codabar,
  };

  /// Converts a set of formats into the bit mask the native decoder expects.
  ///
  /// An empty set means "every supported format", which is what the decoder
  /// falls back to as well.
  static int toMask(Set<BarcodeFormat> formats) {
    var mask = 0;
    for (final format in formats) {
      mask |= format.value;
    }
    return mask;
  }

  /// Maps a native format bit back to an enum value.
  static BarcodeFormat fromValue(int value) {
    for (final format in BarcodeFormat.values) {
      if (format.value == value) return format;
    }
    return BarcodeFormat.unknown;
  }
}
