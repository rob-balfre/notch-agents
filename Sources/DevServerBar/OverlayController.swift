import AppKit
import Combine
import NotchAgentsCore
import SwiftUI

@MainActor
final class OverlayController {
    private let store: AgentStore
    private let controlPanel: ControlPanelController
    private let bridgePanel = OverlayPanel(interactive: false)
    private let leadingPanel = OverlayPanel()
    private let trailingPanel = OverlayPanel()

    private var cancellables: Set<AnyCancellable> = []

    init(store: AgentStore) {
        self.store = store
        controlPanel = ControlPanelController(store: store)

        store.$summaries
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanels()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updatePanels()
        }
        .store(in: &cancellables)

        updatePanels()
    }

    private func updatePanels() {
        guard let screen = preferredScreen() else {
            bridgePanel.orderOut(nil)
            leadingPanel.orderOut(nil)
            trailingPanel.orderOut(nil)
            return
        }

        let leadingSummaries = visibleSummaries(for: .leading)
        let trailingSummaries = visibleSummaries(for: .trailing)
        let isLeadingCollapsed = leadingSummaries.isEmpty
        let isTrailingCollapsed = trailingSummaries.isEmpty

        renderBridge(
            on: screen,
            isLeadingCollapsed: isLeadingCollapsed,
            isTrailingCollapsed: isTrailingCollapsed
        )
        render(
            panel: leadingPanel,
            side: .leading,
            summaries: leadingSummaries,
            isCollapsed: isLeadingCollapsed,
            on: screen
        )
        render(
            panel: trailingPanel,
            side: .trailing,
            summaries: trailingSummaries,
            isCollapsed: isTrailingCollapsed,
            on: screen
        )
    }

    private func renderBridge(
        on screen: NSScreen,
        isLeadingCollapsed: Bool,
        isTrailingCollapsed: Bool
    ) {
        let frame = OverlayGeometry.bridgeFrame(
            on: screen,
            isLeadingCollapsed: isLeadingCollapsed,
            isTrailingCollapsed: isTrailingCollapsed
        )
        let view = NotchBridgeView(
            isCollapsed: isLeadingCollapsed && isTrailingCollapsed,
            roundsLeadingEdge: isLeadingCollapsed,
            roundsTrailingEdge: isTrailingCollapsed
        )

        bridgePanel.render(view, frame: frame, acceptsMouseEvents: false)
    }

    private func visibleSummaries(for side: AgentSide) -> [AgentSummary] {
        store.summaries.filter {
            $0.side == side && $0.status != .idle
        }
    }

    private func render(
        panel: OverlayPanel,
        side: AgentSide,
        summaries: [AgentSummary],
        isCollapsed: Bool,
        on screen: NSScreen
    ) {
        let frame = OverlayGeometry.frame(
            for: side,
            itemCount: max(1, summaries.count),
            on: screen
        )

        let view = SideOverlayView(
            side: side,
            summaries: summaries,
            showsPlaceholder: !isCollapsed,
            isCollapsed: isCollapsed,
            panelWidth: frame.width,
            collapsedWidth: OverlayGeometry.collapsedWidth,
            onAgentTap: { [weak self] summary in
                self?.handleTap(for: summary, on: screen)
            },
            onOpenPanel: { [weak self] in
                self?.controlPanel.toggle(on: screen)
            },
            onRefresh: { [weak self] in
                self?.store.refresh()
            },
            onRevealStatusFile: { [weak self] in
                self?.revealStatusFile()
            },
            onSampleData: { [weak self] in
                self?.store.writeSampleData()
            },
            onClearData: { [weak self] in
                self?.store.clearSnapshot()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )

        panel.render(
            view,
            frame: frame,
            acceptsMouseEvents: !isCollapsed
        )
    }

    private func handleTap(
        for summary: AgentSummary,
        on screen: NSScreen
    ) {
        if summary.status == .success {
            store.markCompletedSeen(for: summary.agent)
        }

        if let url = summary.primaryTask?.actionURL {
            NSWorkspace.shared.open(url)
            return
        }

        controlPanel.toggle(on: screen)
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first {
            let left = $0.auxiliaryTopLeftArea ?? .zero
            let right = $0.auxiliaryTopRightArea ?? .zero
            return !left.isEmpty && !right.isEmpty
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func revealStatusFile() {
        do {
            let url = try store.ensureStatusFile()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.refresh()
        }
    }
}

private enum OverlayGeometry {
    static let itemWidth: CGFloat = 50
    static let itemSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12
    static let minimumWidth: CGFloat = 86
    static let fallbackGap: CGFloat = 188
    static let fallbackWidth: CGFloat = 240
    static let fallbackHeight: CGFloat = 38
    static let collapsedWidth: CGFloat = 0
    static let seamOverlap: CGFloat = 1

    static func width(for itemCount: Int) -> CGFloat {
        let itemsWidth = CGFloat(itemCount) * itemWidth
        let gapsWidth = CGFloat(max(0, itemCount - 1)) * itemSpacing
        return max(minimumWidth, horizontalPadding * 2 + itemsWidth + gapsWidth)
    }

    static func frame(
        for side: AgentSide,
        itemCount: Int,
        on screen: NSScreen
    ) -> CGRect {
        let targetArea = area(for: side, on: screen)
        let panelWidth = width(for: itemCount)
        let panelHeight = targetArea.height > 0 ? targetArea.height : fallbackHeight
        let y = targetArea.maxY - panelHeight
        let x = side == .leading
            ? targetArea.maxX - panelWidth + seamOverlap
            : targetArea.minX - seamOverlap

        return CGRect(
            x: x,
            y: y,
            width: panelWidth,
            height: panelHeight
        )
    }

    static func bridgeFrame(
        on screen: NSScreen,
        isLeadingCollapsed: Bool,
        isTrailingCollapsed: Bool
    ) -> CGRect {
        let left = area(for: .leading, on: screen)
        let right = area(for: .trailing, on: screen)
        let panelHeight = max(left.height, right.height, fallbackHeight)
        let collapsedInset = min(panelHeight * 0.14, 5)
        let minX = left.maxX - seamOverlap + (isLeadingCollapsed ? collapsedInset : 0)
        let maxX = right.minX + seamOverlap - (isTrailingCollapsed ? collapsedInset : 0)
        let y = max(left.maxY, right.maxY) - panelHeight

        return CGRect(
            x: minX,
            y: y,
            width: max(0, maxX - minX),
            height: panelHeight
        )
    }

    private static func area(
        for side: AgentSide,
        on screen: NSScreen
    ) -> CGRect {
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero

        if !left.isEmpty, !right.isEmpty {
            return side == .leading ? left : right
        }

        let y = screen.frame.maxY - fallbackHeight

        if side == .leading {
            return CGRect(
                x: screen.frame.midX - fallbackGap / 2 - fallbackWidth,
                y: y,
                width: fallbackWidth,
                height: fallbackHeight
            )
        }

        return CGRect(
            x: screen.frame.midX + fallbackGap / 2,
            y: y,
            width: fallbackWidth,
            height: fallbackHeight
        )
    }
}

private final class OverlayPanel: NSPanel {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let interactive: Bool

    init(interactive: Bool = true) {
        self.interactive = interactive
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hidesOnDeactivate = false
        worksWhenModal = true
        ignoresMouseEvents = !interactive
        contentView = hostingView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func render<Content: View>(
        _ view: Content,
        frame: CGRect,
        acceptsMouseEvents: Bool? = nil
    ) {
        hostingView.rootView = AnyView(view)
        ignoresMouseEvents = !(acceptsMouseEvents ?? interactive)
        alphaValue = 1
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}
