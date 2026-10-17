import Foundation

/// One source of truth for the common relative and time-of-day shortcuts.
/// The settings are deliberately expressed as minutes from midnight: "morning"
/// stays morning when the calendar date or time zone changes.
struct ReminderQuickPreset: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case minutes15, minutes30, hour1, hours2
        case todayMorning, todayEvening, tomorrowMorning, tomorrowEvening, mondayMorning
    }

    let kind: Kind
    let date: Date

    var id: Kind { kind }

    func label(language: AppLanguage) -> String {
        switch kind {
        case .minutes15: return language.localizedString("In 15 minutes")
        case .minutes30: return language.localizedString("In 30 minutes")
        case .hour1: return language.localizedString("In 1 hour")
        case .hours2: return language.localizedString("In 2 hours")
        case .todayMorning: return timeOfDayLabel("Today morning", language: language)
        case .todayEvening: return timeOfDayLabel("Today evening", language: language)
        case .tomorrowMorning: return timeOfDayLabel("Tomorrow morning", language: language)
        case .tomorrowEvening: return timeOfDayLabel("Tomorrow evening", language: language)
        case .mondayMorning: return timeOfDayLabel("Monday morning", language: language)
        }
    }

    static func all(now: Date = .now, settings: SettingsSnapshot, calendar: Calendar = .current) -> [Self] {
        let relative: [Self] = [
            .init(kind: .minutes15, date: now.addingTimeInterval(15 * 60).roundedToNearest5Minutes()),
            .init(kind: .minutes30, date: now.addingTimeInterval(30 * 60).roundedToNearest5Minutes()),
            .init(kind: .hour1, date: now.addingTimeInterval(60 * 60).roundedToNearest5Minutes()),
            .init(kind: .hours2, date: now.addingTimeInterval(2 * 60 * 60).roundedToNearest5Minutes())
        ]
        let minimum = now.addingTimeInterval(5 * 60)
        let todayMorning = date(on: now, minutes: settings.morningMinutes, calendar: calendar)
        let todayEvening = date(on: now, minutes: settings.eveningMinutes, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowMorning = date(on: tomorrow, minutes: settings.morningMinutes, calendar: calendar)
        let tomorrowEvening = date(on: tomorrow, minutes: settings.eveningMinutes, calendar: calendar)

        var contextual: [Self]
        if todayMorning > minimum {
            contextual = [.init(kind: .todayMorning, date: todayMorning), .init(kind: .todayEvening, date: todayEvening)]
        } else if todayEvening > minimum {
            contextual = [.init(kind: .todayEvening, date: todayEvening), .init(kind: .tomorrowMorning, date: tomorrowMorning)]
        } else {
            contextual = [.init(kind: .tomorrowMorning, date: tomorrowMorning), .init(kind: .tomorrowEvening, date: tomorrowEvening)]
        }

        // Friday has one extra useful horizon: Monday's first working-morning.
        if calendar.component(.weekday, from: now) == 6,
           let monday = calendar.date(byAdding: .day, value: 3, to: now) {
            contextual.append(.init(kind: .mondayMorning, date: date(on: monday, minutes: settings.morningMinutes, calendar: calendar)))
        }
        return relative + contextual.filter { $0.date > minimum }
    }

    static func notificationActions(now: Date = .now, settings: SettingsSnapshot, calendar: Calendar = .current) -> [Self] {
        // iOS presents at most four actions. Reserve one for completing the
        // knot, keep the most useful immediate delay, and use the remaining
        // space for the two context-aware moments rather than duplicating the
        // entire relative-time row.
        let presets = all(now: now, settings: settings, calendar: calendar)
        let immediate = presets.first(where: { $0.kind == .minutes15 })
        let contextual = presets.filter {
            switch $0.kind {
            case .minutes15, .minutes30, .hour1, .hours2: false
            default: true
            }
        }
        return [immediate].compactMap { $0 } + Array(contextual.prefix(2))
    }

    private static func date(on base: Date, minutes: Int, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: base)
        return calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
    }

    private func timeOfDayLabel(_ key: String, language: AppLanguage) -> String {
        let time = date.formatted(.dateTime.hour().minute().locale(language.locale))
        return "\(language.localizedString(key)) · \(time)"
    }
}
