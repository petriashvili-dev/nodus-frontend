import Foundation
import Combine
import SwiftData
import UserNotifications

/// Trusted contacts and shared knots (`nodus_backend/docs/ios/06-connections-and-sharing.md`).
/// Invites and accepting them need the network (the server issues the link
/// and code); confirming, removing and sharing go through the Outbox.
@MainActor
final class ConnectionsService: ObservableObject {
    nonisolated enum InviteError: Error, Equatable {
        case invalid
        case ownInvite
        case alreadyConnected
        case tooManyInvites
        case offline
        case failed
    }

    @Published private(set) var connections: [Connection] = []

    private let context: ModelContext
    private let api: APIClient
    private let didEnqueue: () -> Void
    private let now: () -> Date

    init(context: ModelContext, api: APIClient, didEnqueue: @escaping () -> Void, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.api = api
        self.didEnqueue = didEnqueue
        self.now = now
        reload()
    }

    func reload() {
        connections = (try? context.fetch(FetchDescriptor<Connection>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    var active: [Connection] { connections.filter(\.isActive) }

    // MARK: - Invites

    func createInvite() async throws -> InviteDTO {
        try await mapErrors {
            try await self.api.send(APIRequest<InviteDTO>(method: .post, path: "connections/invites", idempotencyKey: UUID()))
        }
    }

    func revokeInvite(_ invite: InviteDTO) async {
        _ = try? await api.send(APIRequest<EmptyResponse>(method: .delete, path: "connections/invites/\(invite.id.uuidString)"))
    }

    /// From a link `https://nodus.app/invite/{token}` (or `nodus://invite/{token}`).
    func accept(token: String) async throws -> ConnectionDTO {
        try await store(try await mapErrors {
            try await self.api.send(APIRequest<ConnectionDTO>(method: .post, path: "connections/invites/\(token)/accept", idempotencyKey: UUID()))
        })
    }

    /// A typed code; case, spaces and dashes do not matter on the server.
    func accept(code: String) async throws -> ConnectionDTO {
        try await store(try await mapErrors {
            try await self.api.send(try APIRequest<ConnectionDTO>(
                method: .post, path: "connections/invites/accept", json: AcceptCodeBody(code: code), idempotencyKey: UUID()
            ))
        })
    }

    private func store(_ dto: ConnectionDTO) async throws -> ConnectionDTO {
        let id = dto.id
        if let existing = try context.fetch(FetchDescriptor<Connection>(predicate: #Predicate { $0.id == id })).first {
            existing.apply(dto)
        } else {
            let created = Connection(id: dto.id, userId: dto.userId)
            created.apply(dto)
            context.insert(created)
        }
        try context.save()
        reload()
        return dto
    }

    // MARK: - Confirming and removing

    func confirm(_ connection: Connection) throws {
        connection.status = "active"
        connection.awaitingMyConfirmation = false
        try enqueue(.confirmConnection, .post, "connections/\(connection.id.uuidString)/confirm", entity: connection.id)
    }

    /// Declining a pending connection or breaking an active one: knots
    /// shared between the two stop being shared.
    func remove(_ connection: Connection) throws {
        let id = connection.id
        context.delete(connection)
        try enqueue(.removeConnection, .delete, "connections/\(id.uuidString)", entity: id)
    }

    // MARK: - Shared knots

    /// Owner only, active connections only.
    func share(_ node: ReminderNode, with connection: Connection) throws {
        var members = node.members
        if !members.contains(where: { $0.userId == connection.userId }) {
            members.append(NodeMemberDTO(userId: connection.userId, displayName: connection.displayName))
        }
        node.membersData = try? APICoding.encoder.encode(members)
        node.memberCount = max(members.count, 2)
        try enqueue(
            .addMember, .post, "nodes/\(node.id.uuidString)/members",
            body: try APICoding.encoder.encode(AddMemberBody(userId: connection.userId)),
            entity: node.id
        )
    }

    /// The owner removes anyone; a participant removes only themselves,
    /// which makes the node disappear from this device.
    func remove(member userId: UUID, from node: ReminderNode, isSelf: Bool) throws {
        let nodeId = node.id
        if isSelf {
            context.delete(node)
            let center = UNUserNotificationCenter.current()
            Task {
                let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(nodeId.uuidString) }
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        } else {
            let members = node.members.filter { $0.userId != userId }
            node.membersData = try? APICoding.encoder.encode(members)
            node.memberCount = max(members.count, 1)
        }
        try enqueue(.removeMember, .delete, "nodes/\(nodeId.uuidString)/members/\(userId.uuidString)", entity: nodeId)
    }

    private func enqueue(_ kind: OutboxOperation.Kind, _ method: HTTPMethod, _ path: String, body: Data? = nil, entity: UUID) throws {
        context.insert(OutboxOperation(kind: kind, method: method, path: path, body: body, entityId: entity, now: now()))
        try context.save()
        reload()
        didEnqueue()
    }

    private func mapErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as APIError {
            switch (error.status, error.code) {
            case (_, _) where error.isOffline: throw InviteError.offline
            case (_, "invite_invalid"): throw InviteError.invalid
            case (_, "own_invite"): throw InviteError.ownInvite
            case (_, "already_connected"): throw InviteError.alreadyConnected
            case (_, "too_many_invites"): throw InviteError.tooManyInvites
            default: throw InviteError.failed
            }
        }
    }
}
