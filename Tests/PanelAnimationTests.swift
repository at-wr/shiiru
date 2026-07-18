import XCTest
import UIKit
@testable import Shiiru

/// Regression tests for "animated stickers show static on first open /
/// after tab jump": reuse-pool cells keep their window, so decode
/// completions used to register off-screen phantoms that hoarded the
/// animator's slots. Asserts every visible animated preview advances.
@MainActor
final class PanelAnimationTests: XCTestCase {

    private func pumpRunLoop(seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// Previews of cells actually inside the grid's viewport — walking the
    /// whole hierarchy also finds reuse-pool cells, which keep their window
    /// and stale content while sitting off screen.
    private func previews(in panel: StickerPanelViewController) -> [StickerPreviewView] {
        let grid = panel.view.subviews.compactMap { $0 as? UICollectionView }
            .max { $0.bounds.height < $1.bounds.height }!
        let cells = grid.visibleCells
        let viewport = grid.bounds.inset(by: grid.adjustedContentInset)
        let onScreen = cells.filter { $0.frame.intersects(viewport) }
        let found = onScreen.flatMap { $0.contentView.subviews.compactMap { $0 as? StickerPreviewView } }
        NSLog("[Repro] previews(): cells=%d onScreen=%d found=%d viewport=%@ firstCellFrame=%@",
              cells.count, onScreen.count, found.count,
              NSCoder.string(for: viewport),
              cells.first.map { NSCoder.string(for: $0.frame) } ?? "none")
        return found
    }

    private func frameSignature(_ views: [StickerPreviewView]) -> [ObjectIdentifier?] {
        views.map { view in
            view.layer.contents.map { ObjectIdentifier($0 as AnyObject) }
        }
    }

    func testInitialOpenAnimates() throws {
        SharedStickerStore.shared.removeAll()
        DemoSession.installAllPacks()

        // Mimic the extension lifecycle: the panel's view is loaded and
        // reload() runs BEFORE anything joins a window (willBecomeActive).
        let panel = StickerPanelViewController()
        _ = panel.view
        panel.reload()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 560))
        window.rootViewController = panel
        window.makeKeyAndVisible()
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 3.0) // plenty for the demo APNGs to decode

        let all = previews(in: panel)
        XCTAssertFalse(all.isEmpty, "grid should be populated")
        let before = frameSignature(all)
        pumpRunLoop(seconds: 0.55) // off-period: the demo APNGs loop in exactly 1 s
        let after = frameSignature(all)
        let changed = zip(before, after).filter { $0 != $1 }.count
        NSLog("[Repro] initial-open: \(all.count) previews, \(changed) advanced frames")
        // Demo Motion has 4 animated stickers, all on screen.
        XCTAssertGreaterThanOrEqual(
            changed, 4,
            "the animated pack is on screen; its previews must animate on first open"
        )
        window.isHidden = true
        SharedStickerStore.shared.removeAll()
    }

    /// The dense 8-column emoji grid shows far more cells than the old
    /// 28-preview cap; with budget-based admission (and emoji-sized decode
    /// costs) every visible animated cell must advance, not just the first
    /// batch to claim a slot.
    func testDenseEmojiGridAnimatesWallToWall() throws {
        let store = SharedStickerStore.shared
        store.removeAll()
        DemoSession.installAllPacks()

        // Harvest the demo Motion pack's animated APNGs, then rebuild the
        // store around a single dense emoji pack so the panel opens
        // directly in emoji mode.
        let manifest = store.loadManifest()
        let motion = try XCTUnwrap(manifest.packs.first { $0.id == "9102" })
        let motionDir = AppGroup.stickersDirectory.appendingPathComponent("9102", isDirectory: true)
        let animatedData: [Data] = try motion.stickers.filter(\.isAnimated).map {
            try Data(contentsOf: motionDir.appendingPathComponent($0.fileName))
        }
        XCTAssertFalse(animatedData.isEmpty, "demo Motion pack must carry animated stickers")
        store.removeAll()

        let directory = try store.prepareDirectory(named: "9600")
        var stickers: [StickerManifest.Sticker] = []
        for index in 0..<64 {
            let fileName = String(format: "emoji-%03d.png", index)
            try animatedData[index % animatedData.count]
                .write(to: directory.appendingPathComponent(fileName))
            stickers.append(.init(fileName: fileName, emoji: "😀", isAnimated: true))
        }
        store.upsert(pack: StickerManifest.Pack(
            id: "9600", name: "9600", title: "DENSE",
            isAnimated: true,
            kind: "emoji",
            converterVersion: StickerConverter.pipelineVersion,
            stickers: stickers
        ))

        let panel = StickerPanelViewController()
        _ = panel.view
        panel.reload()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 280))
        window.rootViewController = panel
        window.makeKeyAndVisible()
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 3.0)

        let visible = previews(in: panel)
        XCTAssertGreaterThan(
            visible.count, 28,
            "the dense grid must show more cells than the old animator cap"
        )
        let before = frameSignature(visible)
        pumpRunLoop(seconds: 0.55) // off-period: the demo APNGs loop in exactly 1 s
        let after = frameSignature(visible)
        let frozen = zip(before, after).filter { $0 == $1 }.count
        NSLog("[Repro] dense-emoji: \(visible.count) previews, \(frozen) frozen")
        XCTAssertEqual(frozen, 0, "every visible emoji preview must animate")

        window.isHidden = true
        store.removeAll()
    }

    func testTabJumpAnimates() throws {
        SharedStickerStore.shared.removeAll()
        // Many animated packs so a tab jump scrolls over several sections.
        let store = SharedStickerStore.shared
        let source = AppGroup.stickersDirectory
        DemoSession.installAllPacks()
        let motionDir = source.appendingPathComponent("9102", isDirectory: true)
        for clone in 0..<6 {
            let id = "95\(clone)0"
            let directory = try store.prepareDirectory(named: id)
            var stickers: [StickerManifest.Sticker] = []
            for file in try FileManager.default.contentsOfDirectory(atPath: motionDir.path).sorted() {
                try FileManager.default.copyItem(
                    at: motionDir.appendingPathComponent(file),
                    to: directory.appendingPathComponent(file)
                )
                stickers.append(StickerManifest.Sticker(fileName: file, emoji: "😀", isAnimated: true))
            }
            store.upsert(pack: StickerManifest.Pack(
                id: id, name: id, title: "Clone \(clone)",
                isAnimated: true,
                kind: "sticker",
                converterVersion: StickerConverter.pipelineVersion,
                stickers: stickers
            ))
        }

        let panel = StickerPanelViewController()
        _ = panel.view
        panel.reload()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 560))
        window.rootViewController = panel
        window.makeKeyAndVisible()
        panel.view.layoutIfNeeded()
        pumpRunLoop(seconds: 2.0)

        // Jump to the last pack via its top tab, like tapping the thumbnail.
        let tabBar = panel.view.subviews.compactMap { $0 as? UICollectionView }
            .min { $0.bounds.height < $1.bounds.height }!
        let lastTab = IndexPath(item: tabBar.numberOfItems(inSection: 0) - 1, section: 0)
        panel.collectionView(tabBar, didSelectItemAt: lastTab)
        pumpRunLoop(seconds: 3.0) // scroll animation + decode time

        let grid = panel.view.subviews.compactMap { $0 as? UICollectionView }
            .max { $0.bounds.height < $1.bounds.height }!
        // The headless harness can leave stale mid-flight cells in
        // visibleCells after an animated jump; a layout pass reconciles
        // them with the settled offset (on device this happens naturally).
        grid.layoutIfNeeded()
        pumpRunLoop(seconds: 0.3)
        NSLog("[Repro] grid offset=%.0f contentH=%.0f boundsH=%.0f inset=(%.0f,%.0f) visibleCells=%d sections=%d",
              grid.contentOffset.y, grid.contentSize.height, grid.bounds.height,
              grid.adjustedContentInset.top, grid.adjustedContentInset.bottom,
              grid.visibleCells.count, grid.numberOfSections)
        let visible = previews(in: panel)
        XCTAssertFalse(visible.isEmpty)
        let before = frameSignature(visible)
        pumpRunLoop(seconds: 0.55) // off-period: the demo APNGs loop in exactly 1 s
        let after = frameSignature(visible)
        let changed = zip(before, after).filter { $0 != $1 }.count
        NSLog("[Repro] tab-jump: \(visible.count) previews, \(changed) advanced frames")
        for (index, preview) in visible.enumerated() where before[index] == after[index] {
            var state: [String: String] = [:]
            for child in Mirror(reflecting: preview).children {
                guard let label = child.label else { continue }
                state[label] = "\(child.value)"
            }
            NSLog("[Repro] static preview #%d: wantsAnimation=%@ wantsTicks=%@ loading=%@ hasAnimation=%@",
                  index,
                  state["wantsAnimation"] ?? "?", state["wantsTicks"] ?? "?",
                  state["loadingAnimation"] ?? "?",
                  state["animation"].map { $0.contains("nil") ? "no" : "yes" } ?? "?")
        }
        for child in Mirror(reflecting: StickerAnimator.shared).children {
            guard let label = child.label, label == "views" || label == "waiting" else { continue }
            let table = child.value as? NSHashTable<StickerPreviewView>
            NSLog("[Repro] animator.%@ count=%d", label, table?.count ?? -1)
        }
        // Every arriving cell is animated; phantom pool registrations used
        // to cap this at roughly half.
        XCTAssertGreaterThanOrEqual(
            changed, min(visible.count, StickerAnimator.maxConcurrent),
            "after jumping to an animated pack, every visible preview must animate"
        )
        window.isHidden = true
        SharedStickerStore.shared.removeAll()
    }
}
