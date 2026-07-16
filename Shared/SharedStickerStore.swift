import Foundation

final class SharedStickerStore {
    static let shared = SharedStickerStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "dev.alany.shiiru.sticker-store", qos: .userInitiated)

    private init() {}

    func loadManifest() -> StickerManifest {
        guard let data = try? Data(contentsOf: AppGroup.manifestURL),
              let manifest = try? Self.decoder.decode(StickerManifest.self, from: data)
        else { return .empty }
        return manifest
    }

    func fileURL(pack: StickerManifest.Pack, sticker: StickerManifest.Sticker) -> URL {
        AppGroup.stickersDirectory
            .appendingPathComponent(pack.directoryName, isDirectory: true)
            .appendingPathComponent(sticker.fileName)
    }

    func directoryURL(forPackID packID: String) -> URL {
        AppGroup.stickersDirectory.appendingPathComponent(packID, isDirectory: true)
    }

    func prepareDirectory(forPackID packID: String) throws -> URL {
        let url = directoryURL(forPackID: packID)
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func upsert(pack: StickerManifest.Pack) {
        mutateManifest { manifest in
            manifest.packs.removeAll { $0.id == pack.id }
            manifest.packs.append(pack)
        }
    }

    func removePack(id: String) {
        mutateManifest { manifest in
            manifest.packs.removeAll { $0.id == id }
        }
        try? fileManager.removeItem(at: directoryURL(forPackID: id))
    }

    func removeAll() {
        mutateManifest { $0.packs.removeAll() }
        try? fileManager.removeItem(at: AppGroup.stickersDirectory)
    }

    func syncedPackIDs() -> Set<String> {
        Set(loadManifest().packs.map(\.id))
    }

    private func mutateManifest(_ mutate: (inout StickerManifest) -> Void) {
        queue.sync {
            var manifest = loadManifest()
            mutate(&manifest)
            manifest.version = StickerManifest.currentVersion
            manifest.updatedAt = Date()
            do {
                let data = try Self.encoder.encode(manifest)
                try fileManager.createDirectory(at: AppGroup.containerURL, withIntermediateDirectories: true)
                try data.write(to: AppGroup.manifestURL, options: .atomic)
            } catch {
                NSLog("[Shiiru] Failed to write manifest: \(error)")
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
