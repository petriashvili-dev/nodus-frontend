import Foundation
import UserNotifications
import SwiftData
import Testing
@testable import nodus

@MainActor
struct SyncEngineTests {
    private let container: ModelContainer
    // The draft validator compares with the real clock, so start from now.
    private let clock = TestClock(Date())
    private let store: InMemorySecureStore

    init() throws {
        let schema = Schema([
            ReminderNode.self, ReminderOccurrenceState.self, ReminderOccurrenceOverride.self,
            OutboxOperation.self, SyncMetadata.self, ServerOccurrence.self,
        ])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        store = InMemorySecureStore(session: Fixtures.session(access: "a", refresh: "r", expiresAt: clock.now.addingTimeInterval(3600)))
    }

    private func makeEngine(_ transport: FakeTransport) -> SyncEngine {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let clock = clock
        let session = AuthSession(configuration: configuration, transport: transport, store: store, now: { clock.now })
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        return SyncEngine(container: container, api: api, session: session, now: { clock.now })
    }

    private var context: ModelContext { container.mainContext }

    private func makeService() -> ReminderService {
        ReminderService(
            repository: SwiftDataNodeRepository(context: context),
            notificationScheduler: SilentNotifications(),
            now: { [clock] in clock.now }
        )
    }

    private func draft(_ title: String, in hours: Double = 2) -> ReminderDraft {
        ReminderDraft(title: title, note: "", scheduledAt: clock.now.addingTimeInterval(hours * 3600), repeatSchedule: .none, leadTimes: [])
    }

    private func operations() throws -> [OutboxOperation] {
        try context.fetch(FetchDescriptor<OutboxOperation>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    // MARK: - Local change + Outbox

    @Test func tyingSavesTheKnotAndItsCreateOperationTogether() async throws {
        let node = try await makeService().tie(draft("Позвонить"), settings: .testDefault)

        let queued = try operations()
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createNode)
        #expect(queued.first?.entityId == node.id)
        let body = try APICoding.decoder.decode(CreateNodeBody.self, from: try #require(queued.first?.body))
        #expect(body.id == node.id)
        #expect(body.type == .oneTime)
    }

    @Test func offlineEditsOfAnUnsentKnotCollapseIntoItsCreate() async throws {
        let service = makeService()
        let node = try await service.tie(draft("Черновик"), settings: .testDefault)
        var edit = draft("Окончательно")
        edit.scheduledAt = node.scheduledAt

        try await service.update(node: node, with: edit, settings: .testDefault)

        let queued = try operations()
        #expect(queued.count == 1)
        let body = try APICoding.decoder.decode(CreateNodeBody.self, from: try #require(queued.first?.body))
        #expect(body.title == "Окончательно")
    }

    @Test func deletingAnUnsentKnotDropsItsQueue() async throws {
        let service = makeService()
        let node = try await service.tie(draft("Лишний"), settings: .testDefault)

        try await service.delete(node: node)

        #expect(try operations().isEmpty)
    }

    // MARK: - Sending

    @Test func createIsSentWithItsKeyAndTheResponseBecomesCanonical() async throws {
        let node = try await makeService().tie(draft("Позвонить"), settings: .testDefault)
        let key = try #require(try operations().first?.idempotencyKey)
        let nodeId = node.id
        let transport = FakeTransport { _ in
            .json(201, Self.nodeJSON(id: nodeId, title: "Позвонить", version: 1))
        }

        #expect(try await makeEngine(transport).flushOutbox())

        let sent = await transport.requests(to: "/nodes")
        #expect(sent.count == 1)
        #expect(sent.first?.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(try operations().isEmpty)
        let stored = try #require(try context.fetch(FetchDescriptor<ReminderNode>()).first)
        #expect(stored.serverVersion == 1)
    }

    @Test func networkFailureKeepsTheOperationAndItsKeyForTheRetry() async throws {
        _ = try await makeService().tie(draft("Позвонить"), settings: .testDefault)
        let key = try #require(try operations().first?.idempotencyKey)
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }

        #expect(try await makeEngine(transport).flushOutbox() == false)

        let queued = try #require(try operations().first)
        #expect(queued.status == .retryableFailure)
        #expect(queued.idempotencyKey == key)
        #expect(queued.nextAttemptAt > clock.now)
    }

    @Test func aBusinessErrorIsFinalAndNotRetried() async throws {
        _ = try await makeService().tie(draft("Позвонить"), settings: .testDefault)
        let transport = FakeTransport { _ in Fixtures.problem(400, "validation_failed") }
        let engine = makeEngine(transport)

        _ = try await engine.flushOutbox()
        clock.advance(by: 3600)
        _ = try await engine.flushOutbox()

        #expect(await transport.requests(to: "/nodes").count == 1)
        #expect(try operations().first?.status == .failed)
    }

    @Test func aChainOfOwnEditsUsesTheVersionFromThePreviousResponse() async throws {
        let service = makeService()
        let node = try await service.tie(draft("Первое"), settings: .testDefault)
        // The create goes out; the edit made meanwhile must not collapse into it.
        try #require(try operations().first).hasBeenSent = true
        try context.save()
        var edit = draft("Второе")
        edit.scheduledAt = node.scheduledAt
        try await service.update(node: node, with: edit, settings: .testDefault)
        try #require(try operations().first).hasBeenSent = false
        try context.save()

        let nodeId = node.id
        let transport = FakeTransport { request in
            if request.httpMethod == "POST" { return .json(201, Self.nodeJSON(id: nodeId, title: "Первое", version: 4)) }
            return .json(200, Self.nodeJSON(id: nodeId, title: "Второе", version: 5))
        }
        _ = try await makeEngine(transport).flushOutbox()

        let patch = try #require(await transport.requests.first { $0.httpMethod == "PATCH" })
        let body = try APICoding.decoder.decode(UpdateNodeBody.self, from: try #require(patch.httpBody))
        #expect(body.expectedVersion == 4)
        #expect(try operations().isEmpty)
    }

    @Test func aConflictOnAPrivateNodeIsResentAsANewOperation() async throws {
        let id = UUID()
        let node = ReminderNode(id: id, title: "Старое", scheduledAt: clock.now.addingTimeInterval(3600))
        node.serverVersion = 2
        node.timeZoneIdentifier = "Europe/Moscow"
        context.insert(node)
        try context.save()
        var edit = draft("Моё")
        edit.scheduledAt = node.scheduledAt
        try await makeService().update(node: node, with: edit, settings: .testDefault)
        let firstKey = try #require(try operations().first?.idempotencyKey)

        let attempts = Counter()
        let transport = FakeTransport { _ in
            if attempts.next() == 1 {
                return .json(409, #"{"status":409,"code":"version_conflict","current":\#(Self.nodeJSON(id: id, title: "С другого устройства", version: 3))}"#)
            }
            return .json(200, Self.nodeJSON(id: id, title: "Моё", version: 4))
        }
        _ = try await makeEngine(transport).flushOutbox()

        let patches = await transport.requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 2)
        #expect(patches.last?.value(forHTTPHeaderField: "Idempotency-Key") != firstKey.uuidString)
        let resent = try APICoding.decoder.decode(UpdateNodeBody.self, from: try #require(patches.last?.httpBody))
        #expect(resent.expectedVersion == 3)
        #expect(resent.title == "Моё")
    }

    // MARK: - Pull

    @Test func deltaSyncAppliesChangesAndTheCursorTogether() async throws {
        let kept = UUID()
        let removed = UUID()
        let gone = ReminderNode(id: removed, title: "Удалят", scheduledAt: clock.now)
        gone.serverVersion = 1
        context.insert(gone)
        let metadata = SyncMetadata()
        metadata.cursor = 10
        context.insert(metadata)
        try context.save()

        let transport = FakeTransport { _ in
            .json(200, """
            {"changes":[
              {"revision":11,"entity_type":"node","entity_id":"\(kept.uuidString)","operation":"upsert","version":1,"data":\(Self.nodeJSON(id: kept, title: "Новый", version: 1))},
              {"revision":12,"entity_type":"node","entity_id":"\(removed.uuidString)","operation":"delete","version":2,"data":null},
              {"revision":13,"entity_type":"something_new","entity_id":"x","operation":"upsert","version":1,"data":{"a":1}}
            ],"next_cursor":13,"has_more":false}
            """)
        }
        try await makeEngine(transport).pull()

        let nodes = try context.fetch(FetchDescriptor<ReminderNode>())
        #expect(nodes.map(\.id) == [kept])
        #expect(nodes.first?.title == "Новый")
        #expect(try context.fetch(FetchDescriptor<SyncMetadata>()).first?.cursor == 13)
    }

    @Test func aPendingLocalEditStaysOnTopOfIncomingServerData() async throws {
        let id = UUID()
        let node = ReminderNode(id: id, title: "Сервер", scheduledAt: clock.now.addingTimeInterval(3600))
        node.serverVersion = 1
        node.timeZoneIdentifier = "Europe/Moscow"
        context.insert(node)
        let metadata = SyncMetadata()
        metadata.cursor = 1
        context.insert(metadata)
        try context.save()
        var edit = draft("Моя правка")
        edit.scheduledAt = node.scheduledAt
        try await makeService().update(node: node, with: edit, settings: .testDefault)

        let transport = FakeTransport { _ in
            .json(200, """
            {"changes":[{"revision":2,"entity_type":"node","entity_id":"\(id.uuidString)","operation":"upsert","version":2,
              "data":\(Self.nodeJSON(id: id, title: "Чужая правка", version: 2))}],"next_cursor":2,"has_more":false}
            """)
        }
        try await makeEngine(transport).pull()

        let stored = try #require(try context.fetch(FetchDescriptor<ReminderNode>()).first)
        #expect(stored.title == "Моя правка")
        #expect(stored.serverVersion == 2)
    }

    @Test func knotsFromBeforeTheBackendAreQueuedOnce() async throws {
        let legacy = ReminderNode(title: "Старый узел", scheduledAt: clock.now.addingTimeInterval(3600))
        context.insert(legacy)
        try context.save()
        let transport = FakeTransport { request in
            if request.url!.path.hasSuffix("/nodes") { throw URLError(.notConnectedToInternet) }
            return .json(200, "{}")
        }
        let engine = makeEngine(transport)

        _ = await engine.runCycle(timeZone: TimeZone(identifier: "Europe/Moscow")!)
        _ = await engine.runCycle(timeZone: TimeZone(identifier: "Europe/Moscow")!)

        let creates = try operations().filter { $0.kind == .createNode }
        #expect(creates.count == 1)
        #expect(creates.first?.entityId == legacy.id)
    }

    // MARK: - Fixtures

    nonisolated static func nodeJSON(id: UUID, title: String, version: Int, members: Int = 1) -> String {
        let memberList = (0..<members).map { _ in #"{"user_id":"\#(UUID().uuidString)","display_name":null}"# }.joined(separator: ",")
        return """
        {"id":"\(id.uuidString)","type":"one_time","owner_id":"00000000-0000-0000-0000-000000000001","title":"\(title)",
         "description":null,"timezone":"Europe/Moscow","date":"2026-10-20","time":"10:00","scheduled_at":"2026-10-20T07:00:00+00:00",
         "recurrence":null,"track_years":null,"revision":1,"version":\(version),
         "created_at":"2026-10-18T07:00:00+00:00","updated_at":"2026-10-18T07:00:00+00:00",
         "members":[\(memberList)],"horizon":{"from":"2026-10-17","to":"2026-12-02"},
         "occurrences":[{"node_id":"\(id.uuidString)","key":"once","revision":1,"title":"\(title)","description":null,
           "date":"2026-10-20","time":"10:00","scheduled_at":"2026-10-20T07:00:00+00:00","years":null,"state":"tied","completed_at":null,"is_past":false}]}
        """
    }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@MainActor
final class SilentNotifications: NotificationScheduling {
    func registerCategories(settings: SettingsSnapshot) {}
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization() async -> Bool { false }
    func schedule(node: ReminderNode, occurrenceDate: Date?, scheduledAt: Date?, settings: SettingsSnapshot) async {}
    func cancel(nodeId: UUID, occurrenceDate: Date?) async {}
    func cancelAll(nodeId: UUID) async {}
    func rescheduleAll(nodes: [ReminderNode], plan: [TimelineItem], settings: SettingsSnapshot) async {}
}

extension SettingsSnapshot {
    static let testDefault = SettingsSnapshot(
        untiedKnotsVisibility: .untilEndOfDay, language: .ru, notificationsEnabled: false,
        notificationSoundEnabled: false, hapticsEnabled: false, inAppSoundsEnabled: false
    )
}
