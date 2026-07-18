import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Shiiru

final class StickerConverterTests: XCTestCase {

    func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: StickerConverterTests.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
    }

    func testGunzipInflatesTGS() throws {
        let gzipped = try Data(contentsOf: fixtureURL("sample", "tgs"))
        let json = try StickerConverter.gunzip(gzipped)
        XCTAssertGreaterThan(json.count, gzipped.count)

        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertNotNil(object?["v"], "expected a Lottie version field")
    }

    func testGunzipPassesThroughPlainData() throws {
        let plain = Data("{\"v\":\"5.5.2\"}".utf8)
        XCTAssertEqual(try StickerConverter.gunzip(plain), plain)
    }

    func testStaticWebpBecomesCompliantPNG() throws {
        let url = try fixtureURL("sample", "webp")
        let png = try StickerConverter.convertStaticImage(at: url.path)

        XCTAssertLessThanOrEqual(png.count, StickerConverter.maxFileSize)
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "not a PNG")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 618)
        XCTAssertGreaterThanOrEqual(max(image.width, image.height), 300)
    }

    @MainActor
    func testTGSBecomesAnimatedAPNG() async throws {
        let url = try fixtureURL("sample", "tgs")
        let output = try await StickerConverter.convertTGS(at: url.path)

        XCTAssertTrue(output.isAnimated)
        let data = output.data
        XCTAssertLessThanOrEqual(data.count, StickerConverter.maxFileSize)
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "not a PNG")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, "APNG should contain multiple frames")

        let middle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetCount(source) / 2, nil))
        XCTAssertFalse(isFullyTransparent(middle), "rendered frame is empty")
    }

    private func isFullyTransparent(_ image: CGImage) -> Bool {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return !pixels.enumerated().contains { index, value in
            index % 4 == 3 && value > 0
        }
    }
}

extension StickerConverterTests {
    func testWebmVP9DecodesAndConverts() throws {
        let url = try fixtureURL("sample", "webm")
        let frames = try XCTUnwrap(
            WebmStickerDecoder.decodeFrames(atPath: url.path, maxFrames: 30),
            "libvpx should decode the VP9 fixture"
        )
        XCTAssertGreaterThan(frames.count, 1)

        let output = try StickerConverter.convertWebm(at: url.path)
        XCTAssertLessThanOrEqual(output.data.count, StickerConverter.maxFileSize)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output.data as CFData, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, "animation should survive conversion")
    }

    func testWebmVP8DecodesAndConverts() throws {
        let url = try fixtureURL("sample-vp8", "webm")
        let frames = try XCTUnwrap(
            WebmStickerDecoder.decodeFrames(atPath: url.path, maxFrames: 30),
            "libvpx should decode the VP8 fixture"
        )
        XCTAssertGreaterThan(frames.count, 1)

        let output = try StickerConverter.convertWebm(at: url.path)
        XCTAssertTrue(output.isAnimated)
        XCTAssertLessThanOrEqual(output.data.count, StickerConverter.maxFileSize)
    }

    /// A webm whose frames all quantize identically collapses to one frame
    /// in the encoder; the output must be labeled by what was written, not
    /// by the frame count that went in — the panel trusts `isAnimated`.
    func testStaticContentWebmIsLabeledStatic() throws {
        let url = try fixtureURL("sample-static", "webm")
        let output = try StickerConverter.convertWebm(at: url.path)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1, "solid-color content collapses to one frame")
        XCTAssertFalse(output.isAnimated, "single-frame output must not claim to be animated")
    }

    /// Photographic GIFs above the pass-through budget used to exhaust the
    /// full-palette ladder and fall back to a static first frame; the
    /// color-reduction tiers must keep them moving.
    func testOversizedNoisyGIFKeepsAnimation() throws {
        let url = try makeNoisyGIF(side: 400, frameCount: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try Data(contentsOf: url)
        XCTAssertGreaterThan(input.count, StickerConverter.maxFileSize, "fixture must exceed pass-through budget")

        let output = try StickerConverter.convertAnimatedImage(at: url.path)
        XCTAssertTrue(output.isAnimated, "re-encode must keep the animation alive")
        XCTAssertLessThanOrEqual(output.data.count, StickerConverter.maxFileSize)
    }

    /// Cancelling a sync must abort the conversion, not let it grind on —
    /// `detachedCancellable` forwards the caller's cancellation into the
    /// detached work, and the converter's checkpoints observe it.
    func testCancelledConversionThrows() async throws {
        let url = try fixtureURL("sample", "webm")
        let parent = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try await detachedCancellable {
                    try StickerConverter.convertWebm(at: url.path)
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        parent.cancel()
        let sawCancellation = await parent.value
        XCTAssertTrue(sawCancellation, "cancelled conversion must throw CancellationError")
    }

    /// Deterministic pseudo-noise frames: photographic-ish content that
    /// compresses badly, guaranteeing the GIF exceeds the sticker budget.
    private func makeNoisyGIF(side: Int, frameCount: Int) throws -> URL {
        func makeFrame(seed: Int) -> CGImage {
            let ctx = CGContext(
                data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            var state = UInt64(seed &* 2654435761 &+ 12345)
            func rand() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double((state >> 33) & 0xFFFF) / 65535.0
            }
            let block = 4
            for y in stride(from: 0, to: side, by: block) {
                for x in stride(from: 0, to: side, by: block) {
                    let shade = 0.5 + (rand() - 0.5) * 0.9
                        + 0.2 * sin((Double(x) + 8 * Double(seed)) / 23) * cos(Double(y) / 17)
                    ctx.setFillColor(CGColor(
                        srgbRed: min(1, max(0, shade)),
                        green: min(1, max(0, shade * 0.9)),
                        blue: min(1, max(0, 1 - shade)), alpha: 1
                    ))
                    ctx.fill(CGRect(x: x, y: y, width: block, height: block))
                }
            }
            return ctx.makeImage()!
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noisy-\(UUID().uuidString).gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ))
        for seed in 0..<frameCount {
            let properties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.07]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, makeFrame(seed: seed), properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
