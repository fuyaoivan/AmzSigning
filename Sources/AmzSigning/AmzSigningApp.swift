import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in await SigningNotifications.requestPermission() }
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
