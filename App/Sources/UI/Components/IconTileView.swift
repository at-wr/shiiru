import UIKit

final class IconTileView: UIView {

    private let gradient = CAGradientLayer()

    init(systemName: String, color: UIColor, side: CGFloat = 30) {
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        gradient.colors = [color.addingWhite(0.14).cgColor, color.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.insertSublayer(gradient, at: 0)
        layer.cornerRadius = side * 0.24
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let imageView = UIImageView(image: UIImage(
            systemName: systemName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.55, weight: .medium)
        ))
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: side * 0.62),
            imageView.heightAnchor.constraint(equalToConstant: side * 0.62),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}

private extension UIColor {

    func addingWhite(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(
            red: min(1, r + amount),
            green: min(1, g + amount),
            blue: min(1, b + amount),
            alpha: a
        )
    }
}
