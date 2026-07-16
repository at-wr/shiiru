#import "WebmStickerDecoder.h"

#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

#include <vector>
#include <cstring>

@implementation WebmStickerFrame {
    CGImageRef _image;
    double _timestamp;
}

- (instancetype)initWithImage:(CGImageRef)image timestamp:(double)timestamp {
    if (self = [super init]) {
        _image = CGImageRetain(image);
        _timestamp = timestamp;
    }
    return self;
}

- (CGImageRef)image { return _image; }
- (double)timestamp { return _timestamp; }

- (void)dealloc {
    CGImageRelease(_image);
}

@end

namespace {

struct EBMLReader {
    const uint8_t *data;
    size_t size;
    size_t pos = 0;

    bool eof() const { return pos >= size; }

    uint64_t readVarint(bool keepMarker) {
        if (eof()) return 0;
        uint8_t first = data[pos];
        int length = 1;
        for (uint8_t mask = 0x80; mask != 0; mask >>= 1, length++) {
            if (first & mask) break;
        }
        if (length > 8 || pos + length > size) { pos = size; return 0; }
        uint64_t value = keepMarker ? first : (first & (0xFF >> length));
        for (int i = 1; i < length; i++) value = (value << 8) | data[pos + i];
        pos += length;
        return value;
    }

    uint64_t readUInt(size_t length) {
        uint64_t value = 0;
        for (size_t i = 0; i < length && pos < size; i++) value = (value << 8) | data[pos++];
        return value;
    }
};

struct StickerPacket {
    size_t offset;
    size_t length;
    size_t alphaOffset;
    size_t alphaLength;
    double timestamp;
};

struct ParsedWebm {
    uint64_t videoTrack = 0;
    uint64_t timecodeScale = 1'000'000;
    std::vector<StickerPacket> packets;
};

constexpr uint64_t kSegment = 0x18538067, kInfo = 0x1549A966, kTimecodeScale = 0x2AD7B1;
constexpr uint64_t kTracks = 0x1654AE6B, kTrackEntry = 0xAE, kTrackNumber = 0xD7, kCodecID = 0x86;
constexpr uint64_t kCluster = 0x1F43B675, kTimecode = 0xE7, kSimpleBlock = 0xA3;
constexpr uint64_t kBlockGroup = 0xA0, kBlock = 0xA1, kBlockAdditions = 0x75A1;
constexpr uint64_t kBlockMore = 0xA6, kBlockAdditional = 0xA5;

bool parseBlock(EBMLReader &reader, size_t end, uint64_t videoTrack,
                uint64_t clusterTime, uint64_t scale,
                size_t &offset, size_t &length, double &timestamp) {
    uint64_t track = reader.readVarint(false);
    if (reader.pos + 3 > end) return false;
    int16_t relative = (int16_t)((reader.data[reader.pos] << 8) | reader.data[reader.pos + 1]);
    reader.pos += 2;
    uint8_t flags = reader.data[reader.pos++];
    if ((flags & 0x06) != 0) return false;
    if (track != videoTrack) { reader.pos = end; return false; }
    offset = reader.pos;
    length = end - reader.pos;
    timestamp = double((int64_t)clusterTime + relative) * double(scale) / 1e9;
    reader.pos = end;
    return true;
}

ParsedWebm parseWebm(const uint8_t *bytes, size_t size) {
    ParsedWebm result;
    EBMLReader reader { bytes, size };

    reader.readVarint(true);
    uint64_t headerSize = reader.readVarint(false);
    reader.pos += headerSize;

    std::string codec;
    uint64_t pendingTrackNumber = 0;
    uint64_t clusterTime = 0;

    std::vector<std::pair<uint64_t, size_t>> stack;

    while (!reader.eof()) {
        uint64_t elementId = reader.readVarint(true);
        uint64_t elementSize = reader.readVarint(false);
        if (elementId == 0) break;
        size_t end = reader.pos + elementSize;

        switch (elementId) {
        case kSegment: case kInfo: case kTracks: case kCluster:
            continue;
        case kTrackEntry:
            pendingTrackNumber = 0;
            codec.clear();
            continue;
        case kTimecodeScale:
            result.timecodeScale = reader.readUInt(elementSize);
            break;
        case kTrackNumber:
            pendingTrackNumber = reader.readUInt(elementSize);
            break;
        case kCodecID: {
            codec.assign((const char *)reader.data + reader.pos, elementSize);
            reader.pos = end;
            if (codec == "V_VP9" && result.videoTrack == 0 && pendingTrackNumber != 0) {
                result.videoTrack = pendingTrackNumber;
            }
            break;
        }
        case kTimecode:
            clusterTime = reader.readUInt(elementSize);
            break;
        case kSimpleBlock: {
            StickerPacket packet {};
            if (result.videoTrack != 0 &&
                parseBlock(reader, end, result.videoTrack, clusterTime,
                           result.timecodeScale, packet.offset, packet.length, packet.timestamp)) {
                result.packets.push_back(packet);
            }
            reader.pos = end;
            break;
        }
        case kBlockGroup: {
            StickerPacket packet {};
            bool haveBlock = false;
            while (reader.pos < end) {
                uint64_t innerId = reader.readVarint(true);
                uint64_t innerSize = reader.readVarint(false);
                size_t innerEnd = reader.pos + innerSize;
                if (innerId == kBlock && result.videoTrack != 0) {
                    haveBlock = parseBlock(reader, innerEnd, result.videoTrack, clusterTime,
                                           result.timecodeScale, packet.offset, packet.length,
                                           packet.timestamp);
                } else if (innerId == kBlockAdditions) {
                    while (reader.pos < innerEnd) {
                        uint64_t moreId = reader.readVarint(true);
                        uint64_t moreSize = reader.readVarint(false);
                        size_t moreEnd = reader.pos + moreSize;
                        if (moreId == kBlockMore) continue;
                        if (moreId == kBlockAdditional) {
                            packet.alphaOffset = reader.pos;
                            packet.alphaLength = moreSize;
                        }
                        reader.pos = moreEnd;
                    }
                    reader.pos = innerEnd;
                } else {
                    reader.pos = innerEnd;
                }
            }
            if (haveBlock) result.packets.push_back(packet);
            reader.pos = end;
            break;
        }
        default:
            reader.pos = end;
        }
    }
    return result;
}

CGImageRef CreateImage(const vpx_image_t *color, const vpx_image_t *alpha) {
    const int width = (int)color->d_w;
    const int height = (int)color->d_h;
    std::vector<uint8_t> rgba((size_t)width * height * 4);

    for (int y = 0; y < height; y++) {
        const uint8_t *yRow = color->planes[VPX_PLANE_Y] + y * color->stride[VPX_PLANE_Y];
        const uint8_t *uRow = color->planes[VPX_PLANE_U] + (y >> 1) * color->stride[VPX_PLANE_U];
        const uint8_t *vRow = color->planes[VPX_PLANE_V] + (y >> 1) * color->stride[VPX_PLANE_V];
        const uint8_t *aRow = alpha ? alpha->planes[VPX_PLANE_Y] + y * alpha->stride[VPX_PLANE_Y] : nullptr;
        uint8_t *out = rgba.data() + (size_t)y * width * 4;

        for (int x = 0; x < width; x++) {
            const int c = yRow[x] - 16;
            const int d = uRow[x >> 1] - 128;
            const int e = vRow[x >> 1] - 128;
            auto clamp = [](int v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); };
            const uint8_t a = aRow ? aRow[x] : 255;
            out[x * 4 + 0] = (uint8_t)(clamp((298 * c + 409 * e + 128) >> 8) * a / 255);
            out[x * 4 + 1] = (uint8_t)(clamp((298 * c - 100 * d - 208 * e + 128) >> 8) * a / 255);
            out[x * 4 + 2] = (uint8_t)(clamp((298 * c + 516 * d + 128) >> 8) * a / 255);
            out[x * 4 + 3] = a;
        }
    }

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        rgba.data(), width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : nullptr;
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

struct Decoder {
    vpx_codec_ctx_t ctx {};
    bool ready = false;

    bool init() {
        ready = vpx_codec_dec_init(&ctx, vpx_codec_vp9_dx(), nullptr, 0) == VPX_CODEC_OK;
        return ready;
    }

    vpx_image_t *decode(const uint8_t *data, size_t size) {
        if (!ready || vpx_codec_decode(&ctx, data, (unsigned int)size, nullptr, 0) != VPX_CODEC_OK) {
            return nullptr;
        }
        vpx_codec_iter_t iter = nullptr;
        return vpx_codec_get_frame(&ctx, &iter);
    }

    ~Decoder() {
        if (ready) vpx_codec_destroy(&ctx);
    }
};

}

@implementation WebmStickerDecoder

+ (nullable NSArray<WebmStickerFrame *> *)decodeFramesAtPath:(NSString *)path
                                                   maxFrames:(NSInteger)maxFrames {
    NSData *file = [NSData dataWithContentsOfFile:path];
    if (file.length == 0) return nil;
    const uint8_t *bytes = (const uint8_t *)file.bytes;

    ParsedWebm parsed = parseWebm(bytes, file.length);
    if (parsed.videoTrack == 0 || parsed.packets.empty()) return nil;

    Decoder colorDecoder, alphaDecoder;
    if (!colorDecoder.init() || !alphaDecoder.init()) return nil;

    NSMutableArray<WebmStickerFrame *> *frames = [NSMutableArray array];
    for (const StickerPacket &packet : parsed.packets) {
        vpx_image_t *colorImage = colorDecoder.decode(bytes + packet.offset, packet.length);
        if (!colorImage) continue;
        vpx_image_t *alphaImage = packet.alphaLength > 0
            ? alphaDecoder.decode(bytes + packet.alphaOffset, packet.alphaLength)
            : nullptr;
        CGImageRef image = CreateImage(colorImage, alphaImage);
        if (image) {
            WebmStickerFrame *frame =
                [[WebmStickerFrame alloc] initWithImage:image timestamp:packet.timestamp];
            CGImageRelease(image);
            [frames addObject:frame];
        }
    }
    if (frames.count == 0) return nil;

    if (maxFrames > 0 && (NSInteger)frames.count > maxFrames) {
        NSMutableArray<WebmStickerFrame *> *sampled = [NSMutableArray arrayWithCapacity:maxFrames];
        for (NSInteger i = 0; i < maxFrames; i++) {
            [sampled addObject:frames[i * (NSInteger)frames.count / maxFrames]];
        }
        return sampled;
    }
    return frames;
}

@end
