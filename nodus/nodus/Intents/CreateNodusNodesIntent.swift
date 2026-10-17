import AppIntents
import Foundation
import os

enum SiriTimePeriod: String, AppEnum {
    case morning
    case evening

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Время суток"

    static var caseDisplayRepresentations: [SiriTimePeriod: DisplayRepresentation] = [
        .morning: "Утра",
        .evening: "Вечера"
    ]

}

/// Runs without opening the app so Siri can create knots from the Lock Screen.
/// The system performs speech-to-text; this intent only receives the text.
struct CreateNodusNodesIntent: AppIntent {
    private static let logger = Logger(subsystem: "app.nodus", category: "Siri")
    static var title: LocalizedStringResource = "Завязать узлы Nodus"
    static var description = IntentDescription("Завязывает один или несколько узлов Nodus из продиктованного текста.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Текст", requestValueDialog: "Что нужно завязать в Nodus?")
    var text: String

    /// Siri resolves this only when the parsed text lacks a date or time.
    @Parameter(title: "Дата и время")
    var scheduledAt: Date?

    /// Requested only for phrases such as "завтра в 9", where the hour is
    /// known but the half of the day is not.
    @Parameter(title: "Время суток")
    var timePeriod: SiriTimePeriod?

    static var parameterSummary: some ParameterSummary {
        Summary("Завязать узлы из \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = NodeParsingContext(
            timeZone: .current,
            locale: Locale(identifier: "ru_RU")
        )
        var result: NodeParseResult
        do {
            result = try await DirectNeuroAPIParser().parse(text, context: context)
        } catch {
            Self.logger.error("NeuroAPI parsing failed: \(error.localizedDescription, privacy: .public)")
            return .result(dialog: "Nodus не получил ответ от NeuroAPI. Проверьте ключ TestFlight и подключение к интернету.")
        }
        guard !result.nodes.isEmpty else {
            throw NodeParsingError.invalidResponse
        }

        let now = Date()
        var nodesNeedingDate = result.nodes.filter { node in
            guard let scheduledAt = node.scheduledAt else { return true }
            return scheduledAt <= now
        }

        // The parser deliberately leaves an ambiguous hour unresolved. Give
        // Siri a narrow, natural choice instead of making the user repeat the
        // entire date and time. This is resolved locally: a Siri follow-up
        // must never trigger another AI request.
        var ambiguousTimeDate: Date?
        if !nodesNeedingDate.isEmpty, let hour = Self.ambiguousHour(in: text) {
            let period = try await $timePeriod.requestValue(
                "Вы имели в виду \(hour) утра или \(hour) вечера?"
            )
            ambiguousTimeDate = Self.date(
                for: text,
                hour: hour,
                period: period,
                now: now,
                calendar: .current
            )
            if ambiguousTimeDate != nil {
                nodesNeedingDate = []
            }
        }

        let missingDateCount = nodesNeedingDate.count
        let suppliedDate: Date?
        if missingDateCount > 0 {
            let fallbackQuestion: IntentDialog
            if missingDateCount == 1, let node = nodesNeedingDate.first {
                fallbackQuestion = "Когда напомнить о «\(node.title)»?"
            } else {
                fallbackQuestion = "Когда напомнить об этих \(missingDateCount) узлах?"
            }
            suppliedDate = try await $scheduledAt.requestValue(fallbackQuestion)

            guard let suppliedDate, suppliedDate > Date() else {
                throw $scheduledAt.needsValueError("Укажите будущую дату и время.")
            }
        } else {
            suppliedDate = nil
        }

        let nodes = result.nodes.map {
            ParsedNode(
                title: $0.title,
                note: $0.note,
                scheduledAt: ($0.scheduledAt ?? .distantPast) > now
                    ? $0.scheduledAt
                    : ambiguousTimeDate ?? suppliedDate,
                repeatSchedule: $0.repeatSchedule
            )
        }

        do {
            try await VoiceNodeCreationService.save(nodes)
        } catch {
            Self.logger.error("Siri node save failed: \(error.localizedDescription, privacy: .public)")
            return .result(dialog: "Не удалось сохранить узел. Разблокируйте устройство и попробуйте ещё раз.")
        }

        let count = nodes.count
        let lastTwoDigits = count % 100
        let lastDigit = count % 10
        let dialogSuffix: String
        if (11...14).contains(lastTwoDigits) {
            dialogSuffix = "узлов завязано"
        } else {
            switch lastDigit {
            case 1:
                dialogSuffix = "узел завязан"
            case 2...4:
                dialogSuffix = "узла завязаны"
            default:
                dialogSuffix = "узлов завязано"
            }
        }

        return .result(dialog: "\(count) \(dialogSuffix).")
    }

    /// Returns a 12-hour clock value only when it is introduced as a time and
    /// has no AM/PM-style qualifier. Restricting this to 1...12 avoids
    /// mistaking an unambiguous 24-hour time (for example, "в 18") for a
    /// question about the period of day.
    private static func ambiguousHour(in text: String) -> Int? {
        let pattern = #"(?i)\b(?:в|at)\s*(0?[1-9]|1[0-2])(?:\s*(?:час(?:а|ов)?|ч))?(?!\s*(?::|утра|вечера|дня|ночи|am|pm|a\.m\.|p\.m\.))(?!\s+(?:января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let hourRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[hourRange])
    }

    /// Resolves only explicit relative-day words. Absolute dates and weekday
    /// names stay on the normal Date parameter path, whose resolver already
    /// handles them without sending the answer to the AI service.
    private static func date(
        for text: String,
        hour: Int,
        period: SiriTimePeriod,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let normalized = text.lowercased()
        let dayOffset: Int
        if normalized.contains("послезавтра") || normalized.contains("the day after tomorrow") {
            dayOffset = 2
        } else if normalized.contains("завтра") || normalized.contains("tomorrow") {
            dayOffset = 1
        } else if normalized.contains("сегодня") || normalized.contains("today") {
            dayOffset = 0
        } else {
            return nil
        }

        let calendarHour = hour == 12
            ? (period == .morning ? 0 : 12)
            : hour + (period == .evening ? 12 : 0)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
            return nil
        }
        guard let candidate = calendar.date(
            bySettingHour: calendarHour,
            minute: 0,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }
        return candidate > now ? candidate : nil
    }
}

struct NodusAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNodusNodesIntent(),
            phrases: [
                "Создай узел в \(.applicationName)",
                "Завяжи узел в \(.applicationName)",
                "Добавь узел в \(.applicationName)"
            ],
            shortTitle: "Завязать узел",
            systemImageName: "plus.circle"
        )
    }
}
