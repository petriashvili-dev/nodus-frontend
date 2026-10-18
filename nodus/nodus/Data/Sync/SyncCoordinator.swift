import Foundation
import Network
import UIKit
import os

/// Decides when to sync. One cycle runs at a time; triggers that arrive
/// during a cycle merge into one follow-up cycle (docs/ios/03-sync-engine.md).
///
/// Triggers: launch and foreground, a local change (debounced), the network
/// coming back (`NWPathMonitor` is only a hint), a calendar day or time
/// zone change, a backoff timer for postponed operations, and SSE signals
/// while in the foreground.
@MainActor
final class SyncCoordinator {
    private let engine: SyncEngine
    private var eventStream: EventStream?
    private let logger = Logger(subsystem: "app.nodus", category: "Sync")
    private let pathMonitor = NWPathMonitor()

    /// Called after every cycle so screens re-read the local store.
    var onDataChanged: () -> Void = {}

    private var cycleTask: Task<Void, Never>?
    private var needsAnotherCycle = false
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isNetworkAvailable = true
    private var observers: [NSObjectProtocol] = []

    init(engine: SyncEngine) {
        self.engine = engine
    }

    /// The SSE connection; created by `AppServices` once the API exists.
    func attach(_ stream: EventStream) {
        eventStream = stream
    }

    /// Foreground: sync and keep the event stream open.
    func enterForeground() {
        requestSync()
        Task { await eventStream?.start() }
    }

    /// Background: the stream is closed; push and the next launch catch up.
    func enterBackground() {
        Task { await eventStream?.stop() }
    }

    func start() {
        guard observers.isEmpty else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let coordinator = self
            Task { @MainActor in coordinator?.networkChanged(available: available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.nodus.path-monitor"))

        let center = NotificationCenter.default
        // Midnight, DST and a time zone change all arrive here; the feed and
        // the notification plan follow the new day or zone.
        for name in [UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let coordinator = self
                Task { @MainActor in coordinator?.requestSync() }
            })
        }
    }

    /// Runs a cycle now, or right after the current one.
    func requestSync() {
        if cycleTask != nil {
            needsAnotherCycle = true
            return
        }
        cycleTask = Task { await runCycles() }
    }

    /// A local change: wait briefly so a burst of edits goes out together.
    func localChangeQueued() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            requestSync()
        }
    }

    /// Waits for the cycle in progress (pull-to-refresh, tests).
    func syncNow() async {
        requestSync()
        await cycleTask?.value
    }

    func failedOperations() async -> [SyncEngine.FailedOperation] {
        (try? await engine.failedOperations()) ?? []
    }

    func retryFailedOperation(_ id: UUID) async {
        do {
            try await engine.retryFailedOperation(id)
            requestSync()
        } catch {
            logger.error("Could not retry failed Outbox operation")
        }
    }

    func cancelFailedOperation(_ id: UUID) async {
        do {
            try await engine.cancelFailedOperation(id)
            requestSync()
        } catch {
            logger.error("Could not cancel failed Outbox operation")
        }
    }

    private func runCycles() async {
        repeat {
            needsAnotherCycle = false
            let result = await engine.runCycle(timeZone: .current)
            onDataChanged()
            if result == .sessionEnded {
                logger.notice("Sync paused: the session has ended")
            }
            await scheduleRetry(after: result)
        } while needsAnotherCycle
        cycleTask = nil
    }

    private func scheduleRetry(after result: SyncEngine.CycleResult) async {
        retryTask?.cancel()
        guard result != .sessionEnded else { return }
        guard let next = try? await engine.nextRetryDate() else { return }
        // Offline: the path monitor wakes the queue; still check every few
        // minutes because it is only a hint.
        let delay = max(next.timeIntervalSinceNow, result == .offline ? 60 : 1)
        retryTask = Task {
            try? await Task.sleep(for: .seconds(min(delay, 300)))
            guard !Task.isCancelled else { return }
            requestSync()
        }
    }

    private func networkChanged(available: Bool) {
        let cameBack = available && !isNetworkAvailable
        isNetworkAvailable = available
        if cameBack { requestSync() }
    }
}
