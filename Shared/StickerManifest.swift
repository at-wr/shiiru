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

        var converterVersion: Int?
        var stickers: [Sticker]

        var directoryName: String { id }
    }

    struct Sticker: Codable, Equatable {

        var fileName: String

        var emoji: String
        var isAnimated: Bool
    }
}
