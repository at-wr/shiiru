import Foundation

struct StickerEncodePlanner {

    static let maxSide = 512

    /// Messages renders animated stickers proportionally to their pixel
    /// dimensions (~side/3 pt in the transcript). Below this floor they
    /// display noticeably smaller than on Telegram, so byte pressure is
    /// relieved through fps and palette before the canvas ever shrinks.
    static let minSide = 320

    private let budget: Double
    private let sideCap: Int
    private var remainingTiers: [Double]
    private var attemptsAtTier = 1
    private(set) var side: Int
    private(set) var fps: Double

    init(sourceFPS: Double, budget: Int, maxSide: Int = StickerEncodePlanner.maxSide) {
        self.budget = Double(budget)
        sideCap = min(Self.maxSide, max(Self.minSide, maxSide))
        let target = min(30, max(1, sourceFPS))
        var tiers: [Double] = []
        for candidate in [target, min(24, target), min(20, target)] where tiers.last != candidate {
            tiers.append(candidate)
        }

        for candidate in [16.0, 12.0] where candidate < target {
            tiers.append(candidate)
        }
        fps = tiers.removeFirst()
        remainingTiers = tiers
        side = sideCap
    }

    mutating func next(measuredSize: Int?) -> (side: Int, fps: Double)? {
        let overBudget = measuredSize.map { Double($0) / budget } ?? 4.0

        if side > Self.minSide, attemptsAtTier < 4 {

            var predicted = Double(side) / overBudget.squareRoot() * 0.95
            predicted = min(predicted, Double(side - 16))
            side = max(Self.minSide, Int(predicted / 16) * 16)
            attemptsAtTier += 1
            return (side, fps)
        }

        guard !remainingTiers.isEmpty else { return nil }
        let newFPS = remainingTiers.removeFirst()
        let projected = overBudget * newFPS / fps
        var predicted = Double(side) / projected.squareRoot() * 0.95
        predicted = min(max(predicted, Double(Self.minSide)), Double(sideCap))
        side = max(Self.minSide, Int(predicted / 16) * 16)
        fps = newFPS
        attemptsAtTier = 1
        return (side, fps)
    }
}
