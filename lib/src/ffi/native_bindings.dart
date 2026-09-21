import 'dart:ffi';
import 'dart:io';

/// C structs mirroring `src/lbs_ffi.h`.
final class LbsDecodeOptions extends Struct {
  @Uint32()
  external int formats;
  @Int32()
  external int tryHarder;
  @Int32()
  external int tryRotate;
  @Int32()
  external int tryInvert;
  @Int32()
  external int tryDownscale;
  @Int32()
  external int maxSymbols;
  @Int32()
  external int rotation;
  @Int32()
  external int cropLeft;
  @Int32()
  external int cropTop;
  @Int32()
  external int cropWidth;
  @Int32()
  external int cropHeight;
}

final class LbsBarcode extends Struct {
  external Pointer<Uint8> text;
  @Int32()
  external int textLength;
  external Pointer<Uint8> bytes;
  @Int32()
  external int bytesLength;
  @Uint32()
  external int format;
  @Int32()
  external int orientation;
  @Array(8)
  external Array<Float> corners;
}

final class LbsBarcodeList extends Struct {
  external Pointer<LbsBarcode> items;
  @Int32()
  external int count;
}

/// `lbs_decode_image` as declared in C.
typedef LbsDecodeImageNative =
    Pointer<LbsBarcodeList> Function(
      Pointer<Uint8>,
      Int64,
      Int32,
      Int32,
      Int32,
      Int32,
      Int32,
      Pointer<LbsDecodeOptions>,
    );
/// `lbs_decode_image` as called from Dart.
typedef LbsDecodeImageDart =
    Pointer<LbsBarcodeList> Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      int,
      Pointer<LbsDecodeOptions>,
    );

/// Lazily resolved handles to the shared decoder.
///
/// On Android the core lives in `libbarcode_scanner.so`, which the Gradle
/// build produces from the same CMake sources. On iOS the sources are linked
/// straight into the application binary by CocoaPods, so the symbols are
/// already in the process.
class NativeBindings {
  factory NativeBindings._from(DynamicLibrary library) => NativeBindings._(
    decodeImage: library
        .lookupFunction<LbsDecodeImageNative, LbsDecodeImageDart>(
          'lbs_decode_image',
        ),
    freeList: library.lookupFunction<
      Void Function(Pointer<LbsBarcodeList>),
      void Function(Pointer<LbsBarcodeList>)
    >('lbs_barcode_list_free'),
    supportedFormats: library
        .lookupFunction<Uint32 Function(), int Function()>(
          'lbs_supported_formats',
        ),
    engineVersionPointer: library.lookupFunction<
      Pointer<Uint8> Function(),
      Pointer<Uint8> Function()
    >('lbs_engine_version'),
  );

  NativeBindings._({
    required this.decodeImage,
    required this.freeList,
    required this.supportedFormats,
    required this.engineVersionPointer,
  });

  static NativeBindings? _instance;

  static NativeBindings get instance =>
      _instance ??= NativeBindings._from(_openLibrary());

  final LbsDecodeImageDart decodeImage;
  final void Function(Pointer<LbsBarcodeList>) freeList;
  final int Function() supportedFormats;
  final Pointer<Uint8> Function() engineVersionPointer;

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) return DynamicLibrary.open('libbarcode_scanner.so');
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    throw UnsupportedError(
      'lightweight_barcode_scanner supports Android and iOS only.',
    );
  }
}
