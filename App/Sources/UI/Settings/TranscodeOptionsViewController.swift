import UIKit

/// Lets the user pick which quality axis gives way when a video sticker
/// can't fit iMessage's 500 KB budget — either via a preset or by tuning
/// the floors directly — and re-convert the synced library with it.
final class TranscodeOptionsViewController: UITableViewController {

    private enum SectionKind {
        case presets
        case customKnobs
        case actions
    }

    private var sections: [SectionKind] {
        TranscodePreset.current == .custom
            ? [.presets, .customKnobs, .actions]
            : [.presets, .actions]
    }

    init() {
        super.init(style: .insetGrouped)
        title = "Transcoding"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .presets: return TranscodePreset.allCases.count
        case .customKnobs: return 3
        case .actions: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .presets:
            return """
            iMessage caps every sticker at 500 KB. A busy video sticker \
            can't keep full display size, fluid motion, and rich color all \
            at once inside that budget.
            """
        case .customKnobs:
            return """
            Floors are best-effort. When even the floors don't fit, the \
            frame rate dips slightly and the canvas shrinks step by step \
            so the sticker stays animated.
            """
        case .actions:
            return "Already-synced packs keep their current version until reprocessed."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .presets:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            let preset = TranscodePreset.allCases[indexPath.row]
            cell.textLabel?.text = preset.title
            cell.detailTextLabel?.text = preset.subtitle
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.font = .systemFont(ofSize: 12)
            cell.detailTextLabel?.numberOfLines = 0
            cell.accessoryType = preset == TranscodePreset.current ? .checkmark : .none
            return cell

        case .customKnobs:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Canvas Floor"
                cell.accessoryView = menuButton(
                    options: TranscodePreset.canvasFloorChoices,
                    current: TranscodePreset.customCanvasFloor,
                    format: { "\($0) px" },
                    onPick: { TranscodePreset.customCanvasFloor = $0 }
                )
            case 1:
                cell.textLabel?.text = "Frame Rate Floor"
                cell.accessoryView = menuButton(
                    options: TranscodePreset.fpsFloorChoices,
                    current: TranscodePreset.customFPSFloor,
                    format: { "\(Int($0)) fps" },
                    onPick: { TranscodePreset.customFPSFloor = $0 }
                )
            default:
                cell.textLabel?.text = "Color Floor"
                cell.accessoryView = menuButton(
                    options: TranscodePreset.colorFloorChoices,
                    current: TranscodePreset.customColorFloor,
                    format: { "\($0) colors" },
                    onPick: { TranscodePreset.customColorFloor = $0 }
                )
            }
            return cell

        case .actions:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Reprocess Synced Packs Now"
            cell.textLabel?.textColor = .systemRed
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .presets:
            let preset = TranscodePreset.allCases[indexPath.row]
            guard preset != TranscodePreset.current else { return }
            TranscodePreset.current = preset
            Haptics.tap()
            tableView.reloadData()
        case .customKnobs:
            break
        case .actions:
            confirmReconversion()
        }
    }

    /// A pull-down value picker shown as the row's accessory.
    private func menuButton<Value: Equatable>(
        options: [Value],
        current: Value,
        format: @escaping (Value) -> String,
        onPick: @escaping (Value) -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = format(current)
        configuration.indicator = .popup
        let button = UIButton(configuration: configuration)
        button.menu = UIMenu(children: options.map { value in
            UIAction(title: format(value), state: value == current ? .on : .off) { [weak self] _ in
                onPick(value)
                Haptics.tap()
                self?.tableView.reloadData()
            }
        })
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    private func confirmReconversion() {
        guard !DemoSession.isActive,
              !SharedStickerStore.shared.syncedPackIDs().isEmpty
        else { return }
        let alert = UIAlertController(
            title: "Reprocess Synced Packs?",
            message: "Applies the current setting to everything already in iMessage. "
                + "This downloads and converts your packs again, which can take a while.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Reprocess All", style: .default) { _ in
            Self.reconvertAllSyncedPacks()
            Haptics.success()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private static func reconvertAllSyncedPacks() {
        Task { @MainActor in
            let synced = SharedStickerStore.shared.syncedPackIDs()
            let engine = StickerSyncEngine.shared
            let installed = (try? await TelegramService.shared.installedStickerSets()) ?? []
            let emoji = (try? await TelegramService.shared.customEmojiSets()) ?? []
            for info in installed + emoji where synced.contains(String(info.id.rawValue)) {
                engine.setSyncEnabled(true, for: info)
            }
            if synced.contains(StickerSyncEngine.gifsPackID) {
                engine.setGifSyncEnabled(true)
            }
        }
    }
}
