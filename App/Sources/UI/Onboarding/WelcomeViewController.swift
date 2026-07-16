import UIKit

final class WelcomeViewController: UIViewController {

    var onContinue: (() -> Void)?

    private let mascot = AppIconMascotView(side: 128)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = NSMutableAttributedString(string: "Shiiru", attributes: [
            .font: UIFont.systemFont(ofSize: 40, weight: .bold),
            .foregroundColor: UIColor.label,
        ])
        title.append(NSAttributedString(string: " シール", attributes: [
            .font: UIFont.systemFont(ofSize: 40, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        let titleLabel = UILabel()
        titleLabel.attributedText = title
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Your Telegram stickers,\nright inside iMessage."
        subtitleLabel.font = Theme.bodyFont()
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let steps = UIStackView(arrangedSubviews: [
            makeFeatureRow(
                icon: "paperplane.fill", color: UIColor(hex: 0x2AABEE),
                title: "Log in with Telegram",
                detail: "Directly from your device — nothing in between."
            ),
            makeFeatureRow(
                icon: "square.grid.2x2.fill", color: UIColor(hex: 0x34C759),
                title: "Pick your packs",
                detail: "Static and animated stickers, converted for iMessage."
            ),
            makeFeatureRow(
                icon: "message.fill", color: UIColor(hex: 0xFF9F0A),
                title: "Send from Messages",
                detail: "Tap to send, or peel and drop onto any bubble."
            ),
        ])
        steps.axis = .vertical
        steps.spacing = 20

        let button = FilledButton()
        button.title = "Connect Telegram"
        button.onTap = { [weak self] in self?.onContinue?() }

        let mascotContainer = UIStackView(arrangedSubviews: [mascot])
        mascotContainer.axis = .vertical
        mascotContainer.alignment = .center

        let stack = UIStackView(arrangedSubviews: [mascotContainer, titleLabel, subtitleLabel, steps, button])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: mascotContainer)
        stack.setCustomSpacing(30, after: subtitleLabel)
        stack.setCustomSpacing(34, after: steps)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])

        for (index, animatedView) in stack.arrangedSubviews.enumerated() {
            animatedView.alpha = 0
            animatedView.transform = CGAffineTransform(translationX: 0, y: 20)
            UIView.animate(
                withDuration: 0.6,
                delay: 0.1 + 0.07 * Double(index),
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                animatedView.alpha = 1
                animatedView.transform = .identity
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.mascot.wave()
        }
    }

    private func makeFeatureRow(icon: String, color: UIColor, title: String, detail: String) -> UIView {
        let tile = IconTileView(systemName: icon, color: color)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [tile, textStack])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        return row
    }
}
