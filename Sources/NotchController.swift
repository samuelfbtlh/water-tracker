import SwiftUI
import AppKit
import Observation

/// Dimensões do recorte (notch) da tela, em pontos.
struct NotchGeometry: Equatable {
    let width: CGFloat
    let height: CGFloat
}

/// Painel sem borda que cobre o notch. Não ativa o app ao receber cliques,
/// para não roubar o foco de quem está trabalhando.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `NSHostingView` que rastreia o mouse por conta própria: `onHover` do SwiftUI
/// não dispara de forma confiável em um painel que não está ativo.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Mostra o Gota no notch dos MacBooks que têm um: um indicador recolhido
/// (gota + contagem) que expande o `PanelView` ao passar o mouse. Quando ativo,
/// substitui o ícone da barra de menus (`GotaApp` consulta `isActive`).
@MainActor
@Observable
final class NotchController {
    static let shared = NotchController()

    private(set) var geometry: NotchGeometry?
    /// Estado-alvo da animação: `true` = painel aberto.
    private(set) var expanded = false
    /// Altura do `PanelView` medida pela view (varia com os Ajustes abertos).
    private(set) var panelHeight: CGFloat = 0

    /// Largura da "asa" à direita do recorte (gota + contagem, como no ícone da barra).
    static func wing(showCount: Bool) -> CGFloat { showCount ? 68 : 36 }
    static let panelWidth: CGFloat = 250
    /// Duração da animação de abrir/fechar; a janela só encolhe depois dela.
    static let animation: Animation = .smooth(duration: 0.3)
    private static let collapseDelay: Duration = .milliseconds(350)

    static func collapsedWidth(for notch: NotchGeometry, showCount: Bool) -> CGFloat {
        notch.width + wing(showCount: showCount)
    }

    static func expandedWidth(for notch: NotchGeometry, showCount: Bool) -> CGFloat {
        max(panelWidth, collapsedWidth(for: notch, showCount: showCount))
    }

    /// Existe uma tela com notch conectada.
    var hasNotch: Bool { geometry != nil }

    /// O notch está efetivamente no lugar do ícone da barra.
    var isActive: Bool { geometry != nil && HydrationStore.shared.settings.useNotch }

    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var fitScheduled = false
    /// A janela está dimensionada (e centralizada) para o painel aberto, o que inclui o
    /// tempo da animação de fechar. Fechada, a janela começa na borda esquerda do recorte.
    private(set) var windowOpen = false
    /// Destino pedido pelo mouse; `expanded` só muda depois que a janela foi reposicionada.
    @ObservationIgnored private var wantsExpanded = false

    private init() {
        let found = Self.notchScreen()
        screen = found
        geometry = found.map(Self.geometry(of:))
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Reavalia tela e ajuste do usuário; mostra ou esconde o painel conforme `isActive`.
    func refresh() {
        let found = Self.notchScreen()
        screen = found
        let newGeometry = found.map(Self.geometry(of:))
        if newGeometry != geometry { geometry = newGeometry }

        if isActive {
            showPanel()
        } else {
            hidePanel()
        }
    }

    // MARK: - Hover

    /// O hover só sugere uma mudança; a decisão final usa a posição real do mouse,
    /// porque o painel redimensiona e o SwiftUI pode perder o evento de saída.
    func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 120 : 250))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            let reallyInside = panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
            self.setExpanded(reallyInside)
        }
    }

    /// Abrir: a janela vai ao tamanho final (centralizada) e só então a forma anima.
    /// Fechar: a forma anima primeiro; a janela só encolhe quando a animação termina.
    private func setExpanded(_ value: Bool) {
        guard value != wantsExpanded else { return }
        wantsExpanded = value
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if value {
                NotificationManager.shared.refreshStatus()
                await self.reframe(open: true)
                guard !Task.isCancelled else { return }
                self.expanded = true
            } else {
                self.expanded = false
                try? await Task.sleep(for: Self.collapseDelay)
                guard !Task.isCancelled else { return }
                PanelUIState.shared.settingsExpanded = false
                await self.reframe(open: false)
            }
        }
    }

    /// Troca a janela entre "fechada" (colada ao recorte) e "aberta" (centralizada).
    /// A view muda o deslocamento da forma junto com a janela; esconder a janela por
    /// um instante evita que apareça um quadro com os dois fora de sincronia.
    private func reframe(open: Bool) async {
        guard windowOpen != open else { fit(); return }
        panel?.alphaValue = 0
        windowOpen = open
        try? await Task.sleep(for: .milliseconds(40))
        fit()
        panel?.alphaValue = 1
    }

    func panelHeightChanged(_ height: CGFloat) {
        guard abs(height - panelHeight) > 0.5 else { return }
        panelHeight = height
        scheduleFit()
    }

    // MARK: - Painel

    private func showPanel() {
        if panel == nil { buildPanel() }
        scheduleFit()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        hoverTask?.cancel()
        transitionTask?.cancel()
        wantsExpanded = false
        expanded = false
        windowOpen = false
        PanelUIState.shared.settingsExpanded = false
        panel?.alphaValue = 1
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let view = NotchHostingView(rootView: NotchRootView(controller: self))
        // O tamanho da janela é calculado em `fit()`; o hosting view não deve impor limites.
        view.sizingOptions = []
        view.onHover = { [weak self] inside in
            Task { @MainActor in self?.hoverChanged(inside) }
        }

        let initial = geometry.map {
            NSRect(x: 0, y: 0,
                   width: Self.collapsedWidth(for: $0, showCount: HydrationStore.shared.settings.showCountInBar),
                   height: $0.height)
        } ?? .zero
        let panel = NotchPanel(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        self.panel = panel
    }

    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    /// Fechado: colada à borda esquerda do recorte, estendendo-se só para a direita (a
    /// esquerda fica livre para os menus dos apps). Aberto: centralizada no recorte.
    private func fit() {
        fitScheduled = false
        guard let panel, let screen, let notch = geometry else { return }
        let showCount = HydrationStore.shared.settings.showCountInBar
        let size = windowOpen
            ? CGSize(width: Self.expandedWidth(for: notch, showCount: showCount),
                     height: notch.height + panelHeight)
            : CGSize(width: Self.collapsedWidth(for: notch, showCount: showCount),
                     height: notch.height)
        let x = windowOpen
            ? screen.frame.midX - size.width / 2
            : screen.frame.midX - notch.width / 2
        let frame = NSRect(
            x: x.rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Geometria

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private static func geometry(of screen: NSScreen) -> NotchGeometry {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let measured = screen.frame.width - left - right
        // Sem as áreas auxiliares não dá para medir o recorte; usa uma largura típica.
        let width = (left > 0 && right > 0 && measured > 0) ? measured : 190
        return NotchGeometry(width: width, height: screen.safeAreaInsets.top)
    }
}

// MARK: - View

struct NotchRootView: View {
    @Bindable var controller: NotchController
    @Bindable private var store = HydrationStore.shared

    var body: some View {
        let notch = controller.geometry ?? NotchGeometry(width: 190, height: 32)
        let showCount = store.settings.showCountInBar
        let open = controller.expanded
        let collapsedWidth = NotchController.collapsedWidth(for: notch, showCount: showCount)
        let expandedWidth = NotchController.expandedWidth(for: notch, showCount: showCount)
        // Com a janela aberta (centralizada) a forma recolhida precisa ficar sobre o recorte,
        // não na borda da janela; com a janela fechada ela já começa na borda esquerda do recorte.
        let leading: CGFloat = (open || !controller.windowOpen) ? 0 : (expandedWidth - notch.width) / 2
        let radius: CGFloat = open ? 16 : 10
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)

        // Os dois conteúdos coexistem e se alternam por opacidade; a forma preta
        // (largura × altura) é o que anima, "descendo" do recorte.
        ZStack(alignment: .top) {
            collapsedContent(notch: notch, showCount: showCount)
                .frame(width: collapsedWidth)
                .opacity(open ? 0 : 1)
            expandedContent(notch: notch, width: expandedWidth)
                .opacity(open ? 1 : 0)
                // Ao abrir, o conteúdo só aparece depois de a forma já ter crescido até ele;
                // ao fechar, some de imediato para não vazar para fora da forma que encolhe.
                .animation(open ? .easeIn(duration: 0.12).delay(0.14) : .easeOut(duration: 0.08), value: open)
                .allowsHitTesting(open)
        }
        .frame(
            width: open ? expandedWidth : collapsedWidth,
            height: open ? notch.height + controller.panelHeight : notch.height,
            alignment: .top
        )
        .background(Color.black, in: shape)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .padding(.leading, leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(NotchController.animation, value: open)
        .animation(.easeOut(duration: 0.2), value: controller.panelHeight)
    }

    /// Gota e contagem juntas, à direita do recorte — igual ao rótulo da barra de menus.
    private func collapsedContent(notch: NotchGeometry, showCount: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: notch.width)
            HStack(spacing: 4) {
                DropIndicator(count: store.todayCount, goal: store.settings.goalBottles)
                if showCount {
                    Text("\(store.todayCount)/\(store.settings.goalBottles)")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .frame(width: NotchController.wing(showCount: showCount))
        }
        .frame(height: notch.height)
    }

    private func expandedContent(notch: NotchGeometry, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Faixa do recorte: o conteúdo começa abaixo do notch físico.
            Color.clear.frame(height: notch.height)
            PanelView()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    controller.panelHeightChanged(height)
                }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }
}
