import UIKit

final class AcknowledgementsViewController: UITableViewController {

    private struct Entry {
        let name: String
        let detail: String
        let license: String
        let licenseText: String
        let icon: String
        let color: UIColor
    }

    private let entries: [Entry] = [
        Entry(
            name: "TDLib",
            detail: "Telegram Database Library — the official client library that powers Shiiru's Telegram connection.",
            license: "Boost Software License 1.0",
            licenseText: OpenSourceLicenses.boost,
            icon: "paperplane.fill",
            color: UIColor(hex: 0x2AABEE)
        ),
        Entry(
            name: "TDLibKit",
            detail: "Swift wrapper around TDLib with generated APIs, by Swiftgram.",
            license: "MIT License",
            licenseText: OpenSourceLicenses.tdLibKitMIT,
            icon: "swift",
            color: UIColor(hex: 0xF05138)
        ),
        Entry(
            name: "Telegram iOS",
            detail: "The login monkey animations are the original TGS assets from the official Telegram-iOS app.",
            license: "GPL-2.0",
            licenseText: OpenSourceLicenses.telegramAssetsNote,
            icon: "app.grid",
            color: UIColor(hex: 0x8774E1)
        ),
        Entry(
            name: "libvpx",
            detail: "",
            license: "BSD-3-Clause",
            licenseText: OpenSourceLicenses.libvpxBSD,
            icon: "film.fill",
            color: UIColor(hex: 0x34C759)
        ),
        Entry(
            name: "PhoneNumberKit",
            detail: "",
            license: "MIT License",
            licenseText: OpenSourceLicenses.phoneNumberKitMIT,
            icon: "phone.fill",
            color: UIColor(hex: 0x5856D6)
        ),
        Entry(
            name: "Lottie",
            detail: "Airbnb's animation engine, used to render animated TGS stickers.",
            license: "Apache License 2.0",
            licenseText: OpenSourceLicenses.apache2,
            icon: "circle.dotted.and.circle",
            color: UIColor(hex: 0x00C2A8)
        ),
    ]

    init() {
        super.init(style: .insetGrouped)
        title = "Acknowledgements"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.preferSoftTopEdge()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = IconRowCell(style: .default, reuseIdentifier: nil)
        cell.configure(
            icon: entry.icon, color: entry.color,
            title: entry.name,
            accessory: .disclosure
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        navigationController?.pushViewController(
            TextPageViewController(title: entry.name, text: entry.licenseText),
            animated: true
        )
    }
}

/// License texts come pre-formatted to their own column width; re-wrapping
/// them to the screen mangles the layout. The text view is made as wide as
/// its longest line and keeps efficient vertical scrolling; an enclosing
/// scroll view pans horizontally, so nothing ever wraps.
final class TextPageViewController: UIViewController {
    private static let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private let text: String
    private let scrollView = UIScrollView()
    private let textView = UITextView()

    /// Longest-line width; explicit newlines are the only breaks.
    private lazy var unwrappedTextWidth: CGFloat = ceil((text as NSString).boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin],
        attributes: [.font: Self.font],
        context: nil
    ).width)

    init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        textView.text = text
        textView.font = Self.font
        textView.textColor = .label
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        textView.preferSoftTopEdge()
        scrollView.addSubview(textView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topInset = view.safeAreaInsets.top
        scrollView.frame = CGRect(
            x: 0, y: topInset,
            width: view.bounds.width, height: view.bounds.height - topInset
        )
        // Insets, line-fragment padding, and a little slack past the
        // longest line.
        let width = max(unwrappedTextWidth + 16 + 16 + 12, scrollView.bounds.width)
        textView.frame = CGRect(x: 0, y: 0, width: width, height: scrollView.bounds.height)
        scrollView.contentSize = CGSize(width: width, height: scrollView.bounds.height)
    }
}
