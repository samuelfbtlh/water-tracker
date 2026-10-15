import SwiftUI
import AppKit

@main
struct GotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Bindable private var store = HydrationStore.shared
    @Bindable private var notch = NotchController.shared

    var body: some Scene {
        // Com notch disponível (e ativado), o indicador do notch substitui o ícone.
        MenuBarExtra(isInserted: .constant(!notch.isActive)) {
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
        if store.settings.showCountInBar {
            HStack(spacing: 4) {
                DropIndicator(count: count, goal: goal)
                Text("\(count)/\(goal)")
            }
        } else {
            DropIndicator(count: count, goal: goal)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Usado pelo uninstall.sh: desregistra o login item e sai, sem abrir painel/notificações.
        if CommandLine.arguments.contains("--unregister-login") {
            LoginItemManager.setEnabled(false)
            NSApp.terminate(nil)
            return
        }
        NotificationManager.shared.configure()
        ReminderScheduler.shared.start()
        NotchController.shared.start()
        LoginItemManager.registerDefaultIfFirstLaunch()
    }
}
