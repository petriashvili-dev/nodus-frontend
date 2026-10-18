import Foundation
import SwiftData
import Testing
@testable import nodus

@MainActor
struct ConnectionsTests {
    private let container: ModelContainer
    private let clock = TestClock(Date())

    init() throws {
        container = try ModelContainer(for: NodusModelContainer.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private var context: ModelContext { container.mainContext }

    private func makeService(_ transport: FakeTransport) -> ConnectionsService {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let store = InMemorySecureStore(session: Fixtures.session(access: "a", refresh: "r", expiresAt: clock.now.addingTimeInterval(3600)))
        let session = AuthSession(configuration: configuration, transport: transport, store: store)
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        return ConnectionsService(context: context, api: api, didEnqueue: {})
    }

    private func operations() throws -> [OutboxOperation] {
        try context.fetch(FetchDescriptor<OutboxOperation>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    @Test(arguments: [
        ("invite_invalid", ConnectionsService.InviteError.invalid),
        ("own_invite", .ownInvite),
        ("already_connected", .alreadyConnected),
    ])
    func acceptErrorsKeepTheirMeaning(code: String, expected: ConnectionsService.InviteError) async {
        let service = makeService(FakeTransport { _ in Fixtures.problem(code == "already_connected" ? 409 : 404, code) })

        await #expect(throws: expected) { _ = try await service.accept(code: "K7M2Q9TP") }
    }

    @Test func acceptedConnectionIsStoredWithItsKey() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            .json(200, #"{"id":"\#(id.uuidString)","user_id":"\#(UUID().uuidString)","display_name":"Аня","status":"pending","invited_by_me":false,"awaiting_my_confirmation":false,"version":1}"#)
        }
        let service = makeService(transport)

        let accepted = try await service.accept(code: "k7m2-q9tp")

        #expect(accepted.status == "pending")
        #expect(service.connections.map(\.id) == [id])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") != nil)
    }

    @Test func confirmingIsOptimisticAndQueued() throws {
        let service = makeService(FakeTransport { _ in .json(200, "{}") })
        let connection = Connection(id: UUID(), userId: UUID())
        connection.awaitingMyConfirmation = true
        context.insert(connection)

        try service.confirm(connection)

        #expect(connection.isActive)
        #expect(try operations().map(\.kind) == [.confirmConnection])
    }

    @Test func sharingAddsTheMemberAtOnce() throws {
        let service = makeService(FakeTransport { _ in .json(200, "{}") })
        let node = ReminderNode(title: "Ужин", scheduledAt: clock.now.addingTimeInterval(3600))
        context.insert(node)
        let connection = Connection(id: UUID(), userId: UUID())
        connection.status = "active"
        connection.displayName = "Аня"

        try service.share(node, with: connection)

        #expect(node.isShared)
        #expect(node.members.map(\.displayName) == ["Аня"])
        let operation = try #require(try operations().first)
        #expect(operation.kind == .addMember)
        #expect(operation.entityId == node.id)
    }

    @Test func leavingRemovesTheKnotFromThisDevice() throws {
        let service = makeService(FakeTransport { _ in .json(200, "{}") })
        let me = UUID()
        let node = ReminderNode(title: "Ужин", scheduledAt: clock.now.addingTimeInterval(3600))
        context.insert(node)
        try context.save()

        try service.remove(member: me, from: node, isSelf: true)

        #expect(try context.fetch(FetchDescriptor<ReminderNode>()).isEmpty)
        #expect(try operations().first?.path == "nodes/\(node.id.uuidString)/members/\(me.uuidString)")
    }

    @Test func codesAreGroupedByFour() {
        let invite = InviteDTO(id: UUID(), token: "t", code: "K7M2Q9TP", link: URL(string: "https://nodus.app/invite/t")!, expiresAt: Date())
        #expect(invite.groupedCode == "K7M2 Q9TP")
    }
}
