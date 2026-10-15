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
        if store.settings.showCountInBar {
            HStack(spacing: 4) {
                dropImage(count: count, goal: goal)
                Text("\(count)/\(goal)")
            }
        } else {
            dropImage(count: count, goal: goal)
        }
    }

    @ViewBuilder
    private func dropImage(count: Int, goal: Int) -> some View {
        let name = dropAssetName(count: count, goal: goal)
        if let nsImage = Self.menubarImage(named: name) {
            Image(nsImage: nsImage)
        } else {
            Image(systemName: dropSymbolFallback(count: count, goal: goal))
        }
    }

    private func dropAssetName(count: Int, goal: Int) -> String {
        if goal > 0 && count >= goal {
            return "drop-full"
        }
        if count > 0 {
            return "drop-half"
        }
        return "drop-empty"
    }

    private func dropSymbolFallback(count: Int, goal: Int) -> String {
        if goal > 0 && count >= goal {
            return "drop.fill"
        }
        return "drop"
    }

    private static var menubarImageCache: [String: NSImage] = [:]

    private static func menubarImage(named name: String) -> NSImage? {
        if let cached = menubarImageCache[name] {
            return cached
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "menubar"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        menubarImageCache[name] = image
        return image
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
        LoginItemManager.registerDefaultIfFirstLaunch()
    }
}
