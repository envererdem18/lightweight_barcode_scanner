#import "LBSDecoder.h"

#include <memory>
#include <vector>

#include "Version.h"
#include "barcode_decoder.h"

/// Declared here rather than in the public header: the initialiser takes a C++
/// type, which must not leak into the Swift-visible interface.
@interface LBSBarcode ()
- (nullable instancetype)initWithResult:(const lbs::DecodeResult &)result
                           includeBytes:(BOOL)includeBytes;
@end

@implementation LBSBarcode

- (nullable instancetype)initWithResult:(const lbs::DecodeResult &)result
                  includeBytes:(BOOL)includeBytes {
  self = [super init];
  if (self == nil) return nil;

  _text = [[NSString alloc] initWithBytes:result.text.data()
                                   length:result.text.size()
                                 encoding:NSUTF8StringEncoding]
              ?: @"";
  _format = result.format;
  _orientation = result.orientation;

  NSMutableArray<NSNumber *> *corners = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 4; ++i) {
    [corners addObject:@(result.corners[i].x)];
    [corners addObject:@(result.corners[i].y)];
  }
  _corners = corners;

  if (includeBytes && !result.bytes.empty()) {
    _bytes = [NSData dataWithBytes:result.bytes.data()
                            length:result.bytes.size()];
  }
  return self;
}

@end

@implementation LBSDecoder {
  std::unique_ptr<lbs::Decoder> _decoder;
}

- (instancetype)init {
  self = [super init];
  if (self == nil) return nil;
  _decoder = std::make_unique<lbs::Decoder>();
  return self;
}

- (void)setFormats:(uint32_t)formats
         tryHarder:(BOOL)tryHarder
         tryRotate:(BOOL)tryRotate
         tryInvert:(BOOL)tryInvert
      tryDownscale:(BOOL)tryDownscale
        maxSymbols:(NSInteger)maxSymbols
          rotation:(NSInteger)rotation
          cropLeft:(NSInteger)cropLeft
           cropTop:(NSInteger)cropTop
         cropWidth:(NSInteger)cropWidth
        cropHeight:(NSInteger)cropHeight {
  lbs::DecodeOptions options;
  options.formats = formats;
  options.try_harder = tryHarder == YES;
  options.try_rotate = tryRotate == YES;
  options.try_invert = tryInvert == YES;
  options.try_downscale = tryDownscale == YES;
  options.max_symbols = static_cast<int>(maxSymbols);
  options.rotation = static_cast<int>(rotation);
  options.crop_left = static_cast<int>(cropLeft);
  options.crop_top = static_cast<int>(cropTop);
  options.crop_width = static_cast<int>(cropWidth);
  options.crop_height = static_cast<int>(cropHeight);
  _decoder->SetOptions(options);
}

- (NSArray<LBSBarcode *> *)decodeLuminance:(const uint8_t *)luminance
                                      size:(NSUInteger)size
                                     width:(NSInteger)width
                                    height:(NSInteger)height
                                 rowStride:(NSInteger)rowStride
                               pixelStride:(NSInteger)pixelStride
                              includeBytes:(BOOL)includeBytes {
  const std::vector<lbs::DecodeResult> &results = _decoder->Decode(
      luminance, size, static_cast<int>(width), static_cast<int>(height),
      static_cast<int>(rowStride), static_cast<int>(pixelStride));
  if (results.empty()) return nil;

  NSMutableArray<LBSBarcode *> *barcodes =
      [NSMutableArray arrayWithCapacity:results.size()];
  for (const lbs::DecodeResult &result : results) {
    LBSBarcode *barcode = [[LBSBarcode alloc] initWithResult:result
                                                includeBytes:includeBytes];
    if (barcode != nil) [barcodes addObject:barcode];
  }
  return barcodes;
}

+ (NSString *)engineVersion {
  return @ZXING_VERSION_STR;
}

@end
