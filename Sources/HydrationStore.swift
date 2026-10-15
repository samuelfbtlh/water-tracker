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
}

private struct Persisted: Codable {
    var settings: Settings = Settings()
    var history: [String: Int] = [:]
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
    private(set) var todayKey: String

    private init() {
        let loaded = HydrationStore.load()
        self.settings = loaded.settings
        self.history = loaded.history
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
        trimHistory()
        persist()
        ReminderScheduler.shared.didLogDrink()
    }

    func updateSettings(_ newSettings: Settings) {
        settings = newSettings
        persist()
        ReminderScheduler.shared.recompute()
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

    func last7Days() -> [(label: String, count: Int, isToday: Bool)] {
        let calendar = Calendar.current
        var result: [(label: String, count: Int, isToday: Bool)] = []
        let weekdaySymbols = ["D", "S", "T", "Q", "Q", "S", "S"]
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = HydrationStore.dayFormatter.string(from: date)
            let weekday = calendar.component(.weekday, from: date) - 1
            let label = weekdaySymbols[weekday]
            result.append((label: label, count: history[key] ?? 0, isToday: offset == 0))
        }
        return result
    }

    private func trimHistory() {
        guard history.count > 30 else { return }
        let sortedKeys = history.keys.sorted()
        let excess = sortedKeys.count - 30
        for key in sortedKeys.prefix(excess) {
            history.removeValue(forKey: key)
        }
    }

    private func persist() {
        let data = Persisted(settings: settings, history: history)
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
