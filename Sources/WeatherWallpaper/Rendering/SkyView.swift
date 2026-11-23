import MetalKit
import SwiftUI

@MainActor
final class SkyMetalView: MTKView {
    var renderer: WeatherRenderer?
    private var windowObservation: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        if let window {
            windowObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.renderer?.refreshPolicy() }
            }
        }
        renderer?.refreshPolicy()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.refreshPolicy()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer?.refreshPolicy()
    }

    override func viewDidHide() {
        super.viewDidHide()
        renderer?.refreshPolicy()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        renderer?.refreshPolicy()
    }

    func stop() {
        renderer?.stop()
        renderer = nil
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
    }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }
}

struct SkyView: NSViewRepresentable {
    let environment: SceneEnvironment
    var onError: (Error) -> Void

    func makeNSView(context: Context) -> SkyMetalView {
        let view = SkyMetalView(frame: .zero)
        view.setAccessibilityElement(false)
        do { view.renderer = try WeatherRenderer(view: view, environment: environment) }
        catch { DispatchQueue.main.async { onError(error) } }
        return view
    }

    func updateNSView(_ view: SkyMetalView, context: Context) {}

    static func dismantleNSView(_ view: SkyMetalView, coordinator: ()) { view.stop() }
}
