import AppKit
import UserNotifications
import AmzSigningCore

@MainActor enum SigningNotifications {
    static var deliveryOnly: Bool { CommandLine.arguments.contains("--notify") }

    private static func permission(_ settings: UNNotificationSettings) -> NotificationPermission {
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    static func refreshAuthorization(requestIfNeeded: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if requestIfNeeded && settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard let store = try? StateStore() else { return }
        let delivery = NoticeDelivery(store: store)
        try? delivery.authorizationChanged(permission(settings))
        if let notice = try? delivery.claim() { await send(notice, store: store) }
    }
    private static func send(_ notice: UserNotice, store: StateStore) async {
        guard let state = try? store.read(), state.mode == .automatic,
              state.notice?.id == notice.id, state.requiresAction(notice.issue),
              state.notice?.submittedAt == nil else { return }
        let delivery = NoticeDelivery(store: store)
        let center = UNUserNotificationCenter.current()
        let allowed = permission(await center.notificationSettings())
        try? delivery.authorizationChanged(allowed)
        guard allowed == .allowed else {
            try? delivery.finish(id: notice.id, outcome: .permissionRequired)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "AmzSigning：" + notice.issue.title
        content.body = notice.issue.guidance
        content.sound = .default
        do {
            // A stable request identifier replaces an earlier copy after interruption.
            try await center.add(UNNotificationRequest(identifier: "amzsigning-action", content: content, trigger: nil))
            try delivery.finish(id: notice.id, outcome: .submitted)
        } catch { try? delivery.finish(id: notice.id, outcome: .failed) }
    }
    static func deliverAndExit() async {
        defer { NSApp.terminate(nil) }
        guard let store = try? StateStore(), let notice = try? store.read().notice,
              CommandLine.arguments.last == notice.id else { return }
        await send(notice, store: store)
    }
}

final class NotificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await SigningNotifications.deliverAndExit() }
    }
}
