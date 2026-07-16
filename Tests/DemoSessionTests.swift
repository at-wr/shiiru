import XCTest
import ImageIO
@testable import Shiiru

final class DemoSessionTests: XCTestCase {

    func testInstallAllPacksProducesValidStickers() throws {
        DemoSession.installAllPacks()
        defer {
            SharedStickerStore.shared.removePack(id: "9101")
            SharedStickerStore.shared.removePack(id: "9102")
        }

        let manifest = SharedStickerStore.shared.loadManifest()
        let demoPacks = manifest.packs.filter { ["9101", "9102"].contains($0.id) }
        XCTAssertEqual(demoPacks.count, 2)

        for pack in demoPacks {
            XCTAssertFalse(pack.stickers.isEmpty)
            for sticker in pack.stickers {
                let url = SharedStickerStore.shared.fileURL(pack: pack, sticker: sticker)
                let data = try Data(contentsOf: url)
                if let dir = ProcessInfo.processInfo.environment["SHIIRU_AUDIT_DIR"] {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(pack.id)-\(sticker.fileName)"))
                }
                XCTAssertLessThanOrEqual(data.count, StickerConverter.maxFileSize)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                XCTAssertEqual(
                    CGImageSourceGetCount(source) > 1,
                    sticker.isAnimated,
                    "\(pack.title)/\(sticker.fileName) animation mismatch"
                )
            }
        }
    }
}
