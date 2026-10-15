import SwiftUI

struct PanelView: View {
    @Bindable var store = HydrationStore.shared
    @Bindable var scheduler = ReminderScheduler.shared

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
