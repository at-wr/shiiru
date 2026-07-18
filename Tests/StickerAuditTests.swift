import XCTest
import CoreGraphics
import StickerCore
@testable import Shiiru

/// The audit decides which stale packs actually pay a re-conversion after a
/// pipeline bump; false negatives ship broken stickers, false positives
/// burn a full pack re-convert.
final class StickerAuditTests: XCTestCase {

    private let store = SharedStickerStore.shared

    override func setUp() {
        store.removeAll()
    }

    override func tearDown() {
        store.removeAll()
    }

    private func solidFrame(shade: CGFloat) -> CGImage {
        let side = 64
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: shade, green: 0.4, blue: 1 - shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    /// Writes a pack whose single sticker is animated-labeled with the given
    /// number of real encoded frames.
    private func installPack(
        id: String, kind: String = "sticker", frames: Int, labeledAnimated: Bool, converter: Int = 10
    ) throws {
        let directory = try store.prepareDirectory(named: id)
        let images = (0..<max(frames, 1)).map {
            APNGEncoder.Frame(image: solidFrame(shade: CGFloat($0) / 4), delay: 0.1)
        }
        let data = try XCTUnwrap(APNGEncoder.encode(frames: images, width: 64, height: 64))
        try data.write(to: directory.appendingPathComponent("0.png"))
        store.upsert(pack: StickerManifest.Pack(
            id: id, name: id, title: id,
            isAnimated: labeledAnimated,
            kind: kind,
            converterVersion: converter,
            stickers: [.init(fileName: "0.png", emoji: "😀", isAnimated: labeledAnimated)]
        ))
    }

    func testMislabeledSingleFrameFileIsSuspect() throws {
        try installPack(id: "bad", frames: 1, labeledAnimated: true)
        try installPack(id: "good", frames: 4, labeledAnimated: true)
        try installPack(id: "honest-static", frames: 1, labeledAnimated: false)

        let suspects = StickerAudit.suspectPackIDs(
            manifest: store.loadManifest(), pipelineVersion: 11, store: store
        )
        XCTAssertEqual(
            suspects, ["bad"],
            "only the animated-labeled single-frame pack needs re-conversion"
        )
    }

    func testStaticSavedGifIsSuspect() throws {
        try installPack(id: "gifs", kind: "gif", frames: 1, labeledAnimated: false)

        let suspects = StickerAudit.suspectPackIDs(
            manifest: store.loadManifest(), pipelineVersion: 11, store: store
        )
        XCTAssertEqual(suspects, ["gifs"], "a static saved GIF is the old ladder's fallback")
    }

    func testCurrentVersionPacksAreNeverAudited() throws {
        try installPack(id: "bad-but-current", frames: 1, labeledAnimated: true, converter: 11)

        let suspects = StickerAudit.suspectPackIDs(
            manifest: store.loadManifest(), pipelineVersion: 11, store: store
        )
        XCTAssertTrue(suspects.isEmpty, "audit is scoped to stale packs only")
    }

    /// Orphaned directories (a sync killed between writing files and
    /// publishing) are swept once they age past the safety window;
    /// referenced and freshly-written directories are untouched.
    func testSweepRemovesOnlyOldUnreferencedDirectories() throws {
        try installPack(id: "kept", frames: 2, labeledAnimated: true)

        let fileManager = FileManager.default
        let oldOrphan = try store.prepareDirectory(named: "kept-stale1")
        try Data("x".utf8).write(to: oldOrphan.appendingPathComponent("0.png"))
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: oldOrphan.path
        )
        let freshOrphan = try store.prepareDirectory(named: "kept-fresh2")
        try Data("x".utf8).write(to: freshOrphan.appendingPathComponent("0.png"))
        // Age the referenced directory too, so only the manifest reference
        // (not its recency) is what protects it.
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: store.directoryURL(forPackID: "kept").path
        )

        store.sweepUnreferencedDirectories()

        XCTAssertFalse(fileManager.fileExists(atPath: oldOrphan.path), "aged orphan is removed")
        XCTAssertTrue(fileManager.fileExists(atPath: freshOrphan.path), "in-flight output survives")
        XCTAssertTrue(
            fileManager.fileExists(atPath: store.directoryURL(forPackID: "kept").path),
            "referenced pack directory survives"
        )
    }

    func testStampMovesVersionWithoutTouchingFiles() throws {
        try installPack(id: "clean", frames: 4, labeledAnimated: true)
        let before = store.loadManifest().packs.first { $0.id == "clean" }

        store.stamp(packID: "clean", converterVersion: 11)

        let after = store.loadManifest().packs.first { $0.id == "clean" }
        XCTAssertEqual(after?.converterVersion, 11)
        XCTAssertEqual(after?.stickers, before?.stickers)
        XCTAssertEqual(after?.directoryName, before?.directoryName)
    }
}
