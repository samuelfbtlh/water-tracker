import SwiftUI
import AppKit

/// Gota que reflete o progresso do dia (vazia → metade → cheia). Compartilhada
/// pelo ícone da barra de menus e pelo indicador do notch.
struct DropIndicator: View {
    let count: Int
    let goal: Int

    var body: some View {
        if let nsImage = Self.menubarImage(named: assetName) {
            Image(nsImage: nsImage)
        } else {
            Image(systemName: symbolFallback)
        }
    }

    private var goalMet: Bool { goal > 0 && count >= goal }

    private var assetName: String {
        if goalMet { return "drop-full" }
        if count > 0 { return "drop-half" }
        return "drop-empty"
    }

    private var symbolFallback: String {
        goalMet ? "drop.fill" : "drop"
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
