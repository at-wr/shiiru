import XCTest
import ImageIO
import StickerCore
@testable import Shiiru

final class PackConversionHarness: XCTestCase {

    func testDecoderFrameCounts() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHIIRU_WEBM_DIR"] else {
            throw XCTSkip("set SHIIRU_WEBM_DIR to run the pack harness")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".webm") }
            .sorted()
            .prefix(12)
        for file in files {
            let frames = WebmStickerDecoder.decodeFrames(atPath: "\(dir)/\(file)", maxFrames: 900)
            let times = (frames ?? []).map { String(format: "%.2f", $0.timestamp) }
            print("DECODE \(file): \(frames?.count ?? -1) frames, t=[\(times.prefix(5).joined(separator: ",")) …]")
        }
    }

    func testParameterSweep() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHIIRU_SWEEP_FILE"] else {
            throw XCTSkip("set SHIIRU_SWEEP_FILE to a .webm to run the sweep")
        }
        let decoded = try XCTUnwrap(WebmStickerDecoder.decodeFrames(atPath: dir, maxFrames: 90))
        let duration = max(decoded.last!.timestamp, 0.1)
        for side in [192, 160] {
            for fps in [12.0, 16.0] {
                for colors in [256, 128, 96, 64] {
                    let count = min(decoded.count, max(2, Int((duration * fps).rounded())))
                    let picked = (0..<count).map { decoded[$0 * decoded.count / count] }
                    let frames: [APNGEncoder.Frame] = picked.compactMap {
                        guard let scaled = StickerConverter.scale($0.image, toFit: side, exact: true)
                        else { return nil }
                        return APNGEncoder.Frame(image: scaled, delay: duration / Double(count))
                    }
                    guard let first = frames.first else { continue }
                    let data = APNGEncoder.encode(
                        frames: frames, width: first.image.width, height: first.image.height,
                        maxColors: colors
                    )
                    print("SWEEP side=\(side) fps=\(Int(fps)) colors=\(colors) frames=\(count) -> \((data?.count ?? 0) / 1024)KB")
                }
            }
        }
    }

    /// Converts a directory of custom-emoji sources (webp/webm) with canvas
    /// filling on, verifying padding is cropped and output fills the canvas.
    func testConvertEmojiDirectory() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHIIRU_EMOJI_DIR"] else {
            throw XCTSkip("set SHIIRU_EMOJI_DIR to run the emoji harness")
        }
        let auditDir = ProcessInfo.processInfo.environment["SHIIRU_AUDIT_DIR"]
        if let auditDir {
            try? FileManager.default.createDirectory(atPath: auditDir, withIntermediateDirectories: true)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".webm") || $0.hasSuffix(".webp") }
            .sorted()
        var failures = 0
        for file in files {
            do {
                let output: StickerConverter.Output
                if file.hasSuffix(".webm") {
                    output = try StickerConverter.convertWebm(
                        at: "\(dir)/\(file)", fillCanvas: true, profile: .emoji
                    )
                } else {
                    output = .png(try StickerConverter.convertStaticImage(
                        at: "\(dir)/\(file)", fillCanvas: true
                    ))
                }
                let source = try XCTUnwrap(CGImageSourceCreateWithData(output.data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let frames = CGImageSourceGetCount(source)
                XCTAssertLessThanOrEqual(output.data.count, StickerConverter.maxFileSize)
                // Static emoji upscale to the full canvas; animated emoji
                // trade resolution for the 500 KB budget, but never below
                // the encoder's floor.
                XCTAssertGreaterThanOrEqual(
                    max(image.width, image.height), output.isAnimated ? 160 : 512,
                    "\(file): emoji should fill a high-res canvas"
                )
                print("EMOJI \(file): \(output.isAnimated ? "APNG" : "STATIC") "
                    + "\(image.width)x\(image.height) \(frames)f \(output.data.count / 1024)KB")
                if let auditDir {
                    try? output.data.write(to: URL(fileURLWithPath: "\(auditDir)/emoji-\(file).png"))
                }
            } catch {
                failures += 1
                print("EMOJI \(file): FAILED \(error)")
            }
        }
        print("EMOJI summary: \(failures) failed of \(files.count)")
        XCTAssertEqual(failures, 0)
    }

    func testConvertLocalPack() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHIIRU_WEBM_DIR"] else {
            throw XCTSkip("set SHIIRU_WEBM_DIR to run the pack harness")
        }
        let auditDir = ProcessInfo.processInfo.environment["SHIIRU_AUDIT_DIR"]
        if let auditDir {
            try? FileManager.default.createDirectory(atPath: auditDir, withIntermediateDirectories: true)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".webm") || $0.hasSuffix(".webp") }
            .sorted()
        // SHIIRU_PRESET selects the transcode preset (balanced/smooth/sharp).
        let profile = (ProcessInfo.processInfo.environment["SHIIRU_PRESET"]
            .flatMap(TranscodePreset.init(rawValue:)) ?? .balanced).profile
        var animated = 0, statics = 0, failures = 0
        let clock = ContinuousClock()
        var totalTime = Duration.zero

        for file in files {
            do {
                var output: StickerConverter.Output?
                let elapsed = try clock.measure {
                    if file.hasSuffix(".webm") {
                        output = try StickerConverter.convertWebm(at: "\(dir)/\(file)", profile: profile)
                    } else {
                        output = .png(try StickerConverter.convertStaticImage(at: "\(dir)/\(file)"))
                    }
                }
                totalTime += elapsed
                let data = try XCTUnwrap(output).data
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let frames = CGImageSourceGetCount(source)
                XCTAssertLessThanOrEqual(data.count, StickerConverter.maxFileSize)
                if output?.isAnimated == true { animated += 1 } else { statics += 1 }
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                print("HARNESS \(file): \(output?.isAnimated == true ? "APNG" : "STATIC") "
                    + "\(image.width)x\(image.height) \(frames)f \(data.count / 1024)KB "
                    + String(format: "%.1fs", seconds))
                if let auditDir {
                    try? data.write(to: URL(fileURLWithPath: "\(auditDir)/\(file).png"))
                }
            } catch {
                failures += 1
                print("HARNESS \(file): FAILED \(error)")
            }
        }
        print("HARNESS summary: \(animated) animated, \(statics) static, \(failures) failed of \(files.count), total \(totalTime)")
        XCTAssertEqual(failures, 0)
    }
}
