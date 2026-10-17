import Foundation

enum NodeStatus: String, Codable {
    case active
    case completed
}

enum UntiedKnotsVisibility: String, Codable, CaseIterable, Identifiable {
    case hidden
    case untilEndOfDay
    case always

    var id: String { rawValue }
}

enum LeadTimeUnit: String, Codable, CaseIterable, Identifiable {
    case minutes
    case hours
    case days

    var id: String { rawValue }

    /// A correctly declined, lowercase unit word for a given amount
    /// ("1 минута" / "2 минуты" / "5 минут") — a fixed plural string
    /// can't cover this in Russian, so it's computed rather than pulled
    /// from Localizable.strings.
    func localizedLabel(for amount: Int, language: AppLanguage) -> String {
        guard language == .ru else {
            switch self {
            case .minutes: return amount == 1 ? "minute" : "minutes"
            case .hours: return amount == 1 ? "hour" : "hours"
            case .days: return amount == 1 ? "day" : "days"
            }
        }

        // Accusative, since this always reads as "Напомнить за ..." — only
        // the singular minute form actually differs from nominative
        // ("минуту" vs "минута"); hour and day are masculine inanimate, so
        // their accusative is identical to nominative.
        let forms: (one: String, few: String, many: String)
        switch self {
        case .minutes: forms = ("минуту", "минуты", "минут")
        case .hours: forms = ("час", "часа", "часов")
        case .days: forms = ("день", "дня", "дней")
        }

        let mod100 = amount % 100
        if (11...14).contains(mod100) {
            return forms.many
        }
        switch amount % 10 {
        case 1: return forms.one
        case 2, 3, 4: return forms.few
        default: return forms.many
        }
    }
}

/// A single "remind me before" entry — one universal building block used
/// for every knot, whether it needs exactly one reminder (a task) or
/// several at once (a yearly anniversary's 7-days/1-day/at-the-moment
/// set). `amount == 0` always means "at the moment", regardless of unit.
struct ReminderLeadTime: Codable, Hashable, Identifiable {
    var amount: Int
    var unit: LeadTimeUnit

    var id: String { rawToken }

    var isAtTime: Bool { amount == 0 }

    static let atTime = ReminderLeadTime(amount: 0, unit: .minutes)

    private var interval: TimeInterval {
        guard amount > 0 else { return 0 }
        switch unit {
        case .minutes: return TimeInterval(amount) * 60
        case .hours: return TimeInterval(amount) * 60 * 60
        case .days: return TimeInterval(amount) * 24 * 60 * 60
        }
    }

    func fireDate(before date: Date) -> Date {
        date.addingTimeInterval(-interval)
    }

    /// Serialized as "0" for "at the moment", or "<amount><unit-letter>"
    /// (e.g. "15m", "1h", "7d") — compact enough to store as a single
    /// comma-joined string on `ReminderNode`, same as the old raw enums.
    var rawToken: String {
        guard amount > 0 else { return "0" }
        let letter: String
        switch unit {
        case .minutes: letter = "m"
        case .hours: letter = "h"
        case .days: letter = "d"
        }
        return "\(amount)\(letter)"
    }

    init(amount: Int, unit: LeadTimeUnit) {
        self.amount = amount
        self.unit = unit
    }

    init?(rawToken: String) {
        if rawToken == "0" {
            self = .atTime
            return
        }
        guard let letter = rawToken.last,
              let amount = Int(rawToken.dropLast()),
              amount > 0 else { return nil }
        switch letter {
        case "m": unit = .minutes
        case "h": unit = .hours
        case "d": unit = .days
        default: return nil
        }
        self.amount = amount
    }
}

enum RepeatIntervalUnit: String, Codable, CaseIterable, Identifiable {
    case days
    case weeks
    case months
    case years

    var id: String { rawValue }

    /// Nominative, lowercase, correctly declined for the amount — used
    /// both as the wheel's own label and inside `RepeatSchedule`'s
    /// display phrase ("каждые 3 дня").
    func localizedLabel(for amount: Int, language: AppLanguage) -> String {
        guard language == .ru else {
            switch self {
            case .days: return amount == 1 ? "day" : "days"
            case .weeks: return amount == 1 ? "week" : "weeks"
            case .months: return amount == 1 ? "month" : "months"
            case .years: return amount == 1 ? "year" : "years"
            }
        }

        let forms: (one: String, few: String, many: String)
        switch self {
        case .days: forms = ("день", "дня", "дней")
        case .weeks: forms = ("неделя", "недели", "недель")
        case .months: forms = ("месяц", "месяца", "месяцев")
        case .years: forms = ("год", "года", "лет")
        }

        let mod100 = amount % 100
        if (11...14).contains(mod100) {
            return forms.many
        }
        switch amount % 10 {
        case 1: return forms.one
        case 2, 3, 4: return forms.few
        default: return forms.many
        }
    }
}

enum RepeatKind: String, Codable {
    case none
    case weekdays
    case interval
}

/// How a knot repeats — generalized to "every N days/weeks/months/years"
/// instead of a fixed Daily/Weekly/Monthly/Yearly set, plus the two cases
/// that don't fit that shape at all: never, and "weekdays" (a day-type
/// filter, not a counted interval). `amount`/`unit` are meaningless
/// outside `.interval` and ignored by equality/hashing then, so `.none`
/// and `.weekdays` compare equal regardless of whatever placeholder
/// values they were constructed with.
struct RepeatSchedule: Codable, Hashable {
    var kind: RepeatKind
    var amount: Int
    var unit: RepeatIntervalUnit

    static let none = RepeatSchedule(kind: .none, amount: 1, unit: .days)
    static let weekdays = RepeatSchedule(kind: .weekdays, amount: 1, unit: .days)

    static func every(_ amount: Int, _ unit: RepeatIntervalUnit) -> RepeatSchedule {
        RepeatSchedule(kind: .interval, amount: amount, unit: unit)
    }

    var isRepeating: Bool { kind != .none }

    /// Kept for calendar calculations such as leap-day handling. Visually
    /// and behaviorally, yearly schedules are ordinary recurring knots.
    var isYearly: Bool { kind == .interval && unit == .years }

    init(kind: RepeatKind, amount: Int, unit: RepeatIntervalUnit) {
        self.kind = kind
        self.amount = amount
        self.unit = unit
    }

    static func == (lhs: RepeatSchedule, rhs: RepeatSchedule) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        guard lhs.kind == .interval else { return true }
        return lhs.amount == rhs.amount && lhs.unit == rhs.unit
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        if kind == .interval {
            hasher.combine(amount)
            hasher.combine(unit)
        }
    }

    /// A human-readable summary ("Каждый день" / "Каждые 3 дня" / "По
    /// будням" / "Без повтора") — used as the knot's "kind" wherever it's
    /// shown (the detail sheet's Repeat row, the thread's accessibility
    /// label).
    func displayLabel(language: AppLanguage) -> String {
        switch kind {
        case .none:
            return language.localizedString("No repeat")
        case .weekdays:
            return language.localizedString("Weekdays")
        case .interval:
            return Self.intervalPhrase(amount: amount, unit: unit, language: language)
        }
    }

    private static func intervalPhrase(amount: Int, unit: RepeatIntervalUnit, language: AppLanguage) -> String {
        guard language == .ru else {
            return amount == 1 ? "Every \(unit.localizedLabel(for: 1, language: language))" : "Every \(amount) \(unit.localizedLabel(for: amount, language: language))"
        }

        if amount == 1 {
            switch unit {
            case .days: return "Каждый день"
            case .weeks: return "Каждую неделю"
            case .months: return "Каждый месяц"
            case .years: return "Каждый год"
            }
        }
        return "Каждые \(amount) \(unit.localizedLabel(for: amount, language: language))"
    }

    /// Serialized as "none", "weekdays", or "<amount><unit-letter>"
    /// ("3d", "2w", "6mo", "1y") — months gets a two-letter suffix so it
    /// can't collide with minutes-style single-letter tokens elsewhere.
    var rawToken: String {
        switch kind {
        case .none: return "none"
        case .weekdays: return "weekdays"
        case .interval:
            let letter: String
            switch unit {
            case .days: letter = "d"
            case .weeks: letter = "w"
            case .months: letter = "mo"
            case .years: letter = "y"
            }
            return "\(amount)\(letter)"
        }
    }

    init?(rawToken: String) {
        switch rawToken {
        case "none":
            self = .none
            return
        case "weekdays":
            self = .weekdays
            return
        default:
            break
        }

        if rawToken.hasSuffix("mo"), let amount = Int(rawToken.dropLast(2)), amount > 0 {
            self = .every(amount, .months)
            return
        }
        guard let letter = rawToken.last, let amount = Int(rawToken.dropLast()), amount > 0 else { return nil }
        switch letter {
        case "d": self = .every(amount, .days)
        case "w": self = .every(amount, .weeks)
        case "y": self = .every(amount, .years)
        default: return nil
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case ru
    case en

    var id: String { rawValue }

    static let defaultValue: AppLanguage = .ru

    var locale: Locale { Locale(identifier: rawValue) }

    func localizedString(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    init(locale: Locale) {
        if let languageCode = locale.language.languageCode?.identifier,
           let language = AppLanguage(rawValue: languageCode) {
            self = language
        } else if let language = AppLanguage(rawValue: locale.identifier) {
            self = language
        } else {
            self = .defaultValue
        }
    }
}

/// A common relative-time choice used wherever a knot can be scheduled or
/// moved. Keeping these presets here prevents creation and retie flows from
/// drifting apart.
struct ReminderQuickOffset: Identifiable, Hashable {
    let seconds: TimeInterval
    let localizationKey: String

    var id: TimeInterval { seconds }

    func label(language: AppLanguage) -> String {
        language.localizedString(localizationKey)
    }

    static let standard: [ReminderQuickOffset] = [
        .init(seconds: 15 * 60, localizationKey: "In 15 minutes"),
        .init(seconds: 30 * 60, localizationKey: "In 30 minutes"),
        .init(seconds: 60 * 60, localizationKey: "In 1 hour"),
        .init(seconds: 2 * 60 * 60, localizationKey: "In 2 hours"),
        .init(seconds: 24 * 60 * 60, localizationKey: "In 1 day")
    ]
}

enum ReminderError: LocalizedError {
    case emptyTitle
    case invalidDate
    case noOccurrenceToday
    case persistenceFailed

    var errorDescription: String? {
        message(language: .defaultValue)
    }

    func message(language: AppLanguage) -> String {
        switch self {
        case .emptyTitle:
            language.localizedString("Title cannot be empty.")
        case .invalidDate:
            language.localizedString("Choose a future date and time.")
        case .noOccurrenceToday:
            language.localizedString("This recurring knot has no occurrence today.")
        case .persistenceFailed:
            language.localizedString("Could not tie the knot.")
        }
    }
}
