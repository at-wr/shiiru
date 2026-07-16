import UIKit
import Messages

final class StickerPanelViewController: UIViewController {

    var onOpenApp: (() -> Void)?

    private var programmaticScrollTarget: Int?

    private struct LoadedPack {
        let pack: StickerManifest.Pack
        let stickers: [MSSticker]
        let tabIcon: UIImage?
    }

    private var packs: [LoadedPack] = []
    private var selectedTabIndex = 0

    private let tabHighlight: UIView = {
        let view = UIView()
        view.backgroundColor = .tertiarySystemFill
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()

    private lazy var tabBar: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 44, height: 44)
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.register(PackTabCell.self, forCellWithReuseIdentifier: PackTabCell.reuseIdentifier)
        view.dataSource = self
        view.delegate = self

        view.insertSubview(tabHighlight, at: 0)
        return view
    }()

    private lazy var grid: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeGridLayout())
        view.backgroundColor = .clear
        view.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier)
        view.register(
            PackHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: PackHeaderView.reuseIdentifier
        )
        view.dataSource = self
        view.delegate = self
        view.preferSoftTopEdge()
        return view
    }()

    private let emptyState = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let separator = UIView()
        separator.backgroundColor = .separator

        let settingsButton = UIButton(type: .system)
        settingsButton.setImage(
            UIImage(named: "EntityInputSettingsIcon")?.withRenderingMode(.alwaysTemplate)
                ?? UIImage(systemName: "gearshape.fill"),
            for: .normal
        )
        settingsButton.tintColor = .secondaryLabel
        settingsButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        for subview in [settingsButton, tabBar, separator, grid] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        buildEmptyState()

        NSLayoutConstraint.activate([
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            settingsButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 40),
            settingsButton.heightAnchor.constraint(equalToConstant: 40),

            tabBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            tabBar.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 52),

            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            grid.topAnchor.constraint(equalTo: separator.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func reload() {
        let manifest = SharedStickerStore.shared.loadManifest()

        let savedOrder = UserDefaults(suiteName: AppGroup.identifier)?
            .stringArray(forKey: "packOrder") ?? []
        let orderIndex = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
        packs = manifest.packs
            .enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = orderIndex[lhs.element.id] ?? (1_000_000 + lhs.offset)
                let rhsOrder = orderIndex[rhs.element.id] ?? (1_000_000 + rhs.offset)
                return lhsOrder < rhsOrder
            }
            .map(\.element)
            .compactMap { pack in
                let stickers: [MSSticker] = pack.stickers.compactMap { sticker in
                    let url = SharedStickerStore.shared.fileURL(pack: pack, sticker: sticker)
                    let description = sticker.emoji.isEmpty ? pack.title : sticker.emoji
                    return try? MSSticker(contentsOfFileURL: url, localizedDescription: description)
                }
                guard !stickers.isEmpty else { return nil }
                let iconURL = SharedStickerStore.shared.fileURL(pack: pack, sticker: pack.stickers[0])
                let icon = UIImage(contentsOfFile: iconURL.path)?.scaledDown(to: 88)
                return LoadedPack(pack: pack, stickers: stickers, tabIcon: icon)
            }

        tabBar.reloadData()
        grid.reloadData()
        let isEmpty = packs.isEmpty
        emptyState.isHidden = !isEmpty
        tabBar.isHidden = isEmpty
        grid.isHidden = isEmpty
        if !isEmpty {
            tabBar.layoutIfNeeded()
            setSelectedTab(0, animated: false)
        } else {
            tabHighlight.isHidden = true
        }
    }

    private func setSelectedTab(_ index: Int, animated: Bool) {
        guard index < packs.count,
            let attributes = tabBar.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else {
            tabHighlight.isHidden = true
            return
        }
        selectedTabIndex = index
        let frame = attributes.frame
        let apply = { self.tabHighlight.frame = frame }

        if tabHighlight.isHidden || !animated {
            tabHighlight.isHidden = false
            apply()
        } else {
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction],
                animations: apply
            )
        }

        let itemSize: CGFloat = 44, itemSpacing: CGFloat = 6, sideInset: CGFloat = 10
        let reveal = frame.insetBy(dx: -(sideInset + (itemSize + itemSpacing) * 2), dy: 0)
        tabBar.scrollRectToVisible(reveal, animated: animated)
    }

    @objc private func openApp() {
        onOpenApp?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard !tabHighlight.isHidden,
              tabHighlight.layer.animationKeys() == nil,
              let attributes = tabBar.layoutAttributesForItem(
                  at: IndexPath(item: selectedTabIndex, section: 0)
              ),
              tabHighlight.frame != attributes.frame
        else { return }
        tabHighlight.frame = attributes.frame
    }

    private func buildEmptyState() {
        let emoji = UILabel()
        emoji.text = "🎨"
        emoji.font = .systemFont(ofSize: 44)
        emoji.textAlignment = .center

        let label = UILabel()
        label.text = "No stickers yet.\nOpen the Shiiru app, log in to Telegram,\nand switch on your favorite packs."
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        emptyState.axis = .vertical
        emptyState.spacing = 10
        emptyState.addArrangedSubview(emoji)
        emptyState.addArrangedSubview(label)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    private func makeGridLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, Int(width / 92))
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                heightDimension: .fractionalWidth(1.0 / CGFloat(columns))
            ))
            item.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalWidth(1.0 / CGFloat(columns))
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(28)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
    }
}

extension StickerPanelViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === tabBar ? 1 : packs.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === tabBar ? packs.count : packs[section].stickers.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === tabBar {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PackTabCell.reuseIdentifier, for: indexPath
            ) as! PackTabCell
            cell.configure(image: packs[indexPath.item].tabIcon)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier, for: indexPath
        ) as! StickerCell
        cell.configure(sticker: packs[indexPath.section].stickers[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: PackHeaderView.reuseIdentifier,
            for: indexPath
        ) as! PackHeaderView
        header.title = packs[indexPath.section].pack.title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === tabBar else { return }

        programmaticScrollTarget = indexPath.item
        setSelectedTab(indexPath.item, animated: true)
        let target = IndexPath(item: 0, section: indexPath.item)
        if let attributes = grid.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: target
        ) {
            grid.setContentOffset(CGPoint(x: 0, y: attributes.frame.minY - 2), animated: true)
        } else {
            programmaticScrollTarget = nil
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === grid { programmaticScrollTarget = nil }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === grid { programmaticScrollTarget = nil }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === grid, !packs.isEmpty, programmaticScrollTarget == nil else { return }

        let topSection = grid.indexPathsForVisibleItems.map(\.section).min() ?? 0
        if topSection != selectedTabIndex {
            setSelectedTab(topSection, animated: true)
        }
    }
}

final class StickerCell: UICollectionViewCell {
    static let reuseIdentifier = "StickerCell"

    private let stickerView = MSStickerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stickerView.frame = contentView.bounds
        stickerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(stickerView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(sticker: MSSticker) {
        stickerView.sticker = sticker
        stickerView.startAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stickerView.stopAnimating()
        stickerView.sticker = nil
    }
}

final class PackTabCell: UICollectionViewCell {
    static let reuseIdentifier = "PackTabCell"

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds.insetBy(dx: 6, dy: 6)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage?) {
        imageView.image = image
    }
}

final class PackHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "PackHeaderView"

    private let label = UILabel()

    var title: String? {
        get { label.text }
        set { label.text = newValue?.uppercased() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension UIImage {
    func scaledDown(to side: CGFloat) -> UIImage {
        guard max(size.width, size.height) > side else { return self }
        let ratio = side / max(size.width, size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
