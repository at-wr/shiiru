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

    private static var running: Task<Void, Never>?

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

        guard !DemoSession.isActive, !PreviewMode.isActive else {
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { @MainActor in
            let telegram = TelegramService.shared
            guard await telegram.waitUntilReady(timeout: 30) else {
                log.info("TDLib not ready (logged out or offline); skipping")
                return
            }
            let installed = (try? await telegram.installedStickerSets()) ?? []
            let emoji = (try? await telegram.customEmojiSets()) ?? []
            let gifCount = (try? await telegram.savedAnimations())?.count

            let plan = MaintenancePlan.compute(
                manifest: SharedStickerStore.shared.loadManifest(),
                installed: installed.map { .init(id: String($0.id.rawValue), size: $0.size) },
                emoji: emoji.map { .init(id: String($0.id.rawValue), size: $0.size) },
                knownPackIDs: Preferences.knownPackIDs,
                autoAddNewPacks: Preferences.autoAddNewPacks,
                pipelineVersion: StickerConverter.pipelineVersion,
                gifCount: gifCount
            )
            guard !plan.isEmpty else {
                log.info("nothing to do")
                return
            }
            log.info("plan: \(plan.stickerSetIDs.count) sticker, \(plan.emojiSetIDs.count) emoji, gifs=\(plan.resyncGifs)")

            let engine = StickerSyncEngine.shared
            for info in installed where plan.stickerSetIDs.contains(String(info.id.rawValue)) {
                engine.setSyncEnabled(true, for: info)
            }
            for info in emoji where plan.emojiSetIDs.contains(String(info.id.rawValue)) {
                engine.setSyncEnabled(true, for: info)
            }
            if plan.resyncGifs {
                engine.setGifSyncEnabled(true)
            }
            await engine.waitUntilIdle()
            log.info("maintenance finished")
        }
        running = work

        task.expirationHandler = {
            Task { @MainActor in
                log.warning("maintenance window expired; stopping syncs")
                running?.cancel()
                StickerSyncEngine.shared.cancelActiveSyncs()
            }
        }

        Task { @MainActor in
            await work.value
            running = nil
            task.setTaskCompleted(success: true)
        }
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

    var isEmpty: Bool { stickerSetIDs.isEmpty && emojiSetIDs.isEmpty && !resyncGifs }

    static func compute(
        manifest: StickerManifest,
        installed: [SetSnapshot],
        emoji: [SetSnapshot],
        knownPackIDs: Set<String>,
        autoAddNewPacks: Bool,
        pipelineVersion: Int,
        gifCount: Int? = nil
    ) -> MaintenancePlan {
        var plan = MaintenancePlan()
        let packs = Dictionary(uniqueKeysWithValues: manifest.packs.map { ($0.id, $0) })

        func needsRefresh(_ pack: StickerManifest.Pack, size: Int?) -> Bool {
            if (pack.converterVersion ?? 0) < pipelineVersion { return true }
            if let size, let source = pack.sourceCount, source != size { return true }
            return false
        }

        for set in installed {
            if let pack = packs[set.id] {
                if needsRefresh(pack, size: set.size) { plan.stickerSetIDs.insert(set.id) }
            } else if autoAddNewPacks, !knownPackIDs.contains(set.id) {
                // Genuinely new on the Telegram side; auto-add mirrors the
                // in-app behavior. knownPackIDs stays untouched here so a
                // pack lost to an expired window is retried next run.
                plan.stickerSetIDs.insert(set.id)
            }
        }
        // Emoji packs refresh but never auto-add (parity with the app UI).
        for set in emoji {
            if let pack = packs[set.id], needsRefresh(pack, size: set.size) {
                plan.emojiSetIDs.insert(set.id)
            }
        }
        if let pack = packs["gifs"], pack.packKind == "gif" {
            plan.resyncGifs = needsRefresh(pack, size: gifCount)
        }
        return plan
    }
}
