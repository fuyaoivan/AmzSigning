import AppKit
import UserNotifications
import AmzSigningCore

@MainActor enum SigningNotifications {
    static var deliveryOnly: Bool { CommandLine.arguments.contains("--notify") }

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
    static func deliverAndExit() async {
        defer { NSApp.terminate(nil) }
        guard let store = try? StateStore(), let state = try? store.read(), let notice = state.notice,
              CommandLine.arguments.last == notice.id else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "AmzSigning：" + notice.issue.title
        content.body = notice.issue.guidance
        content.sound = .default
        // One fixed identifier replaces earlier actionable notices from this application.
        try? await center.add(UNNotificationRequest(identifier: "amzsigning-action", content: content, trigger: nil))
    }
}

final class NotificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await SigningNotifications.deliverAndExit() }
    }
}
