## 0.3.0

* **Auto zoom, on by default** (`ScannerOptions.autoZoom`, an `AutoZoom` mode:
  `enabled`, `enabledIosOnly`, `enabledAndroidOnly` or `disabled`, so the ramp
  can be kept on the platform whose lens needs it). When nothing decodes
  for about a second the scanner zooms in gradually, up to an absolute 2x, and
  steps back to its resting point on the first read. Linear symbologies are
  limited by focus rather than resolution: at 1x the only way to fill the frame
  with a barcode is to move inside the lens's minimum focus distance, where it
  can no longer focus. `setZoom` hands control back to the app and switches it
  off for the session. See "Auto zoom" in the README for the measurements
  behind it.
* **The camera now opens at 1.4x** (`ScannerOptions.initialZoom`), which is also
  where auto zoom rests. 1x is the ratio that forces the user closest to the
  symbol, and it made handing the framing back a visible lurch. Pass
  `initialZoom: 1` for the previous full field of view.
* The ramp runs in Dart, over the existing `setZoom` call, so neither platform
  carries its own copy of the logic.

## 0.2.1

* **Fixed the Android camera preview opening sideways.** A SurfaceTexture-backed
  CameraX preview is already rotated by the producer, and the plugin rotated it
  a second time in Dart. Android now reports the already-rotated preview size
  and a texture rotation of 0; iOS, where the capture buffer really does reach
  Flutter untouched, is unchanged. Decoding was never affected - the analysis
  stream is a separate buffer with its own per-frame rotation.

## 0.2.0

* **Swift Package Manager support on iOS.** The plugin now ships a
  `Package.swift` alongside the podspec; Flutter picks whichever integration
  your project uses and neither needs configuration. SPM requires Flutter
  3.44 or newer, CocoaPods keeps working everywhere.
  * The iOS sources moved into the Swift package layout
    (`ios/lightweight_barcode_scanner/Sources/`), split into an
    Objective-C++/C++ target (`lbs_core`) and a Swift target, because SPM will
    not mix languages inside one target.
  * `tool/generate_ios_sources.sh` now also mirrors the shared core's headers
    into the package. SPM rejects a header search path that leaves the package
    root, and the C++ core has to stay at the package root for the Android
    build and the host tests.
* Fixed the `LICENSE` file so pub.dev recognises it as Apache-2.0 again. The
  licence text was intact, but a duplicated boilerplate block after the
  appendix pushed it past pub's "unclaimed text" limit and the package was
  listed with an unknown licence.
* Added `repository` and `issue_tracker` to the pubspec.

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
