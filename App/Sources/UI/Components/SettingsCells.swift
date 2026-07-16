import UIKit

final class IconRowCell: UITableViewCell {
    static let reuseIdentifier = "IconRowCell"

    enum Accessory {
        case disclosure
        case toggle(isOn: Bool, onChange: (Bool) -> Void)
        case none
    }

    private var onToggle: ((Bool) -> Void)?
    private let toggle = UISwitch()
    private let titleLabel = UILabel()
    private var tile: IconTileView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        toggle.addTarget(self, action: #selector(switched), for: .valueChanged)

        titleLabel.font = .systemFont(ofSize: 17)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        icon: String,
        color: UIColor,
        title: String,
        titleColor: UIColor = .label,
        accessory: Accessory
    ) {
        titleLabel.text = title
        titleLabel.textColor = titleColor

        tile?.removeFromSuperview()
        let newTile = IconTileView(systemName: icon, color: color)
        tile = newTile
        contentView.addSubview(newTile)
        NSLayoutConstraint.activate([
            newTile.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            newTile.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        switch accessory {
        case .disclosure:
            accessoryType = .disclosureIndicator
            accessoryView = nil
            selectionStyle = .default
        case .toggle(let isOn, let onChange):
            toggle.isOn = isOn
            onToggle = onChange
            accessoryView = toggle
            accessoryType = .none
            selectionStyle = .none
        case .none:
            accessoryType = .none
            accessoryView = nil
            selectionStyle = .default
        }
    }

    @objc private func switched() {
        Haptics.tap()
        onToggle?(toggle.isOn)
    }
}

final class ProfileCell: UITableViewCell {
    static let reuseIdentifier = "ProfileCell"

    private static let gradientPalette: [(top: UIColor, bottom: UIColor)] = [
        (UIColor(hex: 0xFF885E), UIColor(hex: 0xFF516A)),
        (UIColor(hex: 0xFFCD6A), UIColor(hex: 0xFFA85C)),
        (UIColor(hex: 0x82B1FF), UIColor(hex: 0x665FFF)),
        (UIColor(hex: 0xA0DE7E), UIColor(hex: 0x54CB68)),
        (UIColor(hex: 0x00FCFD), UIColor(hex: 0x4ACCCD)),
        (UIColor(hex: 0x72D5FD), UIColor(hex: 0x2A9EF1)),
        (UIColor(hex: 0xE0A2F3), UIColor(hex: 0xD669ED)),
    ]

    private static let emptyGradient = (top: UIColor(hex: 0xCDCDCD), bottom: UIColor(hex: 0xB1B1B1))

    private let avatarView = UIView()
    private let initialsLabel = UILabel()
    private let avatarImageView = UIImageView()
    private let avatarGradient = CAGradientLayer()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private var avatarLoadID = UUID()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        avatarGradient.startPoint = CGPoint(x: 0.5, y: 0)
        avatarGradient.endPoint = CGPoint(x: 0.5, y: 1)
        avatarGradient.colors = [
            Self.emptyGradient.top.cgColor,
            Self.emptyGradient.bottom.cgColor,
        ]

        let base = UIFont.systemFont(ofSize: 26, weight: .bold)
        initialsLabel.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 26) } ?? base
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        initialsLabel.text = "?"

        avatarView.backgroundColor = Self.emptyGradient.bottom
        avatarView.layer.insertSublayer(avatarGradient, at: 0)
        avatarView.layer.cornerRadius = 30
        avatarView.clipsToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.isHidden = true
        avatarView.addSubview(initialsLabel)
        avatarView.addSubview(avatarImageView)

        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textStack])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 60),
            avatarView.heightAnchor.constraint(equalToConstant: 60),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatarGradient.frame = avatarView.bounds
        CATransaction.commit()
        initialsLabel.frame = avatarView.bounds
        avatarImageView.frame = avatarView.bounds
        avatarImageView.layer.cornerRadius = avatarView.bounds.width / 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarLoadID = UUID()
        avatarImageView.image = nil
        avatarImageView.isHidden = true
        avatarImageView.alpha = 1
        initialsLabel.text = "?"
        applyGradient(Self.emptyGradient)
    }

    func configure(name: String, phone: String?, userID: Int64?) {
        nameLabel.text = name.isEmpty ? "Telegram Account" : name
        detailLabel.text = phone

        let pair = userID.map { Self.gradientPalette[abs(Int(clamping: $0)) % Self.gradientPalette.count] }
            ?? Self.emptyGradient
        applyGradient(pair)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first)
        let initialsText = String(initials).uppercased()
        initialsLabel.text = initialsText.isEmpty ? "?" : initialsText

        if let cached = TelegramService.shared.cachedAvatarImage {
            avatarImageView.image = cached
            avatarImageView.alpha = 1
            avatarImageView.isHidden = false
            return
        }

        avatarImageView.image = nil
        avatarImageView.isHidden = true
        avatarImageView.alpha = 1
        let loadID = UUID()
        avatarLoadID = loadID
        Task { [weak self] in
            guard let image = await TelegramService.shared.avatarImage() else { return }
            guard let self, self.avatarLoadID == loadID else { return }
            self.avatarImageView.image = image
            self.avatarImageView.isHidden = false
            self.avatarImageView.alpha = 0
            UIView.animate(withDuration: 0.2) { self.avatarImageView.alpha = 1 }
        }
    }

    private func applyGradient(_ pair: (top: UIColor, bottom: UIColor)) {
        avatarView.backgroundColor = pair.bottom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatarGradient.colors = [pair.top.cgColor, pair.bottom.cgColor]
        CATransaction.commit()
    }
}
