import Foundation
import os

/// Server-sent events parsed line by line (`id:`, `event:`, `data:`,
/// `retry:`, `: ping`). An event is dispatched on its blank line, or on its
/// `data:` line when the line reader drops blank lines.
nonisolated struct SSEParser: Sendable {
    nonisolated struct Event: Equatable, Sendable {
        var id: String?
        var name: String
        var data: String
    }

    private var id: String?
    private var name: String?
    private(set) var retry: Duration?

    mutating func consume(_ line: String) -> Event? {
        if line.isEmpty {
            name = nil
            return nil
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id":
            id = String(value)
        case "event":
            name = String(value)
        case "retry":
            if let milliseconds = Int(value) { retry = .milliseconds(milliseconds) }
        case "data":
            defer { name = nil }
            return Event(id: id, name: name ?? "message", data: String(value))
        default:
            break
        }
        return nil
    }
}

/// `GET /v1/events` while the app is in the foreground
/// (docs/ios/03-sync-engine.md, "SSE"). Events only say "go and sync"; no
/// data from them is ever applied. Every (re)connection is followed by a
/// sync, so nothing missed while disconnected is lost.
actor EventStream {
    private let configuration: APIConfiguration
    private let session: AuthSession
    private let urlSession: URLSession
    private let cursor: @Sendable () async -> Int?
    private let onSignal: @Sendable () -> Void
    private let logger = Logger(subsystem: "app.nodus", category: "SSE")
    private var task: Task<Void, Never>?

    init(
        configuration: APIConfiguration,
        session: AuthSession,
        urlSession: URLSession = URLSession(configuration: .default),
        cursor: @escaping @Sendable () async -> Int?,
        onSignal: @escaping @Sendable () -> Void
    ) {
        self.configuration = configuration
        self.session = session
        self.urlSession = urlSession
        self.cursor = cursor
        self.onSignal = onSignal
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    /// Background: the connection is closed; foreground starts it again.
    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var delay: Duration = .seconds(3)
        while !Task.isCancelled {
            var serverRetry: Duration?
            do {
                serverRetry = try await connectOnce()
                delay = .seconds(3)
            } catch is CancellationError {
                return
            } catch let error as StreamError {
                if case .tooManyConnections = error { delay = max(delay, .seconds(30)) }
            } catch {
                // Network drop; reconnect with backoff.
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: serverRetry ?? delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

    private enum StreamError: Error {
        case unauthorized
        case tooManyConnections
        case status(Int)
    }

    /// One connection, until it drops. Returns the server's `retry:` delay.
    private func connectOnce() async throws -> Duration? {
        let token = try await session.accessToken()
        var request = URLRequest(url: configuration.url(for: "events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60
        let lastSeen = await cursor()
        if let lastSeen {
            // The event id is the user's revision: a client that fell behind
            // gets a signal right away.
            request.setValue(String(lastSeen), forHTTPHeaderField: "Last-Event-ID")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 401:
            try await session.refresh(rejecting: token)
            throw StreamError.unauthorized
        case 429:
            logger.notice("Too many event streams for this account")
            throw StreamError.tooManyConnections
        default:
            throw StreamError.status(status)
        }

        // Anything missed while disconnected comes through Delta Sync.
        onSignal()
        var parser = SSEParser()
        for try await line in bytes.lines {
            guard let event = parser.consume(line) else { continue }
            guard event.name == "sync.required" else { continue }
            let revision = (try? JSONDecoder().decode(SyncSignal.self, from: Data(event.data.utf8)))?.revision
            if let revision, let known = await cursor(), revision <= known { continue }
            onSignal()
        }
        return parser.retry
    }

    private nonisolated struct SyncSignal: Decodable {
        let revision: Int
    }
}
