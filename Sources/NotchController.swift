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
    /// Área sensível ao mouse, no canto superior esquerdo. A janela é bem maior que o indicador
    /// e quase toda transparente; o rastreamento da janela inteira abriria o painel à toa.
    var hoverSize: CGSize = .zero { didSet { updateTrackingAreas() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        let rect = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - hoverSize.height,
                          width: hoverSize.width, height: hoverSize.height)
        addTrackingArea(NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Mostra o Gota no notch dos MacBooks que têm um: um indicador (gota + contagem) à
/// direita do recorte que, depois de o mouse ficar sobre ele, expande o `PanelView`
/// para baixo. O indicador nunca sai do lugar; o painel só fecha com um clique fora.
/// Quando ativo, substitui o ícone da barra de menus (`GotaApp` consulta `isActive`).
///
/// A janela nunca muda de tamanho: ela tem a altura máxima do painel e só a forma preta
/// (SwiftUI) cresce e encolhe dentro dela. Redimensionar uma janela ancorada no topo muda
/// também a origem dela, e o AppKit faz as duas coisas em passos separados — o que piscava
/// a janela fora do lugar por um quadro. As partes transparentes deixam o clique passar
/// para o app de baixo.
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
    /// Folga de altura da janela abaixo do notch: maior que o `PanelView` com os Ajustes abertos.
    static let maxPanelHeight: CGFloat = 640
    /// Abrir/fechar a forma.
    static let animation: Animation = .smooth(duration: 0.3)
    /// Mudança de altura (Ajustes abrindo/fechando): mesma curva do `PanelView`.
    static let heightAnimation: Animation = .easeInOut(duration: 0.2)
    /// Quanto o mouse precisa ficar sobre o indicador para o painel abrir.
    private static let openDelay: Duration = .milliseconds(666)
    /// Depois de fechado, quanto esperar para recolher os Ajustes sem aparecer na animação.
    private static let resetDelay: Duration = .milliseconds(350)

    static func collapsedWidth(for notch: NotchGeometry, showCount: Bool) -> CGFloat {
        notch.width + wing(showCount: showCount)
    }

    static func expandedWidth(for notch: NotchGeometry, showCount: Bool) -> CGFloat {
        max(panelWidth, collapsedWidth(for: notch, showCount: showCount))
    }

    /// Existe uma tela com notch conectada. Sem ela, a opção "Mostrar no notch" nem aparece.
    var hasNotch: Bool { geometry != nil }

    /// O notch está efetivamente no lugar do ícone da barra.
    var isActive: Bool { geometry != nil && HydrationStore.shared.settings.useNotch }

    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var hostingView: NotchHostingView<NotchRootView>?
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var fitScheduled = false

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

    // MARK: - Abrir e fechar

    /// Só o mouse parado sobre o indicador abre; sair antes do prazo cancela. Com o painel
    /// aberto o hover é ignorado: ele só fecha por clique fora (`collapse`).
    func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside, !expanded else { return }
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            // A decisão final usa a posição real do mouse: o evento de saída pode se perder.
            guard !Task.isCancelled, let self, let rect = self.indicatorRect(),
                  rect.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) else { return }
            self.expand()
        }
    }

    private func expand() {
        guard !expanded else { return }
        resetTask?.cancel()
        NotificationManager.shared.refreshStatus()
        expanded = true
    }

    private func collapse() {
        guard expanded else { return }
        hoverTask?.cancel()
        expanded = false
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resetDelay)
            guard !Task.isCancelled else { return }
            PanelUIState.shared.settingsExpanded = false
        }
    }

    func panelHeightChanged(_ height: CGFloat) {
        guard abs(height - panelHeight) > 0.5 else { return }
        panelHeight = height
    }

    // MARK: - Painel

    private func showPanel() {
        if panel == nil { buildPanel() }
        installClickMonitor()
        scheduleFit()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        hoverTask?.cancel()
        resetTask?.cancel()
        removeClickMonitor()
        expanded = false
        PanelUIState.shared.settingsExpanded = false
        panel?.orderOut(nil)
    }

    /// Clique em qualquer outro lugar fecha o painel. Cliques dentro do painel são
    /// entregues à janela e não chegam ao monitor global.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func buildPanel() {
        let view = NotchHostingView(rootView: NotchRootView(controller: self))
        // O tamanho da janela é calculado em `targetFrame()`; o hosting view não deve impor limites.
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
        self.hostingView = view
    }

    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.fitScheduled = false
            self?.applyFrame()
        }
    }

    private func applyFrame() {
        guard let panel, let target = targetFrame() else { return }
        if let notch = geometry {
            hostingView?.hoverSize = CGSize(
                width: Self.collapsedWidth(for: notch, showCount: HydrationStore.shared.settings.showCountInBar),
                height: notch.height
            )
        }
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    /// Colada à borda esquerda do recorte e ao topo da tela, sempre com a altura máxima.
    private func targetFrame() -> NSRect? {
        guard let screen, let notch = geometry else { return nil }
        let showCount = HydrationStore.shared.settings.showCountInBar
        let size = CGSize(width: Self.expandedWidth(for: notch, showCount: showCount),
                          height: notch.height + Self.maxPanelHeight)
        return NSRect(
            x: (screen.frame.midX - notch.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Retângulo do indicador, em coordenadas de tela.
    private func indicatorRect() -> NSRect? {
        guard let panel, let notch = geometry else { return nil }
        let showCount = HydrationStore.shared.settings.showCountInBar
        return NSRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - notch.height,
            width: Self.collapsedWidth(for: notch, showCount: showCount),
            height: notch.height
        )
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
        let radius: CGFloat = open ? 16 : 10
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)

        // O indicador fica sempre no mesmo lugar (faixa do recorte); o painel aparece por
        // opacidade abaixo dele, e a forma preta (largura × altura) é o que anima.
        ZStack(alignment: .topLeading) {
            expandedContent(notch: notch, width: expandedWidth)
                .opacity(open ? 1 : 0)
                // Ao abrir, o conteúdo só aparece depois de a forma já ter crescido até ele;
                // ao fechar, some de imediato para não vazar para fora da forma que encolhe.
                .animation(open ? .easeIn(duration: 0.12).delay(0.14) : .easeOut(duration: 0.08), value: open)
                .allowsHitTesting(open)
            indicator(notch: notch, showCount: showCount)
                .frame(width: collapsedWidth, alignment: .leading)
        }
        .frame(
            width: open ? expandedWidth : collapsedWidth,
            height: open ? notch.height + controller.panelHeight : notch.height,
            alignment: .topLeading
        )
        .background(Color.black, in: shape)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        // O painel não ativa o app; sem isto os controles ficam com o visual inativo (cinza)
        // até o primeiro clique.
        .environment(\.controlActiveState, .key)
        .animation(NotchController.animation, value: open)
        .animation(NotchController.heightAnimation, value: controller.panelHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Gota e contagem juntas, à direita do recorte — igual ao rótulo da barra de menus.
    private func indicator(notch: NotchGeometry, showCount: Bool) -> some View {
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
