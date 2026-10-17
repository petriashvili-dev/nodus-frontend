import Foundation

struct TimelineService {
    private let repeatEngine: RepeatEngine
    private let calendar: Calendar

    init(repeatEngine: RepeatEngine = RepeatEngine(), calendar: Calendar = .current) {
        self.repeatEngine = repeatEngine
        self.calendar = calendar
    }

    func buildTimeline(
        nodes: [ReminderNode],
        states: [ReminderOccurrenceState],
        overrides: [ReminderOccurrenceOverride],
        settings: SettingsSnapshot,
        now: Date = Date()
    ) -> [TimelineSectionModel] {
        let dayStart = calendar.startOfDay(for: now)
        // Lost knots only ever stay on the thread through the end of the
        // day after they were due, so one-off occurrences never need to be
        // generated further back than that plus a small safety margin.
        let pastStart = calendar.date(byAdding: .day, value: -3, to: now) ?? now

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: stored data
        // predating the repository's upsert fix may still contain duplicate
        // rows for the same occurrence, and a crash on every launch is worse
        // than silently preferring one of them.
        let stateByOccurrence = Dictionary(states.map { (occurrenceKey($0.reminderId, $0.occurrenceDate), $0) }, uniquingKeysWith: { _, latest in latest })
        let overridesByOccurrence = Dictionary(overrides.map { (occurrenceKey($0.reminderId, $0.originalOccurrenceDate), $0) }, uniquingKeysWith: { _, latest in latest })

        var items = nodes.flatMap { node -> [TimelineItem] in
            let occurrenceDates = occurrenceDates(for: node, pastStart: pastStart, now: now)

            let nodeItems = occurrenceDates.compactMap { occurrenceDate -> TimelineItem? in
                let override = overridesByOccurrence[occurrenceKey(node.id, occurrenceDate)]
                guard override?.isDeleted != true else { return nil }

                let displayDate = override?.overriddenScheduledAt ?? occurrenceDate
                let state = stateByOccurrence[occurrenceKey(node.id, occurrenceDate)]
                let status = state?.status ?? node.status
                let isLost = status == .active && displayDate < now

                // A pause applies to the effective date, so an individually
                // retied occurrence is also skipped if it lands during the
                // pause window. The first occurrence at `pausedUntil` or
                // later resumes automatically.
                if node.isRepeating, let pausedUntil = node.pausedUntil, displayDate < pausedUntil {
                    return nil
                }

                guard shouldShow(status: status, scheduledAt: displayDate, settings: settings, now: now) else {
                    return nil
                }

                guard !isLost || isWithinLostWindow(displayDate, now: now) else {
                    return nil
                }

                return TimelineItem(
                    id: "\(node.id.uuidString)-\(Int(occurrenceDate.timeIntervalSince1970))",
                    nodeId: node.id,
                    occurrenceDate: node.isRepeating ? occurrenceDate : nil,
                    title: node.title,
                    note: node.note,
                    kind: node.repeatSchedule.displayLabel(language: settings.language),
                    repeatSchedule: node.repeatSchedule,
                    originDate: node.originDate,
                    scheduledAt: displayDate,
                    status: status,
                    isNow: false,
                    isLost: isLost,
                    isQuiet: false,
                    tintHex: tint(for: node.repeatSchedule, isLost: isLost, isCompleted: status == .completed)
                )
            }

            guard node.isRepeating else {
                return nodeItems
            }

            // A repeating knot shows its two nearest future occurrences,
            // plus any visible completed occurrence and the most recent
            // overdue one. This gives the user one step of look-ahead while
            // keeping the thread compact.
            let mostRecentLost = nodeItems.filter(\.isLost).last
            let completedOccurrences = nodeItems.filter(\.isCompleted)
            let nextUpcoming = nodeItems
                .filter { !$0.isCompleted && !$0.isLost && $0.scheduledAt >= now }
                .prefix(2)
            return [mostRecentLost].compactMap { $0 } + completedOccurrences + nextUpcoming
        }

        items.append(nowItem(now, language: settings.language))
        items.sort { $0.scheduledAt < $1.scheduledAt }

        return Dictionary(grouping: items) { item in
            sectionId(for: item.scheduledAt, now: now)
        }
            .map { key, groupedItems in
                let sortedItems = groupedItems.sorted { $0.scheduledAt < $1.scheduledAt }
                let kind = sectionKind(for: sortedItems[0].scheduledAt, now: now)
                return TimelineSectionModel(id: key, kind: kind, title: title(for: kind, date: sortedItems[0].scheduledAt, now: now, language: settings.language), items: sortedItems)
            }
            .sorted { first, second in
                guard let left = first.items.first?.scheduledAt, let right = second.items.first?.scheduledAt else { return false }
                return left < right
            }
    }

    func lostItems(in sections: [TimelineSectionModel]) -> [TimelineItem] {
        sections.flatMap(\.items).filter(\.isLost).prefix(3).map { $0 }
    }

    /// All repeating schedules use the same occurrence window. Their rows
    /// are narrowed down to the nearest upcoming occurrence and, when
    /// applicable, the latest overdue one in `buildTimeline`.
    private func occurrenceDates(
        for node: ReminderNode,
        pastStart: Date,
        now: Date
    ) -> [Date] {
        repeatEngine.nearestOccurrences(for: node, from: pastStart, now: now)
    }

    /// A lost knot stays on the thread through the rest of the day it was
    /// due plus the whole next day, then disappears at midnight after
    /// that — it doesn't linger indefinitely.
    private func isWithinLostWindow(_ scheduledAt: Date, now: Date) -> Bool {
        guard let cutoff = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: scheduledAt)) else {
            return true
        }
        return now < cutoff
    }

    private func shouldShow(status: NodeStatus, scheduledAt: Date, settings: SettingsSnapshot, now: Date) -> Bool {
        guard status == .completed else { return true }

        switch settings.untiedKnotsVisibility {
        case .hidden:
            return false
        case .untilEndOfDay:
            return calendar.isDate(scheduledAt, inSameDayAs: now)
        case .always:
            return true
        }
    }

    private func nowItem(_ now: Date, language: AppLanguage) -> TimelineItem {
        TimelineItem(
            id: "now",
            nodeId: UUID(),
            occurrenceDate: nil,
            title: nil,
            note: nil,
            kind: language.localizedString("present moment"),
            repeatSchedule: .none,
            originDate: nil,
            scheduledAt: now,
            status: .active,
            isNow: true,
            isLost: false,
            isQuiet: true,
            tintHex: 0xC9A46A
        )
    }

    private func tint(for schedule: RepeatSchedule, isLost: Bool, isCompleted: Bool) -> UInt32 {
        if isLost { return 0xA78368 }
        // Untied knots read the same regardless of repeat schedule — a
        // quiet, pale green rather than the schedule's own color, so
        // "done" stands out as its own state instead of just a dimmed
        // color.
        if isCompleted { return 0x8FAE93 }
        switch schedule.kind {
        case .none:
            return 0x94A3B8
        case .weekdays, .interval:
            return 0x8EA37D
        }
    }

    /// Every calendar day gets its own bucket — items are sparse (at most
    /// a couple per knot now that repeating knots only ever surface their
    /// nearest occurrence), so there's no need to collapse distant dates
    /// into a shared month/year bucket; doing so previously merged e.g. a
    /// knot on the 13th and another on the 29th of the same month into one
    /// section titled after whichever happened to sort first.
    private func sectionId(for date: Date, now: Date) -> String {
        switch sectionKind(for: date, now: now) {
        case .yesterday:
            return "yesterday"
        case .today:
            return "today"
        case .tomorrow:
            return "tomorrow"
        case .date:
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return "date-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        }
    }

    private func sectionKind(for date: Date, now: Date) -> TimelineSectionKind {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), calendar.isDate(date, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .date(calendar.startOfDay(for: date))
    }

    /// Every non-today/tomorrow header reads as "day Month, weekday" — and
    /// once the year no longer matches the current one, the year is appended too.
    private func title(for kind: TimelineSectionKind, date: Date, now: Date, language: AppLanguage) -> String {
        switch kind {
        case .yesterday:
            return language.localizedString("Yesterday")
        case .today:
            return language.localizedString("Today")
        case .tomorrow:
            return language.localizedString("Tomorrow")
        case .date:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let dayMonth = sameYear
                ? date.formatted(.dateTime.day().month(.wide).locale(language.locale))
                : date.formatted(.dateTime.day().month(.wide).year().locale(language.locale))
            let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(language.locale))
                .lowercased(with: language.locale)
            return "\(dayMonth), \(weekday)"
        }
    }

    private func occurrenceKey(_ reminderId: UUID, _ date: Date) -> String {
        "\(reminderId.uuidString)-\(Int(date.timeIntervalSince1970))"
    }
}
