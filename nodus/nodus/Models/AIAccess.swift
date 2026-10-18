import Foundation

/// AI features the server has enabled for this user (`user.features`).
/// The client knows nothing about plans or subscriptions: a feature is either
/// listed or absent, and an absent feature has no entry point at all.
nonisolated enum AIFeature: String, CaseIterable, Sendable {
    case drafts = "ai_drafts"
    case continuations = "ai_continuations"
    case fileImport = "ai_import"
}

nonisolated struct AIAccess: Equatable, Sendable {
    var features: Set<AIFeature>
    /// Server-side consent (`user.ai_consent_at`), never a local flag:
    /// without it the server refuses to send data to the model.
    var consentAt: Date?

    static let none = AIAccess(features: [], consentAt: nil)

    init(features: Set<AIFeature>, consentAt: Date?) {
        self.features = features
        self.consentAt = consentAt
    }

    /// A missing `features` field (older server) means no features. Unknown
    /// keys are ignored so a newer server cannot break an older build.
    init(featureKeys: [String]?, consentAt: Date?) {
        self.init(
            features: Set((featureKeys ?? []).compactMap(AIFeature.init(rawValue:))),
            consentAt: consentAt
        )
    }

    func isAvailable(_ feature: AIFeature) -> Bool {
        features.contains(feature)
    }

    var hasConsent: Bool {
        consentAt != nil
    }

    /// The "AI assistant" switch in Settings exists only for users who have
    /// at least one AI feature.
    var hasAnyFeature: Bool {
        !features.isEmpty
    }
}
