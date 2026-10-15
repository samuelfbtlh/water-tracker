import SwiftUI

struct PanelView: View {
    @Bindable var store = HydrationStore.shared
    @Bindable var scheduler = ReminderScheduler.shared

    @Bindable private var loginState = LoginItemUIState.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.setLocalizedDateFormatFromTemplate("d 'de' MMMM")
        return f
    }()

    private var goalReached: Bool {
        store.todayCount >= store.settings.goalBottles
    }

    private var progress: Double {
        guard store.settings.goalBottles > 0 else { return 0 }
        return min(1.0, Double(store.todayCount) / Double(store.settings.goalBottles))
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            ring
            buttons
            reminderLine
            settingsSection
            Divider()
            HStack {
                Spacer()
                Button("Sair") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gota")
                    .font(.headline)
                Text("Hoje, \(Self.dateFormatter.string(from: Date()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [.cyan, .blue], center: .center),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring, value: progress)

            if goalReached {
                VStack(spacing: 4) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                        .symbolEffect(.bounce, value: goalReached)
                    Text("Meta atingida!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    Text("\(store.todayCount)/\(store.settings.goalBottles)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text(volumeCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 120, height: 120)
    }

    private var volumeCaption: String {
        let drankL = Double(store.todayCount * store.settings.bottleML) / 1000.0
        let goalL = Double(store.settings.goalBottles * store.settings.bottleML) / 1000.0
        return String(format: "%.1f L de %.1f L", drankL, goalL).replacingOccurrences(of: ".", with: ",")
    }

    private var reminderLine: some View {
        Group {
            if NotificationManager.shared.authorizationDenied {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Notificações desativadas", systemImage: "bell.slash")
                }
                .buttonStyle(.plain)
            } else if goalReached {
                Label("Meta atingida, sem lembretes hoje", systemImage: "bell")
            } else if let next = scheduler.nextReminderAt {
                Label("Próximo lembrete às \(Self.timeFormatter.string(from: next))", systemImage: "bell")
            } else {
                Label("Lembretes a partir das \(String(format: "%02d:00", store.settings.startHour))", systemImage: "bell")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var startHourBinding: Binding<Int> {
        Binding(
            get: { store.settings.startHour },
            set: { newValue in
                var s = store.settings
                s.startHour = max(0, min(newValue, s.endHour - 1))
                store.updateSettings(s)
            }
        )
    }

    private var endHourBinding: Binding<Int> {
        Binding(
            get: { store.settings.endHour },
            set: { newValue in
                var s = store.settings
                s.endHour = min(23, max(newValue, s.startHour + 1))
                store.updateSettings(s)
            }
        )
    }

    private var loginToggleBinding: Binding<Bool> {
        Binding(
            get: { loginState.enabled },
            set: { newValue in loginState.setEnabled(newValue) }
        )
    }

    private var settingsSection: some View {
        DisclosureGroup("Ajustes") {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(
                    "Garrafa: \(store.settings.bottleML) ml",
                    value: store.binding(\.bottleML), in: 100...3000, step: 50
                )
                Stepper(
                    "Meta: \(store.settings.goalBottles) garrafas",
                    value: store.binding(\.goalBottles), in: 1...20
                )
                Stepper(
                    "Lembrar a cada \(store.settings.intervalMin) min",
                    value: store.binding(\.intervalMin), in: 15...240, step: 15
                )
                Stepper(
                    "Início: \(String(format: "%02d:00", store.settings.startHour))",
                    value: startHourBinding, in: 0...23
                )
                Stepper(
                    "Fim: \(String(format: "%02d:00", store.settings.endHour))",
                    value: endHourBinding, in: 0...23
                )
                Toggle("Abrir ao iniciar sessão", isOn: loginToggleBinding)
                if loginState.needsApproval {
                    Button("Aprovar nos Ajustes") {
                        LoginItemManager.openSettings()
                    }
                    .buttonStyle(.link)
                }
                if let error = loginState.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Toggle("Mostrar contagem na barra", isOn: store.binding(\.showCountInBar))
                Button("Testar lembrete") {
                    NotificationManager.shared.postReminder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 6)
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation { store.add(1) }
            } label: {
                Text("+1 garrafa")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)

            Button {
                withAnimation { store.add(-1) }
            } label: {
                Text("−1")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.todayCount <= 0)
        }
    }
}
