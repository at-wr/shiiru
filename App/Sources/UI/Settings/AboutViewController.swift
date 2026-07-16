import UIKit

final class AboutViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let mascot = AppIconMascotView(side: 150)

    private enum Row {
        case version
        case github
        case license
        case reportProblem
    }

    private let rows: [Row] = [.version, .github, .license, .reportProblem]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "About"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.background

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(IconRowCell.self, forCellReuseIdentifier: IconRowCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.tableHeaderView = makeHeader()
        tableView.preferSoftTopEdge()
        view.addSubview(tableView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.mascot.wave()
        }
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 320))

        let tile = UIView()
        tile.layer.shadowColor = UIColor(hex: 0x33306B).cgColor
        tile.layer.shadowOpacity = 0.25
        tile.layer.shadowRadius = 18
        tile.layer.shadowOffset = CGSize(width: 0, height: 8)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(iconTapped)))
        tile.addSubview(mascot)

        let name = NSMutableAttributedString(string: "Shiiru", attributes: [
            .font: UIFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: UIColor.label,
        ])
        name.append(NSAttributedString(string: " シール", attributes: [
            .font: UIFont.systemFont(ofSize: 30, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        let nameLabel = UILabel()
        nameLabel.attributedText = name
        nameLabel.textAlignment = .center

        let taglineLabel = UILabel()
        taglineLabel.text = "Your Telegram stickers in iMessage"
        taglineLabel.font = Theme.footnoteFont()
        taglineLabel.textColor = .secondaryLabel
        taglineLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [tile, nameLabel, taglineLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(18, after: tile)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 150),
            tile.heightAnchor.constraint(equalToConstant: 150),
            mascot.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            mascot.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 10),
        ])
        return header
    }

    @objc private func iconTapped() {
        Haptics.tap()
        mascot.wave()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Made with ♥ and TDLib."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: IconRowCell.reuseIdentifier, for: indexPath
        ) as! IconRowCell
        switch rows[indexPath.row] {
        case .version:
            cell.configure(
                icon: "number", color: UIColor(hex: 0x5856D6),
                title: "Version \(Bundle.main.appVersion)",
                accessory: .none
            )
        case .github:
            cell.configure(
                icon: "chevron.left.forwardslash.chevron.right", color: Theme.accent,
                title: "Source on GitHub",
                accessory: .disclosure
            )
        case .license:
            cell.configure(
                icon: "doc.text.fill", color: UIColor(hex: 0xFFC400),
                title: "GNU GPL v2.0 or later",
                accessory: .disclosure
            )
        case .reportProblem:
            cell.configure(
                icon: "exclamationmark.bubble.fill", color: UIColor(hex: 0xFF2D55),
                title: "Report a Problem",
                accessory: .disclosure
            )
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .version:
            UIPasteboard.general.string = "Shiiru \(Bundle.main.appVersion)"
            Haptics.success()
        case .github:
            UIApplication.shared.open(URL(string: "https://github.com/at-wr/shiiru")!)
        case .reportProblem:
            UIApplication.shared.open(URL(string: "https://github.com/at-wr/shiiru/issues")!)
        case .license:
            navigationController?.pushViewController(
                TextPageViewController(title: "GNU GPL v2.0 or later", text: OpenSourceLicenses.gplv2),
                animated: true
            )
        }
    }
}
