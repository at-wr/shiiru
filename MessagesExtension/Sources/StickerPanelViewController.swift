import UIKit
import Messages

final class StickerPanelViewController: UIViewController {

    /// Telegram's entity keyboard exposes three content types.
    private enum Mode: Int { case emoji = 0, stickers = 1, gifs = 2 }
    private var mode: Mode = .stickers
    private var packsByMode: [Int: [LoadedPack]] = [:]
    private let typeSwitcher = EntityTypeSwitcher()
    private var manifestWatcher: DispatchSourceFileSystemObject?
    private var loadedManifestStamp: Date?

    var onOpenApp: (() -> Void)?
    var onSelectSticker: ((MSSticker) -> Void)?

    private var programmaticScrollTarget: Int?

    /// Only URLs and metadata are kept per sticker; decoding and MSSticker
    /// creation happen lazily so opening the panel stays cheap no matter
    /// how many packs are synced.
    private struct LoadedPack {
        struct Item {
            let url: URL
            let description: String
            let isAnimated: Bool
        }

        let pack: StickerManifest.Pack
        let items: [Item]
        var iconURL: URL? { items.first?.url }
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
        view.prefetchDataSource = self
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

        typeSwitcher.onSelect = { [weak self] tag in
            guard let self else { return }
            self.mode = Mode(rawValue: tag) ?? .stickers
            self.applyMode()
        }

        // The grid runs to the very bottom; the type switcher floats above
        // it on a blurred capsule, exactly like Telegram's entity keyboard —
        // stickers stay visible (and scroll) behind it instead of a dead
        // opaque strip being reserved.
        for subview in [grid, settingsButton, tabBar, separator, typeSwitcher] {
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

            typeSwitcher.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            typeSwitcher.heightAnchor.constraint(equalToConstant: 36),
            typeSwitcher.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            typeSwitcher.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// Keeps the last grid rows reachable above the floating switcher.
    private func updateGridInsets() {
        let bottom: CGFloat = typeSwitcher.isHidden ? 8 : 36 + 4 + 12
        guard grid.contentInset.bottom != bottom else { return }
        grid.contentInset.bottom = bottom
        grid.verticalScrollIndicatorInsets.bottom = bottom
    }

    /// Watches manifest.json so a logout / re-sync in the main app updates
    /// the panel even while Messages keeps this extension process alive.
    func startWatchingManifest() {
        manifestWatcher?.cancel()
        let fd = open(AppGroup.manifestURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadIfManifestChanged()
            // Recreate after delete/rename, which invalidates the descriptor.
            self?.startWatchingManifest()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        manifestWatcher = source
    }

    func reloadIfManifestChanged() {
        let manifest = SharedStickerStore.shared.loadManifest()
        guard manifest.updatedAt != loadedManifestStamp else { return }
        reload()
    }

    func reload() {
        let manifest = SharedStickerStore.shared.loadManifest()
        loadedManifestStamp = manifest.updatedAt

        let savedOrder = UserDefaults(suiteName: AppGroup.identifier)?
            .stringArray(forKey: "packOrder") ?? []
        let orderIndex = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
        let all: [LoadedPack] = manifest.packs
            .enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = orderIndex[lhs.element.id] ?? (1_000_000 + lhs.offset)
                let rhsOrder = orderIndex[rhs.element.id] ?? (1_000_000 + rhs.offset)
                return lhsOrder < rhsOrder
            }
            .map(\.element)
            .compactMap { pack in
                let items: [LoadedPack.Item] = pack.stickers.map { sticker in
                    LoadedPack.Item(
                        url: SharedStickerStore.shared.fileURL(pack: pack, sticker: sticker),
                        description: sticker.emoji.isEmpty ? pack.title : sticker.emoji,
                        isAnimated: sticker.isAnimated
                    )
                }
                guard !items.isEmpty else { return nil }
                return LoadedPack(pack: pack, items: items)
            }

        packsByMode = [
            Mode.emoji.rawValue: all.filter { $0.pack.packKind == "emoji" },
            Mode.stickers.rawValue: all.filter { $0.pack.packKind == "sticker" },
            Mode.gifs.rawValue: all.filter { $0.pack.packKind == "gif" },
        ]
        // Only synced categories appear, exactly like Telegram's panel.
        let available: [(String, Int)] = [
            ("Emoji", Mode.emoji.rawValue),
            ("Stickers", Mode.stickers.rawValue),
            ("GIFs", Mode.gifs.rawValue),
        ].filter { !(packsByMode[$0.1] ?? []).isEmpty }
        typeSwitcher.isHidden = available.count <= 1
        if !available.contains(where: { $0.1 == mode.rawValue }) {
            mode = Mode(rawValue: available.first?.1 ?? Mode.stickers.rawValue) ?? .stickers
        }
        typeSwitcher.setItems(available, selected: mode.rawValue)
        applyMode()
        let isEmpty = all.isEmpty
        emptyState.isHidden = !isEmpty
        tabBar.isHidden = isEmpty || mode == .gifs
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

    /// Swaps the visible content set and relayouts the grid for the mode —
    /// dense emoji cells, regular sticker cells, or Telegram's edge-to-edge
    /// three-column GIF mosaic.
    private func applyMode() {
        packs = packsByMode[mode.rawValue] ?? []
        tabBar.isHidden = mode == .gifs
        // Emoji cells insert via collection selection; sticker/GIF cells
        // route touches to their MSStickerView underlay instead.
        grid.allowsSelection = mode == .emoji
        grid.setCollectionViewLayout(makeGridLayout(), animated: false)
        tabBar.reloadData()
        grid.reloadData()
        updateGridInsets()
        if !packs.isEmpty {
            tabBar.selectItem(at: IndexPath(item: 0, section: 0), animated: false, scrollPosition: [])
        }
    }

    @objc private func openApp() {
        onOpenApp?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGridInsets()

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

    /// Approximate on-screen cell edge for the current mode, used to pick
    /// the thumbnail decode resolution.
    private var cellPointSide: CGFloat {
        switch mode {
        case .emoji: return 44
        case .stickers: return 92
        case .gifs: return 124
        }
    }

    private func makeGridLayout() -> UICollectionViewLayout {
        let mode = self.mode
        return UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            if mode == .gifs {
                // Telegram GIF mosaic: >=3 square columns, hairline gaps.
                let columns = max(3, Int(width / 120))
                let item = NSCollectionLayoutItem(layoutSize: .init(
                    widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                    heightDimension: .fractionalWidth(1.0 / CGFloat(columns))
                ))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0.5, leading: 0.5, bottom: 0.5, trailing: 0.5)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .fractionalWidth(1.0 / CGFloat(columns))
                    ),
                    subitems: [item]
                )
                return NSCollectionLayoutSection(group: group)
            }
            // Emoji uses Telegram's dense 8-per-row grid; stickers stay large.
            let columns = mode == .emoji ? max(8, Int(width / 44)) : max(3, Int(width / 92))
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

extension StickerPanelViewController: UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === tabBar ? 1 : packs.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === tabBar ? packs.count : packs[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === tabBar {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PackTabCell.reuseIdentifier, for: indexPath
            ) as! PackTabCell
            cell.configure(url: packs[indexPath.item].iconURL)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier, for: indexPath
        ) as! StickerCell
        let item = packs[indexPath.section].items[indexPath.item]
        cell.configure(
            url: item.url,
            description: item.description,
            animated: item.isAnimated,
            pixelSide: cellPointSide * UIScreen.main.scale,
            fillsCell: mode == .gifs,
            peelable: mode != .emoji
        )
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard collectionView === grid else { return }
        let pixelSide = cellPointSide * UIScreen.main.scale
        for indexPath in indexPaths {
            guard indexPath.section < packs.count,
                  indexPath.item < packs[indexPath.section].items.count else { continue }
            StickerPreview.thumbnail(
                for: packs[indexPath.section].items[indexPath.item].url,
                pixelSide: pixelSide
            ) { _ in }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? StickerCell)?.didBecomeVisible()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? StickerCell)?.didBecomeInvisible()
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
        if collectionView === grid {
            // Peelable modes disable selection: their MSStickerView underlay
            // owns tap-to-insert natively. This path serves the emoji grid.
            guard mode == .emoji else { return }
            let item = packs[indexPath.section].items[indexPath.item]
            guard let sticker = try? MSSticker(
                contentsOfFileURL: item.url, localizedDescription: item.description
            ) else { return }
            if let cell = collectionView.cellForItem(at: indexPath) {
                UIView.animate(withDuration: 0.1, animations: {
                    cell.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                }) { _ in
                    UIView.animate(
                        withDuration: 0.3, delay: 0,
                        usingSpringWithDamping: 0.6, initialSpringVelocity: 0
                    ) {
                        cell.transform = .identity
                    }
                }
            }
            onSelectSticker?(sticker)
            return
        }

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

    private let preview = StickerPreviewView(frame: .zero)
    /// Real MSStickerView underlay in peelable modes: it owns the native
    /// tap-to-insert and peel-and-place gestures, but stays visually hidden
    /// (alpha 0.02 keeps it hit-testable) so its buggy renderer — stale
    /// name-keyed preview cache, full-res frame decoding — never draws the
    /// grid. While a touch is down the underlay is revealed so the system's
    /// drag lift preview shows the real artwork.
    private var stickerView: MSStickerView?
    private lazy var touchWatcher: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(touchChanged(_:)))
        recognizer.minimumPressDuration = 0.01
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private static let hiddenAlpha: CGFloat = 0.02

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.frame = contentView.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(preview)
        contentView.addGestureRecognizer(touchWatcher)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        url: URL,
        description: String,
        animated: Bool,
        pixelSide: CGFloat,
        fillsCell: Bool,
        peelable: Bool
    ) {
        preview.contentModeFill = fillsCell
        preview.configure(url: url, pixelSide: pixelSide, animated: animated)

        stickerView?.removeFromSuperview()
        stickerView = nil
        guard peelable,
              let sticker = try? MSSticker(contentsOfFileURL: url, localizedDescription: description)
        else { return }
        let view = MSStickerView(frame: contentView.bounds, sticker: sticker)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.alpha = Self.hiddenAlpha
        contentView.insertSubview(view, belowSubview: preview)
        stickerView = view
    }

    @objc private func touchChanged(_ recognizer: UILongPressGestureRecognizer) {
        guard let stickerView else { return }
        switch recognizer.state {
        case .began:
            preview.isHidden = true
            stickerView.alpha = 1
        case .ended, .cancelled, .failed:
            preview.isHidden = false
            stickerView.alpha = Self.hiddenAlpha
        default:
            break
        }
    }

    func didBecomeVisible() {
        preview.resumeAnimationIfNeeded()
    }

    func didBecomeInvisible() {
        preview.pauseAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        preview.pauseAnimating()
        preview.isHidden = false
        stickerView?.removeFromSuperview()
        stickerView = nil
        transform = .identity
    }
}

extension StickerCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The touch watcher only mirrors touch state; it must never block
        // MSStickerView's tap/drag or the collection view's pan.
        true
    }
}

final class PackTabCell: UICollectionViewCell {
    static let reuseIdentifier = "PackTabCell"

    private let imageView = UIImageView()
    private var representedURL: URL?

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

    func configure(url: URL?) {
        representedURL = url
        imageView.image = nil
        guard let url else { return }
        StickerPreview.thumbnail(for: url, pixelSide: 88) { [weak self] image in
            guard let self, self.representedURL == url else { return }
            self.imageView.image = image
        }
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

/// Telegram-style entity-type switcher: a blurred capsule bar with a
/// sliding highlight pill behind the selected type (a reimplementation of
/// the look of Telegram's EntityKeyboardBottomPanel).
final class EntityTypeSwitcher: UIView {

    var onSelect: ((Int) -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let highlight = UIView()
    private var buttons: [UIButton] = []
    private var selectedTag = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.clipsToBounds = true
        addSubview(blur)
        highlight.backgroundColor = UIColor.tertiarySystemFill
        blur.contentView.addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [(String, Int)], selected: Int) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.map { title, tag in
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.tag = tag
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            blur.contentView.addSubview(button)
            return button
        }
        selectedTag = selected
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()
        refreshColors()
    }

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag != selectedTag else { return }
        selectedTag = sender.tag
        refreshColors()
        UIView.animate(
            withDuration: 0.35, delay: 0,
            usingSpringWithDamping: 0.8, initialSpringVelocity: 0
        ) {
            self.positionHighlight()
        }
        onSelect?(sender.tag)
    }

    private func refreshColors() {
        for button in buttons {
            button.setTitleColor(button.tag == selectedTag ? .label : .secondaryLabel, for: .normal)
        }
    }

    private func positionHighlight() {
        guard let selected = buttons.first(where: { $0.tag == selectedTag }) else { return }
        highlight.frame = selected.frame.insetBy(dx: 2, dy: 3)
        highlight.layer.cornerRadius = highlight.frame.height / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.layer.cornerRadius = bounds.height / 2
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
        positionHighlight()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: CGFloat(max(buttons.count, 1)) * 104, height: 36)
    }
}
