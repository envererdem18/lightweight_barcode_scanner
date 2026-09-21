#include "barcode_decoder.h"

#include <algorithm>
#include <utility>

#include "BarcodeFormat.h"
#include "ImageView.h"
#include "ReadBarcode.h"
#include "ReaderOptions.h"

namespace lbs {
namespace {

// Translates one public format bit into the ZXing formats it should request.
// Requesting the symbology (variant ' ') rather than a single variant lets
// ZXing return the specific variant it found, which we map back below.
void AppendZXingFormats(uint32_t bit, std::vector<ZXing::BarcodeFormat>* out) {
  using ZXing::BarcodeFormat;
  switch (bit) {
    case kFormatQrCode: out->push_back(BarcodeFormat::QRCode); break;
    case kFormatMicroQrCode: out->push_back(BarcodeFormat::MicroQRCode); break;
    case kFormatRmqrCode: out->push_back(BarcodeFormat::RMQRCode); break;
    case kFormatEan8: out->push_back(BarcodeFormat::EAN8); break;
    case kFormatEan13: out->push_back(BarcodeFormat::EAN13); break;
    case kFormatUpcA: out->push_back(BarcodeFormat::UPCA); break;
    case kFormatUpcE: out->push_back(BarcodeFormat::UPCE); break;
    case kFormatCode39: out->push_back(BarcodeFormat::Code39); break;
    case kFormatCode93: out->push_back(BarcodeFormat::Code93); break;
    case kFormatCode128: out->push_back(BarcodeFormat::Code128); break;
    case kFormatItf: out->push_back(BarcodeFormat::ITF); break;
    case kFormatCodabar: out->push_back(BarcodeFormat::Codabar); break;
    case kFormatDataBar: out->push_back(BarcodeFormat::DataBar); break;
    case kFormatDataBarExpanded: out->push_back(BarcodeFormat::DataBarExp); break;
    default: break;
  }
}

// Maps a decoded ZXing variant back onto our stable public format.
uint32_t ToPublicFormat(ZXing::BarcodeFormat format) {
  using ZXing::BarcodeFormat;
  switch (format) {
    case BarcodeFormat::QRCode:
    case BarcodeFormat::QRCodeModel1:
    case BarcodeFormat::QRCodeModel2:
      return kFormatQrCode;
    case BarcodeFormat::MicroQRCode:
      return kFormatMicroQrCode;
    case BarcodeFormat::RMQRCode:
      return kFormatRmqrCode;
    case BarcodeFormat::EAN8:
      return kFormatEan8;
    case BarcodeFormat::EAN13:
    case BarcodeFormat::ISBN:
      return kFormatEan13;
    case BarcodeFormat::UPCA:
      return kFormatUpcA;
    case BarcodeFormat::UPCE:
      return kFormatUpcE;
    case BarcodeFormat::Code39:
    case BarcodeFormat::Code39Std:
    case BarcodeFormat::Code39Ext:
    case BarcodeFormat::Code32:
    case BarcodeFormat::PZN:
      return kFormatCode39;
    case BarcodeFormat::Code93:
      return kFormatCode93;
    case BarcodeFormat::Code128:
      return kFormatCode128;
    case BarcodeFormat::ITF:
    case BarcodeFormat::ITF14:
      return kFormatItf;
    case BarcodeFormat::Codabar:
      return kFormatCodabar;
    case BarcodeFormat::DataBar:
    case BarcodeFormat::DataBarOmni:
    case BarcodeFormat::DataBarStk:
    case BarcodeFormat::DataBarStkOmni:
    case BarcodeFormat::DataBarLtd:
      return kFormatDataBar;
    case BarcodeFormat::DataBarExp:
    case BarcodeFormat::DataBarExpStk:
      return kFormatDataBarExpanded;
    default:
      return kFormatUnknown;
  }
}

ZXing::ImageFormat ToZXingFormat(PixelFormat format) {
  switch (format) {
    case PixelFormat::kLum: return ZXing::ImageFormat::Lum;
    case PixelFormat::kLumA: return ZXing::ImageFormat::LumA;
    case PixelFormat::kRgb: return ZXing::ImageFormat::RGB;
    case PixelFormat::kBgr: return ZXing::ImageFormat::BGR;
    case PixelFormat::kRgba: return ZXing::ImageFormat::RGBA;
    case PixelFormat::kArgb: return ZXing::ImageFormat::ARGB;
    case PixelFormat::kBgra: return ZXing::ImageFormat::BGRA;
    case PixelFormat::kAbgr: return ZXing::ImageFormat::ABGR;
  }
  return ZXing::ImageFormat::Lum;
}

}  // namespace

struct Decoder::Impl {
  ZXing::ReaderOptions zxing;
};

Decoder::Decoder() : impl_(std::make_unique<Impl>()) {
  SetOptions(DecodeOptions{});
  results_.reserve(4);
}

Decoder::~Decoder() = default;

void Decoder::SetOptions(const DecodeOptions& options) {
  options_ = options;

  const uint32_t mask = options.formats == 0 ? kFormatAll : options.formats;
  std::vector<ZXing::BarcodeFormat> formats;
  formats.reserve(14);
  for (uint32_t bit = 1; bit <= kFormatDataBarExpanded; bit <<= 1) {
    if (mask & bit) AppendZXingFormats(bit, &formats);
  }

  ZXing::ReaderOptions& zx = impl_->zxing;
  zx.setFormats(ZXing::BarcodeFormats(std::move(formats)));
  zx.setTryHarder(options.try_harder);
  zx.setTryRotate(options.try_rotate);
  zx.setTryInvert(options.try_invert);
  zx.setTryDownscale(options.try_downscale);
  zx.setMaxNumberOfSymbols(
      static_cast<uint8_t>(std::clamp(options.max_symbols, 1, 255)));
  // Text is always returned as UTF-8; binary payloads are exposed via bytes().
  zx.setTextMode(ZXing::TextMode::HRI);
  zx.setBinarizer(ZXing::Binarizer::LocalAverage);

  results_.clear();
}

const std::vector<DecodeResult>& Decoder::Decode(const uint8_t* data,
                                                 size_t size, int width,
                                                 int height, int row_stride,
                                                 int pixel_stride,
                                                 PixelFormat format) {
  results_.clear();

  const ZXing::ImageFormat zxing_format = ToZXingFormat(format);
  if (data == nullptr || width <= 0 || height <= 0) return results_;
  if (pixel_stride <= 0) pixel_stride = ZXing::PixStride(zxing_format);
  if (row_stride <= 0) row_stride = width * pixel_stride;
  // The last row of a camera plane is often truncated to `width` bytes rather
  // than padded to a full stride, so require only what is actually read.
  const size_t required = static_cast<size_t>(height - 1) *
                              static_cast<size_t>(row_stride) +
                          static_cast<size_t>(width) *
                              static_cast<size_t>(pixel_stride);
  if (size != 0 && size < required) {
    // A short buffer would make ZXing read out of bounds; refuse the frame
    // instead of trusting the camera metadata.
    return results_;
  }

  ZXing::Barcodes barcodes;
  try {
    ZXing::ImageView image(data, width, height, zxing_format, row_stride,
                           pixel_stride);
    // Rotate before cropping so that the crop rectangle - which comes from the
    // UI - is expressed in the upright image the user is looking at. Both are
    // view transforms: no pixel is touched or copied.
    if (options_.rotation != 0) {
      image = image.rotated(options_.rotation);
    }
    if (options_.crop_width > 0 && options_.crop_height > 0) {
      image = image.cropped(options_.crop_left, options_.crop_top,
                            options_.crop_width, options_.crop_height);
    }
    barcodes = ZXing::ReadBarcodes(image, impl_->zxing);
  } catch (const std::exception&) {
    return results_;
  }

  for (const ZXing::Barcode& barcode : barcodes) {
    if (!barcode.isValid()) continue;
    const uint32_t format = ToPublicFormat(barcode.format());
    if (format == kFormatUnknown) continue;

    DecodeResult result;
    result.text = barcode.text();
    result.bytes = barcode.bytes();
    result.format = format;
    result.orientation = barcode.orientation();
    const ZXing::Position& position = barcode.position();
    const ZXing::PointI corners[4] = {position.topLeft(), position.topRight(),
                                      position.bottomRight(),
                                      position.bottomLeft()};
    for (int i = 0; i < 4; ++i) {
      result.corners[i].x = static_cast<float>(corners[i].x);
      result.corners[i].y = static_cast<float>(corners[i].y);
    }
    results_.push_back(std::move(result));
  }

  return results_;
}

}  // namespace lbs
