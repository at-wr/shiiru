import Foundation
import UIKit
import BackgroundTasks
import os.log

/// Keeps a sticker sync alive after the user leaves the app.
///
/// On iOS 26+ this rides `BGContinuedProcessingTask`: the system shows a
/// live progress pill with a cancel affordance and keeps the process
/// running while we download and transcode. A `UIApplication` background
/// task is held alongside as a bridge for the moments before the system
/// actually launches the continued task. On earlier releases the bridge is
/// all there is (~30 s), and the sync resumes on next foreground.
///
/// Continued-processing tasks must be submitted as the direct result of a
/// user action, so submission only happens while the app is active — a
/// sync started by background maintenance is already covered by its own
/// BGProcessingTask window and must not submit anything here.
@MainActor
final class SyncBackgroundSession {

    static let shared = SyncBackgroundSession()

    /// Must be listed under BGTaskSchedulerPermittedIdentifiers.
    private static let taskIdentifier = "dev.alany.shiiru.sync"

    private static let log = Logger(subsystem: "dev.alany.shiiru", category: "BackgroundSync")

    /// Unified log plus, in debug builds, stderr — so an attached
    /// `devicectl --console` session sees the sequence too.
    private static func trace(_ message: String, error: Bool = false) {
        if error { log.error("\(message)") } else { log.info("\(message)") }
        #if DEBUG
        NSLog("[Shiiru][BackgroundSync] %@", message)
        #endif
    }

    private var registeredHandler = false
    /// A request is in flight (submitted, not yet launched by the system).
    private var submissionPending = false
    /// BGContinuedProcessingTask, held loosely typed so the class loads on
    /// pre-26 runtimes.
    private var continuedTask: AnyObject?
    private var legacyToken: UIBackgroundTaskIdentifier = .invalid
    /// True from the first queued pack until the queue drains.
    private var syncing = false

    private var totalPacks = 0
    private var finishedPacks = 0
    private var currentFraction = 0.0
    private var currentTitle: String?

    /// The system expires continued tasks that stop reporting progress, and
    /// a single dense sticker can take a while between real ticks (longer
    /// still at background QoS). The heartbeat inches the bar forward a few
    /// per-mille between real updates so activity stays visible.
    private var heartbeat: Timer?
    private var realUnits: Int64 = 0
    private var nudgeUnits: Int64 = 0

    private init() {}

    // MARK: - Engine hooks

    /// Every foreground-visible sync queue rides the pill — a first
    /// onboarding batch or a post-update migration is work the user is
    /// waiting on just as much as a manual toggle. (Syncs started inside
    /// the nightly BGProcessingTask never reach submission: the
    /// foreground-active guard in beginIfNeeded covers that window.)
    func packQueued(key: String, userInitiated: Bool) {
        if !syncing {
            syncing = true
            totalPacks = 0
            finishedPacks = 0
            currentFraction = 0
            currentTitle = nil
        }
        totalPacks += 1
        beginIfNeeded()
        publishProgress()
    }

    private var progressTicks = 0
    private var stickerCompleted = 0
    private var stickerTotal = 0

    /// `fraction` is cost-weighted (video stickers dominate a pack's time),
    /// so the bar moves honestly; completed/total drive the subtitle.
    func updateProgress(key: String, packTitle: String, completed: Int, total: Int, fraction: Double) {
        currentTitle = packTitle
        currentFraction = fraction
        stickerCompleted = completed
        stickerTotal = total
        progressTicks += 1
        if progressTicks % 10 == 0 {
            Self.trace("progress \(packTitle) \(completed)/\(total) (tick \(progressTicks))")
        }
        publishProgress()
    }

    func packFinished(key: String) {
        finishedPacks += 1
        currentFraction = 0
        stickerTotal = 0
        Self.trace("pack finished (\(finishedPacks)/\(totalPacks))")
        publishProgress()
    }

    /// The sync queue is empty; release whatever keeps us alive.
    func allDrained() {
        syncing = false
        stopHeartbeat()
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            continuedTask = nil
            Self.trace("continued task completed: queue drained")
        }
        endLegacyTask()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        nudgeUnits = 0
    }

    private func heartbeatTick() {
        guard #available(iOS 26.0, *), syncing,
              let task = continuedTask as? BGContinuedProcessingTask,
              nudgeUnits < 20
        else { return }
        nudgeUnits += 1
        task.progress.completedUnitCount = min(
            realUnits + nudgeUnits, task.progress.totalUnitCount - 1
        )
    }

    // MARK: - Lifetime

    private func beginIfNeeded() {
        // Submissions must be user-initiated from the foreground; syncs
        // running inside a BGProcessingTask window need no extra keepalive.
        guard UIApplication.shared.applicationState == .active else { return }

        if legacyToken == .invalid {
            legacyToken = UIApplication.shared.beginBackgroundTask(withName: "StickerSync") { [weak self] in
                Self.trace("legacy background task expired")
                self?.endLegacyTask()
            }
        }
        if #available(iOS 26.0, *), continuedTask == nil, !submissionPending {
            submitContinuedTask()
        }
    }

    private func endLegacyTask() {
        guard legacyToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyToken)
        legacyToken = .invalid
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask() {
        if !registeredHandler {
            registeredHandler = true
            // Continued-processing handlers are registered at the moment of
            // user intent (unlike BGProcessingTask, which must register at
            // launch).
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.taskIdentifier, using: .main
            ) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MainActor.assumeIsolated {
                    self?.adopt(task)
                }
            }
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: String(localized: "Syncing sticker packs"),
            subtitle: String(localized: "Preparing…")
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            submissionPending = true
            Self.trace("continued task submitted")
        } catch {
            Self.trace("continued task submit failed: \(String(describing: error))", error: true)
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        submissionPending = false
        // The queue may have drained before the system launched the task.
        guard syncing else {
            task.setTaskCompleted(success: true)
            Self.trace("continued task launched after queue drained; completing")
            return
        }
        Self.trace("continued task adopted (\(self.totalPacks) packs queued)")
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self,
                      let task = self.continuedTask as? BGContinuedProcessingTask
                else { return }
                // Out of background runtime (or cancelled from the system
                // UI). Nothing is lost — finished packs are committed and
                // the queue resumes next foreground — so this ends as a
                // pause, not the scary "Sync Failed" pill.
                Self.trace("continued task expired; checkpointed for next foreground", error: true)
                task.updateTitle(
                    String(localized: "Sticker sync paused"),
                    subtitle: String(localized: "Continues next time you open Shiiru")
                )
                task.setTaskCompleted(success: true)
                self.continuedTask = nil
                self.stopHeartbeat()
            }
        }
        startHeartbeat()
        publishProgress()
    }

    private func publishProgress() {
        guard #available(iOS 26.0, *),
              let task = continuedTask as? BGContinuedProcessingTask
        else { return }
        // 1000 units per pack, and the total grows as packs queue up: a
        // single converted sticker in a 100-sticker pack is ~10 visible
        // units. Coarser scales rounded per-sticker progress to zero, the
        // system saw a stalled task, and expired it ("Sync Failed").
        task.progress.totalUnitCount = Int64(max(totalPacks, 1)) * 1000
        realUnits = Int64(((Double(finishedPacks) + min(currentFraction, 1)) * 1000).rounded())
        nudgeUnits = 0
        task.progress.completedUnitCount = realUnits
        if let currentTitle {
            // Per-sticker detail so dense video packs visibly move; the
            // pack counter only matters when several are queued.
            var subtitle = stickerTotal > 0
                ? String(localized: "Sticker \(min(stickerCompleted + 1, stickerTotal)) of \(stickerTotal)")
                : ""
            if totalPacks > 1 {
                let pack = String(localized: "Pack \(min(finishedPacks + 1, totalPacks)) of \(totalPacks)")
                subtitle = subtitle.isEmpty ? pack : "\(subtitle) · \(pack)"
            }
            task.updateTitle(String(localized: "Syncing \(currentTitle)"), subtitle: subtitle)
        }
    }
}
