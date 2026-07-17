import Foundation
import UIKit
import Combine
import TDLibKit
import Lottie

@MainActor
final class StickerSyncEngine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case syncing(progress: Double)
        case synced
        case failed(message: String)

        var isSyncing: Bool {
            if case .syncing = self { return true }
            return false
        }
    }

    static let shared = StickerSyncEngine()

    @Published private(set) var phases: [String: Phase] = [:]

    private let telegram = TelegramService.shared
    private let store = SharedStickerStore.shared
    private var tasks: [String: Task<Void, Never>] = [:]

    private var syncChain: Task<Void, Never>?
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let animationCache = NSCache<NSString, LottieAnimation>()

    private var coverChain: Task<UIImage?, Never>?

    private var pendingCovers: [String: Task<UIImage?, Never>] = [:]

    private init() {
        for id in store.syncedPackIDs() {
            phases[id] = .synced
        }
    }

    func phase(for setID: TdInt64) -> Phase {
        phases[String(setID.rawValue)] ?? .idle
    }

    func setSyncEnabled(_ enabled: Bool, for info: StickerSetInfo) {
        let key = String(info.id.rawValue)
        if enabled {
            guard tasks[key] == nil else { return }
            phases[key] = .syncing(progress: 0)
            SyncBackgroundSession.shared.packQueued()
            let predecessor = syncChain
            let task = Task { [weak self] in
                _ = await predecessor?.value
                if !Task.isCancelled {
                    await self?.sync(info: info, key: key)
                }
                self?.tasks[key] = nil
                self?.noteSyncTaskDrained()
            }
            tasks[key] = task
            syncChain = task
        } else {
            tasks[key]?.cancel()
            tasks[key] = nil
            store.removePack(id: key)
            phases[key] = .idle
        }
    }

    func resetAllPhases() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        phases.removeAll()
    }

    /// One queued pack ended (converted, failed, or cancelled); when the
    /// whole queue drains, the background session can let the process rest.
    private func noteSyncTaskDrained() {
        SyncBackgroundSession.shared.packFinished()
        if tasks.isEmpty {
            SyncBackgroundSession.shared.allDrained()
        }
    }

    /// Stops in-flight syncs without touching what is already synced —
    /// used when background execution time runs out. Interrupted refreshes
    /// keep their existing copy via `rollBack`.
    func cancelActiveSyncs() {
        tasks.values.forEach { $0.cancel() }
    }

    /// Waits for the sync queue to drain (used by background maintenance).
    func waitUntilIdle() async {
        while !tasks.isEmpty, !Task.isCancelled {
            _ = await syncChain?.value
            await Task.yield()
        }
    }

    /// Cleans up an interrupted or failed sync. A pack that already has a
    /// good synced copy (this was a refresh) keeps it — only the partial
    /// output directory is deleted; a first-time sync is removed entirely.
    /// Returns true when an existing copy was preserved.
    @discardableResult
    private func rollBack(key: String, partialDirectory: String?) -> Bool {
        if let partialDirectory { store.removeDirectory(named: partialDirectory) }
        if store.syncedPackIDs().contains(key) {
            phases[key] = .synced
            return true
        }
        store.removePack(id: key)
        phases[key] = .idle
        return false
    }

    /// Removes a pack that no longer exists on the Telegram side (deleted or
    /// archived there), so only the local copy is left to clean up.
    func removeLocalPack(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        store.removePack(id: id)
        phases[id] = nil
    }

    func adoptStorePhases() {
        for id in store.syncedPackIDs() { phases[id] = .synced }
    }

    func markDemoPhase(id: String, synced: Bool) {
        phases[id] = synced ? .synced : .idle
    }

    // MARK: - Saved GIFs

    static let gifsPackID = "gifs"

    func setGifSyncEnabled(_ enabled: Bool) {
        let key = Self.gifsPackID
        if enabled {
            guard tasks[key] == nil else { return }
            phases[key] = .syncing(progress: 0)
            SyncBackgroundSession.shared.packQueued()
            let predecessor = syncChain
            let task = Task { [weak self] in
                _ = await predecessor?.value
                if !Task.isCancelled {
                    await self?.syncGifs(key: key)
                }
                self?.tasks[key] = nil
                self?.noteSyncTaskDrained()
            }
            tasks[key] = task
            syncChain = task
        } else {
            tasks[key]?.cancel()
            tasks[key] = nil
            store.removePack(id: key)
            phases[key] = .idle
        }
    }

    /// Runs download+convert pipelines with bounded parallelism: while one
    /// item sits in the CPU-heavy encoder, the next is already downloading
    /// and decoding. Two lanes roughly halve pack sync time while keeping
    /// the transient frame-buffer memory bounded. Output preserves pack
    /// order; individual failures are skipped exactly like before.
    private func convertItems<Item: Sendable>(
        _ items: [Item],
        syncToken: String,
        directory: URL,
        onProgress: @escaping @MainActor (Double) -> Void,
        convert: @escaping @Sendable (Item) async throws -> (output: StickerConverter.Output, emoji: String)
    ) async throws -> [StickerManifest.Sticker] {
        var results: [(index: Int, sticker: StickerManifest.Sticker)] = []
        var completed = 0.0
        let total = Double(items.count)

        try await withThrowingTaskGroup(of: (Int, StickerManifest.Sticker?).self) { group in
            var next = 0
            // `Swift.Error` spelled explicitly: TDLibKit exports its own
            // `Error` type that would otherwise shadow it here.
            func enqueue(_ group: inout ThrowingTaskGroup<(Int, StickerManifest.Sticker?), any Swift.Error>) {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask {
                    do {
                        let (output, emoji) = try await convert(item)
                        let fileName = String(
                            format: "%03d-%@.%@", index, syncToken, output.fileExtension
                        )
                        try output.data.write(
                            to: directory.appendingPathComponent(fileName), options: .atomic
                        )
                        return (index, StickerManifest.Sticker(
                            fileName: fileName, emoji: emoji, isAnimated: output.isAnimated
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        NSLog("[Shiiru] Skipping item \(index): \(error)")
                        return (index, nil)
                    }
                }
            }
            enqueue(&group)
            enqueue(&group)
            while let (index, sticker) = try await group.next() {
                if let sticker { results.append((index, sticker)) }
                completed += 1
                onProgress(completed / total)
                enqueue(&group)
            }
        }
        return results.sorted { $0.index < $1.index }.map(\.sticker)
    }

    private func syncGifs(key: String) async {
        var partialDirectory: String?
        do {
            let animations = try await telegram.savedAnimations()
            guard !animations.isEmpty else { throw ShiiruError.conversionFailed }

            let syncToken = String(UUID().uuidString.prefix(6))
            let directoryName = "\(key)-\(syncToken)"
            partialDirectory = directoryName
            let directory = try store.prepareDirectory(named: directoryName)

            for animation in animations {
                _ = try? await telegram.downloadFile(startingOnly: animation.animation)
            }
            let manifestStickers = try await convertItems(
                animations,
                syncToken: syncToken,
                directory: directory,
                onProgress: { [weak self] fraction in
                    self?.phases[key] = .syncing(progress: fraction)
                    SyncBackgroundSession.shared.updateProgress(packTitle: "Saved GIFs", fraction: fraction)
                },
                convert: { [telegram] animation in
                    let path = try await telegram.download(file: animation.animation)
                    let isVideo = animation.mimeType.hasPrefix("video")
                    let output: StickerConverter.Output = try await Task.detached(priority: .userInitiated) {
                        if isVideo {
                            return try await StickerConverter.convertVideo(at: path)
                        }
                        return try StickerConverter.convertAnimatedImage(at: path)
                    }.value
                    return (output, "")
                }
            )
            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }
            store.upsert(pack: StickerManifest.Pack(
                id: key, name: key, title: "GIFs",
                isAnimated: true,
                kind: "gif",
                converterVersion: StickerConverter.pipelineVersion,
                sourceCount: animations.count,
                sourceHash: SourceFingerprint.hash(of: animations.map(\.animation.remote.uniqueId)),
                directory: directoryName,
                stickers: manifestStickers
            ))
            phases[key] = .synced
            Haptics.success()
        } catch is CancellationError {
            rollBack(key: key, partialDirectory: partialDirectory)
        } catch {
            if !rollBack(key: key, partialDirectory: partialDirectory) {
                let message = (error as? TDLibKit.Error)?.friendlyMessage ?? error.localizedDescription
                phases[key] = .failed(message: message)
                Haptics.error()
            }
        }
    }

    private func sync(info: StickerSetInfo, key: String) async {
        var partialDirectory: String?
        do {
            let set = try await telegram.stickerSet(id: info.id)
            let stickers = set.stickers
            guard !stickers.isEmpty else { throw ShiiruError.conversionFailed }

            let syncToken = String(UUID().uuidString.prefix(6))
            let directoryName = "\(key)-\(syncToken)"
            partialDirectory = directoryName
            let directory = try store.prepareDirectory(named: directoryName)

            for sticker in stickers {
                _ = try? await telegram.downloadFile(startingOnly: sticker.sticker)
            }

            let title = set.title
            let manifestStickers = try await convertItems(
                stickers,
                syncToken: syncToken,
                directory: directory,
                onProgress: { [weak self] fraction in
                    self?.phases[key] = .syncing(progress: fraction)
                    SyncBackgroundSession.shared.updateProgress(packTitle: title, fraction: fraction)
                },
                convert: { [weak self] sticker in
                    guard let self else { throw CancellationError() }
                    return (try await self.convert(sticker: sticker), sticker.emoji)
                }
            )

            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }

            store.upsert(pack: StickerManifest.Pack(
                id: key,
                name: set.name,
                title: set.title,
                isAnimated: stickers.contains { $0.format == .stickerFormatTgs },
                kind: info.stickerType == .stickerTypeCustomEmoji ? "emoji" : "sticker",
                converterVersion: StickerConverter.pipelineVersion,
                sourceCount: stickers.count,
                sourceHash: SourceFingerprint.hash(of: stickers.map(\.sticker.remote.uniqueId)),
                directory: directoryName,
                stickers: manifestStickers
            ))
            phases[key] = .synced
            Haptics.success()
        } catch is CancellationError {
            rollBack(key: key, partialDirectory: partialDirectory)
        } catch {
            if !rollBack(key: key, partialDirectory: partialDirectory) {
                let message = (error as? TDLibKit.Error)?.friendlyMessage ?? error.localizedDescription
                phases[key] = .failed(message: message)
                Haptics.error()
            }
        }
    }

    private func convert(sticker: Sticker) async throws -> StickerConverter.Output {
        // Custom emoji artwork rarely fills its canvas; crop and enlarge it
        // so the glyph doesn't float inside a mostly-empty sticker.
        var fill = false
        if case .stickerFullTypeCustomEmoji = sticker.fullType { fill = true }
        switch sticker.format {
        case .stickerFormatWebp:
            let path = try await telegram.download(file: sticker.sticker)
            return .png(try await Task.detached(priority: .userInitiated) { [fill] in
                try StickerConverter.convertStaticImage(at: path, fillCanvas: fill)
            }.value)
        case .stickerFormatTgs:
            let path = try await telegram.download(file: sticker.sticker)
            return try await StickerConverter.convertTGS(at: path, fillCanvas: fill)
        case .stickerFormatWebm:

            let path = try await telegram.download(file: sticker.sticker)
            if let animated = try? await Task.detached(priority: .userInitiated, operation: { [fill] in
                try StickerConverter.convertWebm(at: path, fillCanvas: fill)
            }).value {
                return animated
            }

            guard let thumbnail = sticker.thumbnail else { throw ShiiruError.unsupportedSticker }
            let thumbPath = try await telegram.download(file: thumbnail.file)
            return .png(try await Task.detached(priority: .userInitiated) { [fill] in
                try StickerConverter.convertStaticImage(at: thumbPath, fillCanvas: fill)
            }.value)
        }
    }

    func coverImage(for info: StickerSetInfo) async -> UIImage? {
        let key = String(info.id.rawValue) as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        if DemoSession.isActive {
            guard let pack = store.loadManifest().packs.first(where: { $0.id == key as String }),
                  let sticker = pack.stickers.first,
                  let image = UIImage(contentsOfFile: store.fileURL(pack: pack, sticker: sticker).path)
            else { return nil }
            thumbnailCache.setObject(image, forKey: key)
            return image
        }

        guard let file = Self.coverFile(for: info) else { return nil }

        let id = key as String
        if let pending = pendingCovers[id] { return await pending.value }

        let predecessor = coverChain
        let task = Task { [telegram, thumbnailCache] () -> UIImage? in
            _ = await predecessor?.value
            guard let path = try? await telegram.download(file: file),
                  let image = UIImage(contentsOfFile: path)
            else { return nil }
            thumbnailCache.setObject(image, forKey: key)
            return image
        }
        coverChain = task
        pendingCovers[id] = task
        let image = await task.value
        pendingCovers[id] = nil
        return image
    }

    static func coverFile(for info: StickerSetInfo) -> File? {

        if let cover = info.covers.first {
            if let thumbnail = cover.thumbnail { return thumbnail.file }
            if cover.format == .stickerFormatWebp { return cover.sticker }
        }
        if let thumbnail = info.thumbnail, thumbnail.format != .thumbnailFormatTgs {
            return thumbnail.file
        }
        return nil
    }

    func prefetchCovers(for sets: [StickerSetInfo]) {
        Task { [weak self] in
            guard let self else { return }
            for info in sets {
                if let file = Self.coverFile(for: info) {
                    try? await self.telegram.downloadFile(startingOnly: file)
                }
            }
        }
    }

    func animatedCover(for info: StickerSetInfo) async -> LottieAnimation? {
        let key = String(info.id.rawValue) as NSString
        if let cached = animationCache.object(forKey: key) { return cached }

        var file: File?
        if let thumbnail = info.thumbnail, thumbnail.format == .thumbnailFormatTgs {
            file = thumbnail.file
        } else if let cover = info.covers.first, cover.format == .stickerFormatTgs {
            file = cover.sticker
        }
        guard let file,
              let path = try? await telegram.download(file: file),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? StickerConverter.gunzip(raw),
              let animation = try? LottieAnimation.from(data: json)
        else { return nil }
        animationCache.setObject(animation, forKey: key)
        return animation
    }
}

private extension TelegramService {

    func downloadFile(startingOnly file: File) async throws {
        guard !file.local.isDownloadingCompleted else { return }
        _ = try await downloadStarting(file: file)
    }
}
