import XCTest
@testable import Shiiru

final class StickerEncodePlannerTests: XCTestCase {

    private func plans(
        sourceFPS: Double,
        sizeForPlan: (Int, Double) -> Int?
    ) -> [(side: Int, fps: Double)] {
        var planner = StickerEncodePlanner(sourceFPS: sourceFPS, budget: 500_000)
        var all: [(side: Int, fps: Double)] = [(planner.side, planner.fps)]
        var plan: (side: Int, fps: Double)? = all[0]
        while let current = plan {
            plan = planner.next(measuredSize: sizeForPlan(current.side, current.fps))
            if let plan { all.append(plan) }
        }
        return all
    }

    func testHoldsFPSWhileResolutionFalls() {

        let all = plans(sourceFPS: 30) { _, _ in 700_000 }
        let attemptsAt30 = all.prefix { $0.fps == 30 }
        XCTAssertEqual(all.first?.side, 512)
        XCTAssertGreaterThan(attemptsAt30.count, 1, "should retry smaller sides before touching fps")

        XCTAssertLessThanOrEqual(attemptsAt30.last?.side ?? 512, 320)
    }

    func testRespectsFloorsAndTierOrder() {
        for all in [
            plans(sourceFPS: 30) { _, _ in 2_000_000 },
            plans(sourceFPS: 30) { _, _ in nil },
            plans(sourceFPS: 60) { _, _ in 600_000 },
        ] {
            for plan in all {
                XCTAssertGreaterThanOrEqual(plan.fps, 12, "12 fps is the absolute emergency floor")
                XCTAssertGreaterThanOrEqual(
                    plan.side, 320,
                    "the canvas floor keeps transcript display size near Telegram's"
                )
            }

            if let firstEmergency = all.firstIndex(where: { $0.fps < 20 }) {
                XCTAssertTrue(
                    all[..<firstEmergency].contains { $0.fps == 20 },
                    "the 20 fps floor must be tried before any emergency tier"
                )
            }
            let rates = all.map(\.fps)
            XCTAssertEqual(rates, rates.sorted(by: >), "fps must only ever descend")
        }
    }

    func testTerminatesForUnfittableInput() {
        let all = plans(sourceFPS: 30) { _, _ in 5_000_000 }
        XCTAssertLessThan(all.count, 24, "planner must exhaust, not loop")
        XCTAssertEqual(all.last?.fps, 12, "the last stand before static is the 12 fps emergency tier")
    }

    func testDenseVideoGetsEmergencyTierInsteadOfStatic() {

        let all = plans(sourceFPS: 30) { side, fps in
            Int(3.0 * fps) * (side * side / 6)
        }
        XCTAssertTrue(all.contains { $0.fps < 20 }, "emergency tiers must be reachable")
    }

    func testSlowSourceKeepsNativeRateAndNeverResamplesUp() {
        let all = plans(sourceFPS: 12) { _, _ in 700_000 }
        for plan in all {
            XCTAssertEqual(plan.fps, 12, "a 12 fps source has exactly one fps tier")
        }
    }

    func testPlaybackSideCapBoundsEveryPlan() {

        let cap = StickerConverter.playbackSideCap(frameCount: 90)
        XCTAssertLessThan(cap, 512)
        var planner = StickerEncodePlanner(sourceFPS: 30, budget: 500_000, maxSide: cap)
        XCTAssertLessThanOrEqual(planner.side, cap)
        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)
        while let current = plan {
            XCTAssertLessThanOrEqual(current.side, cap)
            plan = planner.next(measuredSize: 450_000)
            if current.fps <= 12 { break }
        }

        XCTAssertEqual(StickerConverter.playbackSideCap(frameCount: 30), 512)
    }

    func testPredictionJumpsTowardFittingSide() {

        var planner = StickerEncodePlanner(sourceFPS: 30, budget: 500_000)
        let next = planner.next(measuredSize: 2_000_000)
        XCTAssertEqual(next?.side, 320, "the jump clamps at the display-size floor")
        XCTAssertEqual(next?.fps, 30)
    }

    func testFPSTierDropCanRaiseResolutionBack() throws {
        var planner = StickerEncodePlanner(sourceFPS: 30, budget: 500_000)

        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)
        while let current = plan, current.fps == 30 {
            plan = planner.next(measuredSize: 550_000)
        }
        let dropped = try XCTUnwrap(plan)
        XCTAssertEqual(dropped.fps, 24)
        XCTAssertGreaterThan(dropped.side, 320, "fewer frames should buy some resolution back")
    }
}
