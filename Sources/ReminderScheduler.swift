import Foundation
import Observation

// Implementação completa (heartbeat, janela ativa, snooze) chega na Etapa 4.
// Por ora, apenas a superfície usada por HydrationStore/PanelView.
@MainActor
@Observable
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private(set) var nextReminderAt: Date?

    private init() {}

    func start() {}
    func recompute() {}
    func didLogDrink() {}
    func snooze(minutes: Int) {}
}
