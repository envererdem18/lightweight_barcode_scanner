import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'barcode_format.dart';
import 'barcode_result.dart';
import 'ffi/native_bindings.dart';
import 'scanner_options.dart';

/// Pixel layouts accepted by [BarcodeScanner.decodePixels], mirroring
/// `LbsPixelFormat` in `src/lbs_ffi.h`.
enum ImagePixelFormat {
  luminance(0),
  luminanceAlpha(1),
  rgb(2),
  bgr(3),
  rgba(4),
  argb(5),
  bgra(6),
  abgr(7);

  const ImagePixelFormat(this.value);
  final int value;
}

/// Decodes barcodes from still images.
///
/// This is the one path where pixels travel from Dart into native code, which
/// is fine for a one-shot image: unlike a camera frame it is not on a 30 fps
/// budget. Live scanning uses [BarcodeScannerController] instead, where frames
/// never leave the native side.
abstract final class BarcodeScanner {
  /// Version of the vendored ZXing-C++ decoding engine.
  static String get engineVersion {
    final pointer = NativeBindings.instance.engineVersionPointer();
    var length = 0;
    while (pointer[length] != 0) {
      length++;
    }
    return utf8.decode(pointer.asTypedList(length));
  }

  /// Formats this build can decode.
  static Set<BarcodeFormat> get supportedFormats {
    final mask = NativeBindings.instance.supportedFormats();
    return <BarcodeFormat>{
      for (final format in BarcodeFormat.all)
        if (mask & format.value != 0) format,
    };
  }

  /// Decodes an encoded image (PNG, JPEG, WebP, ...).
  ///
  /// The image is decoded by Flutter's own codecs, then handed to the native
  /// decoder as raw pixels. No image decoding library is bundled.
  static Future<List<BarcodeResult>> decodeImage(
    Uint8List encoded, {
    Set<BarcodeFormat> formats = const {},
    DecoderProfile profile = DecoderProfile.thorough,
    int maxResults = 8,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null) return const <BarcodeResult>[];
        return await decodePixels(
          pixels: data.buffer.asUint8List(),
          width: frame.image.width,
          height: frame.image.height,
          pixelFormat: ImagePixelFormat.rgba,
          formats: formats,
          profile: profile,
          maxResults: maxResults,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
      descriptor.dispose();
    }
  }

  /// Decodes a raw pixel buffer.
  ///
  /// Use this when you already hold pixels - for example a camera still or a
  /// buffer produced by another plugin - to skip re-encoding the image.
  static Future<List<BarcodeResult>> decodePixels({
    required Uint8List pixels,
    required int width,
    required int height,
    ImagePixelFormat pixelFormat = ImagePixelFormat.luminance,
    int rowStride = 0,
    int pixelStride = 0,
    Set<BarcodeFormat> formats = const {},
    DecoderProfile profile = DecoderProfile.thorough,
    int maxResults = 8,
    ui.Rect? cropRegion,
  }) async {
    if (width <= 0 || height <= 0 || pixels.isEmpty) {
      return const <BarcodeResult>[];
    }

    // The bytes have to live in native memory for the duration of the call.
    // One copy per image, never per frame.
    final buffer = malloc<Uint8>(pixels.length);
    final options = malloc<LbsDecodeOptions>();
    try {
      buffer.asTypedList(pixels.length).setAll(0, pixels);

      options.ref
        ..formats = BarcodeFormat.toMask(formats)
        ..tryHarder = profile == DecoderProfile.fast ? 0 : 1
        ..tryRotate = profile == DecoderProfile.fast ? 0 : 1
        ..tryInvert = profile == DecoderProfile.thorough ? 1 : 0
        ..tryDownscale = profile == DecoderProfile.fast ? 0 : 1
        ..maxSymbols = maxResults < 1 ? 1 : maxResults
        ..rotation = 0
        ..cropLeft = cropRegion?.left.round() ?? 0
        ..cropTop = cropRegion?.top.round() ?? 0
        ..cropWidth = cropRegion?.width.round() ?? 0
        ..cropHeight = cropRegion?.height.round() ?? 0;

      final request = _DecodeRequest(
        buffer.address,
        pixels.length,
        width,
        height,
        rowStride,
        pixelStride,
        pixelFormat.value,
        options.address,
      );

      // Decoding a large still image can take tens of milliseconds; keep it
      // off the UI isolate. The buffers are native memory, so passing their
      // addresses is safe and free.
      return kIsWeb
          ? _decodeSync(request)
          : await Isolate.run(() => _decodeSync(request));
    } finally {
      malloc
        ..free(buffer)
        ..free(options);
    }
  }
}

/// Plain data so it can cross an isolate boundary.
class _DecodeRequest {
  const _DecodeRequest(
    this.bufferAddress,
    this.size,
    this.width,
    this.height,
    this.rowStride,
    this.pixelStride,
    this.pixelFormat,
    this.optionsAddress,
  );

  final int bufferAddress;
  final int size;
  final int width;
  final int height;
  final int rowStride;
  final int pixelStride;
  final int pixelFormat;
  final int optionsAddress;
}

List<BarcodeResult> _decodeSync(_DecodeRequest request) {
  final bindings = NativeBindings.instance;
  final list = bindings.decodeImage(
    Pointer<Uint8>.fromAddress(request.bufferAddress),
    request.size,
    request.width,
    request.height,
    request.rowStride,
    request.pixelStride,
    request.pixelFormat,
    Pointer<LbsDecodeOptions>.fromAddress(request.optionsAddress),
  );
  if (list == nullptr) return const <BarcodeResult>[];

  try {
    final imageSize = ui.Size(
      request.width.toDouble(),
      request.height.toDouble(),
    );
    final results = <BarcodeResult>[];
    for (var i = 0; i < list.ref.count; i++) {
      final item = list.ref.items[i];
      results.add(
        BarcodeResult(
          value: utf8.decode(
            item.text.asTypedList(item.textLength),
            allowMalformed: true,
          ),
          format: BarcodeFormat.fromValue(item.format),
          imageSize: imageSize,
          cornerPoints: <ui.Offset>[
            for (var c = 0; c < 8; c += 2)
              ui.Offset(item.corners[c], item.corners[c + 1]),
          ],
          rawBytes: item.bytesLength > 0
              ? Uint8List.fromList(item.bytes.asTypedList(item.bytesLength))
              : null,
        ),
      );
    }
    return results;
  } finally {
    bindings.freeList(list);
  }
}
