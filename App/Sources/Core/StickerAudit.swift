import Foundation
import ImageIO

/// Local health check for packs converted by an older pipeline: a pipeline
/// bump used to re-convert every synced pack, but most packs' files are
/// unaffected by any given change — only packs showing an actual defect
/// should pay the re-conversion. Clean stale packs are restamped in place.
enum StickerAudit {

    /// Packs whose on-disk output shows a defect of pipelines < 11:
    /// animated-labeled files holding a single frame (the encoder merged
    /// identical frames without relabeling) and saved-GIF items stuck on a
    /// static frame (the ladder gave up before reducing colors). Packs
    /// degraded from webm sources (VP8, decode failures) can't be told
    /// apart from honest statics locally; maintenance verification catches
    /// them source-side.
    static func suspectPackIDs(
        manifest: StickerManifest,
        pipelineVersion: Int,
        store: SharedStickerStore = .shared
    ) -> Set<String> {
        var suspects: Set<String> = []
        for pack in manifest.packs where (pack.converterVersion ?? 0) < pipelineVersion {
            if isSuspect(pack, store: store) { suspects.insert(pack.id) }
        }
        return suspects
    }

    private static func isSuspect(_ pack: StickerManifest.Pack, store: SharedStickerStore) -> Bool {
        for sticker in pack.stickers {
            // Saved GIFs are animations by nature; a static item is the
            // old ladder's fallback.
            if pack.packKind == "gif", !sticker.isAnimated { return true }
            guard sticker.isAnimated else { continue }
            let url = store.fileURL(pack: pack, sticker: sticker)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return true }
            if CGImageSourceGetCount(source) <= 1 { return true }
        }
        return false
    }
}
