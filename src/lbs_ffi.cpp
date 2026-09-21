#include "lbs_ffi.h"

#include <cstdlib>
#include <cstring>
#include <new>

#include "Version.h"
#include "barcode_decoder.h"

namespace {

lbs::PixelFormat ToPixelFormat(int32_t value) {
  switch (value) {
    case kLbsPixelFormatLumA: return lbs::PixelFormat::kLumA;
    case kLbsPixelFormatRgb: return lbs::PixelFormat::kRgb;
    case kLbsPixelFormatBgr: return lbs::PixelFormat::kBgr;
    case kLbsPixelFormatRgba: return lbs::PixelFormat::kRgba;
    case kLbsPixelFormatArgb: return lbs::PixelFormat::kArgb;
    case kLbsPixelFormatBgra: return lbs::PixelFormat::kBgra;
    case kLbsPixelFormatAbgr: return lbs::PixelFormat::kAbgr;
    default: return lbs::PixelFormat::kLum;
  }
}

char* DuplicateString(const std::string& value) {
  char* copy = static_cast<char*>(std::malloc(value.size() + 1));
  if (copy == nullptr) return nullptr;
  std::memcpy(copy, value.data(), value.size());
  copy[value.size()] = '\0';
  return copy;
}

uint8_t* DuplicateBytes(const std::vector<uint8_t>& value) {
  if (value.empty()) return nullptr;
  uint8_t* copy = static_cast<uint8_t*>(std::malloc(value.size()));
  if (copy == nullptr) return nullptr;
  std::memcpy(copy, value.data(), value.size());
  return copy;
}

}  // namespace

LbsBarcodeList* lbs_decode_image(const uint8_t* data, int64_t size,
                                 int32_t width, int32_t height,
                                 int32_t row_stride, int32_t pixel_stride,
                                 int32_t pixel_format,
                                 const LbsDecodeOptions* options) {
  auto* list = static_cast<LbsBarcodeList*>(std::calloc(1, sizeof(LbsBarcodeList)));
  if (list == nullptr) return nullptr;

  lbs::DecodeOptions decode_options;
  if (options != nullptr) {
    decode_options.formats = options->formats;
    decode_options.try_harder = options->try_harder != 0;
    decode_options.try_rotate = options->try_rotate != 0;
    decode_options.try_invert = options->try_invert != 0;
    decode_options.try_downscale = options->try_downscale != 0;
    decode_options.max_symbols = options->max_symbols;
    decode_options.rotation = options->rotation;
    decode_options.crop_left = options->crop_left;
    decode_options.crop_top = options->crop_top;
    decode_options.crop_width = options->crop_width;
    decode_options.crop_height = options->crop_height;
  }

  lbs::Decoder decoder;
  decoder.SetOptions(decode_options);
  const std::vector<lbs::DecodeResult>& results =
      decoder.Decode(data, size < 0 ? 0 : static_cast<size_t>(size), width,
                     height, row_stride, pixel_stride,
                     ToPixelFormat(pixel_format));
  if (results.empty()) return list;

  auto* items = static_cast<LbsBarcode*>(
      std::calloc(results.size(), sizeof(LbsBarcode)));
  if (items == nullptr) return list;

  int32_t count = 0;
  for (const lbs::DecodeResult& result : results) {
    LbsBarcode& item = items[count];
    item.text = DuplicateString(result.text);
    if (item.text == nullptr) continue;
    item.text_length = static_cast<int32_t>(result.text.size());
    item.bytes = DuplicateBytes(result.bytes);
    item.bytes_length =
        item.bytes == nullptr ? 0 : static_cast<int32_t>(result.bytes.size());
    item.format = result.format;
    item.orientation = result.orientation;
    for (int i = 0; i < 4; ++i) {
      item.corners[i * 2] = result.corners[i].x;
      item.corners[i * 2 + 1] = result.corners[i].y;
    }
    ++count;
  }

  list->items = items;
  list->count = count;
  return list;
}

void lbs_barcode_list_free(LbsBarcodeList* list) {
  if (list == nullptr) return;
  for (int32_t i = 0; i < list->count; ++i) {
    std::free(const_cast<char*>(list->items[i].text));
    std::free(const_cast<uint8_t*>(list->items[i].bytes));
  }
  std::free(list->items);
  std::free(list);
}

uint32_t lbs_supported_formats(void) { return lbs::kFormatAll; }

const char* lbs_engine_version(void) { return ZXING_VERSION_STR; }
