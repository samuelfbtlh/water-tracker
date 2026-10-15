import Foundation
import Observation
import AppKit
import SwiftUI

struct Settings: Codable, Equatable {
    var bottleML: Int = 500
    var goalBottles: Int = 4
    var intervalMin: Int = 60
    var startHour: Int = 8
    var endHour: Int = 22
    var showCountInBar: Bool = true
    var useNotch: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case bottleML, goalBottles, intervalMin, startHour, endHour, showCountInBar, useNotch
    }

    // Decode manual: dado persistido de versões anteriores não tem os campos novos —
    // sem isto, o decode falha e `Persisted` volta ao padrão, perdendo o histórico.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        bottleML = try c.decodeIfPresent(Int.self, forKey: .bottleML) ?? d.bottleML
        goalBottles = try c.decodeIfPresent(Int.self, forKey: .goalBottles) ?? d.goalBottles
        intervalMin = try c.decodeIfPresent(Int.self, forKey: .intervalMin) ?? d.intervalMin
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour) ?? d.startHour
        endHour = try c.decodeIfPresent(Int.self, forKey: .endHour) ?? d.endHour
        showCountInBar = try c.decodeIfPresent(Bool.self, forKey: .showCountInBar) ?? d.showCountInBar
        useNotch = try c.decodeIfPresent(Bool.self, forKey: .useNotch) ?? d.useNotch
    }
}

private struct Persisted: Codable {
    var settings: Settings = Settings()
    var history: [String: Int] = [:]
    var metGoal: [String: Bool] = [:]

    init() {}

    init(settings: Settings, history: [String: Int], metGoal: [String: Bool]) {
        self.settings = settings
        self.history = history
        self.metGoal = metGoal
    }

    private enum CodingKeys: String, CodingKey { case settings, history, metGoal }

    // Decode manual: dado persistido da v1 não tem `metGoal` — sem isto, o decode
    // falha inteiro e reseta settings/history também.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        history = try container.decodeIfPresent([String: Int].self, forKey: .history) ?? [:]
        metGoal = try container.decodeIfPresent([String: Bool].self, forKey: .metGoal) ?? [:]
    }
}

/// Um dia na faixa de streak (D-6 … hoje) — ver regra do streak no handoff de design.
struct StreakDay: Identifiable {
    let id: String
    let met: Bool
    let isToday: Bool
}

@MainActor
@Observable
final class HydrationStore {
    static let shared = HydrationStore()

    private static let defaultsKey = "gota.state.v1"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private(set) var settings: Settings
    private(set) var history: [String: Int]
    private(set) var metGoal: [String: Bool]
    private(set) var todayKey: String

    private init() {
        let loaded = HydrationStore.load()
        self.settings = loaded.settings
        self.history = loaded.history
        self.metGoal = loaded.metGoal
        self.todayKey = HydrationStore.dayFormatter.string(from: Date())

        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDay() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDay() }
        }
    }

    var todayCount: Int {
        history[todayKey] ?? 0
    }

    func refreshDay() {
        let key = HydrationStore.dayFormatter.string(from: Date())
        if key != todayKey {
            todayKey = key
        }
    }

    func add(_ delta: Int) {
        refreshDay()
        let current = history[todayKey] ?? 0
        let updated = max(0, current + delta)
        history[todayKey] = updated
        // Vale o último valor do dia, não "em algum momento" — um "−1" depois de
        // bater a meta desfaz o dia batido (regra do streak, handoff seção 4).
        metGoal[todayKey] = updated >= settings.goalBottles
        trimHistory()
        persist()
        ReminderScheduler.shared.didLogDrink()
    }

    func updateSettings(_ newSettings: Settings) {
        settings = newSettings
        persist()
        ReminderScheduler.shared.recompute()
        NotchController.shared.refresh()
    }

    /// Binding genérico para um campo de Settings — usado pelos Steppers/Toggles do painel.
    func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                self.updateSettings(updated)
            }
        )
    }

    /// Últimos 7 dias (D-6 … hoje) para a faixa de pontos do streak.
    func last7StreakDays() -> [StreakDay] {
        let calendar = Calendar.current
        var result: [StreakDay] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = HydrationStore.dayFormatter.string(from: date)
            result.append(StreakDay(id: key, met: metGoal[key] ?? false, isToday: offset == 0))
        }
        return result
    }

    /// Dias consecutivos terminando ontem ou hoje com meta batida (handoff seção 4).
    var streak: Int {
        let calendar = Calendar.current
        var count = 0
        if var cursor = calendar.date(byAdding: .day, value: -1, to: Date()) {
            while metGoal[HydrationStore.dayFormatter.string(from: cursor)] == true {
                count += 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
        }
        if metGoal[todayKey] == true {
            count += 1
        }
        return count
    }

    private func trimHistory() {
        guard history.count > 30 else { return }
        let sortedKeys = history.keys.sorted()
        let excess = sortedKeys.count - 30
        for key in sortedKeys.prefix(excess) {
            history.removeValue(forKey: key)
            metGoal.removeValue(forKey: key)
        }
    }

    private func persist() {
        let data = Persisted(settings: settings, history: history, metGoal: metGoal)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: HydrationStore.defaultsKey)
    }

    private static func load() -> Persisted {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted()
        }
        return decoded
    }
}
