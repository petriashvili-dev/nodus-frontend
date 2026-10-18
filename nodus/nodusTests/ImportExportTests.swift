import Foundation
import Testing
@testable import nodus

struct ImportExportTests {
    private actor AttemptCounter {
        private var value = 0
        func next() -> Int { value += 1; return value }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(_ transport: FakeTransport) -> ImportExportService {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let store = InMemorySecureStore(session: Fixtures.session(
            access: "token", refresh: "refresh", expiresAt: now.addingTimeInterval(3600)
        ))
        let session = AuthSession(configuration: configuration, transport: transport, store: store, now: { now })
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        return ImportExportService(api: api)
    }

    @Test func exportReturnsServerFileAndContentDispositionName() async throws {
        let payload = #"{"source":"nodus","version":1,"nodes":[]}"#
        let transport = FakeTransport { _ in
            FakeTransport.Reply(status: 200, body: Data(payload.utf8), headers: [
                "Content-Type": "application/json",
                "Content-Disposition": "attachment; filename=\"nodus-export-2026-10-18.json\"",
            ])
        }

        let file = try await service(transport).export()

        #expect(file.data == Data(payload.utf8))
        #expect(file.fileName == "nodus-export-2026-10-18.json")
        #expect(await transport.requests(to: "/me/export").count == 1)
    }

    @Test func directImportSendsContentNameTimezoneAndIdempotencyKey() async throws {
        let transport = FakeTransport { _ in
            FakeTransport.Reply(status: 200, body: Data(#"{"mode":"direct","format":"nodus/v1","result":{"created_nodes":2,"skipped_duplicates":1,"skipped_inactive":0,"issues":[]}}"#.utf8))
        }

        let response = try await service(transport).importFile(
            data: Data(#"{"source":"nodus","version":1,"nodes":[]}"#.utf8),
            fileName: "backup.json",
            timezone: "Europe/Moscow"
        )

        let request = try #require(await transport.requests(to: "/me/import").first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["file_name"] == "backup.json")
        #expect(json["timezone"] == "Europe/Moscow")
        #expect(json["content"]?.contains("nodus") == true)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        #expect(response.mode == "direct")
        #expect(response.result?.createdNodes == 2)
    }

    @Test func confirmUsesThePersistedOperationKeyAndSelectedIndexes() async throws {
        let jobId = UUID()
        let key = UUID()
        let transport = FakeTransport { _ in
            .json(200, """
            {"id":"\(jobId.uuidString)","status":"completed","file_name":"todo.csv","preview":[]}
            """)
        }

        try await service(transport).confirm(jobId, indexes: [0, 2], idempotencyKey: key)

        let request = try #require(await transport.requests(to: "/me/imports/\(jobId.uuidString)/confirm").first)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: [Int]])
        #expect(body["indexes"] == [0, 2])
    }

    @Test func retryAfterTransportFailureReusesTheSameImportKey() async throws {
        let attempts = AttemptCounter()
        let transport = FakeTransport { _ in
            if await attempts.next() == 1 { throw URLError(.timedOut) }
            return .json(200, #"{"mode":"direct","format":"nodus/v1","result":{"created_nodes":0,"skipped_duplicates":0,"skipped_inactive":0,"issues":[]}}"#)
        }
        let importer = service(transport)
        let data = Data(#"{"source":"nodus","version":1,"nodes":[]}"#.utf8)

        do {
            _ = try await importer.importFile(data: data, fileName: "same.json", timezone: "UTC")
            Issue.record("expected the first attempt to time out")
        } catch let error as APIError {
            #expect(error.isRetryableWithSameKey)
        }
        _ = try await importer.importFile(data: data, fileName: "same.json", timezone: "UTC")

        let requests = await transport.requests(to: "/me/import")
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Idempotency-Key") == requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
    }
}
