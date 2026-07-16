import XCTest
import ImageIO
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
}
