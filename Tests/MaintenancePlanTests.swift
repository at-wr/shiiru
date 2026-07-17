import XCTest
@testable import Shiiru

final class MaintenancePlanTests: XCTestCase {

    private let pipeline = 10

    private func pack(
        _ id: String,
        kind: String = "sticker",
        converter: Int = 10,
        sourceCount: Int? = 12
    ) -> StickerManifest.Pack {
        StickerManifest.Pack(
            id: id, name: id, title: id,
            isAnimated: false,
            kind: kind,
            converterVersion: converter,
            sourceCount: sourceCount,
            stickers: [.init(fileName: "0.png", emoji: "😀", isAnimated: false)]
        )
    }

    private func manifest(_ packs: [StickerManifest.Pack]) -> StickerManifest {
        StickerManifest(version: 1, updatedAt: .now, packs: packs)
    }

    func testUpToDateStoreProducesEmptyPlan() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([pack("1"), pack("2", kind: "emoji")]),
            installed: [.init(id: "1", size: 12)],
            emoji: [.init(id: "2", size: 12)],
            knownPackIDs: ["1", "2"],
            autoAddNewPacks: true,
            pipelineVersion: pipeline
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testNewPackAutoAdds() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([]),
            installed: [.init(id: "7", size: 4)],
            emoji: [],
            knownPackIDs: [],
            autoAddNewPacks: true,
            pipelineVersion: pipeline
        )
        XCTAssertEqual(plan.stickerSetIDs, ["7"])
    }

    func testNewPackRespectsAutoAddOffAndKnownIDs() {
        for (autoAdd, known) in [(false, Set<String>()), (true, Set(["7"]))] {
            let plan = MaintenancePlan.compute(
                manifest: manifest([]),
                installed: [.init(id: "7", size: 4)],
                emoji: [],
                knownPackIDs: known,
                autoAddNewPacks: autoAdd,
                pipelineVersion: pipeline
            )
            XCTAssertTrue(plan.isEmpty, "autoAdd=\(autoAdd) known=\(known)")
        }
    }

    func testStalePipelineTriggersResync() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([pack("1", converter: 9), pack("2", kind: "emoji", converter: 9)]),
            installed: [.init(id: "1", size: 12)],
            emoji: [.init(id: "2", size: 12)],
            knownPackIDs: ["1", "2"],
            autoAddNewPacks: false,
            pipelineVersion: pipeline
        )
        XCTAssertEqual(plan.stickerSetIDs, ["1"])
        XCTAssertEqual(plan.emojiSetIDs, ["2"])
    }

    func testTelegramContentDriftTriggersResync() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([pack("1", sourceCount: 12)]),
            installed: [.init(id: "1", size: 15)],
            emoji: [],
            knownPackIDs: ["1"],
            autoAddNewPacks: false,
            pipelineVersion: pipeline
        )
        XCTAssertEqual(plan.stickerSetIDs, ["1"])
    }

    func testLegacyManifestWithoutSourceCountDoesNotLoop() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([pack("1", sourceCount: nil)]),
            installed: [.init(id: "1", size: 15)],
            emoji: [],
            knownPackIDs: ["1"],
            autoAddNewPacks: false,
            pipelineVersion: pipeline
        )
        XCTAssertTrue(plan.isEmpty, "no baseline count → no churn until next manual sync")
    }

    func testEmojiNeverAutoAdds() {
        let plan = MaintenancePlan.compute(
            manifest: manifest([]),
            installed: [],
            emoji: [.init(id: "9", size: 40)],
            knownPackIDs: [],
            autoAddNewPacks: true,
            pipelineVersion: pipeline
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testGifsRefreshOnStalePipelineAndCountDrift() {
        let stale = MaintenancePlan.compute(
            manifest: manifest([pack("gifs", kind: "gif", converter: 9, sourceCount: 3)]),
            installed: [], emoji: [],
            knownPackIDs: [], autoAddNewPacks: false,
            pipelineVersion: pipeline,
            gifCount: 3
        )
        XCTAssertTrue(stale.resyncGifs)

        let drifted = MaintenancePlan.compute(
            manifest: manifest([pack("gifs", kind: "gif", sourceCount: 3)]),
            installed: [], emoji: [],
            knownPackIDs: [], autoAddNewPacks: false,
            pipelineVersion: pipeline,
            gifCount: 5
        )
        XCTAssertTrue(drifted.resyncGifs)

        let unchanged = MaintenancePlan.compute(
            manifest: manifest([pack("gifs", kind: "gif", sourceCount: 3)]),
            installed: [], emoji: [],
            knownPackIDs: [], autoAddNewPacks: false,
            pipelineVersion: pipeline,
            gifCount: 3
        )
        XCTAssertFalse(unchanged.resyncGifs)
    }

    func testRemovedTelegramPacksAreLeftAlone() {
        // Deleted/archived on Telegram: background maintenance must neither
        // re-sync nor delete them — the user decides in the app.
        let plan = MaintenancePlan.compute(
            manifest: manifest([pack("1")]),
            installed: [],
            emoji: [],
            knownPackIDs: ["1"],
            autoAddNewPacks: true,
            pipelineVersion: pipeline
        )
        XCTAssertTrue(plan.isEmpty)
    }
}
