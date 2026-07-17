import Foundation
import UIKit
import BackgroundTasks

/// Keeps a sticker sync alive after the user leaves the app.
///
/// On iOS 26+ this rides `BGContinuedProcessingTask`: the system shows a
/// live progress pill with a cancel affordance and keeps the process
/// running while we download and transcode. On earlier releases the best
/// available fallback is a `UIApplication` background task, which buys the
/// standard ~30 s grace period to checkpoint; the sync then resumes the
/// next time the app comes to the foreground.
///
/// Continued-processing tasks must be submitted as the direct result of a
/// user action — all call sites originate from the sync toggles.
@MainActor
final class SyncBackgroundSession {

    static let shared = SyncBackgroundSession()

    /// Must be listed under BGTaskSchedulerPermittedIdentifiers.
    private static let taskIdentifier = "dev.alany.shiiru.sync"

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
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            continuedTask = nil
        }
        endLegacyTask()
    }

    // MARK: - Lifetime

    private func beginIfNeeded() {
        if #available(iOS 26.0, *) {
            guard continuedTask == nil else { return }
            submitContinuedTask()
        } else {
            guard legacyToken == .invalid else { return }
            legacyToken = UIApplication.shared.beginBackgroundTask(withName: "StickerSync") { [weak self] in
                self?.endLegacyTask()
            }
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
        } catch {
            NSLog("[Shiiru] Continued processing submit failed: \(error)")
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        // The queue may have drained before the system launched the task.
        guard syncing else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self,
                      let task = self.continuedTask as? BGContinuedProcessingTask
                else { return }
                // Expired or user-cancelled from the system UI: the in-app
                // sync state stays intact and finishes next foreground.
                task.setTaskCompleted(success: false)
                self.continuedTask = nil
            }
        }
        publishProgress()
    }

    private func publishProgress() {
        guard #available(iOS 26.0, *),
              let task = continuedTask as? BGContinuedProcessingTask
        else { return }
        let overall = (Double(finishedPacks) + min(currentFraction, 1))
            / Double(max(totalPacks, 1))
        task.progress.completedUnitCount = Int64((overall * 1000).rounded())
        if let currentTitle {
            task.updateTitle(
                String(localized: "Syncing \(currentTitle)"),
                subtitle: String(localized: "Pack \(min(finishedPacks + 1, totalPacks)) of \(totalPacks)")
            )
        }
    }
}
