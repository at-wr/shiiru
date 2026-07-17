import UIKit
import Lottie

final class PackCell: UITableViewCell {

    static let reuseIdentifier = "PackCell"

    var onToggle: ((Bool) -> Void)?

    var representedID: String?

    private let thumbnailView = UIImageView()
    private let animationView = LottieAnimationView()
    private let titleLabel = UILabel()
    private let newBadge = PaddedLabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let syncSwitch = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        thumbnailView.backgroundColor = .clear
        thumbnailView.layer.cornerRadius = 12
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.clipsToBounds = true
        thumbnailView.contentMode = .scaleAspectFit

        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.backgroundBehavior = .pauseAndRestore
        animationView.frame = thumbnailView.bounds
        animationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        thumbnailView.addSubview(animationView)

        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncSwitch.setContentHuggingPriority(.required, for: .horizontal)
        syncSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)

        progressView.trackTintColor = Theme.background
        progressView.progressTintColor = Theme.accent
        progressView.isHidden = true

        syncSwitch.addTarget(self, action: #selector(toggled), for: .valueChanged)

        newBadge.text = "NEW"
        newBadge.font = .systemFont(ofSize: 11, weight: .bold)
        newBadge.textColor = .white
        newBadge.backgroundColor = Theme.accent
        newBadge.layer.cornerRadius = 7
        newBadge.layer.cornerCurve = .continuous
        newBadge.clipsToBounds = true
        newBadge.isHidden = true
        newBadge.setContentHuggingPriority(.required, for: .horizontal)
        newBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, newBadge, UIView()])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleRow, statusLabel, progressView])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setCustomSpacing(6, after: statusLabel)

        let row = UIStackView(arrangedSubviews: [thumbnailView, textStack, syncSwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 52),
            thumbnailView.heightAnchor.constraint(equalToConstant: 52),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        animationView.stop()
        animationView.animation = nil
        representedID = nil
        onToggle = nil
    }

    private var subtitle = ""

    func configure(title: String, subtitle: String, phase: StickerSyncEngine.Phase, isNew: Bool = false) {
        titleLabel.text = title
        newBadge.isHidden = !isNew
        self.subtitle = subtitle
        apply(phase: phase)
    }

    /// Lightweight path for sync progress ticks: touches only the status
    /// line, progress bar, and switch — never the thumbnail, so covers
    /// don't reload (and flash) on every tick.
    func update(phase: StickerSyncEngine.Phase) {
        apply(phase: phase)
    }

    private func apply(phase: StickerSyncEngine.Phase) {
        switch phase {
        case .idle:
            statusLabel.text = subtitle
            statusLabel.textColor = .secondaryLabel
            progressView.isHidden = true
            syncSwitch.setOn(false, animated: true)
            syncSwitch.isEnabled = true
        case .syncing(let progress):
            statusLabel.text = "Syncing…"
            statusLabel.textColor = Theme.accent
            progressView.isHidden = false
            progressView.setProgress(Float(progress), animated: true)
            syncSwitch.setOn(true, animated: true)
            syncSwitch.isEnabled = true
        case .synced:
            statusLabel.text = "In iMessage · \(subtitle)"
            statusLabel.textColor = .secondaryLabel
            progressView.isHidden = true
            syncSwitch.setOn(true, animated: true)
            syncSwitch.isEnabled = true
        case .failed(let message):
            statusLabel.text = "Failed: \(message)"
            statusLabel.textColor = .systemRed
            progressView.isHidden = true
            syncSwitch.setOn(false, animated: true)
            syncSwitch.isEnabled = true
        }
    }

    func setThumbnail(_ image: UIImage?) {
        guard let image, animationView.animation == nil else { return }
        // Re-configures fire on every sync progress tick; only transition
        // when the image actually changes (covers are NSCache'd instances).
        guard thumbnailView.image !== image else { return }
        UIView.transition(with: thumbnailView, duration: 0.2, options: .transitionCrossDissolve) {
            self.thumbnailView.image = image
        }
    }

    func setAnimatedThumbnail(_ animation: LottieAnimation?) {
        guard let animation else { return }
        // Same animation already installed: leave it playing untouched —
        // resetting it every phase update made covers flash and restart.
        if animationView.animation === animation {
            if !animationView.isAnimationPlaying { animationView.play() }
            return
        }
        // Keep the static cover visible underneath while the animation
        // fades in, so the handoff never blanks the cell.
        animationView.animation = animation
        animationView.alpha = 0
        animationView.play()
        UIView.animate(withDuration: 0.2) {
            self.animationView.alpha = 1
        } completion: { _ in
            self.thumbnailView.image = nil
        }
    }

    @objc private func toggled() {
        Haptics.tap()
        onToggle?(syncSwitch.isOn)
    }
}

final class PaddedLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 6, dy: 2))
    }
}
