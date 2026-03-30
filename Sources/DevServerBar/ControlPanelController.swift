import AppKit
import SwiftUI

@MainActor
final class ControlPanelController {
    private let panel: NSPanel

    init(store: AgentStore) {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "Notch Agents"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: ControlPanelView(
                store: store,
                onMarkCompletedSeen: { agent in
                    store.markCompletedSeen(for: agent)
                }
            )
        )
    }

    func toggle(on screen: NSScreen?) {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        show(on: screen)
    }

    private func show(on screen: NSScreen?) {
        positionPanel(on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanel(on screen: NSScreen?) {
        guard let screen else {
            panel.center()
            return
        }

        let originY: CGFloat
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero

        if !left.isEmpty, !right.isEmpty {
            originY = min(left.minY, right.minY) - panel.frame.height - 12
        } else {
            originY = screen.visibleFrame.maxY - panel.frame.height - 18
        }

        let originX = screen.frame.midX - panel.frame.width / 2
        panel.setFrameOrigin(CGPoint(x: originX, y: originY))
    }
}
