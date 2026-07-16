import UIKit
import Lottie

final class TGSHeroView: UIView {

    private let animationView = LottieAnimationView()
    private let side: CGFloat

    init(name: String, side: CGFloat = 136) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        animationView.frame = bounds
        animationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.backgroundBehavior = .pauseAndRestore
        addSubview(animationView)

        if let url = Bundle.main.url(forResource: name, withExtension: "tgs"),
           let raw = try? Data(contentsOf: url),
           let json = try? StickerConverter.gunzip(raw),
           let animation = try? LottieAnimation.from(data: json) {
            animationView.animation = animation
            animationView.play()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }
}
