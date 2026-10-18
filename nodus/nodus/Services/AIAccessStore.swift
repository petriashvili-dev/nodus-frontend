import Foundation
import Combine

/// The last AI access the server reported, kept in the app group so the
/// Siri intent sees the same answer as the app without a network round trip.
/// Only the server profile (`GET /v1/me`, sync `entity_type: user`) writes
/// it; until the account exists it stays empty and every AI entry point is
/// hidden.
@MainActor
final class AIAccessStore: ObservableObject {
    @Published private(set) var access: AIAccess

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AIAccessStore.sharedDefaults) {
        self.defaults = defaults
        access = Self.load(from: defaults)
    }

    /// Applied immediately: a feature granted or revoked on the server shows
    /// or hides its entry point without a relaunch.
    func apply(_ newAccess: AIAccess) {
        guard newAccess != access else { return }
        access = newAccess
        defaults.set(newAccess.features.map(\.rawValue).sorted(), forKey: Keys.features)
        defaults.set(newAccess.consentAt, forKey: Keys.consentAt)
    }

    nonisolated static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: NodusModelContainer.appGroupID) ?? .standard
    }

    nonisolated static func load(from defaults: UserDefaults = sharedDefaults) -> AIAccess {
        AIAccess(
            featureKeys: defaults.stringArray(forKey: Keys.features),
            consentAt: defaults.object(forKey: Keys.consentAt) as? Date
        )
    }

    private nonisolated enum Keys {
        static let features = "aiFeatures"
        static let consentAt = "aiConsentAt"
    }
}
