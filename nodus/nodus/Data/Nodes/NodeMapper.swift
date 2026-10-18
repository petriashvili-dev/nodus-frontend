import Foundation

/// Translates between the app's knot (`ReminderNode`: one moment plus a
/// `RepeatSchedule`) and the server template (type, local date and time in
/// an IANA zone, `Recurrence`).
///
/// | App | Server |
/// |---|---|
/// | no repeat | `one_time` with `date` + `time` |
/// | weekdays | `recurring` weekly, Monday–Friday |
/// | every N days | `recurring` daily, `interval` N |
/// | every N weeks | `recurring` weekly on the weekday of the start |
/// | every N months | `recurring` monthly on the day of the start |
/// | every year with an origin date | `anniversary` (`date` = origin, `track_years`) |
/// | every N years | `recurring` yearly |
nonisolated enum NodeMapper {
    struct Template: Equatable, Sendable {
        var type: NodeType
        var title: String
        var description: String?
        var timezone: String
        var date: String?
        var time: String?
        var recurrence: RecurrenceDTO?
        var trackYears: Bool?
    }

    /// The fields of a node as the app stores them.
    struct LocalFields: Equatable, Sendable {
        var title: String
        var note: String?
        var scheduledAt: Date
        var originDate: Date?
        var repeatSchedule: RepeatSchedule
        var timeZone: TimeZone
    }

    // MARK: App → server

    static func template(for fields: LocalFields) -> Template {
        let calendar = Self.calendar(in: fields.timeZone)
        let date = LocalDate.string(from: fields.scheduledAt, calendar: calendar)
        let time = LocalTime.string(from: fields.scheduledAt, calendar: calendar)
        var template = Template(
            type: .oneTime,
            title: fields.title,
            description: fields.note,
            timezone: fields.timeZone.identifier,
            date: date,
            time: time
        )

        let schedule = fields.repeatSchedule
        switch schedule.kind {
        case .none:
            return template
        case .weekdays:
            template.recurrence = recurrence("weekly", 1, start: date, time: time,
                                             weekDays: ["monday", "tuesday", "wednesday", "thursday", "friday"])
        case .interval:
            let amount = max(schedule.amount, 1)
            switch schedule.unit {
            case .days:
                template.recurrence = recurrence("daily", amount, start: date, time: time)
            case .weeks:
                let weekday = weekdayName(calendar.component(.weekday, from: fields.scheduledAt))
                template.recurrence = recurrence("weekly", amount, start: date, time: time, weekDays: [weekday])
            case .months:
                template.recurrence = recurrence("monthly", amount, start: date, time: time,
                                                 monthDay: calendar.component(.day, from: fields.scheduledAt))
            case .years:
                if amount == 1, let origin = fields.originDate {
                    template.type = .anniversary
                    template.date = LocalDate.string(from: origin, calendar: calendar)
                    template.trackYears = true
                    return template
                }
                template.recurrence = recurrence("yearly", amount, start: date, time: time)
            }
        }
        template.type = .recurring
        template.date = nil
        template.time = nil
        return template
    }

    static func createBody(id: UUID, fields: LocalFields) -> CreateNodeBody {
        let template = template(for: fields)
        return CreateNodeBody(
            id: id,
            type: template.type,
            title: template.title,
            description: template.description,
            timezone: template.timezone,
            date: template.date,
            time: template.time,
            recurrence: template.recurrence,
            trackYears: template.trackYears
        )
    }

    static func updateBody(fields: LocalFields) -> UpdateNodeBody {
        let template = template(for: fields)
        return UpdateNodeBody(
            expectedVersion: nil,
            title: template.title,
            description: template.description,
            timezone: template.timezone,
            date: template.date,
            time: template.time,
            recurrence: template.recurrence,
            trackYears: template.trackYears
        )
    }

    // MARK: Server → app

    struct Decoded: Equatable, Sendable {
        var fields: LocalFields
        var isUndated: Bool
        var status: NodeStatus
        var completedAt: Date?
    }

    /// The app's view of a server node. `now` picks the moment of a series
    /// the editor shows: the start of the rule, or the next anniversary.
    static func decode(_ dto: NodeDTO, now: Date) -> Decoded {
        let zone = TimeZone(identifier: dto.timezone) ?? .current
        let calendar = Self.calendar(in: zone)
        var fields = LocalFields(
            title: dto.title,
            note: dto.description,
            scheduledAt: dto.scheduledAt ?? dto.createdAt,
            originDate: nil,
            repeatSchedule: .none,
            timeZone: zone
        )
        var isUndated = false
        var status = NodeStatus.active
        var completedAt: Date?

        switch dto.type {
        case .oneTime:
            if let date = dto.date {
                fields.scheduledAt = dto.scheduledAt
                    ?? moment(date: date, time: dto.time ?? "09:00", calendar: calendar)
                    ?? dto.createdAt
            } else {
                isUndated = true
            }
            if let once = dto.occurrences?.first(where: { $0.key == "once" }), once.state == "untied" {
                status = .completed
                completedAt = once.completedAt
            }
        case .recurring:
            guard let rule = dto.recurrence else { break }
            fields.repeatSchedule = schedule(for: rule)
            fields.scheduledAt = moment(date: rule.startDate, time: rule.times.first ?? "09:00", calendar: calendar)
                ?? fields.scheduledAt
        case .anniversary:
            fields.repeatSchedule = .every(1, .years)
            let time = dto.time ?? "09:00"
            if let date = dto.date {
                fields.originDate = moment(date: date, time: time, calendar: calendar)
            }
            fields.scheduledAt = dto.occurrences?
                .compactMap(\.scheduledAt)
                .filter { $0 >= now }
                .min()
                ?? nextAnniversary(origin: fields.originDate, after: now, calendar: calendar)
                ?? fields.scheduledAt
        }
        return Decoded(fields: fields, isUndated: isUndated, status: status, completedAt: completedAt)
    }

    static func schedule(for rule: RecurrenceDTO) -> RepeatSchedule {
        let amount = max(rule.interval, 1)
        switch rule.frequency {
        case "daily":
            return .every(amount, .days)
        case "weekly":
            let weekdays: Set = ["monday", "tuesday", "wednesday", "thursday", "friday"]
            if amount == 1, Set(rule.weekDays) == weekdays { return .weekdays }
            return .every(amount, .weeks)
        case "monthly":
            return .every(amount, .months)
        case "yearly":
            return .every(amount, .years)
        default:
            return .every(amount, .days)
        }
    }

    // MARK: Occurrence keys

    /// The key of the nearest occurrence of a node the server has never
    /// seen: generation 0, slot 0 (one time per rule in this app), `once`
    /// for a one-time node. After sync the server's keys take over.
    static func offlineOccurrenceKey(isRepeating: Bool, occurrence: Date, timeZone: TimeZone) -> String {
        guard isRepeating else { return "once" }
        let compact = LocalDate.string(from: occurrence, calendar: calendar(in: timeZone))
            .replacingOccurrences(of: "-", with: "")
        return "g0-\(compact)-0"
    }

    // MARK: Helpers

    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func moment(date: String, time: String, calendar: Calendar) -> Date? {
        guard let day = LocalDate.components(from: date), let clock = LocalTime.components(from: time) else {
            return nil
        }
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = clock.hour
        components.minute = clock.minute
        return calendar.date(from: components)
    }

    private static func nextAnniversary(origin: Date?, after now: Date, calendar: Calendar) -> Date? {
        guard let origin else { return nil }
        var components = calendar.dateComponents([.month, .day, .hour, .minute], from: origin)
        let year = calendar.component(.year, from: now)
        for candidateYear in [year, year + 1] {
            components.year = candidateYear
            var day = components
            if day.month == 2 && day.day == 29 && calendar.date(from: day).map({ calendar.component(.day, from: $0) }) != 29 {
                day.day = 28
            }
            if let date = calendar.date(from: day), date >= now { return date }
        }
        return nil
    }

    private static func recurrence(
        _ frequency: String,
        _ interval: Int,
        start: String,
        time: String,
        weekDays: [String] = [],
        monthDay: Int? = nil
    ) -> RecurrenceDTO {
        RecurrenceDTO(
            frequency: frequency,
            interval: interval,
            startDate: start,
            until: nil,
            times: [time],
            weekDays: weekDays,
            monthDay: monthDay
        )
    }

    private static func weekdayName(_ weekday: Int) -> String {
        ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][(weekday - 1 + 7) % 7]
    }
}

/// Local calendar date `yyyy-MM-dd`.
nonisolated enum LocalDate {
    static func string(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func components(from string: String) -> (year: Int, month: Int, day: Int)? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

/// Local time `HH:mm`, 24 hours.
nonisolated enum LocalTime {
    static func string(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func components(from string: String) -> (hour: Int, minute: Int)? {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }
}
