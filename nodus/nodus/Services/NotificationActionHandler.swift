import Foundation
import UserNotifications

/// Routes a notification tap or quick action back into the running app.
/// The OS only allows a single delegate per `UNUserNotificationCenter`, so
/// this sits between the system callback and whichever view model is
/// currently alive, rather than each feature registering its own delegate.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case open
        case untie
        case snooze(ReminderQuickPreset.Kind)
    }

    private var onAction: ((Action, UUID, Date?) async -> Void)?
    private var pendingActions: [(Action, UUID, Date?)] = []
    /// Remote pushes (APNs) — `true` for a tap, `false` while in foreground.
    private var onPush: ((PushPayload, Bool) async -> Void)?
    private var pendingTaps: [PushPayload] = []

    /// Installs the push router; replays a tap that launched the app.
    @MainActor
    func setPushHandler(_ handler: @escaping (PushPayload, Bool) async -> Void) {
        onPush = handler
        let queued = pendingTaps
        pendingTaps.removeAll()
        Task { @MainActor in
            for payload in queued {
                await handler(payload, true)
            }
        }
    }

    /// Installs the UI-side action handler and replays actions received while
    /// SwiftUI was still building the scene after a cold launch.
    @MainActor
    func setActionHandler(_ handler: @escaping (Action, UUID, Date?) async -> Void) {
        onAction = handler
        let queuedActions = pendingActions
        pendingActions.removeAll()

        Task { @MainActor in
            for (action, nodeId, occurrenceDate) in queuedActions {
                await handler(action, nodeId, occurrenceDate)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let payload = PushPayload(userInfo: userInfo) {
            Task { @MainActor in
                guard let onPush else {
                    pendingTaps.append(payload)
                    completionHandler()
                    return
                }
                await onPush(payload, true)
                completionHandler()
            }
            return
        }
        guard let nodeIdString = userInfo["nodeId"] as? String, let nodeId = UUID(uuidString: nodeIdString) else {
            completionHandler()
            return
        }
        // Local notification userInfo values round-trip through Objective-C,
        // so the timestamp can arrive as NSNumber (and older requests may
        // contain a numeric string). Decode both forms before falling back
        // to a non-repeating action.
        let occurrenceDate = notificationDate(from: userInfo["occurrenceDate"])

        let action: Action
        switch response.actionIdentifier {
        case "UNTIE":
            action = .untie
        default:
            let identifier = response.actionIdentifier
            if identifier.hasPrefix("SNOOZE_"),
               let kind = ReminderQuickPreset.Kind(rawValue: String(identifier.dropFirst("SNOOZE_".count))) {
                action = .snooze(kind)
            } else {
                action = .open
            }
        }

        // The completion handler must wait for `onAction` to actually
        // finish (retie/untie do real async work: DB save, cancelling the
        // old pending nudges, scheduling new ones) — calling it any
        // earlier tells iOS the background work is done, and the process
        // can be suspended mid-flight, leaving stale nudges uncancelled.
        Task { @MainActor in
            guard let onAction else {
                // On a cold launch iOS can deliver the response before the
                // first SwiftUI view has configured its model context. Keep
                // the action until `setActionHandler` is called rather than
                // silently dropping a snooze or completion.
                pendingActions.append((action, nodeId, occurrenceDate))
                completionHandler()
                return
            }
            await onAction(action, nodeId, occurrenceDate)
            completionHandler()
        }
    }

    /// Without this, a notification fires silently while the app is in
    /// the foreground — the quick actions still need a visible banner to
    /// be tapped at all.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A push about something the open app shows by itself becomes a
        // branded toast instead of a duplicate system banner.
        if let payload = PushPayload(userInfo: notification.request.content.userInfo) {
            Task { @MainActor in await onPush?(payload, false) }
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }

    private func notificationDate(from value: Any?) -> Date? {
        let timestamp: TimeInterval?
        switch value {
        case let number as NSNumber:
            timestamp = number.doubleValue
        case let string as String:
            timestamp = TimeInterval(string)
        case let number as TimeInterval:
            timestamp = number
        default:
            timestamp = nil
        }
        return timestamp.map(Date.init(timeIntervalSince1970:))
    }
}
