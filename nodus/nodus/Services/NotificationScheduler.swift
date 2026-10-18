import Foundation
import UserNotifications
import os

@MainActor
protocol NotificationScheduling {
    func registerCategories(settings: SettingsSnapshot)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    /// `occurrenceDate` identifies a repeating occurrence; `scheduledAt` is
    /// its current (possibly overridden) fire date.
    func schedule(node: ReminderNode, occurrenceDate: Date?, scheduledAt: Date?, settings: SettingsSnapshot) async
    func cancel(nodeId: UUID, occurrenceDate: Date?) async
    func cancelAll(nodeId: UUID) async
    func rescheduleAll(nodes: [ReminderNode], plan: [TimelineItem], settings: SettingsSnapshot) async
}

final class NotificationScheduler: NotificationScheduling {
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "app.nodus", category: "Notification")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func registerCategories(settings: SettingsSnapshot) {
        let untie = UNNotificationAction(identifier: "UNTIE", title: settings.language.localizedString("Untie"), options: [])
        let smartActions = ReminderQuickPreset.notificationActions(settings: settings).map { preset in
            UNNotificationAction(identifier: "SNOOZE_\(preset.kind.rawValue)", title: preset.label(language: settings.language), options: [])
        }
        let category = UNNotificationCategory(identifier: "KNOT", actions: [untie] + smartActions, intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The event-time notification gets nagged out if the knot is still
    /// untouched. Advance reminders, however, are deliberately sent only
    /// once: they announce the upcoming event and must not become a repeated
    /// alert days before it. Nudges are scheduled upfront — untying, retying,
    /// or deleting the knot already cancels pending requests (see
    /// `cancel`/`cancelAll`).
    private let nudgeCount = 3
    private let nudgeInterval: TimeInterval = 5 * 60

    func schedule(
        node: ReminderNode,
        occurrenceDate: Date? = nil,
        scheduledAt overriddenScheduledAt: Date? = nil,
        settings: SettingsSnapshot
    ) async {
        guard settings.notificationsEnabled else { return }
        guard !node.leadTimes.isEmpty else { return }
        // A repeated knot must always carry its original occurrence date in
        // the notification payload. That date is the key used by overrides;
        // the effective fire date may change independently after a snooze.
        let occurrenceIdentity = node.isRepeating ? (occurrenceDate ?? node.scheduledAt) : nil
        let scheduledAt = overriddenScheduledAt ?? occurrenceDate ?? node.scheduledAt

        for leadTime in node.leadTimes {
            guard !Task.isCancelled else { return }
            let baseFireDate = leadTime.fireDate(before: scheduledAt)
            let lastNudge = leadTime.isAtTime ? nudgeCount : 0

            for nudge in 0...lastNudge {
                guard !Task.isCancelled else { return }
                let fireTime = baseFireDate.addingTimeInterval(TimeInterval(nudge) * nudgeInterval)
                guard fireTime > Date() else { continue }

                let content = UNMutableNotificationContent()
                content.title = node.title
                content.body = notificationBody(for: node, leadTime: leadTime, language: settings.language)
                content.categoryIdentifier = "KNOT"
                content.sound = settings.notificationSoundEnabled ? UNNotificationSound(named: UNNotificationSoundName("notify.wav")) : nil
                var userInfo: [AnyHashable: Any] = ["nodeId": node.id.uuidString]
                if let occurrenceIdentity {
                    userInfo["occurrenceDate"] = occurrenceIdentity.timeIntervalSince1970
                }
                content.userInfo = userInfo

                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireTime)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let suffix = identifierSuffix(base: leadTime.rawToken, nudge: nudge)
                let request = UNNotificationRequest(identifier: identifier(nodeId: node.id, occurrenceDate: occurrenceIdentity, suffix: suffix), content: content, trigger: trigger)

                do {
                    try await center.add(request)
                } catch {
                    logger.error("Notification scheduling failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func identifierSuffix(base: String?, nudge: Int) -> String? {
        guard nudge > 0 else { return base }
        return [base, "nudge\(nudge)"].compactMap { $0 }.joined(separator: "-")
    }

    /// A lead time is part of the scheduled request, but was previously
    /// invisible to the recipient. Include it in advance reminders so a
    /// yearly knot on 10 August does not look like it has unexpectedly
    /// moved when its "1 day before" notification arrives on the 9th.
    private func notificationBody(for node: ReminderNode, leadTime: ReminderLeadTime, language: AppLanguage) -> String {
        let message = node.note ?? language.localizedString("A knot is waiting on the thread.")
        guard !leadTime.isAtTime else { return message }

        let amount = leadTime.amount
        let unit = leadTime.unit.localizedLabel(for: amount, language: language)
        switch language {
        case .ru:
            return "Напоминание за \(amount) \(unit). \(message)"
        case .en:
            return "Reminder \(amount) \(unit) before. \(message)"
        }
    }

    func cancel(nodeId: UUID, occurrenceDate: Date? = nil) async {
        let prefix = identifier(nodeId: nodeId, occurrenceDate: occurrenceDate)
        let pendingRequests = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()
        let matchesOccurrence: (String) -> Bool = { identifier in
            identifier == prefix || identifier.hasPrefix("\(prefix)-")
        }
        let pendingIDs = pendingRequests.map(\.identifier).filter(matchesOccurrence)
        let deliveredIDs = deliveredNotifications.map(\.request.identifier).filter(matchesOccurrence)
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    func cancelAll(nodeId: UUID) async {
        let pendingRequests = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()
        let pendingIDs = pendingRequests.map(\.identifier).filter { $0.hasPrefix(nodeId.uuidString) }
        let deliveredIDs = deliveredNotifications.map(\.request.identifier).filter { $0.hasPrefix(nodeId.uuidString) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    func rescheduleAll(nodes: [ReminderNode], plan: [TimelineItem], settings: SettingsSnapshot) async {
        for node in nodes {
            guard !Task.isCancelled else { return }
            await cancelAll(nodeId: node.id)
        }

        guard settings.notificationsEnabled else { return }

        for item in plan {
            guard !Task.isCancelled else { return }
            guard let node = nodes.first(where: { $0.id == item.nodeId }) else { continue }
            await schedule(
                node: node,
                occurrenceDate: item.occurrenceDate,
                scheduledAt: item.scheduledAt,
                settings: settings
            )
        }
    }

    private func identifier(nodeId: UUID, occurrenceDate: Date?, suffix: String? = nil) -> String {
        let base: String
        if let occurrenceDate {
            base = "\(nodeId.uuidString)-\(Int(occurrenceDate.timeIntervalSince1970))"
        } else {
            base = nodeId.uuidString
        }
        guard let suffix else { return base }
        return "\(base)-\(suffix)"
    }
}
