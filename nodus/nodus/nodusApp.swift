//
//  nodusApp.swift
//  nodus
//
//  Created by Petriashvili Kirill on 25.06.2026.
//

import SwiftData
import SwiftUI
import AppIntents
import UserNotifications
import UIKit

/// Notification responses are delivered during application launch, before a
/// SwiftUI view's `.task` is guaranteed to run. Installing the delegate here
/// ensures a notification quick action is never missed on a cold launch.
final class NodusAppDelegate: NSObject, UIApplicationDelegate {
    let notificationHandler = NotificationActionHandler()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationHandler
        return true
    }
}

@main
struct nodusApp: App {
    @UIApplicationDelegateAdaptor(NodusAppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    init() {
        FontRegistrar.registerCustomFontsIfNeeded()
        NodusAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(services: services, notificationHandler: appDelegate.notificationHandler)
        }
        .modelContainer(services.modelContainer)
    }
}
