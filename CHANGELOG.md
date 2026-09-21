## 0.1.0

Initial release.

* Live scanning with a shared ZXing-C++ reader core: CameraX on Android,
  AVFoundation on iOS. Camera frames are decoded natively; only results cross
  into Dart.
* QR Code (including Micro QR and rMQR), EAN-8, EAN-13, UPC-A, UPC-E, Code 39,
  Code 93, Code 128, ITF, Codabar, GS1 DataBar and DataBar Expanded.
* Texture-based preview, torch, zoom, tap-to-focus, camera switching.
* Region of interest, frame throttling, duplicate suppression and format
  filtering, all applied natively.
* Single, continuous and multi-barcode scan modes.
* Static image decoding over `dart:ffi` (`BarcodeScanner.decodeImage`).
* Explicit scanner state machine and error model.
