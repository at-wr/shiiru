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

    /// One queued pack sync. User-initiated packs jump ahead of the
    /// automatic backlog (stale re-conversions, drift repairs) so the pack
    /// the user just toggled is what runs — and what the background pill
    /// tracks — instead of waiting behind a migration storm.
    private struct PendingSync {
        let key: String
        let userInitiated: Bool
        let run: () async -> Void
    }

    private var pendingSyncs: [PendingSync] = []
    private var runningKey: String?
    private var runner: Task<Void, Never>?

    private var queuedKeys: Set<String> {
        var keys = Set(pendingSyncs.map(\.key))
        if let runningKey { keys.insert(runningKey) }
        return keys
    }

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

    /// `userInitiated` marks syncs the user asked for directly (toggles,
    /// Sync All) — only those may put up the system's background progress
    /// pill. Automatic work (stale re-conversion, drift checks) runs
    /// foreground-only and resumes on the next open or nightly window.
    func setSyncEnabled(_ enabled: Bool, for info: StickerSetInfo, userInitiated: Bool = true) {
        let key = String(info.id.rawValue)
        if enabled {
            guard !queuedKeys.contains(key) else { return }
            phases[key] = .syncing(progress: 0)
            SyncBackgroundSession.shared.packQueued(key: key, userInitiated: userInitiated)
            enqueue(PendingSync(key: key, userInitiated: userInitiated) { [weak self] in
                await self?.sync(info: info, key: key)
            })
        } else {
            dropPending(key: key)
            tasks[key]?.cancel()
            tasks[key] = nil
            store.removePack(id: key)
            phases[key] = .idle
        }
    }

    func resetAllPhases() {
        pendingSyncs.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        phases.removeAll()
    }

    // MARK: - Queue

    private func enqueue(_ item: PendingSync) {
        if item.userInitiated, let index = pendingSyncs.firstIndex(where: { !$0.userInitiated }) {
            pendingSyncs.insert(item, at: index)
        } else {
            pendingSyncs.append(item)
        }
        ensureRunner()
    }

    private func ensureRunner() {
        guard runner == nil, !pendingSyncs.isEmpty else { return }
        runner = Task { [weak self] in
            while let self, !self.pendingSyncs.isEmpty {
                let next = self.pendingSyncs.removeFirst()
                self.runningKey = next.key
                let work = Task { await next.run() }
                self.tasks[next.key] = work
                await work.value
                self.tasks[next.key] = nil
                self.runningKey = nil
                self.noteSyncEnded(key: next.key)
            }
            self?.runner = nil
        }
    }

    /// Removes a not-yet-started sync from the queue (toggle-off, engine
    /// shutdown) and settles its phase and session bookkeeping.
    private func dropPending(key: String) {
        guard let index = pendingSyncs.firstIndex(where: { $0.key == key }) else { return }
        pendingSyncs.remove(at: index)
        phases[key] = store.syncedPackIDs().contains(key) ? .synced : .idle
        noteSyncEnded(key: key)
    }

    /// One queued pack ended (converted, failed, cancelled, or dropped);
    /// when the whole queue drains, the background session can rest.
    private func noteSyncEnded(key: String) {
        SyncBackgroundSession.shared.packFinished(key: key)
        if pendingSyncs.isEmpty, runningKey == nil {
            SyncBackgroundSession.shared.allDrained()
        }
    }

    /// Stops in-flight syncs without touching what is already synced —
    /// used when background execution time runs out. The interrupted
    /// refresh keeps its existing copy via `rollBack`; pending items are
    /// dropped and retried by the next maintenance pass.
    func cancelActiveSyncs() {
        for key in pendingSyncs.map(\.key) {
            dropPending(key: key)
        }
        tasks.values.forEach { $0.cancel() }
    }

    /// Waits for the sync queue to drain (used by background maintenance).
    func waitUntilIdle() async {
        while !Task.isCancelled, let current = runner {
            _ = await current.value
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
        dropPending(key: id)
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

    func setGifSyncEnabled(_ enabled: Bool, userInitiated: Bool = true) {
        let key = Self.gifsPackID
        if enabled {
            guard !queuedKeys.contains(key) else { return }
            phases[key] = .syncing(progress: 0)
            SyncBackgroundSession.shared.packQueued(key: key, userInitiated: userInitiated)
            enqueue(PendingSync(key: key, userInitiated: userInitiated) { [weak self] in
                await self?.syncGifs(key: key)
            })
        } else {
            dropPending(key: key)
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
    ///
    /// In the background iOS enforces a hard CPU budget — 50% of a core
    /// averaged over 180 s — and terminates violators along with the
    /// continued-processing task (observed in the field as an immediate
    /// "task failed" pill ~100 s after backgrounding, at 89% average).
    /// While backgrounded the pipeline therefore runs a single lane and
    /// sleeps ~1.4× each item's duration between items, a ~40% duty cycle.
    private func convertItems<Item: Sendable>(
        _ items: [Item],
        syncToken: String,
        directory: URL,
        weight: (Item) -> Double = { _ in 1 },
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int, _ fraction: Double) -> Void,
        convert: @escaping @Sendable (Item) async throws -> (output: StickerConverter.Output, emoji: String)
    ) async throws -> [StickerManifest.Sticker] {
        var results: [(index: Int, sticker: StickerManifest.Sticker)] = []
        var completed = 0
        // Progress is weighted by expected conversion cost — a video
        // sticker takes orders of magnitude longer than a static one, and
        // an equal-weight bar would sprint through the statics then stall.
        let weights = items.map(weight)
        let totalWeight = max(weights.reduce(0, +), 1)
        var completedWeight = 0.0

        try await withThrowingTaskGroup(
            of: (index: Int, sticker: StickerManifest.Sticker?, elapsed: Duration).self
        ) { group in
            var next = 0
            var inFlight = 0
            let clock = ContinuousClock()
            // `Swift.Error` spelled explicitly: TDLibKit exports its own
            // `Error` type that would otherwise shadow it here.
            func enqueue(
                _ group: inout ThrowingTaskGroup<
                    (index: Int, sticker: StickerManifest.Sticker?, elapsed: Duration), any Swift.Error
                >
            ) {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                inFlight += 1
                group.addTask {
                    let start = clock.now
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
                        ), clock.now - start)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        NSLog("[Shiiru] Skipping item \(index): \(error)")
                        return (index, nil, clock.now - start)
                    }
                }
            }

            func isBackgrounded() async -> Bool {
                await MainActor.run { UIApplication.shared.applicationState == .background }
            }

            enqueue(&group)
            if await !isBackgrounded() { enqueue(&group) }
            while let (index, sticker, elapsed) = try await group.next() {
                inFlight -= 1
                if let sticker { results.append((index, sticker)) }
                completed += 1
                completedWeight += weights[index]
                onProgress(completed, items.count, completedWeight / totalWeight)
                if await isBackgrounded() {
                    // Duty-cycle pause; capped so the progress pill's
                    // heartbeat window comfortably outlasts it.
                    try? await Task.sleep(for: min(elapsed * 1.4, .seconds(45)))
                    if inFlight == 0 { enqueue(&group) }
                } else {
                    enqueue(&group)
                    if inFlight < 2 { enqueue(&group) }
                }
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
                weight: { $0.mimeType.hasPrefix("video") ? 10 : 2 },
                onProgress: { [weak self] completed, total, fraction in
                    self?.phases[key] = .syncing(progress: fraction)
                    SyncBackgroundSession.shared.updateProgress(
                        key: key, packTitle: "Saved GIFs",
                        completed: completed, total: total, fraction: fraction
                    )
                },
                convert: { [telegram] animation in
                    try Task.checkCancellation()
                    let path = try await telegram.download(file: animation.animation)
                    let isVideo = animation.mimeType.hasPrefix("video")
                    let output: StickerConverter.Output = try await detachedCancellable {
                        if isVideo {
                            return try await StickerConverter.convertVideo(at: path)
                        }
                        return try StickerConverter.convertAnimatedImage(at: path)
                    }
                    return (output, "")
                }
            )
            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }
            // A cancelled sync must not publish — toggling off already
            // removed the pack, and upserting would resurrect it.
            try Task.checkCancellation()
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
                // Rough foreground cost ratios: webp ~instant, TGS renders
                // in fractions of a second, webm decodes+encodes for many
                // seconds.
                weight: { sticker in
                    switch sticker.format {
                    case .stickerFormatWebp: return 1
                    case .stickerFormatTgs: return 6
                    case .stickerFormatWebm: return 20
                    }
                },
                onProgress: { [weak self] completed, total, fraction in
                    self?.phases[key] = .syncing(progress: fraction)
                    SyncBackgroundSession.shared.updateProgress(
                        key: key, packTitle: title,
                        completed: completed, total: total, fraction: fraction
                    )
                },
                convert: { [weak self] sticker in
                    guard let self else { throw CancellationError() }
                    return (try await self.convert(sticker: sticker), sticker.emoji)
                }
            )

            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }
            // A cancelled sync must not publish — toggling off already
            // removed the pack, and upserting would resurrect it.
            try Task.checkCancellation()

            // First-time packs pin to the top of the saved order — the same
            // spot the "NEW" row occupies — so they don't sink to the bottom
            // of the app list and the iMessage panel after a relaunch.
            if !Preferences.packOrder.contains(key), !store.syncedPackIDs().contains(key) {
                Preferences.packOrder = [key] + Preferences.packOrder
            }

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
        try Task.checkCancellation()
        // Custom emoji artwork rarely fills its canvas; crop and enlarge it
        // so the glyph doesn't float inside a mostly-empty sticker.
        var fill = false
        if case .stickerFullTypeCustomEmoji = sticker.fullType { fill = true }
        // Emoji always favor fluid motion; stickers follow the user's
        // transcode preset (Settings → Transcoding).
        let profile = fill ? TranscodeProfile.emoji : TranscodePreset.current.profile
        switch sticker.format {
        case .stickerFormatWebp:
            let path = try await telegram.download(file: sticker.sticker)
            return .png(try await detachedCancellable { [fill] in
                try StickerConverter.convertStaticImage(at: path, fillCanvas: fill)
            })
        case .stickerFormatTgs:
            let path = try await telegram.download(file: sticker.sticker)
            return try await StickerConverter.convertTGS(at: path, fillCanvas: fill, profile: profile)
        case .stickerFormatWebm:
            let path = try await telegram.download(file: sticker.sticker)
            do {
                return try await detachedCancellable { [fill, profile] in
                    try StickerConverter.convertWebm(at: path, fillCanvas: fill, profile: profile)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the pack usable, but leave a trace — a silent
                // downgrade reads as "sticker randomly static" in the field.
                NSLog("[Shiiru] webm conversion failed (%@), using static thumbnail", String(describing: error))
            }

            guard let thumbnail = sticker.thumbnail else { throw ShiiruError.unsupportedSticker }
            let thumbPath = try await telegram.download(file: thumbnail.file)
            return .png(try await detachedCancellable { [fill] in
                try StickerConverter.convertStaticImage(at: thumbPath, fillCanvas: fill)
            })
        }
    }

    /// Synchronous cache hits let list rebuilds (segment switches, full
    /// reloads) paint covers immediately instead of blank-then-fill.
    func cachedCover(for info: StickerSetInfo) -> UIImage? {
        thumbnailCache.object(forKey: String(info.id.rawValue) as NSString)
    }

    func cachedAnimatedCover(for info: StickerSetInfo) -> LottieAnimation? {
        animationCache.object(forKey: String(info.id.rawValue) as NSString)
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

/// Runs blocking conversion work off the main actor while preserving the
/// caller's cancellation. A bare `Task.detached` severs it — cancelling a
/// sync would leave the current sticker (and with it the whole pack) grinding
/// on to completion.
func detachedCancellable<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) { try await work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
