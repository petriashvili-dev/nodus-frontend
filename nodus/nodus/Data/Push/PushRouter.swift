import Foundation
import os

/// The `nodus` part of an APNs payload (`nodus_backend/docs/ios/05-push-and-deeplinks.md`).
/// A push is only a signal: the data always comes from sync.
nonisolated struct PushPayload: Equatable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case sharedNodeChanged = "shared_node_changed"
        case connectionChanged = "connection_changed"
        case aiDraftsReady = "ai_drafts_ready"
        case importReady = "import_ready"
    }

    /// `nil` for a kind this build does not know: open the app and sync.
    var kind: Kind?
    var eventId: String?
    var nodeId: UUID?
    var connectionId: UUID?
    var jobId: UUID?
    var importId: UUID?
    var title: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let nodus = userInfo["nodus"] as? [String: Any] else { return nil }
        kind = (nodus["kind"] as? String).flatMap(Kind.init(rawValue:))
        eventId = nodus["event_id"] as? String
        nodeId = (nodus["node_id"] as? String).flatMap(UUID.init(uuidString:))
        connectionId = (nodus["connection_id"] as? String).flatMap(UUID.init(uuidString:))
        jobId = (nodus["job_id"] as? String).flatMap(UUID.init(uuidString:))
        importId = (nodus["import_id"] as? String).flatMap(UUID.init(uuidString:))
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        title = (alert as? [String: Any])?["title"] as? String ?? alert as? String
    }
}

/// Remembers shown events for a week so one event is never shown twice
/// (a push and the same change seen in the open app).
@MainActor
final class PushEventLog {
    private let defaults: UserDefaults
    private let now: () -> Date
    private static let key = "pushShownEvents"
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// `true` the first time an event id is seen.
    func markShown(_ eventId: String?) -> Bool {
        guard let eventId else { return true }
        var shown = defaults.dictionary(forKey: Self.key) as? [String: Date] ?? [:]
        let cutoff = now().addingTimeInterval(-Self.retention)
        shown = shown.filter { $0.value > cutoff }
        guard shown[eventId] == nil else { return false }
        shown[eventId] = now()
        defaults.set(shown, forKey: Self.key)
        return true
    }
}

/// Foreground: no system banner — a branded toast and a sync. Tap: sync
/// first, then open the screen once the entity exists locally.
@MainActor
final class PushRouter {
    struct Destinations {
        var sync: () async -> Void = {}
        var toast: (String) -> Void = { _ in }
        var openDraftsReview: (UUID) -> Void = { _ in }
        var openNode: (UUID) -> Bool = { _ in false }
        var openConnections: (UUID?) -> Void = { _ in }
        var openImport: (UUID) -> Void = { _ in }
    }

    var destinations = Destinations()
    private let log: PushEventLog
    private let logger = Logger(subsystem: "app.nodus", category: "Push")

    init(log: PushEventLog? = nil) {
        self.log = log ?? PushEventLog()
    }

    func received(_ payload: PushPayload) async {
        let isNew = log.markShown(payload.eventId)
        await destinations.sync()
        // Ready drafts are announced by the drafts flow itself after sync.
        guard isNew, payload.kind != .aiDraftsReady, let title = payload.title else { return }
        destinations.toast(title)
    }

    func tapped(_ payload: PushPayload) async {
        _ = log.markShown(payload.eventId)
        await destinations.sync()
        switch payload.kind {
        case .aiDraftsReady:
            if let jobId = payload.jobId { destinations.openDraftsReview(jobId) }
        case .sharedNodeChanged:
            // Gone (deleted, access lost): the thread itself is the answer.
            if let nodeId = payload.nodeId, !destinations.openNode(nodeId) {
                logger.notice("Pushed node is no longer available")
            }
        case .connectionChanged:
            destinations.openConnections(payload.connectionId)
        case .importReady:
            if let importId = payload.importId { destinations.openImport(importId) }
        case nil:
            break
        }
    }
}
