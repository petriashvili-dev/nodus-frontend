import Foundation

/// `UserProfile` from `GET /v1/me` and sync `entity_type: user`.
nonisolated struct UserProfileDTO: Codable, Sendable, Equatable {
    var id: UUID
    var isAnonymous: Bool
    var email: String?
    var displayName: String?
    var timezone: String?
    /// Missing on an older server — treated as no features.
    var features: [String]?
    var aiConsentAt: Date?
    var version: Int

    var aiAccess: AIAccess {
        AIAccess(featureKeys: features, consentAt: aiConsentAt)
    }
}

nonisolated struct RegisterDeviceBody: Encodable, Sendable {
    var installationId: UUID
    var apnsToken: String?
    var apnsEnvironment: String?
    var appVersion: String?
}
