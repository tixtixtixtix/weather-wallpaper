import AppKit

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopController {
    private struct Surface {
        let window: NSWindow
        let view: SkyMetalView
    }
    private let environment: SceneEnvironment
    private let onError: (Error) -> Void
    private var surfaces: [Surface] = []
    var isRunning: Bool { !surfaces.isEmpty }

    init(environment: SceneEnvironment, onError: @escaping (Error) -> Void) {
        self.environment = environment
        self.onError = onError
    }

    func start() {
        guard surfaces.isEmpty else { return }
        do {
            // Fail before opening any windows if Metal is unavailable.
            _ = try MetalResources.shared.get()
            for screen in NSScreen.screens {
                let window = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false, screen: screen)
                window.title = "Weather Wallpaper — \(screen.localizedName)"
                window.setFrame(screen.frame, display: false)
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.ignoresMouseEvents = true
                window.isOpaque = true
                window.backgroundColor = .black
                window.hasShadow = false
                window.hidesOnDeactivate = false
                window.isReleasedWhenClosed = false
                window.isExcludedFromWindowsMenu = true
                window.animationBehavior = .none
                let view = SkyMetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.autoresizingMask = [.width, .height]
                view.setAccessibilityElement(false)
                view.renderer = try WeatherRenderer(view: view, environment: environment, moonlitHaze: true)
                window.contentView = view
                surfaces.append(Surface(window: window, view: view))
                window.orderBack(nil)
                view.renderer?.refreshPolicy()
            }
        } catch {
            stop()
            onError(error)
        }
    }

    func stop() {
        for surface in surfaces {
            surface.view.stop()
            surface.window.orderOut(nil)
            surface.window.close()
        }
        surfaces.removeAll()
    }

    func rebuildIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }
}
