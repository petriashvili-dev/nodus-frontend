import Foundation
import Combine
import os

/// Loads `GET /app-config` on launch and on every return from the
/// background, without blocking the UI. The last answer and its `ETag` are
/// kept, so `304` and offline launches use the saved config.
@MainActor
final class AppConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig

    private let api: APIClient
    private let defaults: UserDefaults
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.nodus", category: "AppConfig")
    private var isRefreshing = false

    init(api: APIClient, defaults: UserDefaults = AIAccessStore.sharedDefaults, now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.defaults = defaults
        self.now = now
        config = defaults.data(forKey: Keys.body).map(AppConfig.init(json:)) ?? .defaults
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var headers: [String: String] = [:]
        if let etag = defaults.string(forKey: Keys.etag) {
            headers["If-None-Match"] = etag
        }
        let request = APIRequest<EmptyResponse>(method: .get, path: "app-config", requiresAuth: false, headers: headers)
        do {
            let (data, responseHeaders) = try await api.data(request)
            defaults.set(data, forKey: Keys.body)
            defaults.set(responseHeaders["etag"], forKey: Keys.etag)
            config = AppConfig(json: data)
        } catch let error as APIError where error.status == 304 {
            // Unchanged: the saved config stays.
        } catch {
            logger.notice("App config unavailable; using the saved or built-in values")
        }
    }

    /// The installed build is below `min_supported_version`.
    var requiresUpdate: Bool {
        guard let installed = AppVersion.installed else { return false }
        return config.requiresUpdate(current: installed)
    }

    /// A newer build exists; offered at most once a day.
    func shouldOfferUpdate() -> Bool {
        guard let installed = AppVersion.installed, config.hasNewerVersion(than: installed) else { return false }
        if let last = defaults.object(forKey: Keys.lastUpdateOffer) as? Date,
           now().timeIntervalSince(last) < 24 * 60 * 60 {
            return false
        }
        defaults.set(now(), forKey: Keys.lastUpdateOffer)
        return true
    }

    private enum Keys {
        static let body = "appConfigBody"
        static let etag = "appConfigETag"
        static let lastUpdateOffer = "appConfigLastUpdateOffer"
    }
}
