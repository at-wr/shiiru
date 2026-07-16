import UIKit

final class AppIconMascotView: UIView {

    init(side: CGFloat = 136) {
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        layer.cornerRadius = side * 0.2237
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let artwork = UIImageView(image: UIImage(named: "AppIconGlass"))
        artwork.contentMode = .scaleAspectFill
        artwork.frame = bounds
        artwork.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(artwork)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func wave() {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0, -0.09, 0.07, -0.045, 0.02, 0]
        animation.duration = 0.55
        animation.timingFunctions = (0..<6).map { _ in
            CAMediaTimingFunction(name: .easeInEaseOut)
        }
        layer.add(animation, forKey: "wave")
    }
}
