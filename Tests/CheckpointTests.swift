import XCTest
import CoreGraphics
import StickerCore
@testable import Shiiru

/// Interrupted syncs leave a checkpointed partial directory; the next
/// attempt at the same source must resume it — and only it.
@MainActor
final class CheckpointTests: XCTestCase {

    private let store = SharedStickerStore.shared

    override func setUp() {
        store.removeAll()
    }

    override func tearDown() {
        store.removeAll()
    }

    private func frame(shade: CGFloat) -> CGImage {
        let side = 64
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: shade, green: 0.3, blue: 1 - shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    func testResumableDirectoryMatchesOnSourceHash() throws {
        _ = try store.prepareDirectory(named: "42-abc123")
        store.writeCheckpoint(directory: "42-abc123", sourceHash: "hash-a")

        XCTAssertEqual(store.resumableDirectory(forPackID: "42", sourceHash: "hash-a"), "42-abc123")
        XCTAssertNil(
            store.resumableDirectory(forPackID: "42", sourceHash: "hash-b"),
            "a changed source starts over instead of resuming stale output"
        )
        XCTAssertNil(store.resumableDirectory(forPackID: "7", sourceHash: "hash-a"))
    }

    func testPublishedDirectoryIsNotResumable() throws {
        _ = try store.prepareDirectory(named: "42-abc123")
        store.writeCheckpoint(directory: "42-abc123", sourceHash: "hash-a")
        store.upsert(pack: StickerManifest.Pack(
            id: "42", name: "42", title: "42",
            isAnimated: false,
            converterVersion: StickerConverter.pipelineVersion,
            directory: "42-abc123",
            stickers: [.init(fileName: "000-abc123.png", emoji: "", isAnimated: false)]
        ))
        XCTAssertNil(store.resumableDirectory(forPackID: "42", sourceHash: "hash-a"))
    }

    func testConvertedEntriesRebuildFromFiles() throws {
        let dir = try store.prepareDirectory(named: "42-tok")
        let animated = try XCTUnwrap(APNGEncoder.encode(
            frames: (0..<3).map { .init(image: frame(shade: CGFloat($0) / 2), delay: 0.1) },
            width: 64, height: 64
        ))
        try animated.write(to: dir.appendingPathComponent("000-tok.png"))
        let still = try XCTUnwrap(APNGEncoder.encodeStatic(frame(shade: 0.5), width: 64, height: 64))
        try still.write(to: dir.appendingPathComponent("002-tok.png"))
        // A different sync token and the checkpoint sidecar are not entries.
        try Data("x".utf8).write(to: dir.appendingPathComponent("001-other.png"))
        store.writeCheckpoint(directory: "42-tok", sourceHash: "h")

        let entries = StickerSyncEngine.convertedEntries(
            directory: dir, syncToken: "tok", emojis: ["😀", "😁", "😂"]
        )
        XCTAssertEqual(Set(entries.keys), [0, 2])
        XCTAssertEqual(entries[0]?.isAnimated, true)
        XCTAssertEqual(entries[2]?.isAnimated, false)
        XCTAssertEqual(entries[0]?.emoji, "😀")
        XCTAssertEqual(entries[0]?.fileName, "000-tok.png")
    }

    func testSweepSparesFreshCheckpointsAndReapsAbandonedOnes() throws {
        let fileManager = FileManager.default
        let dir = try store.prepareDirectory(named: "42-tok")
        try Data("x".utf8).write(to: dir.appendingPathComponent("000-tok.png"))
        store.writeCheckpoint(directory: "42-tok", sourceHash: "h")
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: dir.path
        )

        store.sweepUnreferencedDirectories()
        XCTAssertTrue(
            fileManager.fileExists(atPath: dir.path),
            "a checkpointed partial outlives the one-day orphan sweep"
        )

        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)],
            ofItemAtPath: dir.appendingPathComponent(SharedStickerStore.checkpointFileName).path
        )
        store.sweepUnreferencedDirectories()
        XCTAssertFalse(
            fileManager.fileExists(atPath: dir.path),
            "an abandoned checkpoint eventually counts as an orphan"
        )
    }
}
