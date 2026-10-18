import Foundation
import Testing
@testable import nodus

@MainActor
struct PushRouterTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "PushRouterTests.\(UUID().uuidString)"))
    }

    private func payload(kind: String, eventId: String, extra: [String: String] = [:], title: String = "Узел изменили") -> PushPayload? {
        var nodus: [String: Any] = ["kind": kind, "event_id": eventId]
        extra.forEach { nodus[$0.key] = $0.value }
        return PushPayload(userInfo: ["aps": ["alert": ["title": title, "body": "…"]], "nodus": nodus])
    }

    @Test func parsesTheNodusPart() throws {
        let jobId = UUID()
        let push = try #require(payload(kind: "ai_drafts_ready", eventId: "e1", extra: ["job_id": jobId.uuidString]))

        #expect(push.kind == .aiDraftsReady)
        #expect(push.jobId == jobId)
        #expect(push.title == "Узел изменили")
        #expect(PushPayload(userInfo: ["aps": [:]]) == nil)
    }

    @Test func unknownKindsStillSync() async throws {
        let push = try #require(payload(kind: "something_new", eventId: "e2"))
        let synced = Recorder<Bool>()
        let router = PushRouter(log: PushEventLog(defaults: defaults))
        router.destinations.sync = { synced.record(true) }

        await router.tapped(push)

        #expect(push.kind == nil)
        #expect(synced.values == [true])
    }

    @Test func oneEventIsAnnouncedOnce() async throws {
        let push = try #require(payload(kind: "shared_node_changed", eventId: "same", extra: ["node_id": UUID().uuidString]))
        let toasts = Recorder<String>()
        let router = PushRouter(log: PushEventLog(defaults: defaults))
        router.destinations.toast = { toasts.record($0) }

        await router.received(push)
        await router.received(push)

        #expect(toasts.values == ["Узел изменили"])
    }

    @Test func readyDraftsOpenTheReviewAfterSync() async throws {
        let jobId = UUID()
        let push = try #require(payload(kind: "ai_drafts_ready", eventId: "e3", extra: ["job_id": jobId.uuidString]))
        let steps = Recorder<String>()
        let router = PushRouter(log: PushEventLog(defaults: defaults))
        router.destinations.sync = { steps.record("sync") }
        router.destinations.openDraftsReview = { steps.record("open \($0)") }
        router.destinations.toast = { steps.record("toast \($0)") }

        await router.received(push)
        await router.tapped(push)

        #expect(steps.values == ["sync", "sync", "open \(jobId)"])
    }

    @Test func readyImportsOpenTheirPreviewAfterSync() async throws {
        let importId = UUID()
        let push = try #require(payload(kind: "import_ready", eventId: "e4", extra: ["import_id": importId.uuidString]))
        let steps = Recorder<String>()
        let router = PushRouter(log: PushEventLog(defaults: defaults))
        router.destinations.sync = { steps.record("sync") }
        router.destinations.openImport = { steps.record("open \($0)") }

        await router.tapped(push)

        #expect(steps.values == ["sync", "open \(importId)"])
    }

    @Test func oldEventsAreForgottenAfterAWeek() {
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let log = PushEventLog(defaults: defaults, now: { now })

        #expect(log.markShown("e"))
        #expect(!log.markShown("e"))
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(log.markShown("e"))
    }
}
