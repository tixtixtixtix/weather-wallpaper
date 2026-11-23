import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let windowPresence = WindowPresenceController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Desktop windows are "visible windows", so don't use `flag` to decide whether to reopen.
        model.showMainWindow?()
        if let window = sender.windows.first(where: { $0.canBecomeMain && $0.title == "Weather Wallpaper" }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@main
struct WeatherWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Weather Wallpaper", id: "main") {
            MainView(model: delegate.model)
                .background(MainWindowPresence(controller: delegate.windowPresence))
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1060, height: 740)
        .windowResizability(.contentMinSize)
        .commands { WallpaperCommands() }

        Settings {
            PreferencesView(model: delegate.model)
        }

        MenuBarExtra {
            WeatherMenuView(model: delegate.model)
        } label: {
            WeatherMenuLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct WallpaperCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Weather Wallpaper") { WindowPresenceController.showMainWindow(using: openWindow) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
