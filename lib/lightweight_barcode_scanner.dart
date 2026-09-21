/// A lightweight, fully offline barcode and QR scanner.
///
/// Camera frames are analysed by a shared ZXing-C++ core inside the native
/// camera pipeline; Flutter only ever receives the decoded results. No machine
/// learning runtime, no network access, no image data leaves the device.
library;

export 'src/barcode_format.dart';
export 'src/barcode_result.dart';
export 'src/image_decoder.dart' show BarcodeScanner, ImagePixelFormat;
export 'src/platform/scanner_preview.dart' show ScannerPreview;
export 'src/scanner_controller.dart';
export 'src/scanner_options.dart';
export 'src/scanner_state.dart';
export 'src/scanner_view.dart';
