import UIKit
import Combine
import TDLibKit

final class PacksViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let refreshControl = UIRefreshControl()
    private let emptyStateView = EmptyStateView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)

    private var sets: [StickerSetInfo] = []
    private var emojiSets: [StickerSetInfo] = []
    private var gifCount = 0
    private var gifCoverFile: File?
    /// Synced packs that no longer exist in the user's Telegram account
    /// (deleted or archived there). They stay usable in iMessage, so they
    /// stay visible here — in their own section — until switched off.
    private var orphanedPacks: [StickerManifest.Pack] = []
    private let kindSwitcher = UISegmentedControl(items: ["Stickers", "Emoji", "GIFs"])
    private var currentKind: Int { kindSwitcher.selectedSegmentIndex }
    private var visibleSets: [StickerSetInfo] { currentKind == 1 ? emojiSets : sets }
    private var visibleOrphans: [StickerManifest.Pack] {
        let kind = currentKind == 1 ? "emoji" : "sticker"
        return currentKind == 2 ? [] : orphanedPacks.filter { $0.packKind == kind }
    }

    private var newPackIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private let sync = StickerSyncEngine.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "My Stickers"
        view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(
                    title: "Sync All Packs",
                    image: UIImage(systemName: "square.and.arrow.down.on.square")
                ) { [weak self] _ in self?.syncAll() },
                UIAction(
                    title: "Remove All from iMessage",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmRemoveAll() },
            ])
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.register(PackCell.self, forCellReuseIdentifier: PackCell.reuseIdentifier)
        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 80, bottom: 0, right: 0)
        kindSwitcher.selectedSegmentIndex =
            (0..<kindSwitcher.numberOfSegments).contains(Preferences.packListKind)
                ? Preferences.packListKind : 0
        kindSwitcher.addTarget(self, action: #selector(kindChanged), for: .valueChanged)
        let header = SwitcherHeaderView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        header.install(kindSwitcher)
        tableView.tableHeaderView = header

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.preferSoftTopEdge()
        view.addSubview(tableView)

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.refreshControl = refreshControl

        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateView)

        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingSpinner)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        sync.$phases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadVisibleRows() }
            .store(in: &cancellables)

        // The moment TDLib's connection comes up, re-run cover loading for
        // anything that raced ahead of it on first login.
        TelegramService.shared.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &cancellables)

        loadingSpinner.startAnimating()
        Task { await load() }
    }

    private func confirmRemoveAll() {
        let alert = UIAlertController(
            title: "Remove All Synced Stickers?",
            message: "Your packs stay in Telegram; this only clears them from iMessage.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Remove All", style: .destructive) { [weak self] _ in
            SharedStickerStore.shared.removeAll()
            StickerSyncEngine.shared.resetAllPhases()
            self?.orphanedPacks = []
            self?.tableView.reloadData()
            Haptics.success()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func syncAll() {
        Haptics.tap()
        for info in sets + emojiSets where sync.phase(for: info.id) == .idle {
            if DemoSession.isActive {
                DemoSession.setPack(id: String(info.id.rawValue), enabled: true)
            } else {
                sync.setSyncEnabled(true, for: info)
            }
        }
        newPackIDs.removeAll()
        tableView.reloadData()
    }

    @objc private func refresh() {
        Task { await load() }
    }

    private func load() async {
        do {
            let wasEmpty = sets.isEmpty
            let fetched: [StickerSetInfo]
            if DemoSession.isActive {
                fetched = DemoSession.sampleSets
            } else if PreviewMode.isActive {
                PreviewMode.preparePreferences()
                fetched = PreviewMode.sampleSets
            } else {
                // Right after onboarding the session may still be settling;
                // fetching through that window returns lists whose cover
                // files aren't downloadable yet.
                _ = await TelegramService.shared.waitUntilReady(timeout: 10)
                fetched = try await TelegramService.shared.installedStickerSets()
            }
            sets = arrange(fetched)
            let fetchedEmoji = try? await TelegramService.shared.customEmojiSets()
            emojiSets = fetchedEmoji ?? []
            let animations = (try? await TelegramService.shared.savedAnimations()) ?? []
            gifCount = animations.count
            gifCoverFile = animations.first?.thumbnail?.file
            refreshOrphans(fetched: fetched, fetchedEmoji: fetchedEmoji)
            sync.prefetchCovers(for: sets)
            reconvertStalePacks()
            // Author-side pack edits (stickers added/removed/reordered)
            // apply on open too, not only in the nightly window.
            BackgroundMaintenance.runCheck()
            tableView.reloadData()
            emptyStateView.isHidden = !sets.isEmpty
            if wasEmpty, !sets.isEmpty {
                animateFirstAppearance()
            }
        } catch {
            let alert = UIAlertController(
                title: "Couldn't Load Stickers",
                message: error.telegramFriendlyMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        loadingSpinner.stopAnimating()
        refreshControl.endRefreshing()
    }

    /// Diffs the synced store against what Telegram reports as installed.
    /// Only kinds whose fetch actually succeeded participate, so a transient
    /// network failure never misclassifies live packs as orphaned.
    private func refreshOrphans(fetched: [StickerSetInfo], fetchedEmoji: [StickerSetInfo]?) {
        guard !DemoSession.isActive, !PreviewMode.isActive else {
            orphanedPacks = []
            return
        }
        let stickerIDs = Set(fetched.map { String($0.id.rawValue) })
        let emojiIDs = fetchedEmoji.map { Set($0.map { String($0.id.rawValue) }) }
        orphanedPacks = SharedStickerStore.shared.loadManifest().packs.filter { pack in
            switch pack.packKind {
            case "sticker": return !stickerIDs.contains(pack.id)
            case "emoji": return emojiIDs.map { !$0.contains(pack.id) } ?? false
            default: return false
            }
        }
    }

    private func reconvertStalePacks() {
        let manifest = SharedStickerStore.shared.loadManifest()
        guard manifest.packs.contains(where: {
            ($0.converterVersion ?? 0) < StickerConverter.pipelineVersion
        }) else { return }
        Task { [weak self] in
            // Only packs whose files the audit flags re-convert here; clean
            // stale packs are restamped (or source-verified) by the
            // maintenance pass that runs on the same foreground load.
            let suspectIDs = await Task.detached(priority: .utility) {
                StickerAudit.suspectPackIDs(
                    manifest: manifest, pipelineVersion: StickerConverter.pipelineVersion
                )
            }.value
            guard let self, !suspectIDs.isEmpty else { return }
            for info in self.sets + self.emojiSets
            where suspectIDs.contains(String(info.id.rawValue)) {
                if self.sync.phase(for: info.id) == .synced {
                    self.sync.setSyncEnabled(true, for: info, userInitiated: false)
                }
            }
            if suspectIDs.contains(StickerSyncEngine.gifsPackID) {
                self.sync.setGifSyncEnabled(true, userInitiated: false)
            }
        }
    }

    private func arrange(_ fetched: [StickerSetInfo]) -> [StickerSetInfo] {
        let known = Preferences.knownPackIDs
        let firstRun = !Preferences.hasSeenPackList

        var incoming: Set<String> = []
        for info in fetched {
            let id = String(info.id.rawValue)
            incoming.insert(id)

            if !firstRun, !known.contains(id) {
                newPackIDs.insert(id)
            }
        }
        Preferences.knownPackIDs = known.union(incoming)
        Preferences.hasSeenPackList = true

        if Preferences.autoAddNewPacks {
            for info in fetched where newPackIDs.contains(String(info.id.rawValue)) {
                if case .idle = sync.phase(for: info.id) {
                    sync.setSyncEnabled(true, for: info)
                }
            }
        }

        let orderIndex = Dictionary(
            uniqueKeysWithValues: Preferences.packOrder.enumerated().map { ($1, $0) }
        )
        let newOnes = fetched.filter { newPackIDs.contains(String($0.id.rawValue)) }
        let rest = fetched
            .filter { !newPackIDs.contains(String($0.id.rawValue)) }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = orderIndex[String(lhs.element.id.rawValue)] ?? (1_000_000 + lhs.offset)
                let rhsOrder = orderIndex[String(rhs.element.id.rawValue)] ?? (1_000_000 + rhs.offset)
                return lhsOrder < rhsOrder
            }
            .map(\.element)
        return newOnes + rest
    }

    private func persistOrder() {
        Preferences.packOrder = sets.map { String($0.id.rawValue) }
    }

    private func animateFirstAppearance() {
        tableView.layoutIfNeeded()
        for (index, cell) in (tableView.visibleCells).enumerated() {
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: 18)
            UIView.animate(
                withDuration: 0.5,
                delay: 0.035 * Double(index),
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                cell.alpha = 1
                cell.transform = .identity
            }
        }
    }

    /// Phase ticks arrive for every converted sticker; update only the
    /// status/progress of visible cells. Re-running the full `configure`
    /// here re-fired cover loads and made thumbnails flash on every tick.
    private func reloadVisibleRows() {
        for cell in tableView.visibleCells {
            guard let cell = cell as? PackCell, let id = cell.representedID else { continue }
            cell.update(phase: sync.phases[id] ?? .idle)
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        visibleOrphans.isEmpty ? 1 : 2
    }

    @objc private func kindChanged() {
        Haptics.tap()
        Preferences.packListKind = currentKind
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 1 { return visibleOrphans.count }
        return currentKind == 2 ? 1 : visibleSets.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "No Longer on Telegram" : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 {
            return "These packs were removed or archived in Telegram. They still work in iMessage; switch one off to delete it from this device."
        }
        return sets.isEmpty
            ? nil
            : "Enabled packs appear in Messages: open a conversation, tap ‘+’, and scroll to Shiiru. Hold and drag to re-arrange."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PackCell.reuseIdentifier, for: indexPath
        ) as! PackCell
        if indexPath.section == 1 {
            configureOrphan(cell, at: indexPath.row)
            return cell
        }
        if currentKind == 2 {
            let key = StickerSyncEngine.gifsPackID
            cell.representedID = key
            cell.configure(
                title: "Saved GIFs",
                subtitle: gifCount > 0 ? "\(gifCount) GIFs from Telegram" : "Your saved GIFs from Telegram",
                phase: sync.phases[key] ?? .idle,
                isNew: false
            )
            cell.onToggle = { [weak self] enabled in
                self?.sync.setGifSyncEnabled(enabled)
            }
            if let file = gifCoverFile {
                Task { [weak cell] in
                    var path = try? await TelegramService.shared.download(file: file)
                    if path == nil {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        path = try? await TelegramService.shared.download(file: file)
                    }
                    if let path, let image = UIImage(contentsOfFile: path),
                       cell?.representedID == key {
                        cell?.setThumbnail(image)
                    }
                }
            }
            return cell
        }
        configure(cell, with: visibleSets[indexPath.row])
        return cell
    }

    private func configureOrphan(_ cell: PackCell, at index: Int) {
        let pack = visibleOrphans[index]
        cell.representedID = pack.id
        cell.configure(
            title: pack.title,
            subtitle: "\(pack.stickers.count) stickers",
            phase: .synced
        )
        cell.onToggle = { [weak self] enabled in
            guard !enabled else { return }
            self?.removeOrphan(id: pack.id)
        }
        // The artwork already lives on disk; use the first sticker as cover.
        if let sticker = pack.stickers.first {
            let url = SharedStickerStore.shared.fileURL(pack: pack, sticker: sticker)
            Task { [weak cell] in
                let image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
                guard let image, cell?.representedID == pack.id else { return }
                cell?.setThumbnail(image)
            }
        }
    }

    private func removeOrphan(id: String) {
        sync.removeLocalPack(id: id)
        guard let index = visibleOrphans.firstIndex(where: { $0.id == id }) else { return }
        orphanedPacks.removeAll { $0.id == id }
        if visibleOrphans.isEmpty {
            tableView.deleteSections(IndexSet(integer: 1), with: .automatic)
        } else {
            tableView.deleteRows(at: [IndexPath(row: index, section: 1)], with: .automatic)
        }
        Haptics.success()
    }

    private func configure(_ cell: PackCell, with info: StickerSetInfo) {
        var subtitle = "\(info.size) stickers"
        let hasAnimated = info.covers.contains { $0.format == .stickerFormatTgs }
        let hasVideo = info.covers.contains { $0.format == .stickerFormatWebm }
        if hasAnimated { subtitle += " · Animated" }
        else if hasVideo { subtitle += " · Video" }

        let packID = String(info.id.rawValue)
        cell.representedID = packID
        cell.configure(
            title: info.title,
            subtitle: subtitle,
            phase: sync.phase(for: info.id),
            isNew: newPackIDs.contains(packID)
        )
        cell.onToggle = { [weak self] enabled in
            if DemoSession.isActive {
                DemoSession.setPack(id: packID, enabled: enabled)
                self?.reloadVisibleRows()
            } else {
                self?.sync.setSyncEnabled(enabled, for: info)
            }
        }
        // Cached covers paint synchronously so list rebuilds don't flash
        // blank thumbnails; only misses go through the async path.
        let cachedCover = StickerSyncEngine.shared.cachedCover(for: info)
        let cachedAnimation = StickerSyncEngine.shared.cachedAnimatedCover(for: info)
        if let cachedCover { cell.setThumbnail(cachedCover) }
        if let cachedAnimation { cell.setAnimatedThumbnail(cachedAnimation) }
        guard cachedCover == nil || cachedAnimation == nil else { return }
        Task { [weak cell] in
            if cachedCover == nil {
                var image = await StickerSyncEngine.shared.coverImage(for: info)
                if image == nil {
                    // First-login covers can race TDLib settling into the
                    // session; a delayed second attempt heals them without
                    // waiting for a manual refresh.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    image = await StickerSyncEngine.shared.coverImage(for: info)
                }
                if let image, cell?.representedID == packID {
                    cell?.setThumbnail(image)
                }
            }
            if cachedAnimation == nil,
               let animation = await StickerSyncEngine.shared.animatedCover(for: info),
               cell?.representedID == packID {
                cell?.setAnimatedThumbnail(animation)
            }
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        currentKind == 0 && indexPath.section == 0
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        let moved = sets.remove(at: sourceIndexPath.row)
        sets.insert(moved, at: destinationIndexPath.row)

        newPackIDs.remove(String(moved.id.rawValue))
        persistOrder()
        Haptics.tap()
    }
}

extension PacksViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard indexPath.section == 0, currentKind == 0, indexPath.row < sets.count else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = sets[indexPath.row]
        return [item]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {

    }
}

private final class EmptyStateView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let mascot = AppIconMascotView(side: 84)
        let mascotContainer = UIStackView(arrangedSubviews: [mascot])
        mascotContainer.axis = .vertical
        mascotContainer.alignment = .center

        let titleLabel = UILabel()
        titleLabel.text = "No Sticker Packs"
        titleLabel.font = Theme.titleFont()
        titleLabel.textAlignment = .center

        let body = UILabel()
        body.text = "Add sticker packs in Telegram first,\nthen pull to refresh."
        body.font = Theme.footnoteFont()
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [mascotContainer, titleLabel, body])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: mascotContainer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Table header that keeps the kind switcher inside the readable width
/// regardless of when the table resizes it.
private final class SwitcherHeaderView: UIView {
    private weak var switcher: UISegmentedControl?

    func install(_ control: UISegmentedControl) {
        switcher = control
        addSubview(control)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switcher?.frame = bounds.insetBy(dx: 16, dy: 6)
    }
}
