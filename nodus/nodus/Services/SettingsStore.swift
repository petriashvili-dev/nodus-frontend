import Foundation
import Combine
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @AppStorage("untiedKnotsVisibility") private var untiedKnotsVisibilityRaw = UntiedKnotsVisibility.untilEndOfDay.rawValue
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("soundEnabled") var notificationSoundEnabled = true
    @AppStorage("hapticsEnabled") var hapticsEnabled = true
    @AppStorage("inAppSoundsEnabled") var inAppSoundsEnabled = true
    @AppStorage("animatedSplashEnabled") var animatedSplashEnabled = true
    @AppStorage("hasSeenVoicePermissionPrimer") var hasSeenVoicePermissionPrimer = false
    @AppStorage("quickMorningMinutes") var morningMinutes = 9 * 60
    @AppStorage("quickEveningMinutes") var eveningMinutes = 18 * 60

    var untiedKnotsVisibility: UntiedKnotsVisibility {
        get { UntiedKnotsVisibility(rawValue: untiedKnotsVisibilityRaw) ?? .untilEndOfDay }
        set {
            untiedKnotsVisibilityRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var appLanguage: AppLanguage {
        .ru
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            untiedKnotsVisibility: untiedKnotsVisibility,
            language: appLanguage,
            notificationsEnabled: notificationsEnabled,
            notificationSoundEnabled: notificationSoundEnabled,
            hapticsEnabled: hapticsEnabled,
            inAppSoundsEnabled: inAppSoundsEnabled,
            morningMinutes: morningMinutes,
            eveningMinutes: eveningMinutes
        )
    }
}
