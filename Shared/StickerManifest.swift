import Foundation

struct StickerManifest: Codable, Equatable {
    var version: Int
    var updatedAt: Date
    var packs: [Pack]

    static let currentVersion = 1

    static var empty: StickerManifest {
        StickerManifest(version: currentVersion, updatedAt: .distantPast, packs: [])
    }

    struct Pack: Codable, Equatable, Identifiable {

        var id: String

        var name: String

        var title: String

        var isAnimated: Bool

        /// "sticker" (default), "emoji", or "gif".
        var kind: String? = nil

        var converterVersion: Int?
        /// Telegram-side item count at sync time; drift means the pack
        /// changed upstream and should be re-synced.
        var sourceCount: Int? = nil
        /// On-disk directory; tokened per sync so Messages can never serve
        /// cached renders for stale URLs. Falls back to id for old manifests.
        var directory: String? = nil
        var stickers: [Sticker]

        var directoryName: String { directory ?? id }
        var packKind: String { kind ?? "sticker" }
    }

    struct Sticker: Codable, Equatable {

        var fileName: String

        var emoji: String
        var isAnimated: Bool
    }
}
