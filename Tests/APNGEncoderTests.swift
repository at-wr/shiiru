import XCTest
import StickerCore
import ImageIO
@testable import Shiiru

final class APNGEncoderTests: XCTestCase {

    private func makeFrame(hue: CGFloat, size: Int = 128) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.setFillColor(UIColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor)
        let offset = CGFloat(hue) * CGFloat(size) / 2
        context.fillEllipse(in: CGRect(x: offset, y: offset, width: CGFloat(size) / 2, height: CGFloat(size) / 2))
        return context.makeImage()!
    }

    func testAnimatedOutputIsValidAPNG() throws {
        let frames = (0..<8).map { index in
            APNGEncoder.Frame(image: makeFrame(hue: CGFloat(index) / 8), delay: 0.1)
        }
        let data = try XCTUnwrap(APNGEncoder.encode(frames: frames, width: 128, height: 128))

        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 8, "all frames should decode")

        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 3, nil))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
    }

    func testStaticQuantizedPNGDecodes() throws {
        let image = makeFrame(hue: 0.5, size: 512)
        let data = try XCTUnwrap(APNGEncoder.encodeStatic(image, width: 512, height: 512))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 512)
    }

    func testQuantizedBeatsTruecolorSize() throws {

        let frames = (0..<12).map { index in
            APNGEncoder.Frame(image: makeFrame(hue: CGFloat(index) / 12, size: 256), delay: 0.08)
        }
        let quantized = try XCTUnwrap(APNGEncoder.encode(frames: frames, width: 256, height: 256))

        let truecolor = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            truecolor, "public.png" as CFString, frames.count, nil
        )!
        for frame in frames {
            CGImageDestinationAddImage(dest, frame.image, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.08]
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)

        XCTAssertLessThan(
            quantized.count, truecolor.length,
            "indexed APNG (\(quantized.count)) should be smaller than truecolor (\(truecolor.length))"
        )
    }
}
