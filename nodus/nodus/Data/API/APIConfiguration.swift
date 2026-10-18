import Foundation

/// Where the backend lives. The value comes from the `NODUS_API_BASE_URL`
/// build setting through `nodus-Info.plist`, so Debug and Release can point
/// at different hosts without code changes.
nonisolated struct APIConfiguration: Sendable {
    let baseURL: URL

    static let live = APIConfiguration(bundle: .main)

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    init(bundle: Bundle) {
        let raw = bundle.object(forInfoDictionaryKey: "NodusAPIBaseURL") as? String
        // A missing key is a project misconfiguration; fail loudly in Debug
        // and fall back to the local server rather than crash in Release.
        assert(raw?.isEmpty == false, "NodusAPIBaseURL is missing from Info.plist")
        self.init(baseURL: URL(string: raw ?? "") ?? URL(string: "http://localhost:5258/v1")!)
    }

    func url(for path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.append(path: String(component))
        }
        guard !query.isEmpty else { return url }
        return url.appending(queryItems: query)
    }
}
