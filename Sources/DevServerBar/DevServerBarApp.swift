import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct NotchAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AgentStore
    private let overlayController: OverlayController

    init() {
        let store = AgentStore()
        _store = StateObject(wrappedValue: store)
        overlayController = OverlayController(store: store)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
