import AppKit
import SwiftUI

/// Only the main window controls Dock presence; desktop surfaces stay open in menu-bar mode.
@MainActor
final class WindowPresenceController: NSObject {
    private weak var mainWindow: NSWindow?
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.setPolicy = setPolicy
        super.init()
    }

    func track(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        mainWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowClosed),
                                               name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowShown),
                                               name: NSWindow.didBecomeMainNotification, object: window)
        setPolicy(.regular)
    }

    @objc private func mainWindowClosed(_ notification: Notification) { setPolicy(.accessory) }
    @objc private func mainWindowShown(_ notification: Notification) { setPolicy(.regular) }

    static func showMainWindow(using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MainWindowPresence: NSViewRepresentable {
    let controller: WindowPresenceController

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        weak var controller: WindowPresenceController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controller?.track(window) }
        }
    }
}
