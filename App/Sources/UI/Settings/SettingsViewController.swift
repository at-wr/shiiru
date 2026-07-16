import UIKit

final class SettingsViewController: UITableViewController {

    private enum Row {
        case account
        case autoAdd
        case howTo
        case privacy
        case acknowledgements
        case about
        case clearSynced
        case logOut
    }

    private let sections: [(title: String?, rows: [Row])] = [
        (nil, [.account]),
        ("Stickers", [.autoAdd]),
        (nil, [.howTo, .privacy, .acknowledgements, .about]),
        (nil, [.clearSynced, .logOut]),
    ]

    init() {
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(IconRowCell.self, forCellReuseIdentifier: IconRowCell.reuseIdentifier)
        tableView.register(ProfileCell.self, forCellReuseIdentifier: ProfileCell.reuseIdentifier)
        tableView.preferSoftTopEdge()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section].rows.first {
        case .autoAdd:
            return "New packs added to your Telegram account will start syncing to iMessage automatically."
        case .clearSynced:
            return "Shiiru \(Bundle.main.appVersion)"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]

        if row == .account {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ProfileCell.reuseIdentifier, for: indexPath
            ) as! ProfileCell
            let user = TelegramService.shared.user
            var name = [user?.firstName, user?.lastName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            var phone = user.map { CountryCodes.formatInternational($0.phoneNumber) }
            var userID = user?.id
            if DemoSession.isActive {
                (name, phone, userID) = ("App Review", DemoSession.displayPhone, 1145)
            } else if PreviewMode.isActive, user == nil {
                (name, phone, userID) = ("Utya Duck", CountryCodes.formatInternational("15550123456"), 9001)
            }
            cell.configure(name: name, phone: phone, userID: userID)
            return cell
        }

        let cell = tableView.dequeueReusableCell(
            withIdentifier: IconRowCell.reuseIdentifier, for: indexPath
        ) as! IconRowCell

        switch row {
        case .account:
            break
        case .autoAdd:
            cell.configure(
                icon: "plus.circle.fill", color: UIColor(hex: 0x2AABEE),
                title: "Auto-Add New Packs",
                accessory: .toggle(isOn: Preferences.autoAddNewPacks) { enabled in
                    Preferences.autoAddNewPacks = enabled
                }
            )
        case .howTo:
            cell.configure(
                icon: "message.fill", color: UIColor(hex: 0x34C759),
                title: "How to Use in Messages",
                accessory: .disclosure
            )
        case .privacy:
            cell.configure(
                icon: "hand.raised.fill", color: UIColor(hex: 0x8E8E93),
                title: "Privacy Policy",
                accessory: .disclosure
            )
        case .acknowledgements:
            cell.configure(
                icon: "text.book.closed.fill", color: UIColor(hex: 0xFF9F0A),
                title: "Acknowledgements",
                accessory: .disclosure
            )
        case .about:
            cell.configure(
                icon: "info.circle.fill", color: UIColor(hex: 0x0079FF),
                title: "About Shiiru",
                accessory: .disclosure
            )
        case .clearSynced:
            cell.configure(
                icon: "trash.fill", color: UIColor(hex: 0xFF453A),
                title: "Remove All Synced Stickers",
                accessory: .none
            )
        case .logOut:
            cell.configure(
                icon: "rectangle.portrait.and.arrow.right.fill", color: UIColor(hex: 0xFF453A),
                title: "Log Out",
                titleColor: .systemRed,
                accessory: .none
            )
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .account, .autoAdd:
            break
        case .howTo:
            navigationController?.pushViewController(HowToViewController(), animated: true)
        case .privacy:
            navigationController?.pushViewController(PrivacyPolicyViewController(), animated: true)
        case .acknowledgements:
            navigationController?.pushViewController(AcknowledgementsViewController(), animated: true)
        case .about:
            navigationController?.pushViewController(AboutViewController(), animated: true)
        case .clearSynced:
            confirmClearSynced()
        case .logOut:
            confirmLogOut()
        }
    }

    private func confirmClearSynced() {
        let alert = UIAlertController(
            title: "Remove All Synced Stickers?",
            message: "Your packs stay in Telegram; this only clears them from iMessage.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Remove All", style: .destructive) { _ in
            SharedStickerStore.shared.removeAll()
            StickerSyncEngine.shared.resetAllPhases()
            Haptics.success()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmLogOut() {
        let alert = UIAlertController(
            title: "Log Out of Telegram?",
            message: "Synced stickers will also be removed from iMessage.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { _ in
            if DemoSession.isActive {
                DemoSession.deactivate()
                return
            }
            SharedStickerStore.shared.removeAll()
            StickerSyncEngine.shared.resetAllPhases()
            Task { await TelegramService.shared.logOut() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

extension Bundle {
    var appVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

final class HowToViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages Setup"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        let steps: [(String, String)] = [
            ("1", "Open Messages and go to any conversation."),
            ("2", "Tap the ‘+’ button next to the text field."),
            ("3", "Scroll to the bottom of the menu — newly installed iMessage apps like Shiiru appear last."),
            ("4", "Tap Shiiru, then tap a sticker to send it — or drag it onto any bubble."),
        ]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 22
        for (number, text) in steps {
            let badge = UILabel()
            badge.text = number
            badge.font = .systemFont(ofSize: 16, weight: .bold)
            badge.textColor = .white
            badge.textAlignment = .center
            badge.backgroundColor = Theme.accent
            badge.layer.cornerRadius = 14
            badge.clipsToBounds = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

            let label = UILabel()
            label.text = text
            label.font = Theme.bodyFont()
            label.numberOfLines = 0

            let row = UIStackView(arrangedSubviews: [badge, label])
            row.axis = .horizontal
            row.spacing = 14
            row.alignment = .top
            stack.addArrangedSubview(row)
        }

        let tip = UILabel()
        tip.text = "Tip: in the Messages app list, tap “Edit” to pin Shiiru to your favorites."
        tip.font = Theme.footnoteFont()
        tip.textColor = .secondaryLabel
        tip.numberOfLines = 0
        stack.addArrangedSubview(tip)

        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}
