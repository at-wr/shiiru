import Foundation
import UIKit
import BackgroundTasks
import Combine
import os
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
    ///
    /// It runs as a strict dispatch timer on a background queue and writes
    /// `Progress` (thread-safe) directly: main-runloop timers stall once
    /// the device locks, and a field log showed dasd's Activity Progress
    /// Policy expiring the task ~70 s after lock for exactly that reason.
    private var heartbeatSource: DispatchSourceTimer?
    /// Monotonic unit counter shared with the heartbeat thread; the
    /// progress object rides along so ticks never touch the main actor.
    private let pulse = OSAllocatedUnfairLock<(pulse: ProgressPulse, progress: Progress?)>(
        initialState: (ProgressPulse(), nil)
    )
    private var connectivityWatch: AnyCancellable?
    /// True while the pill is retitled to the waiting-for-network state.
    private var offlineTitleShown = false

    private init() {
        // An expired or user-cancelled continued task never runs again on
        // its own (the API only extends foreground time) — but the sync
        // queue survives and resumes when the app returns. Re-arming the
        // keepalive on activation means the next trip to the background
        // rides a fresh continued task instead of freezing silently.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.syncing else { return }
                Self.trace("app active with sync in flight; re-arming keepalive")
                self.beginIfNeeded()
            }
        }
    }

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
        guard heartbeatSource == nil else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(200))
        source.setEventHandler { [pulse] in
            pulse.withLock { state in
                guard let progress = state.progress,
                      let published = state.pulse.beat() else { return }
                progress.completedUnitCount = published
            }
        }
        source.resume()
        heartbeatSource = source

        // Connectivity drives the heartbeat's pace and the pill's honesty:
        // offline, real progress stalls through no fault of the sync, so
        // the crawl slows (larger allowance, third cadence) and the title
        // says why instead of looking stuck.
        connectivityWatch = TelegramService.shared.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.connectionChanged(connected)
            }
    }

    private func stopHeartbeat() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
        connectivityWatch = nil
        offlineTitleShown = false
        pulse.withLock { state in
            state.pulse.reset()
            state.progress = nil
        }
    }

    private func connectionChanged(_ connected: Bool) {
        guard #available(iOS 26.0, *), syncing,
              let task = continuedTask as? BGContinuedProcessingTask
        else { return }
        pulse.withLock { state in
            state.pulse.lead = connected ? 40 : 100
            state.pulse.cadence = connected ? 1 : 3
        }
        if connected {
            if offlineTitleShown {
                offlineTitleShown = false
                publishProgress()
            }
        } else if !offlineTitleShown {
            offlineTitleShown = true
            Self.trace("network down; holding continued task alive")
            task.updateTitle(
                String(localized: "Waiting for network…"),
                subtitle: String(localized: "Sync continues when you're back online")
            )
        }
    }

    // MARK: - Lifetime

    private func beginIfNeeded() {
        // Submissions must be user-initiated from the foreground; syncs
        // running inside a BGProcessingTask window need no extra keepalive.
        guard UIApplication.shared.applicationState == .active else { return }

        // The UIKit task only bridges the gap until the continued task
        // launches (and is the whole keepalive pre-26); once one is
        // adopted it must not linger — holding both trips UIKit's
        // 30-second background-task warning and risks termination.
        if legacyToken == .invalid, continuedTask == nil {
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
        // The system now keeps the process alive; the bridge has done its
        // job (field logs showed it lingering into the 30-second warning).
        endLegacyTask()
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
        let total = Int64(max(totalPacks, 1)) * 1000
        let real = Int64(((Double(finishedPacks) + min(currentFraction, 1)) * 1000).rounded())
        let published = pulse.withLock { state in
            state.progress = task.progress
            return state.pulse.update(realUnits: real, totalUnits: total)
        }
        task.progress.totalUnitCount = total
        // Published units are monotonic: synthetic heartbeat lead is never
        // rewound when a real tick lands — the system's progress tracker
        // treats regressions as an unhealthy task.
        task.progress.completedUnitCount = published
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
