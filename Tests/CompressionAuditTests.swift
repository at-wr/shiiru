import XCTest
import ImageIO
@testable import Shiiru
import StickerCore

final class CompressionAuditTests: XCTestCase {

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: CompressionAuditTests.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
    }

    private func report(_ label: String, _ data: Data) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let frames = CGImageSourceGetCount(source)
        print("AUDIT \(label): \(data.count) bytes, \(image.width)x\(image.height), \(frames) frames")
        if let dir = ProcessInfo.processInfo.environment["SHIIRU_AUDIT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(label).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            print("AUDIT \(label): wrote \(url.path)")
        }
    }

    func testAuditStaticWebp() throws {
        let png = try StickerConverter.convertStaticImage(at: fixtureURL("sample", "webp").path)
        try report("webp-static", png)
        XCTAssertLessThanOrEqual(png.count, StickerConverter.maxFileSize)
    }

    @MainActor
    func testAuditTGS() async throws {
        let clock = ContinuousClock()
        var output: StickerConverter.Output?
        let elapsed = try await clock.measure {
            output = try await StickerConverter.convertTGS(at: fixtureURL("sample", "tgs").path)
        }
        let data = try XCTUnwrap(output).data
        print("AUDIT tgs: converted in \(elapsed)")
        try report("tgs-animated", data)
        XCTAssertLessThanOrEqual(data.count, StickerConverter.maxFileSize)
    }

    @MainActor
    func testAuditRealWorldTGS() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "TwoFactorSetupMonkeyIdle", withExtension: "tgs"))
        let output = try await StickerConverter.convertTGS(at: url.path)
        try report("monkey-animated", output.data)
        XCTAssertLessThanOrEqual(output.data.count, StickerConverter.maxFileSize)
        XCTAssertTrue(output.isAnimated, "complex TGS should keep its animation")
    }

    func testAuditWebm() throws {
        let clock = ContinuousClock()
        var output: StickerConverter.Output?
        let elapsed = try clock.measure {
            output = try StickerConverter.convertWebm(at: fixtureURL("sample", "webm").path)
        }
        let data = try XCTUnwrap(output).data
        print("AUDIT webm: converted in \(elapsed)")
        try report("webm-animated", data)
        XCTAssertLessThanOrEqual(data.count, StickerConverter.maxFileSize)
    }
}
