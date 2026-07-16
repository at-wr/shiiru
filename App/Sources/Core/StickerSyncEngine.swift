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
            let predecessor = syncChain
            let task = Task { [weak self] in
                _ = await predecessor?.value
                if !Task.isCancelled {
                    await self?.sync(info: info, key: key)
                }
                self?.tasks[key] = nil
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
            let predecessor = syncChain
            let task = Task { [weak self] in
                _ = await predecessor?.value
                if !Task.isCancelled {
                    await self?.syncGifs(key: key)
                }
                self?.tasks[key] = nil
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

    private func syncGifs(key: String) async {
        do {
            let animations = try await telegram.savedAnimations()
            guard !animations.isEmpty else { throw ShiiruError.conversionFailed }

            let syncToken = String(UUID().uuidString.prefix(6))
            let directoryName = "\(key)-\(syncToken)"
            let directory = try store.prepareDirectory(named: directoryName)
            var completed = 0.0
            var manifestStickers: [StickerManifest.Sticker] = []

            for animation in animations {
                _ = try? await telegram.downloadFile(startingOnly: animation.animation)
            }
            for (index, animation) in animations.enumerated() {
                try Task.checkCancellation()
                do {
                    let path = try await telegram.download(file: animation.animation)
                    let isVideo = animation.mimeType.hasPrefix("video")
                    let output: StickerConverter.Output = try await Task.detached(priority: .userInitiated) {
                        if isVideo {
                            return try await StickerConverter.convertVideo(at: path)
                        }
                        return try StickerConverter.convertAnimatedImage(at: path)
                    }.value
                    let fileName = String(
                        format: "%03d-%@.%@", index, syncToken, output.fileExtension
                    )
                    try output.data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                    manifestStickers.append(StickerManifest.Sticker(
                        fileName: fileName, emoji: "", isAnimated: output.isAnimated
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    NSLog("[Shiiru] Skipping GIF \(index): \(error)")
                }
                completed += 1
                phases[key] = .syncing(progress: completed / Double(animations.count))
            }
            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }
            store.upsert(pack: StickerManifest.Pack(
                id: key, name: key, title: "GIFs",
                isAnimated: true,
                kind: "gif",
                converterVersion: StickerConverter.pipelineVersion,
                directory: directoryName,
                stickers: manifestStickers
            ))
            phases[key] = .synced
            Haptics.success()
        } catch is CancellationError {
            store.removePack(id: key)
            phases[key] = .idle
        } catch {
            store.removePack(id: key)
            let message = (error as? TDLibKit.Error)?.friendlyMessage ?? error.localizedDescription
            phases[key] = .failed(message: message)
            Haptics.error()
        }
    }

    private func sync(info: StickerSetInfo, key: String) async {
        do {
            let set = try await telegram.stickerSet(id: info.id)
            let stickers = set.stickers
            guard !stickers.isEmpty else { throw ShiiruError.conversionFailed }

            let syncToken = String(UUID().uuidString.prefix(6))
            let directoryName = "\(key)-\(syncToken)"
            let directory = try store.prepareDirectory(named: directoryName)
            var completed = 0.0
            let total = Double(stickers.count)
            var manifestStickers: [StickerManifest.Sticker] = []

            for sticker in stickers {
                _ = try? await telegram.downloadFile(startingOnly: sticker.sticker)
            }

            for (index, sticker) in stickers.enumerated() {
                try Task.checkCancellation()
                do {
                    let output = try await convert(sticker: sticker)

                    let fileName = String(
                        format: "%03d-%@.%@", index, syncToken, output.fileExtension
                    )
                    try output.data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                    manifestStickers.append(StickerManifest.Sticker(
                        fileName: fileName,
                        emoji: sticker.emoji,
                        isAnimated: output.isAnimated
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {

                    NSLog("[Shiiru] Skipping sticker \(index) in \(info.name): \(error)")
                }
                completed += 1
                phases[key] = .syncing(progress: completed / total)
            }

            guard !manifestStickers.isEmpty else { throw ShiiruError.conversionFailed }

            store.upsert(pack: StickerManifest.Pack(
                id: key,
                name: set.name,
                title: set.title,
                isAnimated: stickers.contains { $0.format == .stickerFormatTgs },
                kind: info.stickerType == .stickerTypeCustomEmoji ? "emoji" : "sticker",
                converterVersion: StickerConverter.pipelineVersion,
                directory: directoryName,
                stickers: manifestStickers
            ))
            phases[key] = .synced
            Haptics.success()
        } catch is CancellationError {
            store.removePack(id: key)
            phases[key] = .idle
        } catch {
            store.removePack(id: key)
            let message = (error as? TDLibKit.Error)?.friendlyMessage ?? error.localizedDescription
            phases[key] = .failed(message: message)
            Haptics.error()
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
            return .png(try await Task.detached(priority: .userInitiated) {
                try StickerConverter.convertStaticImage(at: thumbPath)
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
