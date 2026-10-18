import Foundation
import SwiftData
import Testing
@testable import nodus

@MainActor
struct AIDraftsTests {
    private let container: ModelContainer
    private let clock = TestClock(Date())
    private let defaults: UserDefaults

    init() throws {
        let schema = Schema([
            ReminderNode.self, ReminderOccurrenceState.self, ReminderOccurrenceOverride.self,
            OutboxOperation.self, SyncMetadata.self, ServerOccurrence.self, AIDraftJob.self,
        ])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        defaults = try #require(UserDefaults(suiteName: "AIDraftsTests.\(UUID().uuidString)"))
    }

    private var context: ModelContext { container.mainContext }

    private func makeService(_ transport: FakeTransport, access: AIAccess) -> (AIDraftsService, AIAccessStore, APIClient, AuthSession) {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let store = InMemorySecureStore(session: Fixtures.session(access: "a", refresh: "r", expiresAt: clock.now.addingTimeInterval(3600)))
        let clock = clock
        let session = AuthSession(configuration: configuration, transport: transport, store: store, now: { clock.now })
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        let accessStore = AIAccessStore(defaults: defaults)
        accessStore.apply(access)
        let account = AccountService(api: api, session: session, store: store, aiAccessStore: accessStore)
        let service = AIDraftsService(context: context, api: api, aiAccessStore: accessStore, account: account, didEnqueue: {}, now: { clock.now })
        return (service, accessStore, api, session)
    }

    private let allowed = AIAccess(features: [.drafts], consentAt: Date(timeIntervalSince1970: 1_792_000_000))

    // MARK: - Submitting

    @Test func withoutConsentNothingIsSent() async {
        let transport = FakeTransport { _ in Issue.record("must not be sent"); return .json(500, "{}") }
        let (service, _, _, _) = makeService(transport, access: AIAccess(features: [.drafts], consentAt: nil))

        #expect(await service.submit("Позвонить врачу завтра") == .needsConsent)
        #expect(await transport.requests.isEmpty)
    }

    @Test func withoutTheFeatureNothingIsSent() async {
        let transport = FakeTransport { _ in Issue.record("must not be sent"); return .json(500, "{}") }
        let (service, _, _, _) = makeService(transport, access: .none)

        #expect(await service.submit("Позвонить") == .unavailable)
    }

    @Test func acceptedJobKeepsTheTextUnderTheServerId() async throws {
        let jobId = UUID()
        let transport = FakeTransport { _ in
            .json(202, #"{"id":"\#(jobId.uuidString)","status":"queued","drafts":[]}"#)
        }
        let (service, _, _, _) = makeService(transport, access: allowed)

        #expect(await service.submit("Позвонить врачу завтра в 10") == .accepted(jobId: jobId))

        let sent = try #require(await transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["text"] as? String == "Позвонить врачу завтра в 10")
        #expect(body["reference_time"] != nil)
        let job = try #require(service.job(id: jobId))
        #expect(job.transcript == "Позвонить врачу завтра в 10")
        #expect(job.status == .queued)
    }

    @Test func offlineTheNoteWaitsInDrafts() async throws {
        let (service, _, _, _) = makeService(FakeTransport { _ in throw URLError(.notConnectedToInternet) }, access: allowed)

        guard case .savedOffline = await service.submit("Купить хлеб") else {
            Issue.record("expected savedOffline"); return
        }
        let jobs = service.unfinishedJobs()
        #expect(jobs.map(\.status) == [.unsent])
        #expect(jobs.first?.transcript == "Купить хлеб")
    }

    @Test func consentRequiredFromTheServerAsksForConsent() async {
        let (service, _, _, _) = makeService(FakeTransport { request in
            request.url!.path.hasSuffix("/me") ? .json(200, "{}") : Fixtures.problem(403, "ai_consent_required")
        }, access: allowed)

        #expect(await service.submit("Купить хлеб") == .needsConsent)
    }

    @Test func grantingConsentIsOptimisticAndQueued() throws {
        let (service, accessStore, _, _) = makeService(FakeTransport { _ in .json(200, "{}") }, access: AIAccess(features: [.drafts], consentAt: nil))

        try service.grantConsent()

        #expect(accessStore.access.hasConsent)
        let operations = try context.fetch(FetchDescriptor<OutboxOperation>())
        #expect(operations.map(\.kind) == [.setAIConsent])
        let body = try APICoding.decoder.decode(AIConsentBody.self, from: try #require(operations.first?.body))
        #expect(body.granted)
    }

    // MARK: - Reviewing and confirming

    @Test func draftsWithoutADateMustBeCompletedBeforeConfirming() {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let missing = EditableDraft(
            draft: NodeDraftDTO(index: 0, type: .oneTime, title: "Позвонить врачу", timezone: "Europe/Moscow",
                                issues: [DraftIssueDTO(code: "missing_date", field: "date", message: nil)]),
            fallbackZone: moscow, now: clock.now
        )
        let tomorrow = LocalDate.string(from: clock.now.addingTimeInterval(86_400), calendar: NodeMapper.calendar(in: moscow))
        let complete = EditableDraft(
            draft: NodeDraftDTO(index: 1, type: .oneTime, title: "Сдать отчёт", timezone: "Europe/Moscow", date: tomorrow, time: "10:00"),
            fallbackZone: moscow, now: clock.now
        )

        #expect(!missing.isValid(now: clock.now))
        #expect(complete.isValid(now: clock.now))
        #expect(complete.draft.scheduledAt == NodeMapper.moment(date: tomorrow, time: "10:00", calendar: NodeMapper.calendar(in: moscow)))
    }

    @Test func confirmingCreatesKnotsAndOneOperationTogether() throws {
        let (service, _, _, _) = makeService(FakeTransport { _ in .json(200, "{}") }, access: allowed)
        let job = AIDraftJob(transcript: "…", timeZone: .current, referenceTime: clock.now)
        job.isOnServer = true
        job.status = .ready
        context.insert(job)
        try context.save()
        let drafts = [
            ReminderDraft(title: "Первый", scheduledAt: clock.now.addingTimeInterval(3600)),
            ReminderDraft(title: "Второй", scheduledAt: clock.now.addingTimeInterval(7200)),
        ]

        let nodes = try service.confirm(job, drafts: drafts)

        let operations = try context.fetch(FetchDescriptor<OutboxOperation>())
        #expect(operations.map(\.kind) == [.confirmAIDrafts])
        let body = try APICoding.decoder.decode(ConfirmDraftsBody.self, from: try #require(operations.first?.body))
        #expect(body.nodes.map(\.id) == nodes.map(\.id))
        #expect(try context.fetch(FetchDescriptor<ReminderNode>()).count == 2)
        #expect(job.status == .confirmed)
    }

    @Test func aRejectedConfirmationRemovesTheOptimisticKnots() async throws {
        let transport = FakeTransport { _ in Fixtures.problem(400, "validation_failed") }
        let (service, _, api, session) = makeService(transport, access: allowed)
        let job = AIDraftJob(transcript: "…", timeZone: .current, referenceTime: clock.now)
        job.isOnServer = true
        job.status = .ready
        context.insert(job)
        try context.save()
        _ = try service.confirm(job, drafts: [ReminderDraft(title: "Первый", scheduledAt: clock.now.addingTimeInterval(3600))])

        let clock = clock
        let engine = SyncEngine(container: container, api: api, session: session, now: { clock.now })
        _ = try await engine.flushOutbox()

        #expect(try context.fetch(FetchDescriptor<ReminderNode>()).isEmpty)
        #expect(service.job(id: job.id)?.status == .ready)
    }
}

private extension NodeDraftDTO {
    init(index: Int, type: NodeType, title: String, timezone: String?, date: String? = nil, time: String? = nil, issues: [DraftIssueDTO]? = nil) {
        self.init(index: index, type: type, title: title, description: nil, timezone: timezone, date: date, time: time,
                  recurrence: nil, trackYears: nil, issues: issues)
    }
}
