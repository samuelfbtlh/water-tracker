import SwiftUI
import AppKit

@main
struct GotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Text("Gota")
                .padding(16)
                .frame(width: 290)
        } label: {
            Label("0/4", systemImage: "drop")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Etapas seguintes vão configurar NotificationManager e ReminderScheduler aqui.
    }
}
