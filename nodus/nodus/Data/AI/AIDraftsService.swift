import Foundation
import SwiftData
import os

/// Voice AI drafts through the backend (`nodus_backend/docs/ios/07-ai.md`).
/// Nothing becomes a knot until the user confirms the drafts.
@MainActor
final class AIDraftsService {
    nonisolated enum SubmitResult: Equatable, Sendable {
        /// The server accepted the job (`202`); it is safe to close the screen.
        case accepted(jobId: UUID)
        /// No network before `202`: the text is kept to send later.
        case savedOffline(jobId: UUID)
        case needsConsent
        case unavailable
        case quotaExceeded
        case failed
    }

    private let context: ModelContext
    private let api: APIClient
    private let aiAccessStore: AIAccessStore
    private let account: AccountService
    private let didEnqueue: () -> Void
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.nodus", category: "AIDrafts")

    init(
        context: ModelContext,
        api: APIClient,
        aiAccessStore: AIAccessStore,
        account: AccountService,
        didEnqueue: @escaping () -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.api = api
        self.aiAccessStore = aiAccessStore
        self.account = account
        self.didEnqueue = didEnqueue
        self.now = now
    }

    // MARK: - Consent

    /// "Allow" on the consent screen: optimistic locally, sent through the
    /// Outbox (`PUT /me/ai-consent`).
    func grantConsent() throws {
        try setConsent(true)
    }

    /// The "AI assistant" switch turned off.
    func revokeConsent() throws {
        try setConsent(false)
    }

    private func setConsent(_ granted: Bool) throws {
        var access = aiAccessStore.access
        access.consentAt = granted ? (access.consentAt ?? now()) : nil
        aiAccessStore.apply(access)
        // Only the latest choice matters; an unsent earlier one is replaced.
        let kind = OutboxOperation.Kind.setAIConsent.rawValue
        let unsent = try context.fetch(FetchDescriptor<OutboxOperation>(predicate: #Predicate { $0.kindRaw == kind && !$0.hasBeenSent }))
        unsent.forEach(context.delete)
        context.insert(OutboxOperation(
            kind: .setAIConsent, method: .put, path: "me/ai-consent",
            body: try APICoding.encoder.encode(AIConsentBody(granted: granted)),
            entityId: nil, now: now()
        ))
        try context.save()
        didEnqueue()
    }

    // MARK: - Submitting

    /// Sends a voice note. Only after `202` may the UI say the screen can be
    /// closed. Online only; offline the text waits in "Drafts".
    func submit(_ text: String, referenceTime: Date? = nil) async -> SubmitResult {
        let access = aiAccessStore.access
        guard access.isAvailable(.drafts) else { return .unavailable }
        guard access.hasConsent else { return .needsConsent }

        let job = AIDraftJob(transcript: text, timeZone: .current, referenceTime: referenceTime ?? now())
        context.insert(job)
        try? context.save()
        return await send(job)
    }

    /// "Send" for a note saved offline, "Retry" for a failed one — always a
    /// new job with a new key: the server remembers the old answer.
    func resubmit(_ job: AIDraftJob) async -> SubmitResult {
        let access = aiAccessStore.access
        guard access.isAvailable(.drafts) else { return .unavailable }
        guard access.hasConsent else { return .needsConsent }
        if job.isOnServer {
            let fresh = AIDraftJob(transcript: job.transcript, timeZone: .current, referenceTime: now())
            context.delete(job)
            context.insert(fresh)
            try? context.save()
            return await send(fresh)
        }
        return await send(job)
    }

    private func send(_ job: AIDraftJob) async -> SubmitResult {
        let body = CreateDraftJobBody(text: job.transcript, timezone: job.timeZoneIdentifier, referenceTime: job.referenceTime)
        do {
            let request = try APIRequest<AIDraftJobDTO>(method: .post, path: "ai/node-drafts", json: body, idempotencyKey: UUID())
            let dto = try await api.send(request)
            // The server's id replaces the local one.
            let accepted = AIDraftJob(transcript: job.transcript, timeZone: TimeZone(identifier: job.timeZoneIdentifier) ?? .current, referenceTime: job.referenceTime)
            accepted.id = dto.id
            accepted.apply(dto)
            context.delete(job)
            context.insert(accepted)
            try context.save()
            return .accepted(jobId: dto.id)
        } catch let error as APIError {
            switch (error.status, error.code) {
            case (_, _) where error.isOffline:
                return .savedOffline(jobId: job.id)
            case (403, "ai_consent_required"):
                Task { await account.refresh() }
                return .needsConsent
            case (403, "feature_not_available"):
                Task { await account.refresh() }
                return .unavailable
            case (429, "ai_quota_exceeded"):
                return .quotaExceeded
            default:
                logger.notice("Draft job refused: \(error.code ?? "-", privacy: .public)")
                return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: - Confirming

    /// Creates the reviewed knots locally and queues the single confirm
    /// operation in the same save. A rejection removes them again.
    func confirm(_ job: AIDraftJob, drafts: [ReminderDraft]) throws -> [ReminderNode] {
        let moment = now()
        var nodes: [ReminderNode] = []
        var bodies: [CreateNodeBody] = []
        for draft in drafts {
            let node = ReminderNode(
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: draft.note.isEmpty ? nil : draft.note,
                scheduledAt: draft.scheduledAt,
                originDate: draft.repeatSchedule.isYearly ? draft.originDate : nil,
                repeatSchedule: draft.repeatSchedule,
                leadTimes: draft.leadTimes,
                createdAt: moment,
                updatedAt: moment
            )
            node.timeZoneIdentifier = job.timeZoneIdentifier
            nodes.append(node)
            bodies.append(NodeMapper.createBody(id: node.id, fields: ReminderService.fields(of: node)))
        }
        nodes.forEach(context.insert)
        job.status = .confirmed
        context.insert(OutboxOperation(
            kind: .confirmAIDrafts, method: .post, path: "ai/node-drafts/\(job.id.uuidString)/confirm",
            body: try APICoding.encoder.encode(ConfirmDraftsBody(nodes: bodies)),
            entityId: job.id, now: moment
        ))
        try context.save()
        didEnqueue()
        return nodes
    }

    func cancel(_ job: AIDraftJob) throws {
        if job.isOnServer {
            context.insert(OutboxOperation(
                kind: .cancelAIDrafts, method: .post, path: "ai/node-drafts/\(job.id.uuidString)/cancel",
                body: nil, entityId: job.id, now: now()
            ))
            job.status = .cancelled
        } else {
            context.delete(job)
        }
        try context.save()
        didEnqueue()
    }

    /// A finished job leaves "Drafts" (its text is no longer needed).
    func dismiss(_ job: AIDraftJob) throws {
        context.delete(job)
        try context.save()
    }

    // MARK: - Reading

    func unfinishedJobs() -> [AIDraftJob] {
        let jobs = (try? context.fetch(FetchDescriptor<AIDraftJob>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return jobs.filter(\.isUnfinished)
    }

    func job(id: UUID) -> AIDraftJob? {
        try? context.fetch(FetchDescriptor<AIDraftJob>(predicate: #Predicate { $0.id == id })).first
    }

    /// The server drafts as editable knots for the review screen.
    static func editableDrafts(of job: AIDraftJob, now: Date) -> [EditableDraft] {
        job.drafts.map { EditableDraft(draft: $0, fallbackZone: TimeZone(identifier: job.timeZoneIdentifier) ?? .current, now: now) }
    }
}

/// One draft on the review screen, edited with the regular knot editor.
nonisolated struct EditableDraft: Identifiable, Equatable, Sendable {
    let id: Int
    var draft: ReminderDraft
    /// The model left the date or time out; the user must pick one.
    var needsDate: Bool
    var isIncluded = true
    var issues: [DraftIssueDTO]

    init(draft dto: NodeDraftDTO, fallbackZone: TimeZone, now: Date) {
        id = dto.index
        issues = dto.issues ?? []
        let zone = TimeZone(identifier: dto.timezone ?? "") ?? fallbackZone
        let asNode = NodeDTO(
            id: UUID(), type: dto.type, ownerId: UUID(), title: dto.title, description: dto.description,
            timezone: zone.identifier, date: dto.date, time: dto.time, scheduledAt: nil,
            recurrence: dto.recurrence, trackYears: dto.trackYears, version: 0, createdAt: now, updatedAt: now,
            members: nil, horizon: nil, occurrences: nil
        )
        let decoded = NodeMapper.decode(asNode, now: now)
        let hasMoment = dto.type == .recurring ? dto.recurrence != nil : dto.date != nil
        needsDate = !hasMoment || dto.time == nil && dto.type == .oneTime
        draft = ReminderDraft(
            title: decoded.fields.title,
            note: decoded.fields.note ?? "",
            scheduledAt: hasMoment ? decoded.fields.scheduledAt : .earliestReminderTime(now: now),
            originDate: decoded.fields.originDate,
            repeatSchedule: decoded.fields.repeatSchedule,
            leadTimes: ReminderNode.defaultLeadTimes
        )
    }

    /// Ready to confirm: a title and a future moment the user has seen.
    func isValid(now: Date) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !needsDate
            && (draft.repeatSchedule.isRepeating || draft.scheduledAt > now)
    }
}
