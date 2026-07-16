import UIKit
import Lottie

final class MonkeyView: UIView {

    enum State: Equatable {
        case idle
        case eyesClosed
        case peeking
        case tracking(CGFloat)
    }

    private(set) var state: State = .idle

    private let animationView = LottieAnimationView()
    private var idleTimer: Timer?

    private var generation = 0

    private let side: CGFloat

    private static let trackingRange: ClosedRange<CGFloat> = 18...160
    private static let closeEnd: CGFloat = 41
    private static let peekEnd: CGFloat = 14

    init(side: CGFloat = 136) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        animationView.frame = bounds
        animationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundBehavior = .pauseAndRestore
        addSubview(animationView)

        showStill()
        scheduleIdleVariation()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { idleTimer?.invalidate() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    private static var cache: [String: LottieAnimation] = [:]

    private static func animation(_ name: String) -> LottieAnimation? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "tgs"),
              let raw = try? Data(contentsOf: url),
              let json = try? StickerConverter.gunzip(raw),
              let animation = try? LottieAnimation.from(data: json)
        else { return nil }
        cache[name] = animation
        return animation
    }

    private func play(
        _ name: String,
        from: CGFloat,
        to: CGFloat,
        duration: Double = 0.3,
        completion: (() -> Void)? = nil
    ) {
        guard let animation = Self.animation(name) else { completion?(); return }
        if animationView.animation !== animation {
            animationView.animation = animation
        }
        let naturalDuration = Double(abs(to - from)) / animation.framerate
        animationView.animationSpeed = duration > 0 ? max(naturalDuration / duration, 0.01) : 1
        let expected = generation
        animationView.play(fromFrame: from, toFrame: to) { [weak self] _ in
            guard let self, self.generation == expected else { return }
            completion?()
        }
    }

    private func showStill() {
        guard let animation = Self.animation("TwoFactorSetupMonkeyIdle") else { return }
        animationView.animation = animation
        animationView.currentFrame = 0
    }

    private func scheduleIdleVariation() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 1.0..<1.5),
            repeats: false
        ) { [weak self] _ in
            guard let self, self.state == .idle else { return }
            let variation = ["idle", "blink", "ear"].randomElement()!
            switch variation {
            case "blink":
                self.play("TwoFactorSetupMonkeyIdle1", from: 0, to: 30) { [weak self] in
                    self?.scheduleIdleVariation()
                }
            case "ear":
                self.play("TwoFactorSetupMonkeyIdle2", from: 0, to: 30) { [weak self] in
                    self?.scheduleIdleVariation()
                }
            default:
                self.showStill()
                self.scheduleIdleVariation()
            }
        }
    }

    func setState(_ newState: State) {
        let previous = state
        if newState == previous { return }
        state = newState
        generation += 1
        idleTimer?.invalidate()

        switch (previous, newState) {
        case (_, .idle):
            switch previous {
            case .eyesClosed:
                play("TwoFactorSetupMonkeyClose", from: Self.closeEnd, to: 0) { [weak self] in
                    self?.scheduleIdleVariation()
                }
            case .peeking:
                play("TwoFactorSetupMonkeyCloseAndPeek", from: Self.closeEnd, to: 0) { [weak self] in
                    self?.scheduleIdleVariation()
                }
            case .tracking:
                play("TwoFactorSetupMonkeyTracking", from: currentTrackingFrame, to: 0) { [weak self] in
                    self?.showStill()
                    self?.scheduleIdleVariation()
                }
            default:
                showStill()
                scheduleIdleVariation()
            }

        case (.idle, .eyesClosed), (.tracking, .eyesClosed):
            if case .tracking = previous {
                play("TwoFactorSetupMonkeyTracking", from: currentTrackingFrame, to: 0) { [weak self] in
                    self?.play("TwoFactorSetupMonkeyClose", from: 0, to: Self.closeEnd)
                }
            } else {
                play("TwoFactorSetupMonkeyClose", from: 0, to: Self.closeEnd)
            }

        case (.peeking, .eyesClosed):
            play("TwoFactorSetupMonkeyPeek", from: Self.peekEnd, to: 0)

        case (.eyesClosed, .peeking):
            play("TwoFactorSetupMonkeyPeek", from: 0, to: Self.peekEnd)

        case (_, .peeking):
            play("TwoFactorSetupMonkeyCloseAndPeek", from: 0, to: Self.closeEnd)

        case (_, .tracking(let value)):
            let target = Self.trackingRange.lowerBound
                + value.clamped01 * (Self.trackingRange.upperBound - Self.trackingRange.lowerBound)
            switch previous {
            case .tracking:
                play("TwoFactorSetupMonkeyTracking", from: currentTrackingFrame, to: target)
            case .eyesClosed:
                play("TwoFactorSetupMonkeyClose", from: Self.closeEnd, to: 0) { [weak self] in
                    self?.play("TwoFactorSetupMonkeyTracking", from: 0, to: target)
                }
            case .peeking:
                play("TwoFactorSetupMonkeyCloseAndPeek", from: Self.closeEnd, to: 0) { [weak self] in
                    self?.play("TwoFactorSetupMonkeyTracking", from: 0, to: target)
                }
            default:
                play("TwoFactorSetupMonkeyTracking", from: 0, to: target)
            }

        default:
            break
        }
    }

    private var currentTrackingFrame: CGFloat {
        if animationView.animation === Self.animation("TwoFactorSetupMonkeyTracking") {
            return animationView.realtimeAnimationFrame
        }
        return 0
    }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) }
}
