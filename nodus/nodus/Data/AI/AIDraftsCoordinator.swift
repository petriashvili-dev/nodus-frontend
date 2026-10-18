import Foundation
import Combine

/// The state of the voice → drafts → knots flow shared by the thread, the
/// consent screen, the review screen and "Drafts" in Settings.
@MainActor
final class AIDraftsCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for `202`.
        case sending
        /// Accepted; "Untangling thoughts…" until the drafts are ready.
        case waiting(jobId: UUID)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var reviewJob: AIDraftJob?
    @Published var isShowingConsent = false
    @Published private(set) var jobs: [AIDraftJob] = []

    let service: AIDraftsService
    /// Brief messages on the thread (the toast of the current screen).
    var toast: (String) -> Void = { _ in }
    private let language: () -> AppLanguage
    private let synchronize: () async -> Void
    private var textAwaitingConsent: String?
    private var readyJobIds: Set<UUID> = []

    init(
        service: AIDraftsService,
        language: @escaping () -> AppLanguage = { .ru },
        synchronize: @escaping () async -> Void = {}
    ) {
        self.service = service
        self.language = language
        self.synchronize = synchronize
        jobs = service.unfinishedJobs()
        readyJobIds = Set(jobs.filter { $0.status == .ready }.map(\.id))
    }

    // MARK: - Voice note

    /// From the composer. Returns `true` when the composer can close.
    func submit(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        phase = .sending
        let result = await service.submit(trimmed)
        return handle(result, text: trimmed)
    }

    private func handle(_ result: AIDraftsService.SubmitResult, text: String) -> Bool {
        refreshJobs()
        switch result {
        case let .accepted(jobId):
            phase = .waiting(jobId: jobId)
            return true
        case .savedOffline:
            phase = .idle
            toast(string("No connection. The note is saved in Drafts"))
            return true
        case .needsConsent:
            phase = .idle
            textAwaitingConsent = text
            isShowingConsent = true
            return false
        case .unavailable:
            phase = .idle
            toast(string("This feature is currently unavailable."))
            return true
        case .quotaExceeded:
            phase = .idle
            toast(string("The AI limit for today is used up"))
            return false
        case .failed:
            phase = .idle
            toast(string("Could not untangle the note"))
            return false
        }
    }

    /// "Close" on the waiting card: the job keeps going on the server.
    func closeWaiting() {
        phase = .idle
    }

    // MARK: - Consent

    func consentGranted() async {
        isShowingConsent = false
        do {
            try service.grantConsent()
        } catch {
            toast(string("This feature is currently unavailable."))
            return
        }
        // The server profile is the only source of consent. The Outbox
        // writes it first; only a confirmed profile may unlock the AI call.
        await synchronize()
        guard service.serverHasConsent else {
            if let text = textAwaitingConsent {
                service.saveLocally(text)
                textAwaitingConsent = nil
                refreshJobs()
                toast(string("No connection. The note is saved in Drafts"))
            } else {
                toast(string("No connection"))
            }
            return
        }
        guard let text = textAwaitingConsent else { return }
        textAwaitingConsent = nil
        phase = .sending
        _ = handle(await service.submit(text), text: text)
    }

    func consentDeclined() {
        isShowingConsent = false
        textAwaitingConsent = nil
    }

    /// The "AI assistant" switch in Settings.
    func setConsent(_ granted: Bool) {
        do {
            if granted { try service.grantConsent() } else { try service.revokeConsent() }
        } catch {
            toast(string("This feature is currently unavailable."))
        }
    }

    // MARK: - Jobs

    /// After every sync: a job that became ready opens by itself while its
    /// waiting card is on screen, otherwise it is announced.
    func dataChanged() {
        refreshJobs()
        let ready = Set(jobs.filter { $0.status == .ready }.map(\.id))
        let newlyReady = ready.subtracting(readyJobIds)
        readyJobIds = ready

        if case let .waiting(jobId) = phase, let job = jobs.first(where: { $0.id == jobId }) {
            switch job.status {
            case .ready:
                phase = .idle
                reviewJob = job
            case .failed, .expired, .cancelled:
                phase = .idle
                toast(statusMessage(for: job))
            default:
                break
            }
        } else if !newlyReady.isEmpty, reviewJob == nil {
            toast(string("Drafts are ready"))
        }
    }

    /// A push or deep link with `job_id` (the same screen as in foreground).
    func openJob(id: UUID) {
        refreshJobs()
        if let job = service.job(id: id), job.status == .ready {
            reviewJob = job
        }
    }

    func confirm(_ job: AIDraftJob, drafts: [ReminderDraft]) -> Bool {
        do {
            _ = try service.confirm(job, drafts: drafts)
            reviewJob = nil
            refreshJobs()
            toast(string(drafts.count == 1 ? "Knot tied." : "Knots tied"))
            return true
        } catch {
            toast(string("Could not tie the knot."))
            return false
        }
    }

    func cancel(_ job: AIDraftJob) {
        try? service.cancel(job)
        if reviewJob?.id == job.id { reviewJob = nil }
        refreshJobs()
    }

    func remove(_ job: AIDraftJob) {
        try? service.dismiss(job)
        refreshJobs()
    }

    func resubmit(_ job: AIDraftJob) async {
        let text = job.transcript
        phase = .sending
        _ = handle(await service.resubmit(job), text: text)
    }

    func refreshJobs() {
        jobs = service.unfinishedJobs()
    }

    /// What "Drafts" says about a job that is not simply waiting or ready.
    func statusMessage(for job: AIDraftJob) -> String {
        switch job.status {
        case .unsent:
            return string("Not sent yet")
        case .queued, .processing:
            return string("Untangling thoughts…")
        case .ready:
            return string("Ready to review")
        case .expired:
            return string("The drafts have expired")
        case .failed where job.errorCode == "nothing_recognized":
            return string("No knots found in the note")
        case .failed, .cancelled, .confirmed:
            return string("Could not untangle the note")
        }
    }

    private func string(_ key: String) -> String {
        language().localizedString(key)
    }
}
