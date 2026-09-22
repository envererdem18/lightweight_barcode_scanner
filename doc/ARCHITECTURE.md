# Architecture

## The shape of it

```text
                          Flutter
                             │
         BarcodeScannerView  │  BarcodeScannerController
                             │
        ┌────────────────────┴────────────────────┐
        │            platform channels            │   results + control only
        │         (method + event channel)        │   never pixels
        └────────────────────┬────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
            iOS                          Android
      AVCaptureSession              CameraX ImageAnalysis
      AVCaptureVideoDataOutput      ImageProxy (YUV_420_888)
              │                             │
              │  Y plane (NV12)             │  plane[0]
              └──────────────┬──────────────┘
                             │
                  lbs::Decoder  (src/barcode_decoder.cpp)
                             │
                   ZXing-C++ reader core
                   (third_party/zxing-cpp)
                             │
                      DecodeResult
                             │
                          Flutter
```

Two boundaries matter:

1. **The decoder never sees a platform type.** `src/barcode_decoder.h`
   references no JNI, AVFoundation, CameraX or Flutter symbol. It takes a
   pointer, a size and a layout.
2. **Flutter never sees a frame.** The camera writes into memory the decoder
   reads and the GPU displays. Dart receives a short list of strings and
   coordinates.

## Why not ML Kit, Vision, or OpenCV

This is the decision the rest of the design follows from.

**Google ML Kit** is the obvious default on Android, and it is a poor fit here.
The bundled barcode model adds several megabytes to the APK; the unbundled one
adds a Google Play Services dependency, which means it does not work on devices
without Play Services, needs a download before the first scan, and is not
available at all in markets where Play Services is absent. It is also
Android-only, so iOS needs a second implementation with different behaviour,
different format names and different failure modes.

**Apple Vision / VisionKit** is excellent and free of binary cost on iOS, and
it has the same structural problem in reverse: it is iOS-only. Combining ML Kit
and Vision gives two decoders with two sets of quirks, and every bug report
starts with "on which platform?". Vision also decodes on Apple's schedule
rather than ours - frame pacing and result timing are not ours to tune.

**OpenCV** brings tens of megabytes and a large build surface to solve a
problem that is not computer vision in general, but reading a handful of
well-specified symbologies.

**ZXing-C++** is a focused, mature reader that compiles to a few hundred
kilobytes, runs identically on both platforms from one source tree, needs no
model, no runtime and no network, and lets us keep control of threading, frame
pacing and memory. One decoder, one behaviour, one set of bugs. The trade-off
is real: ML Kit's detector is better at blurry, angled and partially occluded
symbols than a classical decoder. For a scanner where the user is deliberately
aiming at a code, that gap is small, and it costs neither megabytes nor a
services dependency.

The same reasoning rules out cloud decoding, which additionally would mean
shipping user images off the device.

## Frame paths

Per the requirement that every camera frame path be documented:

### Android, analysis

| | |
|---|---|
| Owner | CameraX `ImageProxy`, released by `ScannerSession.analyze`'s `finally` |
| Format | `YUV_420_888`, plane 0 (luminance) |
| Width / height | `ImageProxy.width` / `.height`, from the resolution selector |
| Row stride | `planes[0].rowStride` - usually larger than the width |
| Pixel stride | `planes[0].pixelStride` - 1 on every device seen so far, but read from the plane, never assumed |
| Lifetime | Until `image.close()`, at the end of the analyzer callback |
| Thread | `lbs-decode-<id>`, a single-thread executor |
| Copies | **None.** `planes[0].buffer` is a direct `ByteBuffer`; JNI takes its address with `GetDirectBufferAddress` and ZXing's `ImageView` wraps it |

### Android, preview

| | |
|---|---|
| Owner | The `SurfaceTexture` behind Flutter's `SurfaceTextureEntry` |
| Path | CameraX `Preview` → `Surface` → Flutter texture |
| Thread | GPU / the render thread |
| Copies | **None**, and the CPU never touches these frames |

### iOS, analysis and preview (the same buffer)

| | |
|---|---|
| Owner | `CVPixelBuffer` from the `CMSampleBuffer`, retained by `ScannerSession` for the texture |
| Format | `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (NV12), plane 0 |
| Width / height | `CVPixelBufferGetWidthOfPlane(_, 0)` / `…HeightOfPlane` |
| Row stride | `CVPixelBufferGetBytesPerRowOfPlane(_, 0)` |
| Pixel stride | 1 (NV12's luminance plane is dense) |
| Lifetime | Retained until the next frame replaces it; the base address is only valid between `CVPixelBufferLockBaseAddress` and the matching unlock |
| Thread | `dev.enver.lightweight_barcode_scanner.capture`, a serial queue |
| Copies | **None.** The decoder reads the camera's memory and Flutter renders the very same buffer |

### Dart, static images

| | |
|---|---|
| Owner | Dart, via `malloc` |
| Format | Whatever `ImagePixelFormat` says; `decodeImage` produces RGBA from Flutter's codecs |
| Lifetime | One call |
| Thread | A background isolate (`Isolate.run`) |
| Copies | **One**, from the Dart heap into native memory. Acceptable for a still image, which is why live frames do not use this path |

## Threading and the frame gate

```text
camera thread ──▶ frame gate ──▶ decode worker ──▶ result callback ──▶ Flutter
```

There is no queue and no separate worker hand-off. On both platforms the
decode happens **inline on the capture callback's own serial queue**, which
gives the gate for free:

* Android: `STRATEGY_KEEP_ONLY_LATEST` means CameraX holds at most one frame
  for us and drops the rest. Because `ImageProxy.close()` is the last thing
  `analyze` does, a new frame cannot arrive while a decode is running.
* iOS: `alwaysDiscardsLateVideoFrames = true` does the same for
  `AVCaptureVideoDataOutput`, and the serial queue serialises the callbacks.

On top of that, a timestamp check drops frames that arrive sooner than
`1 / detectionsPerSecond`. The camera runs at 30-60 fps; the decoder attempts
8-15 per second. The scanner therefore always works on the newest frame, and
latency cannot accumulate.

Nothing decodes on the UI thread or the iOS main thread. Results are posted
back to the main thread only to hand them to the event sink.

## Rotation and the region of interest

Buffers are never physically rotated - that would be a full-frame copy on every
frame. Instead:

* The capture connection is left in the sensor's native orientation.
* The rotation needed to make the frame upright is passed to the decoder as
  metadata, where `ZXing::ImageView::rotated()` applies it by flipping strides.
  Negative strides cost nothing.
* The preview is a GPU transform, but which side applies it differs by
  platform, and getting this wrong rotates the preview twice:

| | Preview buffer | Who makes it upright |
|---|---|---|
| Android | CameraX `Preview` → `SurfaceTexture` | **The producer.** A SurfaceTexture-backed preview arrives already cropped and rotated, and Flutter's texture rendering honours that transform. The plugin reports a texture rotation of 0 and an already-rotated preview size; Dart must not turn it again |
| iOS | The capture `CVPixelBuffer` itself | **Flutter.** The buffer is handed to the texture registry untouched, so Dart rotates it with a `RotatedBox` |

Flutter's own `camera_android_camerax` draws the same distinction, in
`surface_texture_rotated_preview.dart` versus
`image_reader_rotated_preview.dart`.

The analysis stream is unaffected on both platforms: it is a separate,
un-transformed buffer, and the decoder rotates each frame by that frame's own
`rotationDegrees`.

The scan region is applied **after** rotation, so the rectangle you pass is in
the same coordinate space as the preview the user is looking at.
`ImageView::cropped()` is also stride arithmetic, so a scan window makes
decoding cheaper without any copy - roughly 3-5x on an empty frame at 20% of
the area.

Corner points come back in the coordinate space of the rotated, cropped image;
`BarcodeResult.imageSize` reports that space so they can be mapped onto a
widget.

## Memory

A steady-state frame performs **no heap allocation**:

* `lbs::Decoder` is created once per session and reused. It caches the
  translated `ZXing::ReaderOptions` and only rebuilds them when the formats,
  rotation or crop actually change.
* Its result vector is reused between frames; it is cleared, not reallocated.
* No intermediate image buffer exists. There is no YUV→RGB conversion, no
  JPEG or PNG encoding, and no `Uint8List` per frame.

Allocation happens only on a successful decode, proportional to the payload,
plus the platform objects needed to carry the result across the channel.
Duplicate suppression keeps even that rare: the same `format + value` is
dropped natively within the filter window and never reaches Dart.

## Binary size

The vendored ZXing subset is built with `ZXING_READERS=ON`, `ZXING_WRITERS=OFF`
and only the 1D and QR symbologies enabled - Aztec, Data Matrix, MaxiCode and
PDF417 are not compiled at all. `tool/vendor_zxing.sh` derives the file list
from upstream's own CMake for exactly that configuration and prunes everything
else, so the vendored tree is ~2 MB of source rather than ~22 MB.

Measured with the example app (release, arm64):

| | |
|---|---|
| `libbarcode_scanner.so` (Android arm64) | ~878 KB |
| `libbarcode_scanner.so` (Android armeabi-v7a) | ~700 KB |
| `lightweight_barcode_scanner.framework` (iOS arm64) | ~790 KB |

Android links libc++ statically (`ANDROID_STL=c++_static`): it is the only
library in the plugin that needs it and no C++ object crosses a `.so`
boundary, so this trades ~390 KB of growth in our own library for the 1.25 MB
`libc++_shared.so` that would otherwise be shipped - a net saving of roughly
860 KB per ABI. Release builds also use `--gc-sections`, `--exclude-libs,ALL`
and hidden visibility so that the reader paths nothing calls are dropped.

## Vendoring

`tool/vendor_zxing.sh` clones a pinned upstream tag, configures upstream's own
CMake with our feature flags, asks the `ZXing` target which sources it would
build, and copies exactly those - plus all headers, because compiled-out
sources still `#include` headers of the features they guard.

`core/generated/Version.h`, which normally lands in a CMake build directory,
is generated once and committed, so CocoaPods - which never runs CMake - sees
the same feature flags as the Android build.

## Why the iOS build needs forwarders

The shared C++ core has to live at the package root so that the Android CMake
build and the host tests compile the same files, and neither iOS build system
can reach it from there:

* **CocoaPods** resolves `source_files` relative to the podspec and silently
  drops anything outside it; the official `flutter create
  --template=plugin_ffi` podspec says so in a comment.
* **Swift Package Manager** is stricter. Sources must live inside the package,
  and a header search path that leaves the package root is rejected outright:
  `invalid header search path '../../../src'; header search path should not be
  outside the package root`.

So `tool/generate_ios_sources.sh` mirrors everything the iOS build needs into
the Swift package as one-line forwarders. One `.cpp` per translation unit:

```cpp
// Sources/lbs_core/forwarders/lbs_zxing-cpp_core_src_qrcode_QRReader.cpp
#include "../../../../../third_party/zxing-cpp/core/src/qrcode/QRReader.cpp"
```

and one `.h` per header, mirroring the upstream directory layout, so that the
search path itself can stay inside the package:

```cpp
// Sources/lbs_core/vendor_include/qrcode/QRReader.h
#include "../../../../../../third_party/zxing-cpp/core/src/qrcode/QRReader.h"
```

A quoted `#include` inside an included file resolves against that file's real
directory, so ZXing's own includes keep working unchanged, and `#pragma once`
still dedupes correctly because it keys on the resolved file rather than the
path taken to reach it. The forwarders are generated, never edited.

CocoaPods does not need the header mirror - it can point `HEADER_SEARCH_PATHS`
at the real directories - so the podspec excludes `vendor_include` rather than
compiling a second copy of every header into the target.

## Why iOS has two Swift Package targets

Swift Package Manager will not mix languages inside a single target, and the
plugin is both Swift (the Flutter plugin, the capture session) and
Objective-C++/C++ (the decoder bridge and the shared core). So the package has
two:

| Target | Language | Holds |
|---|---|---|
| `lbs_core` | Objective-C++ / C++ | `LBSDecoder.mm`, the forwarders, the header mirror. Its only public header is `LBSDecoder.h` |
| `lightweight_barcode_scanner` | Swift | The plugin, the capture session, the privacy manifest. Depends on `lbs_core` |

CocoaPods puts all of it in one module, where Swift sees the Objective-C
header without an import; SPM needs an explicit one. `ScannerSession.swift`
therefore guards it:

```swift
#if canImport(lbs_core)
  import lbs_core
#endif
```

The product is named `lightweight-barcode-scanner` with hyphens, not
underscores: Flutter looks the library up under that spelling because Swift
Package Manager turns it into a `CFBundleIdentifier` when the plugin is linked
dynamically, and those cannot contain underscores.

## FFI versus platform channels

| | Live camera | Static image |
|---|---|---|
| Transport | Platform channel | `dart:ffi` |
| What crosses | Decoded results | Pixels, once |
| Why | Frames must not enter Dart at all | One copy of a still image is cheap, and FFI avoids a second copy through the channel codec |

The FFI symbols (`lbs_decode_image`, `lbs_barcode_list_free`,
`lbs_supported_formats`, `lbs_engine_version`) are declared in `src/lbs_ffi.h`.
On Android they live in `libbarcode_scanner.so`; on iOS CocoaPods links them
into the app, so Dart resolves them with `DynamicLibrary.process()`.

The FFI shim is deliberately kept out of the `lbs_core` static library: symbols
only Dart reaches would otherwise be dropped by the linker. Each shared library
and executable compiles `src/lbs_ffi.cpp` directly.

## Testing

`test/native/` builds the shared decoder for the host and runs it against
fixtures stored as module patterns rather than images, so the same fixture can
be rendered at any scale, contrast, rotation, canvas size, row stride and pixel
stride. That covers the cases that only exist on a real camera plane - padded
strides, interleaved planes, truncated last rows - without committing binary
blobs.

`flutter test` covers the Dart models, the controller's state machine and the
widget's lifecycle against a fake platform channel.

Camera behaviour itself - orientation on each device, torch, focus, session
interruption - is not covered by either and has to be checked on real hardware.
