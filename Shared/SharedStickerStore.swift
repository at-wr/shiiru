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

    func prepareDirectory(named name: String) throws -> URL {
        let url = AppGroup.stickersDirectory.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func upsert(pack: StickerManifest.Pack) {
        let stale = loadManifest().packs
            .filter { $0.id == pack.id && $0.directoryName != pack.directoryName }
            .map(\.directoryName)
        mutateManifest { manifest in
            manifest.packs.removeAll { $0.id == pack.id }
            manifest.packs.append(pack)
        }
        for directory in stale {
            try? fileManager.removeItem(
                at: AppGroup.stickersDirectory.appendingPathComponent(directory, isDirectory: true)
            )
        }
    }

    /// Deletes one on-disk directory (e.g. the partial output of an
    /// interrupted sync) without touching the manifest.
    func removeDirectory(named name: String) {
        try? fileManager.removeItem(
            at: AppGroup.stickersDirectory.appendingPathComponent(name, isDirectory: true)
        )
    }

    func removePack(id: String) {
        let directories = loadManifest().packs.filter { $0.id == id }.map(\.directoryName)
        mutateManifest { manifest in
            manifest.packs.removeAll { $0.id == id }
        }
        for directory in directories + [id] {
            try? fileManager.removeItem(
                at: AppGroup.stickersDirectory.appendingPathComponent(directory, isDirectory: true)
            )
        }
    }

    /// Marks a pack as produced by the given pipeline version without
    /// touching its files — used when an audit shows the existing output is
    /// unaffected by a pipeline change.
    func stamp(packID: String, converterVersion: Int) {
        mutateManifest { manifest in
            guard let index = manifest.packs.firstIndex(where: { $0.id == packID }) else { return }
            manifest.packs[index].converterVersion = converterVersion
        }
    }

    func removeAll() {
        mutateManifest { $0.packs.removeAll() }
        try? fileManager.removeItem(at: AppGroup.stickersDirectory)
    }

    func syncedPackIDs() -> Set<String> {
        Set(loadManifest().packs.map(\.id))
    }

    /// Deletes sticker directories no manifest pack references — leftovers
    /// of syncs that died between writing files and publishing (crash,
    /// jetsam). Only directories untouched for a day are removed, so an
    /// in-flight sync's fresh output is never swept.
    func sweepUnreferencedDirectories(olderThan age: TimeInterval = 24 * 60 * 60) {
        let referenced = Set(loadManifest().packs.map(\.directoryName))
        guard let entries = try? fileManager.contentsOfDirectory(
            at: AppGroup.stickersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }
        let cutoff = Date(timeIntervalSinceNow: -age)
        for entry in entries {
            guard let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ), values.isDirectory == true,
                  !referenced.contains(entry.lastPathComponent),
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
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
