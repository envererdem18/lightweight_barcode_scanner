// Platform-neutral barcode decoding core.
//
// This header is the *only* contract between the shared decoder and the
// platform layers (Android/JNI, iOS/Objective-C++, Dart/FFI). It must never
// reference AVFoundation, CameraX, JNI, Flutter or ZXing types.
//
// Frame ownership contract (see docs/ARCHITECTURE.md):
//
//   owner      : the platform camera stack (CVPixelBuffer / ImageProxy)
//   format     : 8-bit luminance (the Y plane of an NV12 / YUV_420_888 frame)
//   lifetime   : valid only for the duration of Decoder::decode()
//   thread     : a dedicated decode worker, never the UI/main thread
//   copies     : none - ImageView wraps the caller's memory in place
//
// The decoder therefore must not retain `luminance` after decode() returns.

#ifndef LIGHTWEIGHT_BARCODE_SCANNER_BARCODE_DECODER_H_
#define LIGHTWEIGHT_BARCODE_SCANNER_BARCODE_DECODER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lbs {

// Public format identifiers. These values are part of the cross-language ABI:
// they are mirrored verbatim in Dart (BarcodeFormat), Kotlin and Swift, so they
// must stay stable. ZXing's own format ids never cross this boundary.
enum Format : uint32_t {
  kFormatUnknown = 0,
  kFormatQrCode = 1u << 0,
  kFormatMicroQrCode = 1u << 1,
  kFormatRmqrCode = 1u << 2,
  kFormatEan8 = 1u << 3,
  kFormatEan13 = 1u << 4,
  kFormatUpcA = 1u << 5,
  kFormatUpcE = 1u << 6,
  kFormatCode39 = 1u << 7,
  kFormatCode93 = 1u << 8,
  kFormatCode128 = 1u << 9,
  kFormatItf = 1u << 10,
  kFormatCodabar = 1u << 11,
  kFormatDataBar = 1u << 12,
  kFormatDataBarExpanded = 1u << 13,
};

// Every format this build of the decoder can produce.
constexpr uint32_t kFormatAll = (1u << 14) - 1;

// Decoder tuning. All fields are plain data so the struct can be filled from
// Kotlin, Swift or Dart without an intermediate representation.
struct DecodeOptions {
  // Bit mask of `Format`. 0 means "every supported format", which is slower -
  // callers are expected to narrow it down.
  uint32_t formats = kFormatAll;

  // ZXing fallbacks. Each one costs CPU, so they are opt-in per scan profile
  // rather than always-on.
  bool try_harder = true;
  bool try_rotate = true;
  bool try_invert = false;
  bool try_downscale = true;

  // Maximum symbols to return. 1 keeps the decoder on its fast path.
  int max_symbols = 1;

  // Clockwise rotation in degrees (0/90/180/270) that maps the sensor buffer
  // onto the upright image. Applied as a *view* transform - no pixels move.
  int rotation = 0;

  // Region of interest in pixels of the *rotated* image, i.e. the upright
  // frame the user sees. A zero width or height means "no crop". Applied as a
  // view transform as well.
  int crop_left = 0;
  int crop_top = 0;
  int crop_width = 0;
  int crop_height = 0;
};

// Pixel layouts the decoder understands. The live camera path always uses
// kLum; the richer layouts exist only for the static-image API, where Flutter
// hands us whatever `dart:ui` produced.
enum class PixelFormat {
  kLum,
  kLumA,
  kRgb,
  kBgr,
  kRgba,
  kArgb,
  kBgra,
  kAbgr,
};

struct Point {
  float x = 0;
  float y = 0;
};

struct DecodeResult {
  std::string text;
  std::vector<uint8_t> bytes;
  uint32_t format = kFormatUnknown;
  // Corner points in the coordinate space of the rotated, cropped image that
  // was handed to ZXing, in top-left, top-right, bottom-right, bottom-left
  // order.
  Point corners[4];
  // Symbol rotation relative to the analysed image, in degrees.
  int orientation = 0;
};

// A reusable decoder.
//
// One instance is meant to live for the whole scanning session and to be used
// by a single worker thread: it caches the translated ZXing options and reuses
// its result buffer so that a steady-state frame costs no heap allocation
// unless a barcode is actually found. It is *not* internally synchronised.
class Decoder {
 public:
  Decoder();
  ~Decoder();

  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;

  // Cheap when the options are unchanged; rebuilding the ZXing option object
  // allocates, so callers should not call this per frame.
  void SetOptions(const DecodeOptions& options);
  const DecodeOptions& options() const { return options_; }

  // Decodes an image buffer in place. `size` is the length of the buffer in
  // bytes and is used for bounds validation; pass 0 if unknown. `pixel_stride`
  // may be 0, in which case it is derived from `format`.
  //
  // The returned reference is owned by the decoder and stays valid until the
  // next call to Decode() or SetOptions().
  const std::vector<DecodeResult>& Decode(const uint8_t* data, size_t size,
                                          int width, int height, int row_stride,
                                          int pixel_stride,
                                          PixelFormat format = PixelFormat::kLum);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  DecodeOptions options_;
  std::vector<DecodeResult> results_;
};

}  // namespace lbs

#endif  // LIGHTWEIGHT_BARCODE_SCANNER_BARCODE_DECODER_H_
