import Foundation
import SwiftData

/// A durable user intent waiting for the server
/// (`nodus_backend/docs/ios/02-outbox-and-errors.md`). It is written in the
/// same SwiftData save as the local change it describes, so a crash can never
/// keep one without the other.
@Model
nonisolated final class OutboxOperation {
    nonisolated enum Status: String, Sendable {
        case pending
        case inFlight
        case retryableFailure
        case blockedConflict
        case failed
    }

    nonisolated enum Kind: String, Sendable {
        case createNode
        case updateNode
        case deleteNode
        case untie
        case retie
        case setTimezone
        case setAIConsent
        case confirmAIDrafts
        case cancelAIDrafts
        case updateProfile
    }

    @Attribute(.unique) var id: UUID
    /// Generated when queued and never changed: retries send the same key.
    var idempotencyKey: UUID
    var kindRaw: String
    var method: String
    var path: String
    /// The request body. Frozen once first sent — the server hashes it
    /// against the key and rejects a changed body with `422`.
    var body: Data?
    /// The node, connection or job this operation belongs to. Operations of
    /// one entity are sent strictly in order.
    var entityId: UUID?
    var statusRaw: String
    var attempts: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var createdAt: Date
    var hasBeenSent: Bool
    /// For `PATCH`/`DELETE` of a node: the version to send as
    /// `expected_version`, filled at first send from the latest version this
    /// device knows (including responses to its own earlier operations).
    var expectedVersion: Int?
    var needsExpectedVersion: Bool

    init(
        kind: Kind,
        method: HTTPMethod,
        path: String,
        body: Data?,
        entityId: UUID?,
        needsExpectedVersion: Bool = false,
        now: Date = Date()
    ) {
        id = UUID()
        idempotencyKey = UUID()
        kindRaw = kind.rawValue
        self.method = method.rawValue
        self.path = path
        self.body = body
        self.entityId = entityId
        statusRaw = Status.pending.rawValue
        attempts = 0
        nextAttemptAt = now
        createdAt = now
        hasBeenSent = false
        self.needsExpectedVersion = needsExpectedVersion
    }

    var kind: Kind? { Kind(rawValue: kindRaw) }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var httpMethod: HTTPMethod { HTTPMethod(rawValue: method) ?? .post }
}
