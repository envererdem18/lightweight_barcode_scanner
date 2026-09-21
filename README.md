# lightweight_barcode_scanner

A small, fully offline barcode and QR scanner for Flutter.

Camera frames are decoded **inside the native camera pipeline** by a shared
ZXing-C++ core. Flutter receives decoded results - never pixels. There is no
machine-learning runtime, no Google Play Services dependency, no Apple Vision,
no OpenCV and no network access.

```text
Native camera ──▶ luminance plane ──▶ shared ZXing-C++ decoder ──▶ result ──▶ Flutter
```

| | |
|---|---|
| Platforms | Android 7.0 (API 24)+, iOS 13+ |
| Native size | ~880 KB per Android ABI, ~790 KB on iOS (arm64, release) |
| Dependencies | CameraX on Android, AVFoundation on iOS, `package:ffi` on Dart |
| Offline | Always. Nothing leaves the device |

## Install

```yaml
dependencies:
  lightweight_barcode_scanner: ^0.1.0
```

### Android

Nothing to configure. The plugin's manifest contributes
`android.permission.CAMERA` and the NDK build produces
`libbarcode_scanner.so` for every ABI your app targets. `minSdk` must be 24 or
higher.

### iOS

Add a usage description to `ios/Runner/Info.plist`; iOS terminates the app
without one:

```xml
<key>NSCameraUsageDescription</key>
<string>Scans barcodes with the camera. Images stay on the device.</string>
```

The plugin is integrated with CocoaPods. Swift Package Manager is not
supported yet - see [Known limitations](#known-limitations).

## Basic usage

```dart
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  late final BarcodeScannerController controller;

  @override
  void initState() {
    super.initState();
    controller = BarcodeScannerController(
      formats: {
        BarcodeFormat.qrCode,
        BarcodeFormat.ean13,
        BarcodeFormat.code128,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BarcodeScannerView(
      controller: controller,
      onDetected: (result) => debugPrint('${result.format}: ${result.value}'),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
```

`BarcodeScannerView` starts the camera when it is mounted, releases it when the
app goes to the background, re-opens it on return, and stops it when the widget
is removed. You own the controller, so it survives a rebuild; dispose it when
your page goes away.

## Supported formats

| Format | `BarcodeFormat` | Notes |
|---|---|---|
| QR Code | `qrCode` | Models 1 and 2 |
| Micro QR / rMQR | `microQrCode`, `rmqrCode` | Also matched when `qrCode` is requested |
| EAN-13 | `ean13` | |
| EAN-8 | `ean8` | |
| UPC-A | `upcA` | Reported as a 13 digit GTIN, see below |
| UPC-E | `upcE` | Reported in expanded 13 digit form |
| Code 39 | `code39` | Including the extended and Code 32 / PZN variants |
| Code 93 | `code93` | |
| Code 128 | `code128` | Including GS1-128 |
| ITF | `itf` | Including ITF-14 |
| Codabar | `codabar` | |
| GS1 DataBar | `dataBar` | Omni, stacked and limited variants |
| GS1 DataBar Expanded | `dataBarExpanded` | |

Aztec, Data Matrix, PDF417 and MaxiCode are compiled **out** of the vendored
decoder. Enabling them is a two-line change to `tool/vendor_zxing.sh`, at a
cost in binary size and per-frame CPU.

**Always pass the formats you actually need.** An empty `formats` set means
"try everything", which costs CPU on every frame and raises the chance of a
misread from a lookalike symbology.

### UPC-A values

ZXing follows ISO/IEC 15420 and GS1 and reports UPC-A and UPC-E content as the
13 digit GTIN, so the 12 digit code printed on a package comes back with a
leading zero (`036000291452` reads as `0036000291452`). Strip it if you need
the printed form:

```dart
final printed = result.format == BarcodeFormat.upcA
    ? result.value.substring(1)
    : result.value;
```

## Controller lifecycle

```dart
await controller.start();   // open the camera and begin analysing
await controller.pause();   // stop analysing, keep the camera warm
await controller.resume();  // analyse again
await controller.stop();    // release the camera and the preview texture
controller.dispose();       // terminal; every later call throws
```

`controller.state` moves through `idle → initializing → running`, and to
`paused`, `stopped` or `error` from there. Invalid transitions do not silently
do nothing: calling anything on a disposed controller throws a
`BarcodeScannerException` with `BarcodeScannerErrorCode.invalidState`.

Use `pause`/`resume` around a result dialog - it is instant. Use `stop`/`start`
when leaving the screen; `stop` is what actually releases the camera.

### Errors

```dart
switch (controller.error?.code) {
  case BarcodeScannerErrorCode.permissionDenied:            // ask again
  case BarcodeScannerErrorCode.permissionPermanentlyDenied: // send to Settings
  case BarcodeScannerErrorCode.cameraUnavailable:
  case BarcodeScannerErrorCode.cameraInitializationFailed:
  case BarcodeScannerErrorCode.cameraInterrupted:           // a call, or split view
  case BarcodeScannerErrorCode.unsupportedOperation:        // e.g. no torch
  case BarcodeScannerErrorCode.invalidState:
  case BarcodeScannerErrorCode.unknown:
  case null:
}
```

`BarcodeScannerException.isRecoverable` tells you whether retrying can help.

## Torch, zoom and focus

```dart
await controller.setTorch(true);
await controller.toggleTorch();
await controller.setZoom(2.0);          // clamped to the camera's range
await controller.setFocusPoint(const Offset(0.5, 0.5)); // fractions of the preview
await controller.setFocusPoint(null);   // back to continuous autofocus
await controller.switchCamera();
```

`controller.preview` reports `hasTorch`, `minZoom` and `maxZoom` once the
camera is running. `setTorch` on a camera without a torch throws
`unsupportedOperation` rather than failing quietly.

Continuous autofocus, continuous auto-exposure and continuous auto white
balance are enabled by default, and on iOS the autofocus range is restricted to
near subjects - a correct decoder with bad focus is still a bad scanner.
`BarcodeScannerView` focuses where the user taps unless you pass
`tapToFocus: false`.

## Region of interest

```dart
BarcodeScannerView(
  controller: controller,
  scanWindow: const Rect.fromLTWH(0.1, 0.3, 0.8, 0.4), // fractions of the preview
)
```

The widget dims the area outside the window and the decoder only looks inside
it. Cropping is a view transform over the camera's own memory - no pixels are
copied - so a smaller window is a straight CPU saving, typically 3-5x on an
empty frame.

You can also set it directly: `controller.setScanRegion(rect)`, or
`setScanRegion(null)` to scan the whole frame.

## Continuous scanning and duplicate filtering

```dart
BarcodeScannerController(
  scanMode: ScanMode.continuous,                         // keep scanning
  duplicateFilterDuration: const Duration(milliseconds: 750),
  detectionsPerSecond: 12,
);
```

| `ScanMode` | Behaviour |
|---|---|
| `continuous` | Keeps scanning. The default |
| `single` | Stops analysing after the first accepted barcode; the controller moves to `paused` |
| `multiple` | Returns every barcode found in a frame. Costs more CPU, so it is opt-in |

The same `format + value` is suppressed for `duplicateFilterDuration`, natively,
before it ever crosses into Dart. `Duration.zero` disables suppression and gives
you one event per successful frame.

`detectionsPerSecond` caps decode attempts. The camera keeps running at 30 or
60 fps; surplus frames are **dropped, never queued**, so the scanner always
works on the most recent frame and never builds up latency.

### Streams

```dart
controller.barcodes.listen((result) => ...);  // one event per barcode
controller.captures.listen((capture) {        // one event per analysed frame
  print('${capture.barcodes.length} in ${capture.imageSize}');
});
```

`result.cornerPoints` and `result.boundingBox` are in the coordinate space of
`result.imageSize`, which is the analysed image after rotation and cropping.

## Decoder profiles

```dart
BarcodeScannerController(profile: DecoderProfile.balanced);
```

| Profile | What it enables | When |
|---|---|---|
| `fast` | No fallbacks | Upright, well-lit symbols; lowest latency |
| `balanced` | Rotation and downscale fallbacks | The default |
| `thorough` | Also inverted (light-on-dark) symbols | Still images, or a "having trouble?" mode |

## Static image decoding

```dart
final results = await BarcodeScanner.decodeImage(bytes);      // PNG, JPEG, WebP...
final fromPixels = await BarcodeScanner.decodePixels(
  pixels: luminance,
  width: 1280,
  height: 720,
  pixelFormat: ImagePixelFormat.luminance,
);
```

This is the one path where pixels travel from Dart into native code, over
`dart:ffi`. The image is decoded by Flutter's own codecs (no image library is
bundled), copied once into native memory and decoded on a background isolate.

```dart
BarcodeScanner.engineVersion;     // vendored ZXing-C++ version
BarcodeScanner.supportedFormats;  // what this build can decode
```

## Performance recommendations

* **Name your formats.** The single biggest lever.
* **Use a scan window** when the UI already tells the user where to aim.
* **Stay at `ScanResolution.medium` (1280x720)** unless you are reading small
  or dense symbols. `high` roughly doubles the per-frame cost.
* **Leave `detectionsPerSecond` at 12.** More attempts do not make a symbol
  appear sooner; they just burn battery.
* **Use `ScanMode.single`** when one code is all you need.

Decode latency of the shared core, measured on an Apple M-series host with
clean synthetic frames (`tool/run_native_benchmark.sh`). Treat it as relative
guidance, not a phone benchmark - a real device is slower and real frames are
noisier:

| Case | 640x480 | 1280x720 | 1920x1080 |
|---|---|---|---|
| QR, one format | 0.45 ms | 0.54 ms | 1.13 ms |
| QR, all formats | 0.30 ms | 0.52 ms | 1.12 ms |
| EAN-13 | 0.06 ms | 0.12 ms | 0.27 ms |
| Empty frame | 0.17 ms | 0.38 ms | 0.87 ms |
| Empty frame, 20% scan window | 0.02 ms | 0.08 ms | 0.18 ms |

## Privacy

* No image ever leaves the device, and the plugin makes no network calls.
* The only permission required is the camera. No internet, location,
  microphone, contacts, storage or photo-library access.
* Everything is decoded locally, so the scanner works fully offline.
* An empty privacy manifest (`PrivacyInfo.xcprivacy`) ships with the iOS pod:
  nothing is collected and nothing is tracked.

## Known limitations

* **Swift Package Manager is not supported.** SPM cannot reference sources
  outside its package directory, and the C++ core is shared with the Android
  CMake build. Use CocoaPods, which Flutter still supports.
* **No web, macOS, Windows or Linux.** The camera pipelines are Android and
  iOS only. The C++ core itself is portable.
* **Front-camera frames are mirrored.** Matrix codes still decode, but a
  mirrored 1D symbol may need `DecoderProfile.thorough`.
* **Device verification is on you.** The decoder is covered by host tests and
  both platform builds are verified, but camera behaviour - orientation,
  torch, focus - has to be checked on real hardware. Emulators and simulators
  do not reproduce it.

## Development

```bash
tool/vendor_zxing.sh [tag]      # re-vendor the ZXing-C++ reader core
tool/generate_fixtures.py       # regenerate the symbol fixtures
tool/run_native_tests.sh        # host tests for the shared C++ decoder
tool/run_native_benchmark.sh    # decode latency benchmark
flutter test                    # Dart unit and widget tests
```

`doc/ARCHITECTURE.md` explains the frame paths, the threading model and why
this package does not use ML Kit or Apple Vision.

## License

Apache-2.0. This package redistributes a subset of
[ZXing-C++](https://github.com/zxing-cpp/zxing-cpp), also Apache-2.0; see
`NOTICE` and `third_party/zxing-cpp/VENDORING.md`.
