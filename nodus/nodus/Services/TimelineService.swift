import Foundation

struct TimelineService {
    private let repeatEngine: RepeatEngine
    private let calendar: Calendar

    init(repeatEngine: RepeatEngine = RepeatEngine(), calendar: Calendar = .current) {
        self.repeatEngine = repeatEngine
        self.calendar = calendar
    }

    /// The thread. A node the server has confirmed shows exactly its
    /// occurrences from the last `GET /feed`; a node created or edited
    /// offline shows its nearest occurrence computed locally until the
    /// server has it (docs/03-outbox-and-sync.md).
    func buildTimeline(
        nodes: [ReminderNode],
        states: [ReminderOccurrenceState],
        overrides: [ReminderOccurrenceOverride],
        serverOccurrences: [ServerOccurrence] = [],
        locallyChangedNodeIds: Set<UUID> = [],
        settings: SettingsSnapshot,
        now: Date = Date()
    ) -> [TimelineSectionModel] {
        // Lost knots only ever stay on the thread through the end of the
        // day after they were due, so one-off occurrences never need to be
        // generated further back than that plus a small safety margin.
        let pastStart = calendar.date(byAdding: .day, value: -3, to: now) ?? now

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: stored data
        // predating the repository's upsert fix may still contain duplicate
        // rows for the same occurrence, and a crash on every launch is worse
        // than silently preferring one of them.
        let stateByOccurrence = Dictionary(states.map { (occurrenceKey($0.reminderId, $0.occurrenceDate), $0) }, uniquingKeysWith: { _, latest in latest })
        let stateByServerKey = Dictionary(states.compactMap { state in state.key.map { ("\(state.reminderId.uuidString):\($0)", state) } }, uniquingKeysWith: { _, latest in latest })
        let overridesByOccurrence = Dictionary(overrides.map { (occurrenceKey($0.reminderId, $0.originalOccurrenceDate), $0) }, uniquingKeysWith: { _, latest in latest })
        let feedByNode = Dictionary(grouping: serverOccurrences.filter(\.isInFeed), by: \.nodeId)

        var items = nodes.flatMap { node -> [TimelineItem] in
            // A "someday" node from another client has no moment to place.
            guard !node.isUndated else { return [] }

            func item(occurrenceDate: Date, title: String, note: String?, status: NodeStatus) -> TimelineItem? {
                let override = overridesByOccurrence[occurrenceKey(node.id, occurrenceDate)]
                guard override?.isDeleted != true else { return nil }

                let displayDate = override?.overriddenScheduledAt ?? occurrenceDate
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
                    title: title,
                    note: note,
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

            let feed = feedByNode[node.id] ?? []
            if node.serverVersion > 0, !locallyChangedNodeIds.contains(node.id), !feed.isEmpty {
                // The server already chose what to show (today plus the next
                // occurrence of a series); titles are as they were then.
                return feed.compactMap { occurrence in
                    let occurrenceDate = occurrence.scheduledAt ?? allDayMoment(occurrence, timeZone: node.timeZone)
                    guard let occurrenceDate else { return nil }
                    let status: NodeStatus
                    if !node.isRepeating {
                        status = node.status
                    } else if let overlay = stateByServerKey[occurrence.id] {
                        status = overlay.status
                    } else {
                        status = occurrence.isUntied ? .completed : .active
                    }
                    return item(occurrenceDate: occurrenceDate, title: occurrence.title, note: occurrence.note, status: status)
                }
            }

            let nodeItems = occurrenceDates(for: node, pastStart: pastStart, now: now).compactMap { occurrenceDate in
                let state = stateByOccurrence[occurrenceKey(node.id, occurrenceDate)]
                return item(occurrenceDate: occurrenceDate, title: node.title, note: node.note, status: state?.status ?? node.status)
            }

            guard node.isRepeating else {
                return nodeItems
            }

            // A repeating knot shows its nearest future occurrence (two
            // while the server feed has not arrived yet), plus any visible
            // completed occurrence and the most recent overdue one.
            let mostRecentLost = nodeItems.filter(\.isLost).last
            let completedOccurrences = nodeItems.filter(\.isCompleted)
            let nextUpcoming = nodeItems
                .filter { !$0.isCompleted && !$0.isLost && $0.scheduledAt >= now }
                .prefix(node.serverVersion == 0 ? 1 : 2)
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

    /// What to plan local notifications for: the server's occurrence window
    /// for confirmed nodes, the thread's own items for nodes changed
    /// offline. iOS keeps at most 64 pending requests and each occurrence
    /// can take several (lead times, nudges), so only the nearest ones are
    /// planned; the window slides on every sync and day change.
    func notificationPlan(
        timeline: [TimelineSectionModel],
        nodes: [ReminderNode],
        states: [ReminderOccurrenceState],
        overrides: [ReminderOccurrenceOverride],
        serverOccurrences: [ServerOccurrence],
        locallyChangedNodeIds: Set<UUID>,
        settings: SettingsSnapshot,
        now: Date = Date(),
        limit: Int = 12
    ) -> [TimelineItem] {
        let horizonByNode = Dictionary(grouping: serverOccurrences.filter(\.isInHorizon), by: \.nodeId)
        let completedKeys = Set(states.filter { $0.status == .completed }.compactMap { state in state.key.map { "\(state.reminderId.uuidString):\($0)" } })
        let hidden = Set(overrides.filter(\.isDeleted).map { occurrenceKey($0.reminderId, $0.originalOccurrenceDate) })
        let serverPlanned = Set(nodes.filter { $0.serverVersion > 0 && !locallyChangedNodeIds.contains($0.id) && horizonByNode[$0.id] != nil }.map(\.id))

        var plan = timeline.flatMap(\.items).filter { item in
            !item.isNow && !item.isLost && item.status == .active && item.scheduledAt > now && !serverPlanned.contains(item.nodeId)
        }
        for node in nodes where serverPlanned.contains(node.id) && node.status == .active {
            for occurrence in horizonByNode[node.id] ?? [] {
                guard let moment = occurrence.scheduledAt ?? allDayMoment(occurrence, timeZone: node.timeZone),
                      moment > now, !occurrence.isPast, !occurrence.isUntied,
                      !completedKeys.contains(occurrence.id),
                      !hidden.contains(occurrenceKey(node.id, moment)) else { continue }
                if node.isRepeating, let pausedUntil = node.pausedUntil, moment < pausedUntil { continue }
                plan.append(TimelineItem(
                    id: occurrence.id,
                    nodeId: node.id,
                    occurrenceDate: node.isRepeating ? moment : nil,
                    title: occurrence.title,
                    note: occurrence.note,
                    kind: node.repeatSchedule.displayLabel(language: settings.language),
                    repeatSchedule: node.repeatSchedule,
                    originDate: node.originDate,
                    scheduledAt: moment,
                    status: .active,
                    isNow: false,
                    isLost: false,
                    isQuiet: false,
                    tintHex: tint(for: node.repeatSchedule, isLost: false, isCompleted: false)
                ))
            }
        }
        return Array(plan.sorted { $0.scheduledAt < $1.scheduledAt }.prefix(limit))
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

    /// All-day occurrences have no moment; the app places them at 09:00 in
    /// the node's zone.
    private func allDayMoment(_ occurrence: ServerOccurrence, timeZone: TimeZone) -> Date? {
        guard let date = occurrence.localDate else { return nil }
        return NodeMapper.moment(date: date, time: occurrence.localTime ?? "09:00", calendar: NodeMapper.calendar(in: timeZone))
    }

    private func occurrenceKey(_ reminderId: UUID, _ date: Date) -> String {
        "\(reminderId.uuidString)-\(Int(date.timeIntervalSince1970))"
    }
}
