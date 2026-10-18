import Foundation
import os

/// Brings the account up to date: creates the anonymous account on first
/// network access, registers the device and loads the profile. The profile
/// is the only source of AI access (docs/01-ai-access.md).
@MainActor
final class AccountService {
    private let api: APIClient
    private let session: AuthSession
    private let store: SecureStore
    private let aiAccessStore: AIAccessStore
    private let appVersion: String?
    private let logger = Logger(subsystem: "app.nodus", category: "Account")

    private(set) var profile: UserProfileDTO?
    private var refreshTask: Task<Void, Never>?
    private var registeredDeviceKey: String?

    /// Pushed in later by the APNs registration.
    var apnsToken: String? {
        didSet { if apnsToken != oldValue { registeredDeviceKey = nil } }
    }

    init(
        api: APIClient,
        session: AuthSession,
        store: SecureStore,
        aiAccessStore: AIAccessStore,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.api = api
        self.session = session
        self.store = store
        self.aiAccessStore = aiAccessStore
        self.appVersion = appVersion
    }

    /// Launch and foreground. Overlapping calls join the one in progress;
    /// failures (offline) are silent — the app keeps working locally.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Applies a profile that arrived from sync or a mutation response.
    func apply(_ profile: UserProfileDTO) {
        self.profile = profile
        aiAccessStore.apply(profile.aiAccess)
        let isAnonymous = profile.isAnonymous
        Task { [session] in try? await session.setAnonymous(isAnonymous) }
    }

    private func performRefresh() async {
        do {
            try await registerDeviceIfNeeded()
            let profile = try await api.send(APIRequest<UserProfileDTO>(method: .get, path: "me"))
            apply(profile)
        } catch let error as APIError where error.isOffline {
            // Offline: keep the last known profile and AI access.
        } catch {
            logger.error("Account refresh failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// `POST /devices` is idempotent and needs no key; it is repeated only
    /// when something it carries changes.
    private func registerDeviceIfNeeded() async throws {
        // Creates the anonymous account on the very first network access.
        _ = try await session.accessToken()
        let userId = await session.userId
        let key = [userId?.uuidString, apnsToken, appVersion].map { $0 ?? "-" }.joined(separator: "|")
        guard key != registeredDeviceKey else { return }

        let body = RegisterDeviceBody(
            installationId: try store.installationId(),
            apnsToken: apnsToken,
            apnsEnvironment: apnsToken == nil ? nil : APNsEnvironment.current,
            appVersion: appVersion
        )
        _ = try await api.send(APIRequest<EmptyResponse>(method: .post, path: "devices", json: body))
        registeredDeviceKey = key
    }
}

nonisolated enum APNsEnvironment {
    /// Only a development-signed build from Xcode is `sandbox`; ad hoc,
    /// TestFlight and App Store are `production`. Decided by the embedded
    /// provisioning profile, not `#if DEBUG`: a wrong environment makes APNs
    /// reject the token. When unsure, the field is not sent.
    static var current: String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            #if DEBUG
            return nil
            #else
            return "production"
            #endif
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return environment(profileData: data)
        #endif
    }

    /// `aps-environment` from the provisioning profile (a CMS container with
    /// an XML plist inside).
    static func environment(profileData data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return nil }
        return value == "production" ? "production" : "sandbox"
    }
}
