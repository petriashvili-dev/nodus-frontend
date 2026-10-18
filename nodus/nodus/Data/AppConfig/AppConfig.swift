import Foundation

/// Server-side settings that change without a release
/// (`nodus_backend/docs/ios/10-app-config.md`). Every key has a built-in
/// default: no network, a missing key or a value of the wrong type all fall
/// back to it.
nonisolated struct AppConfig: Equatable, Sendable {
    var privacyPolicyURL: URL
    var termsURL: URL
    var supportURL: URL
    /// No App Store page yet: update prompts are shown without a button.
    var appStoreURL: URL?
    var minSupportedVersion: AppVersion?
    var latestVersion: AppVersion?
    var limits: Limits

    nonisolated struct Limits: Equatable, Sendable {
        var aiDraftTextMaxChars = 4000
        var importMaxChars = 200_000
        var importAIMaxChars = 30_000
        var displayNameMaxChars = 60
    }

    static let defaults = AppConfig(
        privacyPolicyURL: URL(string: "https://nodus.app/privacy")!,
        termsURL: URL(string: "https://nodus.app/terms")!,
        supportURL: URL(string: "mailto:support@nodus.app")!,
        appStoreURL: nil,
        minSupportedVersion: nil,
        latestVersion: nil,
        limits: Limits()
    )

    /// Builds the config from a `GET /app-config` body, key by key.
    init(json data: Data) {
        self = .defaults
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let values = root["values"] as? [String: Any] ?? [:]
        if let url = Self.url(values["links.privacy_policy"]) { privacyPolicyURL = url }
        if let url = Self.url(values["links.terms"]) { termsURL = url }
        if let url = Self.url(values["links.support"]) { supportURL = url }
        if let url = Self.url(values["links.app_store"]) { appStoreURL = url }
        minSupportedVersion = (values["min_supported_version"] as? String).flatMap(AppVersion.init)
        latestVersion = (values["latest_version"] as? String).flatMap(AppVersion.init)

        let limits = root["limits"] as? [String: Any] ?? [:]
        if let value = limits["ai_draft_text_max_chars"] as? Int { self.limits.aiDraftTextMaxChars = value }
        if let value = limits["import_max_chars"] as? Int { self.limits.importMaxChars = value }
        if let value = limits["import_ai_max_chars"] as? Int { self.limits.importAIMaxChars = value }
        if let value = limits["display_name_max_chars"] as? Int { self.limits.displayNameMaxChars = value }
    }

    private init(
        privacyPolicyURL: URL, termsURL: URL, supportURL: URL, appStoreURL: URL?,
        minSupportedVersion: AppVersion?, latestVersion: AppVersion?, limits: Limits
    ) {
        self.privacyPolicyURL = privacyPolicyURL
        self.termsURL = termsURL
        self.supportURL = supportURL
        self.appStoreURL = appStoreURL
        self.minSupportedVersion = minSupportedVersion
        self.latestVersion = latestVersion
        self.limits = limits
    }

    private static func url(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }

    /// The installed version is below the supported minimum.
    func requiresUpdate(current: AppVersion) -> Bool {
        guard let minSupportedVersion else { return false }
        return current < minSupportedVersion
    }

    func hasNewerVersion(than current: AppVersion) -> Bool {
        guard let latestVersion else { return false }
        return current < latestVersion
    }
}

/// `1.10.0` > `1.9.0`: compared by numeric components, missing ones are 0.
nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    static var installed: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}
