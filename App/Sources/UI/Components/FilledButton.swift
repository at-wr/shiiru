import UIKit

final class FilledButton: UIControl {

    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var storedTitle = ""
    private var glassView: UIVisualEffectView?

    var title: String {
        get { storedTitle }
        set {
            storedTitle = newValue
            if !isLoading { titleLabel.text = newValue }
        }
    }

    private(set) var isLoading = false

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            effect.tintColor = Theme.accent
            let effectView = UIVisualEffectView(effect: effect)
            effectView.isUserInteractionEnabled = false
            insertSubview(effectView, at: 0)
            glassView = effectView
        } else {
            backgroundColor = Theme.accent
        }

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.buttonHeight),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(touchDown), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2
        glassView?.frame = bounds
    }

    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        isUserInteractionEnabled = !loading
        if loading {
            titleLabel.text = nil
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            titleLabel.text = storedTitle
        }
    }

    override var isEnabled: Bool {
        didSet {
            UIView.animate(withDuration: 0.2) {
                self.alpha = self.isEnabled ? 1 : 0.45
            }
        }
    }

    @objc private func touchDown() {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            self.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            self.alpha = 0.85
        }
    }

    @objc private func touchUp() {
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            self.transform = .identity
            self.alpha = self.isEnabled ? 1 : 0.45
        }
    }

    @objc private func tapped() {
        Haptics.tap()
        onTap?()
    }
}
