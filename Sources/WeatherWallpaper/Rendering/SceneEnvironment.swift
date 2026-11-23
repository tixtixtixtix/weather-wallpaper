import Foundation
import WeatherCore

struct RenderPolicy: Equatable {
    var framesPerSecond = 30
    var maximumDimension: CGFloat = 2560
    var particleScale: Float = 1
    var animated = true
    var suspended = false
    var permitsLightning = true
    var bloom = true
    var bloomDownsample = 4
    // Retain the previous renderer for controlled A/B comparisons, not as a battery downgrade.
    var volumetricClouds = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_LEGACY_SKY"] != "1"
    var cloudDownsample = 2
    var cloudSteps = 48
    var meteorSpeed: Float = 1
    var permitsMeteors = true
    var widgetRainAreas: [WidgetRainArea] = []
    var showsWidgetGuide = false
    var notchHaze = NotchHazeConfiguration()
    // The full azimuth panorama still distorts cloud silhouettes; keep it a review prototype.
    var panoramicClouds = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_PANORAMA_REVIEW"] == "1"
}

/// Shared by all displays. Weather and solar calculations are updated outside the frame loop.
@MainActor
final class SceneEnvironment {
    private var transition: SceneTransition
    private var targetScene: SceneState
    private var listeners: [UUID: () -> Void] = [:]
    private var clockAnchor = ProcessInfo.processInfo.systemUptime
    private var clockElapsed: TimeInterval = 0
    private var lastWindSample: TimeInterval = 0
    private var windTravel: Double = 0
    private var lightning = LightningTimeline()
    private var solarMotion: (start: SolarState, end: SolarState, began: TimeInterval, duration: TimeInterval)?
    private(set) var policy = RenderPolicy()
    let renderLabel: String

    init(scene: SceneState, renderLabel: String = "Weather sky") {
        self.renderLabel = renderLabel
        targetScene = scene
        transition = SceneTransition(scene: scene, at: ProcessInfo.processInfo.systemUptime)
    }

    func scene(at time: TimeInterval) -> SceneState {
        var scene = transition.value(at: time)
        if let solarMotion {
            scene.solar = .interpolate(from: solarMotion.start, to: solarMotion.end,
                                       progress: policy.animated ? Float((time - solarMotion.began) / solarMotion.duration) : 0)
        }
        return scene
    }

    func setSolarMotion(from start: SolarState, to end: SolarState, at time: TimeInterval, duration: TimeInterval = 120) {
        solarMotion = (start, end, time, max(1, duration))
    }

    func clearSolarMotion() { solarMotion = nil }

    func animationTime(at time: TimeInterval) -> TimeInterval { motionSeconds(at: time) }

    func isTransitioning(at time: TimeInterval) -> Bool { transition.isActive(at: time) }

    private func motionSeconds(at time: TimeInterval) -> TimeInterval {
        clockElapsed + (policy.animated && !policy.suspended ? time - clockAnchor : 0)
    }

    func lightningSample(at time: TimeInterval, scene: SceneState) -> LightningSample {
        lightning.sample(at: motionSeconds(at: time), storm: scene.storm,
                         enabled: policy.animated && !policy.suspended && policy.permitsLightning)
    }

    /// Integrate velocity rather than multiplying current wind by app uptime. Otherwise a
    /// weather change hours into playback would make clouds and particles jump across the sky.
    func windOffset(at time: TimeInterval, scene: SceneState) -> Double {
        let seconds = motionSeconds(at: time)
        let elapsed = min(1, max(0, seconds - lastWindSample))
        lastWindSample = seconds
        windTravel += elapsed * Double(scene.wind * scene.windDirection)
        return windTravel
    }

    func setScene(_ scene: SceneState, immediate: Bool = false) {
        guard immediate || scene != targetScene else { return }
        targetScene = scene
        transition.setTarget(scene, at: ProcessInfo.processInfo.systemUptime,
                             immediate: immediate || !policy.animated)
        notify()
    }

    func setPolicy(_ newPolicy: RenderPolicy) {
        guard newPolicy != policy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        clockElapsed = motionSeconds(at: now)
        clockAnchor = now
        policy = newPolicy
        notify()
    }

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }

    private func notify() {
        for callback in listeners.values { callback() }
    }
}
