import Testing
@testable import nodus

struct SSEParserTests {
    @Test func dispatchesSyncSignalsAndIgnoresPings() {
        var parser = SSEParser()
        let lines = [
            ": ping",
            "retry: 3000",
            "id: 45",
            "event: sync.required",
            #"data: {"revision":45,"event_id":"45"}"#,
            "",
            ": ping",
        ]

        let events = lines.compactMap { parser.consume($0) }

        #expect(events == [SSEParser.Event(id: "45", name: "sync.required", data: #"{"revision":45,"event_id":"45"}"#)])
        #expect(parser.retry == .milliseconds(3000))
    }

    @Test func eventNameDoesNotLeakIntoTheNextEvent() {
        var parser = SSEParser()
        _ = parser.consume("event: sync.required")
        _ = parser.consume("data: {}")

        let next = parser.consume("data: plain")

        #expect(next?.name == "message")
    }
}
