import Foundation
import BackgroundTasks
import UIKit
import os.log

/// Fully hands-off pack upkeep.
///
/// A discretionary `BGProcessingTask` the system runs when the device is
/// idle (typically overnight on charge, with network). It brings TDLib up
/// from the stored session, diffs Telegram against the synced store, and
/// (re)converts whatever drifted: new packs (when auto-add is on), packs
/// whose Telegram contents changed, and packs converted by an older
/// pipeline (i.e. after an app update). Results land in the shared
/// container, where the Messages extension's manifest watcher picks them
/// up on its own — the user never has to open the app.
@MainActor
enum BackgroundMaintenance {

    /// Must be listed under BGTaskSchedulerPermittedIdentifiers, with
    /// UIBackgroundModes: processing.
    static let taskIdentifier = "dev.alany.shiiru.maintenance"

    private static let log = Logger(subsystem: "dev.alany.shiiru", category: "Maintenance")

    private static var current: Task<Void, Never>?

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: .main
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { handle(task) }
        }
    }

    /// Idempotent: resubmitting the identifier replaces the pending request.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("schedule failed: \(String(describing: error))")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule() // keep the next window booked no matter how this one ends

        let work = runCheck()

        task.expirationHandler = {
            Task { @MainActor in
                log.warning("maintenance window expired; stopping syncs")
                work.cancel()
                StickerSyncEngine.shared.cancelActiveSyncs()
            }
        }

        Task { @MainActor in
            await work.value
            task.setTaskCompleted(success: true)
        }
    }

    /// Runs one drift check + repair pass. Single-flight: a check already in
    /// progress is returned instead of starting another. Called from the
    /// nightly BGProcessingTask, and from the app on foreground loads so
    /// author-side pack edits apply the moment the user opens the app.
    @discardableResult
    static func runCheck() -> Task<Void, Never> {
        if let current { return current }
        let work = Task { @MainActor in
            defer { current = nil }

            guard !DemoSession.isActive, !PreviewMode.isActive else { return }
            let telegram = TelegramService.shared
            guard await telegram.waitUntilReady(timeout: 30) else {
                log.info("TDLib not ready (logged out or offline); skipping")
                return
            }
            let installed = (try? await telegram.installedStickerSets()) ?? []
            let emoji = (try? await telegram.customEmojiSets()) ?? []
            let animations = try? await telegram.savedAnimations()

            let manifest = SharedStickerStore.shared.loadManifest()
            // File probing off the main actor; only stale packs are read.
            // The same hop sweeps directories orphaned by interrupted syncs
            // and trims TDLib's download cache.
            let suspects = await Task.detached(priority: .utility) {
                SharedStickerStore.shared.sweepUnreferencedDirectories()
                return StickerAudit.suspectPackIDs(
                    manifest: manifest, pipelineVersion: StickerConverter.pipelineVersion
                )
            }.value
            await telegram.trimFileCache()
            let plan = MaintenancePlan.compute(
                manifest: manifest,
                installed: installed.map { .init(id: String($0.id.rawValue), size: $0.size) },
                emoji: emoji.map { .init(id: String($0.id.rawValue), size: $0.size) },
                knownPackIDs: Preferences.knownPackIDs,
                autoAddNewPacks: Preferences.autoAddNewPacks,
                pipelineVersion: StickerConverter.pipelineVersion,
                suspectPackIDs: suspects,
                gifCount: animations?.count,
                gifHash: animations.map { SourceFingerprint.hash(of: $0.map(\.animation.remote.uniqueId)) }
            )
            guard !plan.isEmpty else {
                log.info("nothing to do")
                return
            }

            // Same-count packs: fetch the full set and compare fingerprints
            // to catch one-removed-one-added edits.
            var stickerIDs = plan.stickerSetIDs
            var emojiIDs = plan.emojiSetIDs
            let packsByID = Dictionary(uniqueKeysWithValues: manifest.packs.map { ($0.id, $0) })
            for info in installed + emoji {
                let id = String(info.id.rawValue)
                let isSticker = plan.verifyStickerIDs.contains(id)
                guard isSticker || plan.verifyEmojiIDs.contains(id),
                      let pack = packsByID[id],
                      let expected = pack.sourceHash,
                      !Task.isCancelled,
                      let set = try? await telegram.stickerSet(id: info.id)
                else { continue }
                let actual = SourceFingerprint.hash(of: set.stickers.map(\.sticker.remote.uniqueId))
                var drifted = actual != expected
                // Restamp candidates get one source-side check the local
                // audit can't do: a webm source that ended up static is the
                // old VP8/decode-failure fallback and needs the new decoder.
                if !drifted, plan.restampIDs.contains(id),
                   MaintenancePlan.conversionDegraded(
                       sourceIsVideo: set.stickers.map { $0.format == .stickerFormatWebm },
                       localIsAnimated: pack.stickers.map(\.isAnimated)
                   ) {
                    drifted = true
                }
                if drifted {
                    if isSticker { stickerIDs.insert(id) } else { emojiIDs.insert(id) }
                }
            }
            // Clean stale packs keep their files; only the version stamp
            // moves, so the next pass stops auditing them.
            for id in plan.restampIDs
            where !stickerIDs.contains(id) && !emojiIDs.contains(id)
                && !(id == StickerSyncEngine.gifsPackID && plan.resyncGifs) {
                SharedStickerStore.shared.stamp(
                    packID: id, converterVersion: StickerConverter.pipelineVersion
                )
            }
            guard !stickerIDs.isEmpty || !emojiIDs.isEmpty || plan.resyncGifs else {
                log.info("verified: no content drift")
                return
            }
            log.info("plan: \(stickerIDs.count) sticker, \(emojiIDs.count) emoji, gifs=\(plan.resyncGifs)")

            let engine = StickerSyncEngine.shared
            for info in installed where stickerIDs.contains(String(info.id.rawValue)) {
                engine.setSyncEnabled(true, for: info, userInitiated: false)
            }
            for info in emoji where emojiIDs.contains(String(info.id.rawValue)) {
                engine.setSyncEnabled(true, for: info, userInitiated: false)
            }
            if plan.resyncGifs {
                engine.setGifSyncEnabled(true, userInitiated: false)
            }
            await engine.waitUntilIdle()
            log.info("maintenance finished")
        }
        current = work
        return work
    }
}

/// Pure diff between Telegram's state and the synced store. Kept free of
/// dependencies so it is unit-testable.
struct MaintenancePlan: Equatable {

    struct SetSnapshot {
        let id: String
        let size: Int
    }

    var stickerSetIDs: Set<String> = []
    var emojiSetIDs: Set<String> = []
    var resyncGifs = false
    /// Same-count packs whose contents may still have changed (one removed,
    /// one added): fetch the full set and compare its fingerprint against
    /// the stored sourceHash before deciding.
    var verifyStickerIDs: Set<String> = []
    var verifyEmojiIDs: Set<String> = []
    /// Packs stale only by pipeline version whose files passed the audit:
    /// stamp the manifest to the current version instead of re-converting.
    /// (Verification can still promote one to a re-sync first.)
    var restampIDs: Set<String> = []

    var isEmpty: Bool {
        stickerSetIDs.isEmpty && emojiSetIDs.isEmpty && !resyncGifs
            && verifyStickerIDs.isEmpty && verifyEmojiIDs.isEmpty
            && restampIDs.isEmpty
    }

    static func compute(
        manifest: StickerManifest,
        installed: [SetSnapshot],
        emoji: [SetSnapshot],
        knownPackIDs: Set<String>,
        autoAddNewPacks: Bool,
        pipelineVersion: Int,
        suspectPackIDs: Set<String> = [],
        gifCount: Int? = nil,
        gifHash: String? = nil
    ) -> MaintenancePlan {
        var plan = MaintenancePlan()
        let packs = Dictionary(uniqueKeysWithValues: manifest.packs.map { ($0.id, $0) })

        func needsRefresh(_ pack: StickerManifest.Pack, size: Int?) -> Bool {
            if let size, let source = pack.sourceCount, source != size { return true }
            // Items skipped over transient failures (network drops, flood
            // waits) leave the local copy short of its source; heal it on
            // the next pass instead of shipping a forever-incomplete pack.
            if let source = pack.sourceCount, pack.stickers.count < source { return true }
            // A pipeline bump alone re-converts only packs whose files the
            // audit flagged; the rest are restamped in place below.
            if (pack.converterVersion ?? 0) < pipelineVersion,
               suspectPackIDs.contains(pack.id) { return true }
            return false
        }

        func isStale(_ pack: StickerManifest.Pack) -> Bool {
            (pack.converterVersion ?? 0) < pipelineVersion
        }

        for set in installed {
            if let pack = packs[set.id] {
                if needsRefresh(pack, size: set.size) {
                    plan.stickerSetIDs.insert(set.id)
                } else {
                    if isStale(pack) { plan.restampIDs.insert(set.id) }
                    if pack.sourceHash != nil { plan.verifyStickerIDs.insert(set.id) }
                }
            } else if autoAddNewPacks, !knownPackIDs.contains(set.id) {
                // Genuinely new on the Telegram side; auto-add mirrors the
                // in-app behavior. knownPackIDs stays untouched here so a
                // pack lost to an expired window is retried next run.
                plan.stickerSetIDs.insert(set.id)
            }
            // Packs deleted or archived on Telegram never reach this loop
            // and are deliberately left alone: the app's "No Longer on
            // Telegram" section is where the user decides their fate.
        }
        // Emoji packs refresh but never auto-add (parity with the app UI).
        for set in emoji {
            guard let pack = packs[set.id] else { continue }
            if needsRefresh(pack, size: set.size) {
                plan.emojiSetIDs.insert(set.id)
            } else {
                if isStale(pack) { plan.restampIDs.insert(set.id) }
                if pack.sourceHash != nil { plan.verifyEmojiIDs.insert(set.id) }
            }
        }
        // Saved GIFs mirror the Telegram list, but an emptied list must not
        // churn a nightly re-sync that can only fail.
        if let pack = packs["gifs"], pack.packKind == "gif", let gifCount, gifCount > 0 {
            if needsRefresh(pack, size: gifCount) {
                plan.resyncGifs = true
            } else if let gifHash, let source = pack.sourceHash, gifHash != source {
                plan.resyncGifs = true
            } else if isStale(pack) {
                plan.restampIDs.insert(pack.id)
            }
        }
        return plan
    }

    /// True when a source that must animate (webm video sticker) maps to a
    /// static local file — the signature of the old VP8/decode-failure
    /// fallback. Only meaningful for equal-length, order-preserved lists.
    static func conversionDegraded(sourceIsVideo: [Bool], localIsAnimated: [Bool]) -> Bool {
        guard sourceIsVideo.count == localIsAnimated.count else { return false }
        return zip(sourceIsVideo, localIsAnimated).contains { $0 && !$1 }
    }
}
