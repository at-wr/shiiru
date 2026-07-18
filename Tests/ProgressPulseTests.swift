import XCTest
@testable import Shiiru

/// The system expires continued tasks whose progress stalls and distrusts
/// values that move backwards — the pulse must tick steadily, stay
/// monotonic, and never run away from real progress.
final class ProgressPulseTests: XCTestCase {

    func testPublishedNeverMovesBackwards() {
        var pulse = ProgressPulse()
        _ = pulse.update(realUnits: 100, totalUnits: 1000)
        // Heartbeats build a lead over real progress…
        for _ in 0..<10 { _ = pulse.beat() }
        XCTAssertEqual(pulse.published, 110)
        // …and a real tick below the published value must not rewind it.
        XCTAssertEqual(pulse.update(realUnits: 105, totalUnits: 1000), 110)
        // Real progress overtaking the lead raises it directly.
        XCTAssertEqual(pulse.update(realUnits: 400, totalUnits: 1000), 400)
    }

    func testHeartbeatLeadIsBounded() {
        var pulse = ProgressPulse()
        _ = pulse.update(realUnits: 0, totalUnits: 1000)
        for _ in 0..<500 { _ = pulse.beat() }
        XCTAssertEqual(pulse.published, 40, "synthetic lead stops at the allowance")
        // A real tick shrinks the outstanding lead, freeing beat headroom.
        _ = pulse.update(realUnits: 30, totalUnits: 1000)
        for _ in 0..<500 { _ = pulse.beat() }
        XCTAssertEqual(pulse.published, 70)
    }

    func testOfflineCadenceSlowsTheCrawl() {
        var pulse = ProgressPulse()
        _ = pulse.update(realUnits: 0, totalUnits: 1000)
        pulse.lead = 100
        pulse.cadence = 3
        var advanced = 0
        for _ in 0..<30 where pulse.beat() != nil { advanced += 1 }
        XCTAssertEqual(advanced, 10, "offline ticks advance every third beat")
    }

    func testNeverReachesTotalSynthetically() {
        var pulse = ProgressPulse()
        _ = pulse.update(realUnits: 995, totalUnits: 1000)
        for _ in 0..<50 { _ = pulse.beat() }
        XCTAssertEqual(pulse.published, 999, "the last unit is real work's to claim")
    }
}
