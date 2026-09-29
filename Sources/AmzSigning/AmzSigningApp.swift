import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in await SigningNotifications.refreshAuthorization(requestIfNeeded: true) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await SigningNotifications.refreshAuthorization() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

private struct SettingsApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("AmzSigning", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 1120, height: 790)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// Notification delivery uses an AppKit event loop without constructing a settings window.
@main enum AmzSigningApp {
    @MainActor static func main() {
        if SigningNotifications.deliveryOnly {
            let application = NSApplication.shared
            let delegate = NotificationDelegate()
            application.setActivationPolicy(.prohibited)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } else {
            SettingsApplication.main()
        }
    }
}
