import SwiftUI
import AppKit

@main
struct GotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Bindable private var store = HydrationStore.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let count = store.todayCount
        let goal = store.settings.goalBottles
        let symbol = dropSymbol(count: count, goal: goal)
        if store.settings.showCountInBar {
            Label("\(count)/\(goal)", systemImage: symbol)
        } else {
            Image(systemName: symbol)
        }
    }

    private func dropSymbol(count: Int, goal: Int) -> String {
        if goal > 0 && count >= goal {
            return "drop.fill"
        }
        if count > 0 {
            let halfName = "drop.halffull"
            if NSImage(systemSymbolName: halfName, accessibilityDescription: nil) != nil {
                return halfName
            }
        }
        return "drop"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.configure()
        ReminderScheduler.shared.start()
    }
}
