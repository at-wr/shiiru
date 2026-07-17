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

    private var registeredHandler = false
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

    func packQueued() {
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

    func updateProgress(packTitle: String, fraction: Double) {
        currentTitle = packTitle
        currentFraction = fraction
        publishProgress()
    }

    func packFinished() {
        finishedPacks += 1
        currentFraction = 0
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
            Self.log.info("continued task completed: queue drained")
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
              nudgeUnits < 5
        else { return }
        nudgeUnits += 1
        task.progress.completedUnitCount = min(realUnits + nudgeUnits, 999)
    }

    // MARK: - Lifetime

    private func beginIfNeeded() {
        // Submissions must be user-initiated from the foreground; syncs
        // running inside a BGProcessingTask window need no extra keepalive.
        guard UIApplication.shared.applicationState == .active else { return }

        if legacyToken == .invalid {
            legacyToken = UIApplication.shared.beginBackgroundTask(withName: "StickerSync") { [weak self] in
                Self.log.info("legacy background task expired")
                self?.endLegacyTask()
            }
        }
        if #available(iOS 26.0, *), continuedTask == nil {
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
            Self.log.info("continued task submitted")
        } catch {
            Self.log.error("continued task submit failed: \(String(describing: error))")
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        // The queue may have drained before the system launched the task.
        guard syncing else {
            task.setTaskCompleted(success: true)
            Self.log.info("continued task launched after queue drained; completing")
            return
        }
        Self.log.info("continued task adopted (\(self.totalPacks) packs queued)")
        continuedTask = task
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self,
                      let task = self.continuedTask as? BGContinuedProcessingTask
                else { return }
                // Expired or user-cancelled from the system UI: the in-app
                // sync state stays intact and finishes next foreground.
                Self.log.warning("continued task expired/cancelled by system")
                task.setTaskCompleted(success: false)
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
        let overall = (Double(finishedPacks) + min(currentFraction, 1))
            / Double(max(totalPacks, 1))
        realUnits = Int64((overall * 1000).rounded())
        nudgeUnits = 0
        task.progress.completedUnitCount = realUnits
        if let currentTitle {
            task.updateTitle(
                String(localized: "Syncing \(currentTitle)"),
                subtitle: String(localized: "Pack \(min(finishedPacks + 1, totalPacks)) of \(totalPacks)")
            )
        }
    }
}
