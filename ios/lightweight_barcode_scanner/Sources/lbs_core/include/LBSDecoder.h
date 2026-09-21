// Objective-C face of the shared C++ decoder.
//
// The header stays free of C++ so Swift can use it directly; the
// implementation (LBSDecoder.mm) is where Objective-C++ meets lbs::Decoder.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One decoded symbol.
@interface LBSBarcode : NSObject
@property(nonatomic, copy, readonly) NSString *text;
/// A value from `lbs::Format`, mirrored by Dart's BarcodeFormat.
@property(nonatomic, assign, readonly) uint32_t format;
/// Eight floats: x0, y0 ... x3, y3, in the analysed image's coordinates.
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *corners;
@property(nonatomic, assign, readonly) NSInteger orientation;
@property(nonatomic, copy, readonly, nullable) NSData *bytes;
@end

/// A reusable decoder. Not thread safe: one instance per capture queue.
@interface LBSDecoder : NSObject

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
        cropHeight:(NSInteger)cropHeight;

/// Decodes an 8-bit luminance plane in place. Nothing is copied and the
/// pointer does not have to outlive the call.
- (nullable NSArray<LBSBarcode *> *)decodeLuminance:(const uint8_t *)luminance
                                               size:(NSUInteger)size
                                              width:(NSInteger)width
                                             height:(NSInteger)height
                                          rowStride:(NSInteger)rowStride
                                        pixelStride:(NSInteger)pixelStride
                                       includeBytes:(BOOL)includeBytes;

/// Version of the vendored ZXing-C++ engine.
+ (NSString *)engineVersion;

@end

NS_ASSUME_NONNULL_END
