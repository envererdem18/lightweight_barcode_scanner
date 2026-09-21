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
