import UIKit

final class SetupRequiredViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let hero = UILabel()
        hero.text = "🛠️"
        hero.font = .systemFont(ofSize: 56)
        hero.textAlignment = .center

        let titleLabel = UILabel()
        titleLabel.text = "One More Step"
        titleLabel.font = Theme.largeTitleFont()
        titleLabel.textAlignment = .center

        let body = UILabel()
        body.numberOfLines = 0
        body.font = Theme.bodyFont()
        body.textColor = .secondaryLabel
        body.text = """
        Shiiru needs your own Telegram API credentials:

        1. Open my.telegram.org and log in
        2. Go to “API development tools” and create an app
        3. Copy api_id and api_hash into
           App/Sources/Config/TelegramConfig.swift
        4. Rebuild the app

        This keeps your Telegram session strictly between your device and Telegram.
        """

        let link = UIButton(type: .system)
        link.setTitle("Open my.telegram.org", for: .normal)
        link.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        link.addTarget(self, action: #selector(openLink), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [hero, titleLabel, body, link])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    @objc private func openLink() {
        UIApplication.shared.open(URL(string: "https://my.telegram.org")!)
    }
}
