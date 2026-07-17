import XCTest
import UIKit
@testable import Shiiru

/// Renders the real extension panel inside the simulator test host and
/// verifies layout and rendering end to end: the grid must reach the very
/// bottom (no dead strip), the floating type switcher must appear exactly
/// when more than one category is synced, and cell previews must actually
/// decode. Screenshots land in SHIIRU_AUDIT_DIR for visual review.
@MainActor
final class PanelSmokeTests: XCTestCase {

    private var window: UIWindow!
    private var panel: StickerPanelViewController!

    override func setUp() async throws {
        SharedStickerStore.shared.removeAll()
        DemoSession.installAllPacks()

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 560))
        panel = StickerPanelViewController()
        window.rootViewController = panel
        window.makeKeyAndVisible()
        panel.view.layoutIfNeeded()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        panel = nil
        SharedStickerStore.shared.removeAll()
    }

    /// Adds synthetic emoji/GIF packs by cloning demo artwork, so all three
    /// categories exist.
    private func installAllCategories() throws {
        let store = SharedStickerStore.shared
        let source = AppGroup.stickersDirectory.appendingPathComponent("9101", isDirectory: true)
        for (kind, id) in [("emoji", "9201"), ("gif", "gifs")] {
            let directory = try store.prepareDirectory(named: id)
            var stickers: [StickerManifest.Sticker] = []
            for file in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent(file),
                    to: directory.appendingPathComponent(file)
                )
                stickers.append(StickerManifest.Sticker(fileName: file, emoji: "😀", isAnimated: false))
            }
            store.upsert(pack: StickerManifest.Pack(
                id: id, name: id, title: kind.uppercased(),
                isAnimated: false,
                kind: kind,
                converterVersion: StickerConverter.pipelineVersion,
                stickers: stickers
            ))
        }
    }

    private func pumpRunLoop(seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private func collectionViews(in root: UIView) -> [UICollectionView] {
        var result: [UICollectionView] = []
        var queue: [UIView] = [root]
        while let view = queue.popLast() {
            if let collection = view as? UICollectionView { result.append(collection) }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    private var grid: UICollectionView {
        collectionViews(in: panel.view).max { $0.bounds.height < $1.bounds.height }!
    }

    private var switcher: EntityTypeSwitcher {
        func find(_ view: UIView) -> EntityTypeSwitcher? {
            if let match = view as? EntityTypeSwitcher { return match }
            for sub in view.subviews { if let match = find(sub) { return match } }
            return nil
        }
        return find(panel.view)!
    }

    private func snapshot(_ name: String) {
        panel.view.layoutIfNeeded()
        // layer.render(in:) draws CGImage-backed layer trees even in a
        // headless test host, where drawHierarchy returns blank frames.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.backgroundColor = .systemBackground
            window.layer.render(in: context.cgContext)
        }
        guard let dir = ProcessInfo.processInfo.environment["SHIIRU_AUDIT_DIR"],
              let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-\(name).png"))
    }

    func testSingleCategoryFillsToBottomWithoutSwitcher() throws {
        panel.reload()
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 2)

        XCTAssertTrue(switcher.isHidden, "one category → no switcher")
        XCTAssertEqual(
            grid.frame.maxY, panel.view.bounds.maxY, accuracy: 0.5,
            "grid must reach the very bottom — no reserved strip"
        )

        let cells = grid.visibleCells.compactMap { $0 as? StickerCell }
        XCTAssertFalse(cells.isEmpty, "demo stickers must be visible")
        let rendered = cells.filter { cell in
            cell.contentView.subviews.contains { $0.layer.contents != nil }
        }
        XCTAssertFalse(rendered.isEmpty, "previews must decode and render")
        snapshot("stickers-only")
    }

    func testAllCategoriesShowFloatingSwitcher() throws {
        try installAllCategories()
        panel.reload()
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 2)

        XCTAssertFalse(switcher.isHidden, "three categories → switcher visible")
        XCTAssertEqual(grid.frame.maxY, panel.view.bounds.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(
            grid.contentInset.bottom, 36,
            "grid content must scroll clear of the floating switcher"
        )
        snapshot("stickers-mode")

        switcher.onSelect?(0)
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 1.5)
        XCTAssertFalse(grid.visibleCells.isEmpty, "emoji grid renders")
        snapshot("emoji-mode")

        switcher.onSelect?(2)
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 1.5)
        XCTAssertFalse(grid.visibleCells.isEmpty, "gif grid renders")
        snapshot("gif-mode")
    }

    func testEmptyStoreShowsEmptyState() {
        SharedStickerStore.shared.removeAll()
        panel.reload()
        panel.view.layoutIfNeeded()
        XCTAssertTrue(grid.isHidden)
        snapshot("empty")
    }
}
