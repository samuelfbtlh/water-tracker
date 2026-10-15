import Foundation
import Observation

/// Checa a última release no GitHub ao abrir o painel (no máximo 1x a cada 24 h).
/// Silencioso em qualquer erro/offline — só expõe algo se houver versão mais nova.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release {
        let version: String
        let url: URL
    }

    private(set) var available: Release?

    private static let lastCheckKey = "gota.lastUpdateCheck"
    private static let endpoint = URL(string: "https://api.github.com/repos/vleineker/water-tracker/releases/latest")!

    private init() {}

    func checkIfDue() {
        guard available == nil else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        Task { await check() }
    }

    private func check() async {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let (data, response) = try? await URLSession.shared.data(from: Self.endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              let url = URL(string: html) else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(latest, than: current) {
            available = Release(version: latest, url: url)
            // Sem trava de 24 h enquanto houver versão nova: após relançar, reaparece.
            UserDefaults.standard.removeObject(forKey: Self.lastCheckKey)
        }
    }

    /// Compara "1.10.2" × "1.9" numericamente, componente a componente (faltante = 0).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
