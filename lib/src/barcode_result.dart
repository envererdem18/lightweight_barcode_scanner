import 'dart:typed_data';
import 'dart:ui';

import 'barcode_format.dart';

/// A single decoded barcode.
///
/// The result is deliberately small: text, symbology and geometry. Raw bytes
/// are only present when the scanner was configured with
/// `includeRawBytes: true`, because copying them across the platform boundary
/// on every detection is pure overhead for the common case.
class BarcodeResult {
  const BarcodeResult({
    required this.value,
    required this.format,
    required this.imageSize,
    this.cornerPoints,
    this.rawBytes,
  });

  /// The decoded content as UTF-8 text.
  final String value;

  /// The symbology that produced [value].
  final BarcodeFormat format;

  /// Size of the analysed image, in pixels, after rotation and cropping.
  ///
  /// [cornerPoints] live in this coordinate space; use it to map them onto a
  /// widget.
  final Size imageSize;

  /// Corners in top-left, top-right, bottom-right, bottom-left order.
  final List<Offset>? cornerPoints;

  /// The undecoded payload. Only populated when explicitly requested.
  final Uint8List? rawBytes;

  /// Axis-aligned box around [cornerPoints].
  Rect? get boundingBox {
    final points = cornerPoints;
    if (points == null || points.isEmpty) return null;
    var left = points.first.dx;
    var top = points.first.dy;
    var right = left;
    var bottom = top;
    for (final point in points.skip(1)) {
      if (point.dx < left) left = point.dx;
      if (point.dx > right) right = point.dx;
      if (point.dy < top) top = point.dy;
      if (point.dy > bottom) bottom = point.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// The key used for duplicate suppression: symbology plus content.
  String get identity => '${format.name}:$value';

  static BarcodeResult fromMap(Map<Object?, Object?> map, Size imageSize) {
    final corners = map['corners'];
    List<Offset>? cornerPoints;
    if (corners is List && corners.length >= 8) {
      cornerPoints = <Offset>[
        for (var i = 0; i < 8; i += 2)
          Offset(
            (corners[i]! as num).toDouble(),
            (corners[i + 1]! as num).toDouble(),
          ),
      ];
    }
    final bytes = map['bytes'];
    return BarcodeResult(
      value: map['value']! as String,
      format: BarcodeFormat.fromValue((map['format']! as num).toInt()),
      imageSize: imageSize,
      cornerPoints: cornerPoints,
      rawBytes: bytes is Uint8List ? bytes : null,
    );
  }

  @override
  String toString() => 'BarcodeResult(${format.name}, "$value")';
}

/// Everything that came out of one analysed frame.
class BarcodeCapture {
  const BarcodeCapture({required this.barcodes, required this.imageSize});

  final List<BarcodeResult> barcodes;

  /// Size of the analysed image in pixels.
  final Size imageSize;
}
