import Foundation

struct RepeatEngine {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Returns only the occurrences the timeline can render: recent overdue
    /// ones and the next two upcoming ones. The UI never displays a ten-year
    /// run, so materialising it made every reload grow with the age of a knot.
    func nearestOccurrences(for node: ReminderNode, from start: Date, now: Date) -> [Date] {
        guard node.isRepeating else {
            return [node.scheduledAt]
        }

        let schedule = node.repeatSchedule
        var dates: [Date] = []
        var current = firstOccurrence(for: node, schedule: schedule, notBefore: start)

        // At most a few dates sit in the lost window. Once the current date
        // reaches the future, retain it and its immediate successor, then
        // stop instead of materialising an unbounded schedule.
        var upcomingCount = 0
        while true {
            dates.append(current)
            if current > now {
                upcomingCount += 1
                if upcomingCount == 2 { return dates }
            }

            guard let next = nextOccurrence(after: current, original: node.scheduledAt, schedule: schedule) else {
                return dates
            }
            current = next
        }
    }

    /// Finds the occurrence that belongs to `date`'s calendar day. This is
    /// used only as a safe fallback for legacy actions that did not preserve
    /// an occurrence identity; it must never turn a repeating node into a
    /// globally completed one.
    func occurrence(for node: ReminderNode, on date: Date) -> Date? {
        guard node.isRepeating else { return nil }
        let dayStart = calendar.startOfDay(for: date)
        return nearestOccurrences(for: node, from: dayStart, now: dayStart)
            .first { calendar.isDate($0, inSameDayAs: date) }
    }

    private func firstOccurrence(for node: ReminderNode, schedule: RepeatSchedule, notBefore start: Date) -> Date {
        var current: Date
        switch schedule.kind {
        case .none:
            return node.scheduledAt
        case .weekdays:
            current = calendar.date(
                bySettingHour: calendar.component(.hour, from: node.scheduledAt),
                minute: calendar.component(.minute, from: node.scheduledAt),
                second: calendar.component(.second, from: node.scheduledAt),
                of: start
            ) ?? start
            if current < start {
                current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
            }
            while calendar.isDateInWeekend(current) {
                current = nextWeekdayOccurrence(after: current) ?? current
            }
        case .interval:
            let component: Calendar.Component
            switch schedule.unit {
            case .days: component = .day
            case .weeks: component = .weekOfYear
            case .months: component = .month
            case .years: component = .year
            }
            let elapsed = max(0, calendar.dateComponents([component], from: node.scheduledAt, to: start).value(for: component) ?? 0)
            let steps = elapsed / max(schedule.amount, 1)
            current = calendar.date(byAdding: component, value: steps * schedule.amount, to: node.scheduledAt) ?? node.scheduledAt
        }

        // A repeating rule never creates an occurrence before the knot was
        // originally tied. This matters for a weekday knot whose start date
        // is still in the future.
        if current < node.scheduledAt {
            current = node.scheduledAt
            if schedule.kind == .weekdays && calendar.isDateInWeekend(current) {
                current = nextWeekdayOccurrence(after: current) ?? current
            }
        }

        while current < start {
            guard let next = nextOccurrence(after: current, original: node.scheduledAt, schedule: schedule) else {
                return current
            }
            current = next
        }
        return current
    }

    private func nextOccurrence(after date: Date, original: Date, schedule: RepeatSchedule) -> Date? {
        switch schedule.kind {
        case .none:
            return nil
        case .weekdays:
            return nextWeekdayOccurrence(after: date)
        case .interval:
            switch schedule.unit {
            case .days:
                return calendar.date(byAdding: .day, value: schedule.amount, to: date)
            case .weeks:
                return calendar.date(byAdding: .weekOfYear, value: schedule.amount, to: date)
            case .months:
                return calendar.date(byAdding: .month, value: schedule.amount, to: date)
            case .years:
                return nextYearlyOccurrence(after: date, original: original, stepYears: schedule.amount)
            }
        }
    }

    private func nextWeekdayOccurrence(after date: Date) -> Date? {
        var next = date
        repeat {
            guard let candidate = calendar.date(byAdding: .day, value: 1, to: next) else { return nil }
            next = candidate
        } while calendar.isDateInWeekend(next)
        return next
    }

    private func nextYearlyOccurrence(after date: Date, original: Date, stepYears: Int) -> Date? {
        let nextYear = calendar.component(.year, from: date) + stepYears
        return adjustedYearlyDate(original, year: nextYear)
    }

    /// Feb 29 has no equivalent in a non-leap year — falls back to the
    /// 28th rather than skipping the year's occurrence entirely.
    private func adjustedYearlyDate(_ original: Date, year: Int) -> Date {
        var components = calendar.dateComponents([.month, .day, .hour, .minute], from: original)
        components.year = year
        if components.month == 2 && components.day == 29 && calendar.date(from: components) == nil {
            components.day = 28
        }
        return calendar.date(from: components) ?? original
    }
}
