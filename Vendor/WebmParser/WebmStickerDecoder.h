#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebmStickerFrame : NSObject
@property (nonatomic, readonly) CGImageRef image;

@property (nonatomic, readonly) double timestamp;
@end

@interface WebmStickerDecoder : NSObject

+ (nullable NSArray<WebmStickerFrame *> *)decodeFramesAtPath:(NSString *)path
                                                   maxFrames:(NSInteger)maxFrames;

@end

NS_ASSUME_NONNULL_END
