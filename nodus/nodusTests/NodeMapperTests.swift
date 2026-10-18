import Foundation
import Testing
@testable import nodus

struct NodeMapperTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    private func moment(_ date: String, _ time: String, in zone: TimeZone? = nil) -> Date {
        NodeMapper.moment(date: date, time: time, calendar: NodeMapper.calendar(in: zone ?? moscow))!
    }

    private func fields(_ schedule: RepeatSchedule, at date: Date, origin: Date? = nil) -> NodeMapper.LocalFields {
        NodeMapper.LocalFields(title: "Зарядка", note: nil, scheduledAt: date, originDate: origin, repeatSchedule: schedule, timeZone: moscow)
    }

    @Test func oneTimeKnotKeepsLocalDateAndTimeInItsZone() {
        let template = NodeMapper.template(for: fields(.none, at: moment("2026-10-20", "07:30")))

        #expect(template.type == .oneTime)
        #expect(template.date == "2026-10-20")
        #expect(template.time == "07:30")
        #expect(template.timezone == "Europe/Moscow")
        #expect(template.recurrence == nil)
    }

    @Test func weekdaysBecomeAWeeklyRuleMondayToFriday() throws {
        let template = NodeMapper.template(for: fields(.weekdays, at: moment("2026-10-19", "09:00")))
        let rule = try #require(template.recurrence)

        #expect(template.type == .recurring)
        #expect(template.date == nil && template.time == nil)
        #expect(rule.frequency == "weekly")
        #expect(rule.weekDays == ["monday", "tuesday", "wednesday", "thursday", "friday"])
        #expect(rule.startDate == "2026-10-19")
        #expect(rule.times == ["09:00"])
    }

    @Test func everyTwoWeeksRepeatsOnTheStartWeekday() throws {
        // 2026-10-21 is a Wednesday.
        let rule = try #require(NodeMapper.template(for: fields(.every(2, .weeks), at: moment("2026-10-21", "18:15"))).recurrence)

        #expect(rule.frequency == "weekly")
        #expect(rule.interval == 2)
        #expect(rule.weekDays == ["wednesday"])
    }

    @Test func monthlyRepeatsOnTheStartDay() throws {
        let rule = try #require(NodeMapper.template(for: fields(.every(1, .months), at: moment("2026-10-31", "10:00"))).recurrence)

        #expect(rule.frequency == "monthly")
        #expect(rule.monthDay == 31)
    }

    @Test func yearlyWithOriginIsAnAnniversary() {
        let template = NodeMapper.template(for: fields(.every(1, .years), at: moment("2027-03-08", "09:00"), origin: moment("1990-03-08", "00:00")))

        #expect(template.type == .anniversary)
        #expect(template.date == "1990-03-08")
        #expect(template.time == "09:00")
        #expect(template.trackYears == true)
    }

    @Test func dateAndTimeFollowTheNodeZoneNotTheDevice() {
        // 23:30 in New York is already the next day in Moscow.
        let newYork = TimeZone(identifier: "America/New_York")!
        let date = moment("2026-10-20", "23:30", in: newYork)
        let local = NodeMapper.LocalFields(title: "t", note: nil, scheduledAt: date, originDate: nil, repeatSchedule: .none, timeZone: newYork)

        let template = NodeMapper.template(for: local)

        #expect(template.date == "2026-10-20")
        #expect(template.time == "23:30")
    }

    @Test(arguments: [
        (RepeatSchedule.every(3, .days), "daily", 3, [String]()),
        (RepeatSchedule.weekdays, "weekly", 1, ["monday", "tuesday", "wednesday", "thursday", "friday"]),
        (RepeatSchedule.every(1, .weeks), "weekly", 1, ["sunday"]),
        (RepeatSchedule.every(2, .months), "monthly", 2, []),
        (RepeatSchedule.every(2, .years), "yearly", 2, []),
    ])
    func serverRulesMapBackToTheSameSchedule(schedule: RepeatSchedule, frequency: String, interval: Int, weekDays: [String]) {
        let rule = RecurrenceDTO(frequency: frequency, interval: interval, startDate: "2026-10-18", until: nil, times: ["08:00"], weekDays: weekDays, monthDay: nil)

        #expect(NodeMapper.schedule(for: rule) == schedule)
    }

    @Test func decodedRecurringNodeStartsAtItsRuleInItsZone() {
        let dto = node(type: .recurring, recurrence: RecurrenceDTO(frequency: "daily", interval: 1, startDate: "2026-10-18", until: nil, times: ["07:30"], weekDays: [], monthDay: nil))

        let decoded = NodeMapper.decode(dto, now: moment("2026-10-18", "12:00"))

        #expect(decoded.fields.repeatSchedule == .every(1, .days))
        #expect(decoded.fields.scheduledAt == moment("2026-10-18", "07:30"))
        #expect(decoded.fields.timeZone == moscow)
    }

    @Test func untiedOnceOccurrenceMeansACompletedOneTimeNode() {
        var dto = node(type: .oneTime, date: "2026-10-18", time: "10:00")
        let completedAt = moment("2026-10-18", "10:05")
        dto.occurrences = [OccurrenceDTO(nodeId: dto.id, key: "once", title: "t", date: "2026-10-18", time: "10:00", state: "untied", completedAt: completedAt, isPast: false)]

        let decoded = NodeMapper.decode(dto, now: completedAt)

        #expect(decoded.status == .completed)
        #expect(decoded.completedAt == completedAt)
    }

    @Test func oneTimeWithoutADateIsUndated() {
        let decoded = NodeMapper.decode(node(type: .oneTime), now: Date())

        #expect(decoded.isUndated)
    }

    @Test func offlineKeyIsGenerationZeroOfTheLocalDate() {
        let key = NodeMapper.offlineOccurrenceKey(isRepeating: true, occurrence: moment("2026-10-18", "00:30"), timeZone: moscow)

        #expect(key == "g0-20261018-0")
        #expect(NodeMapper.offlineOccurrenceKey(isRepeating: false, occurrence: Date(), timeZone: moscow) == "once")
    }

    private func node(type: NodeType, date: String? = nil, time: String? = nil, recurrence: RecurrenceDTO? = nil) -> NodeDTO {
        NodeDTO(
            id: UUID(), type: type, ownerId: UUID(), title: "t", description: nil, timezone: "Europe/Moscow",
            date: date, time: time, scheduledAt: nil, recurrence: recurrence, trackYears: nil, version: 1,
            createdAt: Date(timeIntervalSince1970: 1_792_000_000), updatedAt: Date(timeIntervalSince1970: 1_792_000_000),
            members: nil, horizon: nil, occurrences: nil
        )
    }
}

private extension OccurrenceDTO {
    init(nodeId: UUID, key: String, title: String, date: String?, time: String?, state: String, completedAt: Date?, isPast: Bool) {
        self.init(nodeId: nodeId, key: key, revision: nil, title: title, description: nil, date: date, time: time,
                  scheduledAt: nil, years: nil, state: state, completedAt: completedAt, isPast: isPast)
    }
}
