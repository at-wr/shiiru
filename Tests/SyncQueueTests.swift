import XCTest
@testable import Shiiru

@MainActor
final class SyncQueueTests: XCTestCase {

    private func item(_ key: String, user: Bool, cost: Double) -> StickerSyncEngine.PendingSync {
        .init(key: key, userInitiated: user, estimatedCost: cost, run: {})
    }

    /// Backgrounded queues run cheap packs first so more of them complete
    /// (and checkpoint durably) before the window closes — without letting
    /// the automatic backlog cut ahead of what the user asked for.
    func testBackgroundPriorityRunsCheapPacksFirstWithinEachClass() {
        let ordered = StickerSyncEngine.backgroundPriority([
            item("auto-big", user: false, cost: 900),
            item("user-big", user: true, cost: 2400),
            item("user-small", user: true, cost: 48),
            item("auto-small", user: false, cost: 12),
            item("gifs", user: true, cost: .greatestFiniteMagnitude),
        ])
        XCTAssertEqual(
            ordered.map(\.key),
            ["user-small", "user-big", "gifs", "auto-small", "auto-big"]
        )
    }

    /// Preemption pauses a running pack only for meaningfully cheaper work
    /// of equal standing — the automatic backlog never bumps a pack the
    /// user asked for.
    func testPreemptOnlyForMeaningfullyCheaperEligibleWork() {
        let bigUser = item("big", user: true, cost: 2000)
        XCTAssertTrue(StickerSyncEngine.shouldPreempt(
            running: bigUser, pending: [item("small", user: true, cost: 100)]
        ))
        XCTAssertFalse(StickerSyncEngine.shouldPreempt(
            running: bigUser, pending: [item("similar", user: true, cost: 900)]
        ), "similar-sized work isn't worth losing the in-flight sticker")
        XCTAssertFalse(StickerSyncEngine.shouldPreempt(
            running: bigUser, pending: [item("auto", user: false, cost: 10)]
        ), "automatic backlog never preempts the user's pack")
        XCTAssertTrue(StickerSyncEngine.shouldPreempt(
            running: item("auto-big", user: false, cost: 2000),
            pending: [item("auto-small", user: false, cost: 10)]
        ))
        XCTAssertFalse(StickerSyncEngine.shouldPreempt(running: bigUser, pending: []))
    }

    func testBackgroundPriorityIsStableForEqualCost() {
        let ordered = StickerSyncEngine.backgroundPriority([
            item("a", user: true, cost: 10),
            item("b", user: true, cost: 10),
            item("c", user: true, cost: 10),
        ])
        XCTAssertEqual(ordered.map(\.key), ["a", "b", "c"])
    }
}
