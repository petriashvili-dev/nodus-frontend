import Foundation
import Combine
import SwiftData
import os

/// Brings the account up to date: creates the anonymous account on first
/// network access, registers the device and loads the profile. The profile
/// is the only source of AI access (docs/01-ai-access.md).
@MainActor
final class AccountService: ObservableObject {
    nonisolated enum EmailError: Error, Equatable {
        case invalidEmail
        case invalidCode
        case alreadyLinked
        case tooManyRequests
        case offline
        case failed
    }

    private let api: APIClient
    private let session: AuthSession
    private let store: SecureStore
    private let aiAccessStore: AIAccessStore
    private let appVersion: String?
    private let logger = Logger(subsystem: "app.nodus", category: "Account")

    @Published private(set) var profile: UserProfileDTO?
    /// An email account's session ended; the user is asked to sign in.
    @Published var isSessionEnded = false
    /// Wipes the local cache, notifications and widgets for a new account
    /// (or none); set by `AppServices`.
    var resetLocalData: (UUID?) async -> Void = { _ in }
    /// Enqueues an Outbox operation on the main store; set by `AppServices`.
    var enqueue: (OutboxOperation) throws -> Void = { _ in }
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

    var isAnonymous: Bool {
        profile?.isAnonymous ?? true
    }

    // MARK: - Display name

    /// `PATCH /me` through the Outbox; the name shows at once.
    func updateDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if var current = profile {
            current.displayName = trimmed.isEmpty ? nil : trimmed
            profile = current
        }
        try enqueue(OutboxOperation(
            kind: .updateProfile, method: .patch, path: "me",
            body: try APICoding.encoder.encode(DisplayNameBody(displayName: trimmed)),
            entityId: nil
        ))
    }

    // MARK: - Linking an email ("Save account")

    /// The answer is the same for any address; a code goes to the email.
    func startLinkingEmail(_ email: String) async throws {
        try await emailRequest {
            _ = try await self.api.send(try APIRequest<EmptyResponse>(method: .post, path: "auth/email/start", json: EmailBody(email: email)))
        }
    }

    /// The same account, now with an email: `UserId` and data stay.
    func verifyLinkingEmail(_ email: String, code: String) async throws {
        try await emailRequest {
            let profile = try await self.api.send(try APIRequest<UserProfileDTO>(
                method: .post, path: "auth/email/verify", json: EmailCodeBody(email: email, code: code)
            ))
            self.apply(profile)
        }
    }

    // MARK: - Recovery ("Restore account")

    func startRecovery(_ email: String) async throws {
        try await emailRequest {
            _ = try await self.api.send(try APIRequest<EmptyResponse>(
                method: .post, path: "auth/email/sign-in/start", json: EmailBody(email: email), requiresAuth: false
            ))
        }
    }

    /// Signs in to the account behind the email. The anonymous account of
    /// this device is not merged: its local data is replaced (the user was
    /// warned), then the restored account arrives through a snapshot.
    func completeRecovery(_ email: String, code: String) async throws {
        try await emailRequest {
            let tokens = try await self.api.send(try APIRequest<AuthTokens>(
                method: .post, path: "auth/email/sign-in/verify", json: EmailCodeBody(email: email, code: code), requiresAuth: false
            ))
            try await self.session.adopt(tokens, isAnonymous: false)
            self.isSessionEnded = false
            self.registeredDeviceKey = nil
            self.profile = nil
            self.aiAccessStore.apply(.none)
            await self.resetLocalData(tokens.userId)
            await self.refresh()
        }
    }

    // MARK: - Logout and deletion

    /// `POST /auth/logout`, `DELETE /devices/{id}`, then the device forgets
    /// the account. Offline the server session simply expires.
    func logout() async {
        if let refreshToken = await session.currentRefreshToken {
            _ = try? await api.send(try APIRequest<EmptyResponse>(
                method: .post, path: "auth/logout", json: RefreshTokenBody(refreshToken: refreshToken), requiresAuth: false
            ))
        }
        if let installation = try? store.installationId() {
            _ = try? await api.send(APIRequest<EmptyResponse>(method: .delete, path: "devices/\(installation.uuidString)"))
        }
        await forgetAccount()
    }

    /// `DELETE /me` — online only, not through the Outbox. `401` after a
    /// lost response means the account is already gone.
    func deleteAccount() async throws {
        do {
            _ = try await api.send(APIRequest<EmptyResponse>(method: .delete, path: "me"))
        } catch let error as APIError where error.status == 401 || error.code == "invalid_refresh_token" {
            // Already deleted.
        } catch APIError.sessionEnded {
            // Already deleted.
        } catch let error as APIError where error.isOffline {
            throw EmailError.offline
        }
        await forgetAccount()
    }

    private func forgetAccount() async {
        try? await session.clear()
        profile = nil
        registeredDeviceKey = nil
        isSessionEnded = false
        aiAccessStore.apply(.none)
        await resetLocalData(nil)
    }

    private func emailRequest(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as APIError {
            switch (error.status, error.code) {
            case (_, _) where error.isOffline: throw EmailError.offline
            case (_, "invalid_code"): throw EmailError.invalidCode
            case (_, "email_already_linked"): throw EmailError.alreadyLinked
            case (_, "validation_failed"): throw EmailError.invalidEmail
            case (429, _): throw EmailError.tooManyRequests
            default: throw EmailError.failed
            }
        }
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
