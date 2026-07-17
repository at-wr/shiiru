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

    /// Telegram's top-panel metrics: 28 pt collapsed items that grow to
    /// 54×68 with titles while the row itself is being dragged
    /// (EntityKeyboardTopPanelComponent), collapsing 0.8 s after the drag.
    private static let collapsedTabSize = CGSize(width: 28, height: 28)
    private static let expandedTabSize = CGSize(width: 54, height: 68)
    private static let collapsedBarHeight: CGFloat = 40
    private static let expandedBarHeight: CGFloat = 76
    private static let tabRowSideInset: CGFloat = 4

    private var tabBarHeightConstraint: NSLayoutConstraint?
    private var tabBarExpanded = false
    private var tabCollapseTimer: Timer?

    private lazy var tabBar: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.collapsedTabSize
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(
            top: 6, left: Self.tabRowSideInset, bottom: 6, right: Self.tabRowSideInset
        )
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.register(PackTabCell.self, forCellWithReuseIdentifier: PackTabCell.reuseIdentifier)
        view.dataSource = self
        view.delegate = self

        view.insertSubview(tabHighlight, at: 0)
        return view
    }()

    /// Dragging the pack row grows its items (Telegram's expand-on-drag);
    /// it settles back down 0.8 s after the finger leaves.
    private func setTabBarExpanded(_ expanded: Bool) {
        guard tabBarExpanded != expanded,
              let layout = tabBar.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        tabBarExpanded = expanded

        // Cell x-positions change with the item size, but contentOffset
        // stays in old-geometry coordinates — uncompensated, the resize
        // visibly scrolls the row to unrelated packs. Anchor whatever pack
        // sits at the viewport's center through the change (Telegram's
        // draggingFocusItemIndex serves the same purpose).
        let sideInset = Self.tabRowSideInset
        let spacing = layout.minimumInteritemSpacing
        let oldSpan = layout.itemSize.width + spacing
        let newSize = expanded ? Self.expandedTabSize : Self.collapsedTabSize
        let newSpan = newSize.width + spacing
        let midX = tabBar.bounds.width / 2
        let anchor = max(0, (tabBar.contentOffset.x + midX - sideInset) / oldSpan)

        layout.itemSize = newSize
        layout.sectionInset.top = expanded ? 4 : 6
        layout.sectionInset.bottom = expanded ? 4 : 6
        tabBarHeightConstraint?.constant = expanded ? Self.expandedBarHeight : Self.collapsedBarHeight

        let count = CGFloat(max(packs.count, 1))
        let contentWidth = sideInset * 2 + count * newSpan - spacing
        let maxOffset = max(0, contentWidth - tabBar.bounds.width)
        let target = min(max(0, sideInset + anchor * newSpan - midX), maxOffset)

        UIView.animate(
            withDuration: 0.3, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            layout.invalidateLayout()
            self.tabBar.contentOffset = CGPoint(x: target, y: 0)
            self.tabBar.layoutIfNeeded()
            self.view.layoutIfNeeded()
            self.updateGridInsets()
        }
    }

    private func scheduleTabBarCollapse() {
        tabCollapseTimer?.invalidate()
        tabCollapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.setTabBarExpanded(false)
        }
    }

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

    /// The strip region adds no material of its own: Messages already
    /// backs the whole drawer with a translucent system backdrop, and any
    /// extra layer reads as an opaque band against it. The grid starts
    /// below the separator instead of passing under the row, so stickers
    /// never show through either.
    private let bottomFade = BottomEdgeFadeView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let separator = UIView()
        separator.backgroundColor = .separator

        let settingsButton = UIButton(type: .system)
        // Drawn at the collapsed pack-thumbnail scale (24 pt art in 28 pt
        // cells) so the gear doesn't dwarf the row; the 40 pt button keeps
        // the hit target.
        let rawIcon = UIImage(named: "EntityInputSettingsIcon")
            ?? UIImage(systemName: "gearshape.fill")!
        let iconSide: CGFloat = 22
        let icon = UIGraphicsImageRenderer(size: CGSize(width: iconSide, height: iconSide))
            .image { _ in
                rawIcon.draw(in: CGRect(x: 0, y: 0, width: iconSide, height: iconSide))
            }
            .withRenderingMode(.alwaysTemplate)
        settingsButton.setImage(icon, for: .normal)
        settingsButton.tintColor = .secondaryLabel
        settingsButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        typeSwitcher.onSelect = { [weak self] tag in
            guard let self else { return }
            self.mode = Mode(rawValue: tag) ?? .stickers
            self.applyMode()
        }

        // The grid runs to the very bottom; the type switcher floats above
        // it on a glass capsule, exactly like Telegram's entity keyboard —
        // stickers stay visible (and scroll) behind it instead of a dead
        // opaque strip being reserved.
        for subview in [grid, bottomFade, settingsButton, tabBar, separator, typeSwitcher] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        buildEmptyState()

        let barHeight = tabBar.heightAnchor.constraint(equalToConstant: Self.collapsedBarHeight)
        tabBarHeightConstraint = barHeight
        barHeight.isActive = true

        NSLayoutConstraint.activate([
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            settingsButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            // Narrow enough that the gear sits close to the first pack;
            // the full-height button keeps the touch target comfortable.
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 40),

            // Clear breathing room under Messages' grabber pill — flush
            // against it, drags on the pack row kept triggering the
            // expand-to-fullscreen gesture instead.
            tabBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            tabBar.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            grid.topAnchor.constraint(equalTo: separator.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bottomFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomFade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: 80),

            typeSwitcher.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            typeSwitcher.heightAnchor.constraint(equalToConstant: 40),
            typeSwitcher.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            typeSwitcher.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// Keeps the last grid rows reachable above the floating switcher.
    private func updateGridInsets() {
        let bottom: CGFloat = typeSwitcher.isHidden ? 8 : 40 + 4 + 12
        bottomFade.isHidden = typeSwitcher.isHidden
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
        // Only synced categories appear, in Telegram's pane order
        // (EntityKeyboard.swift appends gifs, stickers, emoji).
        let available: [(String, Int)] = [
            ("GIFs", Mode.gifs.rawValue),
            ("Stickers", Mode.stickers.rawValue),
            ("Emoji", Mode.emoji.rawValue),
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

    /// The highlight pill hugs the thumbnail (3 pt of air instead of the
    /// full cell) so the selection doesn't look like a loose box.
    private func highlightFrame(for attributes: UICollectionViewLayoutAttributes) -> CGRect {
        attributes.frame.insetBy(dx: 2, dy: 2)
    }

    private func setSelectedTab(_ index: Int, animated: Bool) {
        guard index < packs.count,
            let attributes = tabBar.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else {
            tabHighlight.isHidden = true
            return
        }
        selectedTabIndex = index
        let frame = highlightFrame(for: attributes)
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

        let layout = tabBar.collectionViewLayout as? UICollectionViewFlowLayout
        let span = (layout?.itemSize.width ?? 28) + (layout?.minimumInteritemSpacing ?? 6)
        let reveal = attributes.frame.insetBy(dx: -(Self.tabRowSideInset + span * 2), dy: 0)
        tabBar.scrollRectToVisible(reveal, animated: animated)
    }

    /// Swaps the visible content set and relayouts the grid for the mode —
    /// dense emoji cells, regular sticker cells, or Telegram's edge-to-edge
    /// three-column GIF mosaic.
    private func applyMode() {
        packs = packsByMode[mode.rawValue] ?? []
        tabBar.isHidden = mode == .gifs
        // Every mode routes touches to the cells' MSStickerView underlay —
        // native tap-to-insert and peel-and-place, emoji included.
        grid.allowsSelection = false
        grid.setCollectionViewLayout(makeGridLayout(), animated: false)
        tabBar.reloadData()
        grid.reloadData()
        updateGridInsets()
        // A scroll position carried over from the previous mode would leave
        // the new list starting mid-content, its top rows hidden under the
        // header bar.
        grid.layoutIfNeeded()
        grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
        if !packs.isEmpty {
            tabBar.selectItem(at: IndexPath(item: 0, section: 0), animated: false, scrollPosition: [])
        }
    }

    @objc private func openApp() {
        onOpenApp?()
    }

    /// Messages assembles the extension off-window and attaches it late;
    /// re-poke the visible cells once presentation settles so no animation
    /// is left waiting on a lifecycle callback that already fired.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for cell in grid.visibleCells {
            (cell as? StickerCell)?.didBecomeVisible()
        }
        installUnderlaysOnVisibleCells()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGridInsets()

        guard !tabHighlight.isHidden,
              tabHighlight.layer.animationKeys() == nil,
              let attributes = tabBar.layoutAttributesForItem(
                  at: IndexPath(item: selectedTabIndex, section: 0)
              ),
              tabHighlight.frame != highlightFrame(for: attributes)
        else { return }
        tabHighlight.frame = highlightFrame(for: attributes)
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
            cell.configure(url: packs[indexPath.item].iconURL, title: packs[indexPath.item].pack.title)
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
            peelable: true
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
        guard let cell = cell as? StickerCell else { return }
        cell.didBecomeVisible()
        // At rest (initial fill, small adjustments) install the underlay
        // right away; during drags/jumps it waits for the scroll to settle.
        if !gridIsScrolling {
            cell.installUnderlayIfNeeded()
        }
    }

    private var gridIsScrolling: Bool {
        grid.isDragging || grid.isDecelerating || programmaticScrollTarget != nil
    }

    private func installUnderlaysOnVisibleCells() {
        for cell in grid.visibleCells {
            (cell as? StickerCell)?.installUnderlayIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === grid { installUnderlaysOnVisibleCells() }
        if scrollView === tabBar { scheduleTabBarCollapse() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if scrollView === grid, !willDecelerate { installUnderlaysOnVisibleCells() }
        if scrollView === tabBar, !willDecelerate { scheduleTabBarCollapse() }
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
        guard collectionView === tabBar else { return }

        programmaticScrollTarget = indexPath.item
        setSelectedTab(indexPath.item, animated: true)
        let target = IndexPath(item: 0, section: indexPath.item)
        if let attributes = grid.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: target
        ) {
            // Content scrolls under the translucent tab strip, so the top
            // inset must be subtracted for the header to land below it.
            // setContentOffset does not clamp: an unclamped jump to a short
            // last pack parks the grid overscrolled past the content edge.
            let inset = grid.adjustedContentInset
            let minY = -inset.top
            let maxY = max(minY, grid.contentSize.height + inset.bottom - grid.bounds.height)
            let y = min(max(attributes.frame.minY - inset.top - 2, minY), maxY)
            grid.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            programmaticScrollTarget = nil
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === grid {
            programmaticScrollTarget = nil
            installUnderlaysOnVisibleCells()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === grid { programmaticScrollTarget = nil }
        if scrollView === tabBar {
            tabCollapseTimer?.invalidate()
            setTabBarExpanded(true)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === grid, !packs.isEmpty, programmaticScrollTarget == nil else { return }

        // Rows behind the translucent tab strip don't count as "on top".
        let topEdge = grid.contentOffset.y + grid.adjustedContentInset.top
        let topSection = grid.indexPathsForVisibleItems
            .filter { (grid.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > topEdge }
            .map(\.section).min() ?? 0
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

    private var pendingUnderlay: (url: URL, description: String)?

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
        // MSSticker validates the file and MSStickerView sets up its
        // renderer — both main-thread work that made pack jumps stutter
        // when every transit cell paid it. Cells fill with the cheap
        // preview only; the underlay installs once scrolling settles.
        pendingUnderlay = peelable ? (url, description) : nil
    }

    /// Creates the hit-testable MSStickerView underlay (tap-to-insert and
    /// peel live there). Called when the grid is at rest.
    func installUnderlayIfNeeded() {
        guard let pending = pendingUnderlay, stickerView == nil,
              let sticker = try? MSSticker(
                  contentsOfFileURL: pending.url, localizedDescription: pending.description
              )
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
        pendingUnderlay = nil
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
    private let titleLabel = UILabel()
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        // Telegram's expanded top-panel item: 10 pt title under the icon,
        // visible only while the row is enlarged.
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alpha = 0
        contentView.addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Square cells are the collapsed style; the taller expanded cell
        // stacks the title beneath the artwork.
        let expanded = bounds.height > bounds.width + 4
        if expanded {
            imageView.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.width - 4)
            titleLabel.frame = CGRect(x: 1, y: bounds.width + 1, width: bounds.width - 2, height: 12)
            titleLabel.alpha = 1
        } else {
            imageView.frame = bounds.insetBy(dx: 2, dy: 2)
            titleLabel.alpha = 0
        }
    }

    func configure(url: URL?, title: String) {
        titleLabel.text = title
        representedURL = url
        imageView.image = nil
        guard let url else { return }
        StickerPreview.thumbnail(for: url, pixelSide: 160) { [weak self] image in
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

/// Telegram-style entity-type switcher: a floating glass capsule with a
/// sliding highlight pill behind the selected type — the look of Telegram's
/// EntityKeyboardBottomPanel, on iOS 26 built from real liquid glass
/// (UIGlassEffect), earlier from a chrome-material blur.
final class EntityTypeSwitcher: UIView {

    var onSelect: ((Int) -> Void)?

    private let background: UIVisualEffectView = {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            let view = UIVisualEffectView(effect: glass)
            view.cornerConfiguration = .capsule()
            return view
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        view.clipsToBounds = true
        return view
    }()
    private let highlight = UIView()
    private var buttons: [UIButton] = []
    private var itemWidths: [CGFloat] = []
    private var selectedTag = 1

    /// Telegram's bottom-panel tab typography: medium 14 pt labels with
    /// 12 pt of horizontal padding each side (BottomPanelIconComponent).
    private static let font = UIFont.systemFont(ofSize: 14, weight: .medium)
    private static let itemPadding: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(background)
        // Telegram's resting-lens tint (LiquidLensView fallback blob).
        highlight.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.1)
                : UIColor(white: 0.0, alpha: 0.075)
        }
        highlight.isUserInteractionEnabled = false
        background.contentView.addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [(String, Int)], selected: Int) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.map { title, tag in
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = Self.font
            button.tag = tag
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            background.contentView.addSubview(button)
            return button
        }
        itemWidths = items.map { title, _ in
            ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + Self.itemPadding
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
            withDuration: 0.4, delay: 0,
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
        highlight.frame = selected.frame.insetBy(dx: 3, dy: 3)
        highlight.layer.cornerRadius = highlight.frame.height / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if #unavailable(iOS 26.0) {
            background.layer.cornerRadius = bounds.height / 2
        }
        guard !buttons.isEmpty else { return }
        let total = itemWidths.reduce(0, +)
        let scale = total > 0 ? min(1, bounds.width / total) : 1
        var x: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            let width = itemWidths[index] * scale
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        positionHighlight()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: max(itemWidths.reduce(0, +), 96), height: 40)
    }
}

/// A solid color masked by a vertical alpha ramp so grid content dissolves
/// under the floating switcher instead of hard-clipping — the look of
/// Telegram's EdgeEffect behind its bottom panel (80 pt tall, the ramp
/// finishing 50 pt from the edge, panel color at 0.8 alpha).
final class BottomEdgeFadeView: UIView {

    private let ramp = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        ramp.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        ramp.locations = [0, 0.62]
        layer.mask = ramp
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ramp.frame = bounds
        CATransaction.commit()
    }
}
