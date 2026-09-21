// C ABI for the static-image decoding path (dart:ffi).
//
// Live camera frames never travel through this surface: they stay inside the
// native camera stack and only the decoded result reaches Flutter. This API
// exists for `BarcodeScanner.decodeImage(...)`, where a single copy of a
// still image is acceptable and latency is not frame-bound.

#ifndef LIGHTWEIGHT_BARCODE_SCANNER_LBS_FFI_H_
#define LIGHTWEIGHT_BARCODE_SCANNER_LBS_FFI_H_

#include <stdint.h>

#ifdef _WIN32
#define LBS_EXPORT __declspec(dllexport)
#else
#define LBS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors lbs::PixelFormat.
typedef enum {
  kLbsPixelFormatLum = 0,
  kLbsPixelFormatLumA = 1,
  kLbsPixelFormatRgb = 2,
  kLbsPixelFormatBgr = 3,
  kLbsPixelFormatRgba = 4,
  kLbsPixelFormatArgb = 5,
  kLbsPixelFormatBgra = 6,
  kLbsPixelFormatAbgr = 7,
} LbsPixelFormat;

// Mirrors lbs::DecodeOptions. Laid out with fixed-width fields so the Dart
// struct definition matches on every ABI.
typedef struct {
  uint32_t formats;
  int32_t try_harder;
  int32_t try_rotate;
  int32_t try_invert;
  int32_t try_downscale;
  int32_t max_symbols;
  int32_t rotation;
  int32_t crop_left;
  int32_t crop_top;
  int32_t crop_width;
  int32_t crop_height;
} LbsDecodeOptions;

typedef struct {
  // NUL-terminated UTF-8. Owned by the list.
  const char* text;
  int32_t text_length;
  // Raw payload bytes, owned by the list. NULL when empty.
  const uint8_t* bytes;
  int32_t bytes_length;
  uint32_t format;
  int32_t orientation;
  // x0,y0, x1,y1, x2,y2, x3,y3 - top-left, top-right, bottom-right, bottom-left.
  float corners[8];
} LbsBarcode;

typedef struct {
  LbsBarcode* items;
  int32_t count;
} LbsBarcodeList;

// Decodes a single image. Returns NULL only on allocation failure; an image
// without barcodes yields a list with count == 0. The caller owns the result
// and must release it with lbs_barcode_list_free().
LBS_EXPORT LbsBarcodeList* lbs_decode_image(const uint8_t* data, int64_t size,
                                            int32_t width, int32_t height,
                                            int32_t row_stride,
                                            int32_t pixel_stride,
                                            int32_t pixel_format,
                                            const LbsDecodeOptions* options);

LBS_EXPORT void lbs_barcode_list_free(LbsBarcodeList* list);

// Bit mask of every format this build can decode.
LBS_EXPORT uint32_t lbs_supported_formats(void);

// Version of the vendored ZXing-C++ core, e.g. "3.1.1".
LBS_EXPORT const char* lbs_engine_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // LIGHTWEIGHT_BARCODE_SCANNER_LBS_FFI_H_
