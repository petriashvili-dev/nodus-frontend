import Foundation
import SwiftData
import Testing
@testable import nodus

/// Runs against a real local backend (`nodus_backend/docs/09-operations.md`,
/// `http://localhost:5258`). Opt-in:
/// `TEST_RUNNER_NODUS_E2E=1 xcodebuild test -only-testing:nodusTests/BackendIntegrationTests …`
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NODUS_E2E"] == "1"), .serialized)
struct BackendIntegrationTests {
    private let configuration = APIConfiguration(baseURL: URL(string: "http://localhost:5258/v1")!)
    private let zone = TimeZone(identifier: "Europe/Moscow")!

    private struct Device {
        let container: ModelContainer
        let engine: SyncEngine
        let service: ReminderService
        let api: APIClient
        let session: AuthSession

        var context: ModelContext { container.mainContext }
    }

    private func makeDevice(store: InMemorySecureStore) throws -> Device {
        let schema = Schema([
            ReminderNode.self, ReminderOccurrenceState.self, ReminderOccurrenceOverride.self,
            OutboxOperation.self, SyncMetadata.self, ServerOccurrence.self, AIDraftJob.self,
        ])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let transport = URLSessionTransport()
        let session = AuthSession(configuration: configuration, transport: transport, store: store)
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        let engine = SyncEngine(container: container, api: api, session: session)
        let service = ReminderService(
            repository: SwiftDataNodeRepository(context: container.mainContext),
            notificationScheduler: SilentNotifications()
        )
        return Device(container: container, engine: engine, service: service, api: api, session: session)
    }

    private func makeAccount(_ device: Device, store: InMemorySecureStore) -> AccountService {
        let account = AccountService(api: device.api, session: device.session, store: store, aiAccessStore: AIAccessStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        account.resetLocalData = { userId in try? await device.engine.wipeLocalData(for: userId) }
        return account
    }

    /// Needs the backend started with `EmailOtp__ReviewEmails__0=review@nodus.test`
    /// and `EmailOtp__ReviewCode=246810` (the App Review demo mechanism).
    @Test func savedAccountIsRestoredOnANewDevice() async throws {
        let email = "review@nodus.test"
        let code = "246810"

        let oldStore = InMemorySecureStore()
        let old = try makeDevice(store: oldStore)
        let knot = try await old.service.tie(
            ReminderDraft(title: "Купить подарок", note: "", scheduledAt: Date().addingTimeInterval(7200).roundedToNearest5Minutes(), repeatSchedule: .none, leadTimes: []),
            settings: .testDefault
        )
        #expect(await old.engine.runCycle(timeZone: zone) == .completed)
        let oldAccount = makeAccount(old, store: oldStore)
        // The server issues one code per address per minute, whatever the
        // purpose. The address stays linked between runs, so the old device
        // first tries to sign in to it and links it only on the first run.
        do {
            try await oldAccount.startRecovery(email)
            try await oldAccount.completeRecovery(email, code: code)
            _ = try await old.service.tie(
                ReminderDraft(title: "Купить подарок", note: "", scheduledAt: Date().addingTimeInterval(7200).roundedToNearest5Minutes(), repeatSchedule: .none, leadTimes: []),
                settings: .testDefault
            )
            #expect(await old.engine.runCycle(timeZone: zone) == .completed)
        } catch AccountService.EmailError.invalidCode {
            try await Task.sleep(for: .seconds(61))
            try await oldAccount.startLinkingEmail(email)
            try await oldAccount.verifyLinkingEmail(email, code: code)
        }
        try await Task.sleep(for: .seconds(61))

        let newStore = InMemorySecureStore()
        let fresh = try makeDevice(store: newStore)
        let anonymousKnot = try await fresh.service.tie(
            ReminderDraft(title: "Анонимный узел", note: "", scheduledAt: Date().addingTimeInterval(3600).roundedToNearest5Minutes(), repeatSchedule: .none, leadTimes: []),
            settings: .testDefault
        )
        #expect(await fresh.engine.runCycle(timeZone: zone) == .completed)

        let freshAccount = makeAccount(fresh, store: newStore)
        try await freshAccount.startRecovery(email)
        try await freshAccount.completeRecovery(email, code: code)
        #expect(await fresh.engine.runCycle(timeZone: zone) == .completed)

        let titles = try fresh.context.fetch(FetchDescriptor<ReminderNode>()).map(\.title)
        #expect(titles.contains("Купить подарок"))
        #expect(!titles.contains("Анонимный узел"))
        #expect(!(try fresh.context.fetch(FetchDescriptor<ReminderNode>()).contains { $0.id == anonymousKnot.id }))
        _ = knot
    }

    @Test func knotsMakeTheRoundTripBetweenTwoDevices() async throws {
        let store = InMemorySecureStore()
        let phone = try makeDevice(store: store)
        let soon = Date().addingTimeInterval(3 * 3600).roundedToNearest5Minutes()

        // Created offline-first: local rows + Outbox, nothing sent yet.
        let call = try await phone.service.tie(
            ReminderDraft(title: "Позвонить врачу", note: "", scheduledAt: soon, repeatSchedule: .none, leadTimes: []),
            settings: .testDefault
        )
        let habit = try await phone.service.tie(
            ReminderDraft(title: "Зарядка", note: "", scheduledAt: soon, repeatSchedule: .every(1, .days), leadTimes: []),
            settings: .testDefault
        )
        #expect(try phone.context.fetch(FetchDescriptor<OutboxOperation>()).count == 2)

        #expect(await phone.engine.runCycle(timeZone: zone) == .completed)
        #expect(try phone.context.fetch(FetchDescriptor<OutboxOperation>()).isEmpty)
        let synced = try phone.context.fetch(FetchDescriptor<ReminderNode>())
        #expect(synced.allSatisfy { $0.serverVersion > 0 })
        let feed = try phone.context.fetch(FetchDescriptor<ServerOccurrence>()).filter(\.isInFeed)
        #expect(Set(feed.map(\.nodeId)) == [call.id, habit.id])

        // Untie and edit, then the round trip again.
        try await phone.service.untie(node: call, occurrenceDate: nil)
        var edit = ReminderDraft(title: "Утренняя зарядка", note: "", scheduledAt: soon, repeatSchedule: .every(1, .days), leadTimes: [])
        edit.scheduledAt = habit.scheduledAt
        try await phone.service.update(node: habit, with: edit, settings: .testDefault)
        #expect(await phone.engine.runCycle(timeZone: zone) == .completed)
        #expect(try phone.context.fetch(FetchDescriptor<OutboxOperation>()).isEmpty)

        // A second device of the same account sees it all through a snapshot.
        let tablet = try makeDevice(store: store)
        #expect(await tablet.engine.runCycle(timeZone: zone) == .completed)
        let onTablet = try tablet.context.fetch(FetchDescriptor<ReminderNode>())
        #expect(Set(onTablet.map(\.title)) == ["Позвонить врачу", "Утренняя зарядка"])
        #expect(onTablet.first { $0.id == call.id }?.status == .completed)
        #expect(onTablet.first { $0.id == habit.id }?.repeatSchedule == .every(1, .days))

        // Deleting on the phone reaches the tablet through Delta Sync.
        try await phone.service.delete(node: call)
        #expect(await phone.engine.runCycle(timeZone: zone) == .completed)
        #expect(await tablet.engine.runCycle(timeZone: zone) == .completed)
        #expect(try tablet.context.fetch(FetchDescriptor<ReminderNode>()).map(\.id) == [habit.id])
    }
}
