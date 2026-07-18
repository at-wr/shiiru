import Foundation

/// The unit counter behind the continued task's progress bar.
///
/// The system's Activity Progress Policy expires tasks whose progress
/// stalls (field log: ~70 s after the device locked) and its tracker
/// distrusts values that move backwards. This keeps one monotonic
/// `published` figure: real progress raises it directly, and synthetic
/// heartbeat ticks may only build a bounded lead over real progress —
/// bridging duty-cycle sleeps and network waits without ever rewinding
/// or running away from the truth.
struct ProgressPulse {

    private(set) var published: Int64 = 0
    private(set) var realUnits: Int64 = 0
    private(set) var totalUnits: Int64 = 1
    /// Maximum synthetic lead over real progress, in units.
    var lead: Int64 = 40
    /// Every `cadence`-th tick advances (offline slows the crawl).
    var cadence = 1
    private var tick = 0

    /// Real progress landed; published never moves backwards.
    mutating func update(realUnits: Int64, totalUnits: Int64) -> Int64 {
        self.realUnits = realUnits
        self.totalUnits = max(totalUnits, 1)
        published = min(max(published, realUnits), self.totalUnits)
        return published
    }

    /// One heartbeat; returns the new published value when it advanced.
    mutating func beat() -> Int64? {
        tick += 1
        guard tick % cadence == 0, published - realUnits < lead else { return nil }
        let advanced = min(max(published, realUnits) + 1, totalUnits - 1)
        guard advanced > published else { return nil }
        published = advanced
        return published
    }

    mutating func reset() {
        published = 0
        realUnits = 0
        totalUnits = 1
        lead = 40
        cadence = 1
        tick = 0
    }
}
