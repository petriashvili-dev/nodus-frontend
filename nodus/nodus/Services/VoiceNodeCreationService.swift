import Foundation
import SwiftData

@MainActor
enum VoiceNodeCreationService {
    /// The same default as the editor. It keeps a voice-created knot valid
    /// without inventing a meaningful deadline; Siri always asks for a final
    /// confirmation before this value is saved.
    static func defaultScheduledAt(now: Date = .now) -> Date {
        .earliestReminderTime(now: now)
    }

    static func save(_ parsedNodes: [ParsedNode]) async throws {
        let container = try NodusModelContainer.make()
        let context = ModelContext(container)
        let settings = settingsSnapshot()
        let scheduler = NotificationScheduler()
        scheduler.registerCategories(settings: settings)

        let now = Date()
        for parsed in parsedNodes {
            let node = ReminderNode(
                title: parsed.title,
                note: parsed.note,
                scheduledAt: parsed.scheduledAt ?? defaultScheduledAt(now: now),
                repeatSchedule: parsed.repeatSchedule,
                createdAt: now,
                updatedAt: now
            )
            context.insert(node)
            await scheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
        }
        try context.save()
    }

    private static func settingsSnapshot() -> SettingsSnapshot {
        let defaults = UserDefaults.standard
        return SettingsSnapshot(
            untiedKnotsVisibility: UntiedKnotsVisibility(rawValue: defaults.string(forKey: "untiedKnotsVisibility") ?? "") ?? .untilEndOfDay,
            language: .ru,
            notificationsEnabled: defaults.object(forKey: "notificationsEnabled") as? Bool ?? true,
            notificationSoundEnabled: defaults.object(forKey: "soundEnabled") as? Bool ?? true,
            hapticsEnabled: defaults.object(forKey: "hapticsEnabled") as? Bool ?? true,
            inAppSoundsEnabled: defaults.object(forKey: "inAppSoundsEnabled") as? Bool ?? true,
            morningMinutes: defaults.object(forKey: "quickMorningMinutes") as? Int ?? 9 * 60,
            eveningMinutes: defaults.object(forKey: "quickEveningMinutes") as? Int ?? 18 * 60
        )
    }
}
