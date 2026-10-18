import Foundation
import SwiftData

/// A voice note on its way to becoming knots (`LocalAiDraftJobs`). The text
/// stays on the device until the drafts are confirmed or cancelled: the
/// server does not return it, and a retry needs it.
@Model
nonisolated final class AIDraftJob {
    nonisolated enum Status: String, Sendable {
        /// Saved locally; the server has not accepted it yet (offline).
        case unsent
        case queued
        case processing
        case ready
        case confirmed
        case failed
        case cancelled
        case expired
    }

    /// The server job id once accepted; a local id before that.
    @Attribute(.unique) var id: UUID
    var isOnServer: Bool
    var statusRaw: String
    var transcript: String
    var timeZoneIdentifier: String
    var referenceTime: Date
    var errorCode: String?
    /// `[NodeDraftDTO]` as JSON.
    var draftsData: Data?
    var createdAt: Date
    var readyAt: Date?
    var expiresAt: Date?

    init(transcript: String, timeZone: TimeZone, referenceTime: Date) {
        id = UUID()
        isOnServer = false
        statusRaw = Status.unsent.rawValue
        self.transcript = transcript
        timeZoneIdentifier = timeZone.identifier
        self.referenceTime = referenceTime
        createdAt = referenceTime
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var drafts: [NodeDraftDTO] {
        guard let draftsData else { return [] }
        return (try? APICoding.decoder.decode([NodeDraftDTO].self, from: draftsData)) ?? []
    }

    /// Shown in "Drafts" and kept even when the AI feature is withdrawn.
    var isUnfinished: Bool {
        [.unsent, .queued, .processing, .ready, .failed].contains(status)
    }

    func apply(_ dto: AIDraftJobDTO) {
        isOnServer = true
        statusRaw = dto.status
        errorCode = dto.error
        readyAt = dto.readyAt
        expiresAt = dto.expiresAt
        if let drafts = dto.drafts, !drafts.isEmpty {
            draftsData = try? APICoding.encoder.encode(drafts)
        }
    }
}
