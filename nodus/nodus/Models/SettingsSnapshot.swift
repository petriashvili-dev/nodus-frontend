import Foundation

struct SettingsSnapshot {
    var untiedKnotsVisibility: UntiedKnotsVisibility
    var language: AppLanguage
    var notificationsEnabled: Bool
    var notificationSoundEnabled: Bool
    var hapticsEnabled: Bool
    var inAppSoundsEnabled: Bool
    var morningMinutes: Int = 9 * 60
    var eveningMinutes: Int = 18 * 60
}
